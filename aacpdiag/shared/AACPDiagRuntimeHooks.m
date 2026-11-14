#import "AACPDiag.h"

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>

#import <dlfcn.h>
#import <errno.h>
#import <pthread.h>
#import <stdint.h>
#import <string.h>
#import <sys/socket.h>
#import <time.h>
#import <unistd.h>

#define AAP_DIAG_AF_BLUETOOTH 32
#define AAP_DIAG_AACP_PSM 0x1001
#define AAP_DIAG_TRACKED_FDS 64
#define AAP_DIAG_HOOK_RECORDS 512

#ifndef AACPDIAG_TRANSPORT_SAFE_MODE
#define AACPDIAG_TRANSPORT_SAFE_MODE 0
#endif

typedef int (*AAPDiagSocketFunction)(int, int, int);
typedef int (*AAPDiagConnectFunction)(int, const struct sockaddr *, socklen_t);
typedef ssize_t (*AAPDiagSendFunction)(int, const void *, size_t, int);
typedef ssize_t (*AAPDiagRecvFunction)(int, void *, size_t, int);
typedef ssize_t (*AAPDiagRecvFromFunction)(int,
	void *,
	size_t,
	int,
	struct sockaddr *,
	socklen_t *);
typedef ssize_t (*AAPDiagReadFunction)(int, void *, size_t);
typedef int (*AAPDiagCloseFunction)(int);

static AAPDiagSocketFunction AAPDiagOriginalSocket;
static AAPDiagConnectFunction AAPDiagOriginalConnect;
static AAPDiagSendFunction AAPDiagOriginalSend;
static AAPDiagRecvFunction AAPDiagOriginalRecv;
static AAPDiagRecvFromFunction AAPDiagOriginalRecvFrom;
static AAPDiagReadFunction AAPDiagOriginalRead;
static AAPDiagCloseFunction AAPDiagOriginalClose;

typedef struct {
	int fd;
	BOOL bluetooth;
	BOOL aacp;
	char address[18];
	BOOL connected;
	uint64_t connectedAt;
	uint64_t lastTX;
	uint64_t lastRX;
} AAPDiagSocketState;

static AAPDiagSocketState AAPDiagSockets[AAP_DIAG_TRACKED_FDS];
static pthread_mutex_t AAPDiagSocketLock = PTHREAD_MUTEX_INITIALIZER;
static dispatch_queue_t AAPDiagSocketLogQueue;

#define AAP_DIAG_RX_FRAMES 64
#define AAP_DIAG_RX_BYTES 256
#define AAP_DIAG_ACTIVE_FD_WINDOW_US 30000000ULL

typedef struct {
	int fd;
	uint64_t timestamp;
	char address[18];
	size_t length;
	uint8_t bytes[AAP_DIAG_RX_BYTES];
} AAPDiagRXFrame;

static AAPDiagRXFrame AAPDiagRXFrames[AAP_DIAG_RX_FRAMES];
static size_t AAPDiagRXFrameCursor;
static size_t AAPDiagRXFrameCount;
static pthread_mutex_t AAPDiagRXLock = PTHREAD_MUTEX_INITIALIZER;

typedef uintptr_t (*AAPDiagGenericMethodOriginal)(id,
	SEL,
	uintptr_t,
	uintptr_t,
	uintptr_t,
	uintptr_t);

typedef struct {
	__unsafe_unretained Class cls;
	SEL selector;
	IMP original;
	BOOL failed;
	char *types;
	char *className;
	char *selectorName;
} AAPDiagMethodRecord;

static AAPDiagMethodRecord AAPDiagMethodRecords[AAP_DIAG_HOOK_RECORDS];
static size_t AAPDiagMethodRecordCount;
static pthread_mutex_t AAPDiagMethodLock = PTHREAD_MUTEX_INITIALIZER;
static __thread int AAPDiagMethodHookDepth;
static NSMutableSet<NSString *> *AAPDiagInventoriedClasses;
static pthread_mutex_t AAPDiagInventoryLock = PTHREAD_MUTEX_INITIALIZER;

static const char *const AAPDiagWatchedClasses[] = {
	"BluetoothDevice",
	"BluetoothManager",
	"PAAccessoryManager",
	"BTSDeviceConfigController",
	"BTSDeviceClassic",
	"BTSDevice",
	"AudioAccessoryManager",
};

static const char *const AAPDiagCoreSelectors[] = {
	"address",
	"productId",
	"pairedDevices",
	"connectedDevices",
	"connectedDeviceCount",
	"deviceForAddress:",
	"sendUpdateToAccessory",
	"peripherals",
	"uuidToAddress",
	"peripheral:didDiscoverCharacteristicsForService:error:",
	"peripheral:didUpdateValueForCharacteristic:error:",
	"peripheral:didModifyServices:",
};

static uint64_t AAPDiagMonotonicMicroseconds(void) {
	struct timespec value = {0};
	clock_gettime(CLOCK_MONOTONIC, &value);
	return (uint64_t)value.tv_sec * 1000000ULL +
		(uint64_t)value.tv_nsec / 1000ULL;
}

static void AAPDiagSocketLog(NSString *format, ...) {
	if (!AAPDiagSocketLogQueue) {
		return;
	}
	va_list arguments;
	va_start(arguments, format);
	NSString *message = [[NSString alloc]
		initWithFormat:format
		arguments:arguments];
	va_end(arguments);
	if (!message.length) {
		return;
	}
	dispatch_async(AAPDiagSocketLogQueue, ^{
		AAPDiagLog(@"%@", message);
	});
}

static NSString *AAPDiagSocketHex(const void *bytes, size_t length) {
	if (!bytes || !length) {
		return @"";
	}
	size_t visible = MIN(length, (size_t)512);
	const uint8_t *data = bytes;
	NSMutableString *result = [NSMutableString
		stringWithCapacity:visible * 3];
	for (size_t index = 0; index < visible; index++) {
		[result appendFormat:index ? @" %02X" : @"%02X", data[index]];
	}
	if (visible < length) {
		[result appendFormat:@" ...(%lu bytes)", (unsigned long)length];
	}
	return result;
}

static int AAPDiagFindSocketLocked(int fd) {
	for (int index = 0; index < AAP_DIAG_TRACKED_FDS; index++) {
		if (AAPDiagSockets[index].bluetooth &&
			AAPDiagSockets[index].fd == fd) {
			return index;
		}
	}
	return -1;
}

static void AAPDiagSetSocketAddressLocked(AAPDiagSocketState *state,
	const uint8_t address[6]) {
	if (!state || !address) {
		return;
	}
	snprintf(state->address,
		sizeof(state->address),
		"%02X:%02X:%02X:%02X:%02X:%02X",
		address[0],
		address[1],
		address[2],
		address[3],
		address[4],
		address[5]);
}

static BOOL AAPDiagExtractAddress(const struct sockaddr *address,
	socklen_t length,
	NSString *layout,
	uint8_t output[6]) {
	if (!address || !output) {
		return NO;
	}
	const uint8_t *bytes = (const uint8_t *)address;
	if ([layout isEqualToString:@"psm_offset_8"]) {
		if (length < 8) {
			return NO;
		}
		memcpy(output, bytes + 2, 6);
		return YES;
	}
	if (length >= 10) {
		memcpy(output, bytes + 4, 6);
		return YES;
	}
	return NO;
}

static void AAPDiagTrackBluetoothSocket(int fd) {
	if (fd < 0) {
		return;
	}
	pthread_mutex_lock(&AAPDiagSocketLock);
	int slot = AAPDiagFindSocketLocked(fd);
	if (slot < 0) {
		for (int index = 0; index < AAP_DIAG_TRACKED_FDS; index++) {
			if (!AAPDiagSockets[index].bluetooth) {
				slot = index;
				break;
			}
		}
	}
	if (slot >= 0) {
		AAPDiagSockets[slot].fd = fd;
		AAPDiagSockets[slot].bluetooth = YES;
		AAPDiagSockets[slot].aacp = NO;
		AAPDiagSockets[slot].address[0] = '\0';
		AAPDiagSockets[slot].connected = NO;
		AAPDiagSockets[slot].connectedAt = 0;
		AAPDiagSockets[slot].lastTX = 0;
		AAPDiagSockets[slot].lastRX = 0;
	}
	pthread_mutex_unlock(&AAPDiagSocketLock);
}

static BOOL AAPDiagSocketIsAACP(int fd) {
	BOOL result = NO;
	pthread_mutex_lock(&AAPDiagSocketLock);
	int slot = AAPDiagFindSocketLocked(fd);
	if (slot >= 0) {
		result = AAPDiagSockets[slot].aacp;
	}
	pthread_mutex_unlock(&AAPDiagSocketLock);
	return result;
}

static void AAPDiagPromoteSocketToAACP(int fd) {
	pthread_mutex_lock(&AAPDiagSocketLock);
	int slot = AAPDiagFindSocketLocked(fd);
	if (slot >= 0) {
		AAPDiagSockets[slot].aacp = YES;
	}
	pthread_mutex_unlock(&AAPDiagSocketLock);
}

static void AAPDiagRecordAACPRX(int fd,
	const void *bytes,
	size_t length,
	uint64_t timestamp) {
	if (!bytes || !length) {
		return;
	}
	NSString *address = nil;
	char addressBuffer[18] = {0};
	pthread_mutex_lock(&AAPDiagSocketLock);
	int slot = AAPDiagFindSocketLocked(fd);
	if (slot < 0 || !AAPDiagSockets[slot].aacp) {
		pthread_mutex_unlock(&AAPDiagSocketLock);
		return;
	}
	AAPDiagSockets[slot].lastRX = timestamp;
	strlcpy(addressBuffer,
		AAPDiagSockets[slot].address,
		sizeof(addressBuffer));
	pthread_mutex_unlock(&AAPDiagSocketLock);

	pthread_mutex_lock(&AAPDiagRXLock);
	AAPDiagRXFrame *frame =
		&AAPDiagRXFrames[AAPDiagRXFrameCursor % AAP_DIAG_RX_FRAMES];
	memset(frame, 0, sizeof(*frame));
	frame->fd = fd;
	frame->timestamp = timestamp;
	frame->length = MIN(length, (size_t)AAP_DIAG_RX_BYTES);
	memcpy(frame->bytes, bytes, frame->length);
	strlcpy(frame->address, addressBuffer, sizeof(frame->address));
	AAPDiagRXFrameCursor++;
	if (AAPDiagRXFrameCount < AAP_DIAG_RX_FRAMES) {
		AAPDiagRXFrameCount++;
	}
	pthread_mutex_unlock(&AAPDiagRXLock);
	address = [NSString stringWithUTF8String:addressBuffer];
	AAPDiagSocketLog(
		@"aacp_socket_rx fd=%d len=%zu address=%@ bytes=%@",
		fd,
		length,
		address.length ? address : @"unknown",
		AAPDiagSocketHex(bytes, length));
}

static void AAPDiagRemoveRXHistoryLocked(int fd) {
	for (int index = 0; index < AAP_DIAG_RX_FRAMES; index++) {
		if (AAPDiagRXFrames[index].fd == fd) {
			memset(&AAPDiagRXFrames[index],
				0,
				sizeof(AAPDiagRXFrames[index]));
		}
	}
}

static BOOL AAPDiagRemoveSocket(int fd, BOOL *wasAACP) {
	BOOL wasTracked = NO;
	if (wasAACP) {
		*wasAACP = NO;
	}
	pthread_mutex_lock(&AAPDiagSocketLock);
	int slot = AAPDiagFindSocketLocked(fd);
	if (slot >= 0) {
		wasTracked = AAPDiagSockets[slot].bluetooth;
		if (wasAACP) {
			*wasAACP = AAPDiagSockets[slot].aacp;
		}
		AAPDiagSockets[slot] = (AAPDiagSocketState){0};
	}
	pthread_mutex_unlock(&AAPDiagSocketLock);
	if (wasAACP) {
		pthread_mutex_lock(&AAPDiagRXLock);
		AAPDiagRemoveRXHistoryLocked(fd);
		pthread_mutex_unlock(&AAPDiagRXLock);
	}
	return wasTracked;
}

static uint16_t AAPDiagReadPSM(const struct sockaddr *address,
	socklen_t length,
	NSString **layout) {
	if (!address || length < 4) {
		return 0;
	}
	const uint8_t *bytes = (const uint8_t *)address;
	uint16_t first = (uint16_t)bytes[2] | ((uint16_t)bytes[3] << 8);
	uint16_t second = length >= 8
		? (uint16_t)bytes[6] | ((uint16_t)bytes[7] << 8)
		: 0;
	uint16_t third = length >= 10
		? (uint16_t)bytes[8] | ((uint16_t)bytes[9] << 8)
		: 0;
	if (first == AAP_DIAG_AACP_PSM) {
		if (layout) {
			*layout = @"psm_offset_2";
		}
		return first;
	}
	if (second == AAP_DIAG_AACP_PSM) {
		if (layout) {
			*layout = @"psm_offset_6";
		}
		return second;
	}
	if (third == AAP_DIAG_AACP_PSM) {
		if (layout) {
			*layout = @"psm_offset_8";
		}
		return third;
	}
	if (layout) {
		*layout = @"unmatched";
	}
	return first ?: (second ?: third);
}

static int AAPDiagSocketHook(int domain, int type, int protocol) {
	int result = AAPDiagOriginalSocket
		? AAPDiagOriginalSocket(domain, type, protocol)
		: socket(domain, type, protocol);
	int savedErrno = errno;
	if (domain == AAP_DIAG_AF_BLUETOOTH) {
		AAPDiagTrackBluetoothSocket(result);
		AAPDiagSocketLog(
			@"aacp_socket fd=%d domain=%d type=%d protocol=%d errno=%d(%s)",
			result,
			domain,
			type,
			protocol,
			savedErrno,
			strerror(savedErrno));
	}
	errno = savedErrno;
	return result;
}

static int AAPDiagConnectHook(int fd,
	const struct sockaddr *address,
	socklen_t length) {
	int result = AAPDiagOriginalConnect
		? AAPDiagOriginalConnect(fd, address, length)
		: connect(fd, address, length);
	int savedErrno = errno;
	NSString *layout = nil;
	uint16_t psm = AAPDiagReadPSM(address, length, &layout);
	BOOL matched = psm == AAP_DIAG_AACP_PSM;
	if (matched) {
		AAPDiagPromoteSocketToAACP(fd);
	}
	BOOL connected = result == 0 ||
		savedErrno == EINPROGRESS ||
		savedErrno == EALREADY;
	if (matched && connected) {
		uint8_t mac[6] = {0};
		if (AAPDiagExtractAddress(address, length, layout, mac)) {
			pthread_mutex_lock(&AAPDiagSocketLock);
			int slot = AAPDiagFindSocketLocked(fd);
			if (slot >= 0) {
				AAPDiagSetSocketAddressLocked(
					&AAPDiagSockets[slot],
					mac);
				AAPDiagSockets[slot].connected = YES;
				AAPDiagSockets[slot].connectedAt =
					AAPDiagMonotonicMicroseconds();
			}
			pthread_mutex_unlock(&AAPDiagSocketLock);
		}
	}
	BOOL bluetoothFamily = address && length >= 2 &&
		(((const uint8_t *)address)[1] == AAP_DIAG_AF_BLUETOOTH ||
		 (((const uint8_t *)address)[0] == AAP_DIAG_AF_BLUETOOTH &&
		  ((const uint8_t *)address)[1] == 0));
	if (matched || (result == 0 && bluetoothFamily) ||
		(savedErrno == EINPROGRESS || savedErrno == EALREADY)) {
		AAPDiagSocketLog(
			@"aacp_socket_connect fd=%d result=%d errno=%d(%s) "
			@"psm=0x%04X layout=%@ aacp=%d sockaddr=%@",
			fd,
			result,
			savedErrno,
			strerror(savedErrno),
			psm,
			layout ?: @"unknown",
			matched ? 1 : 0,
			AAPDiagSocketHex(address, length));
	}
	errno = savedErrno;
	return result;
}

static ssize_t AAPDiagSendHook(int fd,
	const void *bytes,
	size_t length,
	int flags) {
	ssize_t result = AAPDiagOriginalSend
		? AAPDiagOriginalSend(fd, bytes, length, flags)
		: send(fd, bytes, length, flags);
	int savedErrno = errno;
	if (AAPDiagSocketIsAACP(fd)) {
		if (result > 0) {
			pthread_mutex_lock(&AAPDiagSocketLock);
			int slot = AAPDiagFindSocketLocked(fd);
			if (slot >= 0) {
				AAPDiagSockets[slot].lastTX =
					AAPDiagMonotonicMicroseconds();
			}
			pthread_mutex_unlock(&AAPDiagSocketLock);
		}
		AAPDiagSocketLog(
			@"aacp_socket_tx fd=%d result=%ld errno=%d(%s) bytes=%@",
			fd,
			(long)result,
			savedErrno,
			strerror(savedErrno),
			result > 0
				? AAPDiagSocketHex(bytes, (size_t)result)
				: @"");
	}
	errno = savedErrno;
	return result;
}

static ssize_t AAPDiagRecvHook(int fd,
	void *bytes,
	size_t length,
	int flags) {
	ssize_t result = AAPDiagOriginalRecv
		? AAPDiagOriginalRecv(fd, bytes, length, flags)
		: recv(fd, bytes, length, flags);
	int savedErrno = errno;
	if (AAPDiagSocketIsAACP(fd)) {
		if (result > 0) {
			AAPDiagRecordAACPRX(fd,
				bytes,
				(size_t)result,
				AAPDiagMonotonicMicroseconds());
		}
		AAPDiagSocketLog(
			@"aacp_socket_rx fd=%d result=%ld errno=%d(%s) bytes=%@",
			fd,
			(long)result,
			savedErrno,
			strerror(savedErrno),
			result > 0
				? AAPDiagSocketHex(bytes, (size_t)result)
				: @"");
	}
	errno = savedErrno;
	return result;
}

static ssize_t AAPDiagRecvFromHook(int fd,
	void *bytes,
	size_t length,
	int flags,
	struct sockaddr *address,
	socklen_t *addressLength) {
	ssize_t result = AAPDiagOriginalRecvFrom
		? AAPDiagOriginalRecvFrom(fd,
			bytes,
			length,
			flags,
			address,
			addressLength)
		: recvfrom(fd, bytes, length, flags, address, addressLength);
	int savedErrno = errno;
	if (AAPDiagSocketIsAACP(fd)) {
		if (result > 0) {
			AAPDiagRecordAACPRX(fd,
				bytes,
				(size_t)result,
				AAPDiagMonotonicMicroseconds());
		}
		AAPDiagSocketLog(
			@"aacp_socket_recvfrom fd=%d result=%ld errno=%d(%s) bytes=%@",
			fd,
			(long)result,
			savedErrno,
			strerror(savedErrno),
			result > 0
				? AAPDiagSocketHex(bytes, (size_t)result)
				: @"");
	}
	errno = savedErrno;
	return result;
}

static ssize_t AAPDiagReadHook(int fd, void *bytes, size_t length) {
	ssize_t result = AAPDiagOriginalRead
		? AAPDiagOriginalRead(fd, bytes, length)
		: read(fd, bytes, length);
	int savedErrno = errno;
	if (AAPDiagSocketIsAACP(fd)) {
		if (result > 0) {
			AAPDiagRecordAACPRX(fd,
				bytes,
				(size_t)result,
				AAPDiagMonotonicMicroseconds());
		}
		AAPDiagSocketLog(
			@"aacp_socket_read fd=%d result=%ld errno=%d(%s) bytes=%@",
			fd,
			(long)result,
			savedErrno,
			strerror(savedErrno),
			result > 0
				? AAPDiagSocketHex(bytes, (size_t)result)
				: @"");
	}
	errno = savedErrno;
	return result;
}

static int AAPDiagCloseHook(int fd) {
	BOOL aacp = NO;
	BOOL tracked = AAPDiagRemoveSocket(fd, &aacp);
	int result = AAPDiagOriginalClose
		? AAPDiagOriginalClose(fd)
		: close(fd);
	int savedErrno = errno;
	if (tracked && aacp) {
		AAPDiagSocketLog(
			@"aacp_socket_close fd=%d result=%d errno=%d(%s)",
			fd,
			result,
			savedErrno,
			strerror(savedErrno));
	}
	errno = savedErrno;
	return result;
}

static int AAPDiagActiveAACPDescriptorLocked(
	NSString *address,
	BOOL *addressMatched,
	BOOL *fallbackUnique) {
	uint64_t now = AAPDiagMonotonicMicroseconds();
	NSString *normalized = AAPDiagNormalizeAddress(address);
	int best = -1;
	uint64_t bestFreshness = 0;
	int unique = -1;
	int uniqueCount = 0;
	for (int index = 0; index < AAP_DIAG_TRACKED_FDS; index++) {
		AAPDiagSocketState *state = &AAPDiagSockets[index];
		if (!state->bluetooth || !state->aacp || !state->connected ||
			state->fd < 0) {
			continue;
		}
		uint64_t freshness = MAX(state->lastTX,
			MAX(state->lastRX, state->connectedAt));
		if (!freshness ||
			now > freshness + AAP_DIAG_ACTIVE_FD_WINDOW_US) {
			continue;
		}
		unique = state->fd;
		uniqueCount++;
		if (normalized.length && state->address[0] &&
			[normalized isEqualToString:
				[NSString stringWithUTF8String:state->address]]) {
			if (best < 0 || freshness > bestFreshness) {
				best = state->fd;
				bestFreshness = freshness;
			}
		}
	}
	if (addressMatched) {
		*addressMatched = best >= 0;
	}
	if (fallbackUnique) {
		*fallbackUnique = NO;
	}
	if (best >= 0) {
		return best;
	}
	if (uniqueCount == 1) {
		if (fallbackUnique) {
			*fallbackUnique = YES;
		}
		return unique;
	}
	return -1;
}

int AAPDiagCopyActiveAACPDescriptorWithMatch(
	NSString *address,
	BOOL *addressMatched) {
	if (addressMatched) {
		*addressMatched = NO;
	}
	BOOL fallbackUnique = NO;
	pthread_mutex_lock(&AAPDiagSocketLock);
	int fd = AAPDiagActiveAACPDescriptorLocked(address,
		addressMatched,
		&fallbackUnique);
	pthread_mutex_unlock(&AAPDiagSocketLock);
	if (fd >= 0) {
		AAPDiagSocketLog(
			@"aacp_active_fd fd=%d address=%@ exact=%d fallback_unique=%d",
			fd,
			address ?: @"nil",
			addressMatched ? *addressMatched : -1,
			fallbackUnique);
	}
	return fd;
}

NSArray<NSDictionary<NSString *, id> *> *
	AAPDiagCopyAACPRXFramesForDescriptor(
		int fd,
		uint64_t sinceMicroseconds) {
	if (fd < 0) {
		return @[];
	}
	pthread_mutex_lock(&AAPDiagRXLock);
	NSMutableArray<NSDictionary<NSString *, id> *> *frames =
		[NSMutableArray array];
	for (int index = 0; index < AAP_DIAG_RX_FRAMES; index++) {
		AAPDiagRXFrame *frame = &AAPDiagRXFrames[index];
		if (frame->fd != fd || !frame->timestamp ||
			frame->timestamp < sinceMicroseconds || !frame->length) {
			continue;
		}
		NSData *data = [NSData dataWithBytes:frame->bytes
			length:frame->length];
		[frames addObject:@{
			@"fd": @(frame->fd),
			@"address": [NSString stringWithUTF8String:frame->address]
				?: @"",
			@"timestamp_us": @(frame->timestamp),
			@"length": @(frame->length),
			@"hex": AAPDiagHex(data),
			@"data": data,
		}];
	}
	pthread_mutex_unlock(&AAPDiagRXLock);
	[frames sortUsingComparator:^NSComparisonResult(
		NSDictionary<NSString *, id> *left,
		NSDictionary<NSString *, id> *right) {
		uint64_t leftTimestamp = [left[@"timestamp_us"] unsignedLongLongValue];
		uint64_t rightTimestamp = [right[@"timestamp_us"] unsignedLongLongValue];
		if (leftTimestamp < rightTimestamp) {
			return NSOrderedAscending;
		}
		if (leftTimestamp > rightTimestamp) {
			return NSOrderedDescending;
		}
		return NSOrderedSame;
	}];
	return frames;
}

static BOOL AAPDiagTypeIsSupported(const char *type, BOOL allowVoid) {
	if (!type) {
		return NO;
	}
	while (*type && strchr("rnNoORV", *type)) {
		type++;
	}
	if (!*type) {
		return NO;
	}
	if (allowVoid && *type == 'v') {
		return YES;
	}
	return strchr("@#:cCsSiIlLqQB*^?", *type) != NULL;
}

static BOOL AAPDiagMethodSignatureIsSupported(NSMethodSignature *signature) {
	if (!signature) {
		return NO;
	}
	const char *returnType = signature.methodReturnType;
	if (!AAPDiagTypeIsSupported(returnType, YES)) {
		return NO;
	}
	NSUInteger argumentCount = signature.numberOfArguments;
	if (argumentCount < 2 || argumentCount > 6) {
		return NO;
	}
	for (NSUInteger index = 0; index < argumentCount; index++) {
		const char *type = [signature getArgumentTypeAtIndex:index];
		if (!AAPDiagTypeIsSupported(type, NO)) {
			return NO;
		}
	}
	return YES;
}

static BOOL AAPDiagSelectorIsRelevant(NSString *name) {
	if (!name.length) {
		return NO;
	}
	for (size_t index = 0;
		index < sizeof(AAPDiagCoreSelectors) / sizeof(AAPDiagCoreSelectors[0]);
		index++) {
		if ([name isEqualToString:
			[NSString stringWithUTF8String:AAPDiagCoreSelectors[index]]]) {
			return YES;
		}
	}
	NSString *lower = name.lowercaseString;
	for (NSString *keyword in @[
		@"listen",
		@"noise",
		@"transparen",
		@"adaptive",
		@"hearing",
		@"anc",
	]) {
		if ([lower containsString:keyword]) {
			return YES;
		}
	}
	return NO;
}

static NSString *AAPDiagTrimDescription(NSString *description) {
	if (!description) {
		return @"nil";
	}
	NSString *singleLine = [description
		stringByReplacingOccurrencesOfString:@"\n"
		withString:@"\\n"];
	if (singleLine.length > 320) {
		return [[singleLine substringToIndex:320]
			stringByAppendingString:@"..."];
	}
	return singleLine;
}

static NSString *AAPDiagDescribeValue(const char *rawType,
	uintptr_t value,
	BOOL afterCall) {
	if (!rawType) {
		return @"?";
	}
	const char *type = rawType;
	while (*type && strchr("rnNoORV", *type)) {
		type++;
	}
	char kind = *type ? *type : '?';
	switch (kind) {
		case '@': {
			if (!value) {
				return @"nil";
			}
			@try {
				id object = (__bridge id)(void *)value;
				return AAPDiagTrimDescription([object description]);
			} @catch (__unused NSException *exception) {
				return @"<description raised>";
			}
		}
		case '#': {
			if (!value) {
				return @"Nil";
			}
			return AAPDiagTrimDescription(
				NSStringFromClass((__bridge Class)(void *)value));
		}
		case ':': {
			SEL selector = (SEL)value;
			const char *name = selector ? sel_getName(selector) : "";
			return [NSString stringWithFormat:@"sel(%s)", name ?: ""];
		}
		case '*': {
			const char *text = (const char *)value;
			if (!text) {
				return @"null";
			}
			size_t length = strnlen(text, 256);
			return [NSString stringWithFormat:@"\"%.*s\"",
				(int)length,
				text];
		}
		case 'B':
			return value ? @"YES" : @"NO";
		case 'c':
		case 's':
		case 'i':
		case 'l':
		case 'q':
			return [NSString stringWithFormat:@"%lld", (long long)(int64_t)value];
		case 'C':
		case 'S':
		case 'I':
		case 'L':
		case 'Q':
			return [NSString stringWithFormat:@"%llu",
				(unsigned long long)(uint64_t)value];
		case '^': {
			if (type[1] == '@' && afterCall && value) {
				@try {
					id object = *(__unsafe_unretained id *)(void *)value;
					return [NSString stringWithFormat:@"%p=%@",
						(void *)value,
						AAPDiagTrimDescription(object ? [object description]
							: @"nil")];
				} @catch (__unused NSException *exception) {
					return [NSString stringWithFormat:@"%p=<raised>",
						(void *)value];
				}
			}
			return [NSString stringWithFormat:@"%p", (void *)value];
		}
		default:
			return [NSString stringWithFormat:@"0x%llX",
				(unsigned long long)value];
	}
}

static NSString *AAPDiagFormatArguments(AAPDiagMethodRecord *record,
	uintptr_t a1,
	uintptr_t a2,
	uintptr_t a3,
	uintptr_t a4,
	BOOL afterCall) {
	uintptr_t values[4] = {a1, a2, a3, a4};
	@try {
		NSMethodSignature *signature =
			[NSMethodSignature signatureWithObjCTypes:record->types];
		NSUInteger count = signature.numberOfArguments;
		NSMutableArray<NSString *> *parts = [NSMutableArray array];
		for (NSUInteger index = 2; index < count; index++) {
			const char *type = [signature getArgumentTypeAtIndex:index];
			[parts addObject:[NSString stringWithFormat:@"arg%lu=%@",
				(unsigned long)(index - 2),
				AAPDiagDescribeValue(type,
					values[index - 2],
					afterCall)]];
		}
		return parts.count ? [parts componentsJoinedByString:@" "] : @"args=none";
	} @catch (__unused NSException *exception) {
		return @"args=<signature error>";
	}
}

static NSString *AAPDiagFormatReturn(AAPDiagMethodRecord *record,
	uintptr_t result) {
	@try {
		NSMethodSignature *signature =
			[NSMethodSignature signatureWithObjCTypes:record->types];
		const char *type = signature.methodReturnType;
		if (!type || type[0] == 'v') {
			return @"void";
		}
		return AAPDiagDescribeValue(type, result, YES);
	} @catch (__unused NSException *exception) {
		return @"<return format error>";
	}
}

static AAPDiagMethodRecord *AAPDiagFindMethodRecord(id self, SEL selector) {
	Class cls = object_getClass(self);
	for (Class candidate = cls; candidate; candidate = class_getSuperclass(candidate)) {
		for (size_t index = 0; index < AAPDiagMethodRecordCount; index++) {
			AAPDiagMethodRecord *record = &AAPDiagMethodRecords[index];
			if (record->cls == candidate && record->selector == selector) {
				return record;
			}
		}
	}
	return NULL;
}

static uintptr_t AAPDiagGenericMethodHook(id self,
	SEL selector,
	uintptr_t a1,
	uintptr_t a2,
	uintptr_t a3,
	uintptr_t a4) {
	pthread_mutex_lock(&AAPDiagMethodLock);
	AAPDiagMethodRecord *record = AAPDiagFindMethodRecord(self, selector);
	AAPDiagGenericMethodOriginal original = record
		? (AAPDiagGenericMethodOriginal)record->original
		: NULL;
	BOOL failed = record ? record->failed : YES;
	pthread_mutex_unlock(&AAPDiagMethodLock);
	if (!record) {
		AAPDiagLog(@"aacp_api_missing_record selector=%s",
			selector ? sel_getName(selector) : "?");
		return 0;
	}
	if (failed || !original) {
		AAPDiagLog(@"aacp_api_missing_original class=%s selector=%s",
			record->className ?: "?",
			record->selectorName ?: "?");
		return 0;
	}
	if (AAPDiagMethodHookDepth > 0) {
		return original(self, selector, a1, a2, a3, a4);
	}
	AAPDiagMethodHookDepth++;
	uint64_t start = AAPDiagMonotonicMicroseconds();
	@autoreleasepool {
		@try {
			AAPDiagLog(@"aacp_api_enter class=%s selector=%s %@",
				record->className ?: "?",
				record->selectorName ?: "?",
				AAPDiagFormatArguments(record, a1, a2, a3, a4, NO));
			uintptr_t result = original(self, selector, a1, a2, a3, a4);
			uint64_t elapsed = AAPDiagMonotonicMicroseconds() - start;
			AAPDiagLog(@"aacp_api_exit class=%s selector=%s result=%@ "
				@"%@ elapsed_us=%llu",
				record->className ?: "?",
				record->selectorName ?: "?",
				AAPDiagFormatReturn(record, result),
				AAPDiagFormatArguments(record, a1, a2, a3, a4, YES),
				(unsigned long long)elapsed);
			AAPDiagMethodHookDepth--;
			return result;
		} @catch (NSException *exception) {
			uint64_t elapsed = AAPDiagMonotonicMicroseconds() - start;
			AAPDiagLog(@"aacp_api_exception class=%s selector=%s reason=%@ "
				@"elapsed_us=%llu",
				record->className ?: "?",
				record->selectorName ?: "?",
				AAPDiagTrimDescription(exception.reason),
				(unsigned long long)elapsed);
			AAPDiagMethodHookDepth--;
			@throw;
		}
	}
}

static BOOL AAPDiagRecordExists(Class cls, SEL selector) {
	for (size_t index = 0; index < AAPDiagMethodRecordCount; index++) {
		if (AAPDiagMethodRecords[index].cls == cls &&
			AAPDiagMethodRecords[index].selector == selector) {
			return YES;
		}
	}
	return NO;
}

static void AAPDiagHookClassMethods(Class cls, BOOL classMethods) {
	if (!cls) {
		return;
	}
	Class source = classMethods ? object_getClass((id)cls) : cls;
	Class recordClass = source;
	unsigned int count = 0;
	Method *methods = class_copyMethodList(source, &count);
	for (unsigned int index = 0; index < count; index++) {
		Method method = methods[index];
		SEL selector = method_getName(method);
		NSString *name = NSStringFromSelector(selector);
		if (!AAPDiagSelectorIsRelevant(name)) {
			continue;
		}
		const char *types = method_getTypeEncoding(method);
		NSMethodSignature *signature = nil;
		@try {
			signature = [NSMethodSignature signatureWithObjCTypes:types];
		} @catch (__unused NSException *exception) {
			signature = nil;
		}
		if (!AAPDiagMethodSignatureIsSupported(signature)) {
			AAPDiagLog(@"hook_skip class=%s selector=%@ types=%s",
				class_getName(cls),
				name,
				types ?: "?");
			continue;
		}

		IMP previous = method_getImplementation(method);
		pthread_mutex_lock(&AAPDiagMethodLock);
		if (AAPDiagRecordExists(recordClass, selector)) {
			pthread_mutex_unlock(&AAPDiagMethodLock);
			continue;
		}
		if (AAPDiagMethodRecordCount >= AAP_DIAG_HOOK_RECORDS) {
			pthread_mutex_unlock(&AAPDiagMethodLock);
			AAPDiagLog(@"hook_capacity_exceeded class=%s",
				class_getName(cls));
			break;
		}
		AAPDiagMethodRecord *record =
			&AAPDiagMethodRecords[AAPDiagMethodRecordCount++];
		record->cls = recordClass;
		record->selector = selector;
		record->original = previous;
		record->failed = NO;
		record->types = types ? strdup(types) : NULL;
		record->className = strdup(class_getName(cls));
		record->selectorName = strdup(name.UTF8String ?: "?");
		pthread_mutex_unlock(&AAPDiagMethodLock);

		IMP original = NULL;
		MSHookMessageEx(recordClass,
			selector,
			(IMP)AAPDiagGenericMethodHook,
			&original);

		pthread_mutex_lock(&AAPDiagMethodLock);
		if (original) {
			record->original = original;
		} else {
			record->failed = record->original == NULL;
		}
		if (record->failed) {
			AAPDiagLog(@"hook_failed class=%s selector=%@",
				class_getName(cls),
				name);
		} else {
			AAPDiagLog(@"hook_installed class=%s selector=%@ "
				@"types=%s%s original=%p",
				class_getName(cls),
				name,
				types ?: "?",
				classMethods ? " kind=class" : " kind=instance",
				record->original);
		}
		pthread_mutex_unlock(&AAPDiagMethodLock);
	}
	free(methods);
}

static void AAPDiagInstallClassHooksForName(const char *className,
	size_t inventoryIndex) {
	(void)inventoryIndex;
	Class cls = objc_getClass(className);
	if (!cls) {
		return;
	}

	BOOL inventory = NO;
	pthread_mutex_lock(&AAPDiagInventoryLock);
	if (!AAPDiagInventoriedClasses) {
		AAPDiagInventoriedClasses = [NSMutableSet set];
	}
	NSString *key = [NSString stringWithUTF8String:className];
	if (key && ![AAPDiagInventoriedClasses containsObject:key]) {
		[AAPDiagInventoriedClasses addObject:key];
		inventory = YES;
	}
	pthread_mutex_unlock(&AAPDiagInventoryLock);
	if (inventory) {
		AAPDiagLog(@"diag_marker phase=runtime_class_found class=%s",
			className);
		AAPDiagLog(@"diag_marker phase=diag7_runtime_discovery class=%s",
			className);
		AAPDiagLogClassInventory(
			[NSString stringWithFormat:@"bluetoothd:%s", className],
			(id)cls);
	}

	for (Class cursor = cls; cursor; cursor = class_getSuperclass(cursor)) {
		if (cursor == [NSObject class]) {
			break;
		}
		AAPDiagHookClassMethods(cursor, NO);
	}
	AAPDiagHookClassMethods(cls, YES);
}

static void AAPDiagInstallClassHooksOnce(void) {
	for (size_t index = 0;
		index < sizeof(AAPDiagWatchedClasses) / sizeof(AAPDiagWatchedClasses[0]);
		index++) {
		AAPDiagInstallClassHooksForName(AAPDiagWatchedClasses[index], index);
	}
}

static void AAPDiagLoadBluetoothFrameworks(void) {
	for (NSString *path in @[
		@"/System/Library/PrivateFrameworks/BluetoothManager.framework/BluetoothManager",
		@"/System/Library/PrivateFrameworks/BluetoothAudio.framework/BluetoothAudio",
		@"/System/Library/PrivateFrameworks/BluetoothServices.framework/BluetoothServices",
		@"/System/Library/PrivateFrameworks/PersonalAudio.framework/PersonalAudio",
		@"/System/Library/PrivateFrameworks/AudioAccessory.framework/AudioAccessory",
		@"/System/Library/PrivateFrameworks/CoreBluetooth.framework/CoreBluetooth",
	]) {
		void *handle = dlopen(path.fileSystemRepresentation, RTLD_LAZY);
		if (!handle) {
			AAPDiagLog(@"framework_load_failed path=%@ error=%s",
				path,
				dlerror() ?: "unknown");
		}
	}
}

static void AAPDiagHookFunction(const char *name,
	void *replacement,
	void **original) {
	void *symbol = dlsym(RTLD_DEFAULT, name);
	if (!symbol) {
		AAPDiagLog(@"function_hook_missing name=%s error=%s",
			name,
			dlerror() ?: "unknown");
		return;
	}
	*original = NULL;
	MSHookFunction(symbol, replacement, original);
	AAPDiagLog(@"function_hook_installed name=%s symbol=%p original=%p",
		name,
		symbol,
		*original);
}

void AAPDiagInstallRuntimeHooks(void) {
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		AAPDiagSocketLogQueue = dispatch_queue_create(
			"com.lns.pogr.aacpdiag.socket-log",
			DISPATCH_QUEUE_SERIAL);
#if AACPDIAG_TRANSPORT_SAFE_MODE
		AAPDiagLog(@"diag_marker phase=runtime_hooks_safe_mode");
#else
		AAPDiagLog(@"diag_marker phase=runtime_hooks_begin");
		AAPDiagLoadBluetoothFrameworks();
#endif
		AAPDiagHookFunction("socket",
			(void *)AAPDiagSocketHook,
			(void **)&AAPDiagOriginalSocket);
		AAPDiagHookFunction("connect",
			(void *)AAPDiagConnectHook,
			(void **)&AAPDiagOriginalConnect);
		AAPDiagHookFunction("send",
			(void *)AAPDiagSendHook,
			(void **)&AAPDiagOriginalSend);
		AAPDiagHookFunction("recv",
			(void *)AAPDiagRecvHook,
			(void **)&AAPDiagOriginalRecv);
		AAPDiagHookFunction("recvfrom",
			(void *)AAPDiagRecvFromHook,
			(void **)&AAPDiagOriginalRecvFrom);
		AAPDiagHookFunction("read",
			(void *)AAPDiagReadHook,
			(void **)&AAPDiagOriginalRead);
		AAPDiagHookFunction("close",
			(void *)AAPDiagCloseHook,
			(void **)&AAPDiagOriginalClose);

#if !AACPDIAG_TRANSPORT_SAFE_MODE
		AAPDiagInstallClassHooksOnce();
		for (NSNumber *delay in @[@1, @3, @10]) {
			dispatch_after(
				dispatch_time(DISPATCH_TIME_NOW,
					(int64_t)delay.doubleValue * NSEC_PER_SEC),
				dispatch_get_global_queue(QOS_CLASS_UTILITY, 0),
				^{
					AAPDiagInstallClassHooksOnce();
				});
		}
		AAPDiagLog(@"diag_marker phase=runtime_hooks_installed "
			@"marker=diag10_active_aacp_fd_reuse");
#else
		AAPDiagLog(@"diag_marker phase=runtime_hooks_installed "
			@"marker=adts3final_socket_hooks_only");
#endif
	});
}
