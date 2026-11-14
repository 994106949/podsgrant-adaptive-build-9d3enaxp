#import "AACPDiag.h"

#import <errno.h>
#import <fcntl.h>
#import <poll.h>
#import <stdint.h>
#import <string.h>
#import <sys/socket.h>
#import <time.h>
#import <unistd.h>

#define AAP_AF_BLUETOOTH 32
#define AAP_SOCK_SEQPACKET 5
#define AAP_BTPROTO_L2CAP 0
#define AAP_AACP_PSM 0x1001
#define AAP_CONNECT_TIMEOUT_MS 900
#define AAP_CONFIG_WAIT_MS 100
#define AAP_MODE_WAIT_MS 2200

#if !defined(AACPDIAG_TRANSPORT_NO_ACTIVE_FD) || \
	!AACPDIAG_TRANSPORT_NO_ACTIVE_FD
struct AAPDiagL2CapAddress {
	uint8_t length;
	uint8_t family;
	uint16_t psm;
	uint8_t address[6];
	uint8_t reserved[6];
} __attribute__((packed));

struct AAPDiagL2CapAddressAlt {
	uint8_t length;
	uint8_t family;
	uint8_t address[6];
	uint16_t psm;
	uint8_t reserved[6];
} __attribute__((packed));
#endif

static const uint8_t AAPDiagAACPHeader[] = {0x04, 0x00, 0x04, 0x00};
static const uint8_t AAPDiagListeningConfigID = 0x1A;
static const uint8_t AAPDiagListeningModeID = 0x0D;

#if !defined(AACPDIAG_TRANSPORT_NO_ACTIVE_FD) || \
	!AACPDIAG_TRANSPORT_NO_ACTIVE_FD
static uint64_t AAPDiagTransportMonotonicMicroseconds(void) {
	struct timespec value = {0};
	clock_gettime(CLOCK_MONOTONIC, &value);
	return (uint64_t)value.tv_sec * 1000000ULL +
		(uint64_t)value.tv_nsec / 1000ULL;
}
#endif

#if !defined(AACPDIAG_TRANSPORT_NO_ACTIVE_FD) || \
	!AACPDIAG_TRANSPORT_NO_ACTIVE_FD
static BOOL AAPDiagParseAddress(NSString *address,
	uint8_t reversed[6],
	uint8_t direct[6]) {
	NSString *normalized = AAPDiagNormalizeAddress(address);
	if (!normalized.length) {
		return NO;
	}
	unsigned int values[6] = {0};
	int count = sscanf(normalized.UTF8String,
		"%x:%x:%x:%x:%x:%x",
		&values[0],
		&values[1],
		&values[2],
		&values[3],
		&values[4],
		&values[5]);
	if (count != 6) {
		return NO;
	}
	for (NSUInteger index = 0; index < 6; index++) {
		if (values[index] > 0xFF) {
			return NO;
		}
		direct[index] = (uint8_t)values[index];
		reversed[5 - index] = (uint8_t)values[index];
	}
	return YES;
}

static int AAPDiagConnectWithVariant(const uint8_t address[6],
	BOOL alternateLayout,
	BOOL alternatePSMEndian,
	NSUInteger sockaddrLength,
	int *lastError,
	NSString **variantName) {
	int fd = socket(AAP_AF_BLUETOOTH, AAP_SOCK_SEQPACKET, AAP_BTPROTO_L2CAP);
	if (fd < 0) {
		*lastError = errno;
		*variantName = @"socket_failed";
		return -1;
	}

	int flags = fcntl(fd, F_GETFL, 0);
	if (flags >= 0) {
		fcntl(fd, F_SETFL, flags | O_NONBLOCK);
	}

	uint16_t psm = alternatePSMEndian
		? (uint16_t)((AAP_AACP_PSM >> 8) | (AAP_AACP_PSM << 8))
		: (uint16_t)AAP_AACP_PSM;
	int result = -1;
	if (!alternateLayout) {
		struct AAPDiagL2CapAddress socketAddress = {0};
		socketAddress.length = (uint8_t)sockaddrLength;
		socketAddress.family = AAP_AF_BLUETOOTH;
		socketAddress.psm = psm;
		memcpy(socketAddress.address, address, 6);
		result = connect(fd,
			(const struct sockaddr *)&socketAddress,
			(socklen_t)sockaddrLength);
	} else {
		struct AAPDiagL2CapAddressAlt socketAddress = {0};
		socketAddress.length = (uint8_t)sockaddrLength;
		socketAddress.family = AAP_AF_BLUETOOTH;
		memcpy(socketAddress.address, address, 6);
		socketAddress.psm = psm;
		result = connect(fd,
			(const struct sockaddr *)&socketAddress,
			(socklen_t)sockaddrLength);
	}

	if (result == 0) {
		*variantName = alternateLayout ? @"alt_layout" : @"psm_layout";
		return fd;
	}

	int error = errno;
	if (error == EINPROGRESS || error == EALREADY) {
		struct pollfd descriptor = {
			.fd = fd,
			.events = POLLOUT,
			.revents = 0,
		};
		int pollResult = poll(&descriptor, 1, AAP_CONNECT_TIMEOUT_MS);
		if (pollResult > 0 &&
			(descriptor.revents & (POLLOUT | POLLERR | POLLHUP))) {
			int socketError = 0;
			socklen_t length = sizeof(socketError);
			if (getsockopt(fd,
				SOL_SOCKET,
				SO_ERROR,
				&socketError,
				&length) == 0 &&
				socketError == 0) {
				*variantName =
					alternateLayout ? @"alt_layout" : @"psm_layout";
				return fd;
			}
			error = socketError;
		} else if (pollResult == 0) {
			error = ETIMEDOUT;
		}
	}

	*lastError = error;
	*variantName = @"connect_failed";
	close(fd);
	return -1;
}

static int AAPDiagConnect(NSString *address,
	NSMutableArray<NSString *> *attempts,
	NSString **connectedLayout) {
	uint8_t reversed[6] = {0};
	uint8_t direct[6] = {0};
	if (!AAPDiagParseAddress(address, reversed, direct)) {
		[attempts addObject:@"address_parse_failed"];
		return -1;
	}

	const uint8_t *addresses[2] = {reversed, direct};
	const char *addressNames[2] = {"reversed", "direct"};
	const BOOL layouts[2] = {NO, YES};
	const char *layoutNames[2] = {"psm_layout", "alt_layout"};
	const BOOL endians[2] = {NO, YES};
	const char *endianNames[2] = {"native_psm", "swapped_psm"};
	const NSUInteger lengths[2] = {12, 16};

	for (NSUInteger addressIndex = 0; addressIndex < 2; addressIndex++) {
		for (NSUInteger layoutIndex = 0; layoutIndex < 2; layoutIndex++) {
			for (NSUInteger endianIndex = 0; endianIndex < 2; endianIndex++) {
				for (NSUInteger lengthIndex = 0;
					lengthIndex < 2;
					lengthIndex++) {
					int lastError = 0;
					NSString *variantName = nil;
					int fd = AAPDiagConnectWithVariant(
						addresses[addressIndex],
						layouts[layoutIndex],
						endians[endianIndex],
						lengths[lengthIndex],
						&lastError,
						&variantName);
					NSString *attempt = [NSString
						stringWithFormat:
							@"%s/%s/%s/len=%lu/%@ errno=%d(%s)",
						addressNames[addressIndex],
						layoutNames[layoutIndex],
						endianNames[endianIndex],
						(unsigned long)lengths[lengthIndex],
						variantName ?: @"unknown",
						lastError,
						strerror(lastError)];
					[attempts addObject:attempt];
					if (fd >= 0) {
						*connectedLayout = [NSString stringWithFormat:
							@"%s/%s/%s/len=%lu",
							addressNames[addressIndex],
							layoutNames[layoutIndex],
							endianNames[endianIndex],
							(unsigned long)lengths[lengthIndex]];
						return fd;
					}
				}
			}
		}
	}
	return -1;
}
#endif

static NSData *AAPDiagFrame(uint8_t settingID, uint8_t value) {
	const uint8_t bytes[] = {
		0x04, 0x00, 0x04, 0x00,
		0x09, 0x00,
		settingID,
		value,
		0x00, 0x00, 0x00,
	};
	return [NSData dataWithBytes:bytes length:sizeof(bytes)];
}

static BOOL AAPDiagPacketMatches(NSData *packet,
	uint8_t settingID,
	NSNumber **modeValue) {
	if (packet.length < 7) {
		return NO;
	}
	const uint8_t *bytes = packet.bytes;
	if (memcmp(bytes, AAPDiagAACPHeader, sizeof(AAPDiagAACPHeader)) != 0) {
		return NO;
	}
	if (bytes[4] != 0x09 || bytes[5] != 0x00 || bytes[6] != settingID) {
		return NO;
	}
	if (modeValue) {
		*modeValue = packet.length > 7 ? @(bytes[7]) : @(-1);
	}
	return YES;
}

static NSDictionary<NSString *, id> *AAPDiagMatchRXFrame(
	NSDictionary<NSString *, id> *frame,
	uint8_t settingID,
	unsigned int requestedMode) {
	NSData *data = frame[@"data"];
	if (![data isKindOfClass:[NSData class]]) {
		return nil;
	}
	NSNumber *echoedMode = nil;
	if (!AAPDiagPacketMatches(data, settingID, &echoedMode)) {
		return nil;
	}
	return @{
		@"packet": frame[@"hex"] ?: AAPDiagHex(data),
		@"echoed_mode": echoedMode ?: @(-1),
		@"echo_matches": @(echoedMode &&
			echoedMode.unsignedIntValue == requestedMode),
		@"timestamp_us": frame[@"timestamp_us"] ?: @0,
	};
}

static NSDictionary<NSString *, id> *AAPDiagFindSettingInFrames(
	NSArray<NSDictionary<NSString *, id> *> *frames,
	uint8_t settingID,
	unsigned int requestedMode,
	NSUInteger *matchCount) {
	NSDictionary *last = nil;
	NSUInteger count = 0;
	for (NSDictionary *frame in frames) {
		NSDictionary *match =
			AAPDiagMatchRXFrame(frame, settingID, requestedMode);
		if (!match) {
			continue;
		}
		count++;
		last = match;
		if ([match[@"echo_matches"] boolValue]) {
			break;
		}
	}
	if (matchCount) {
		*matchCount = count;
	}
	return last;
}

#if !defined(AACPDIAG_TRANSPORT_NO_ACTIVE_FD) || \
	!AACPDIAG_TRANSPORT_NO_ACTIVE_FD
static NSDictionary<NSString *, id> *AAPDiagRunActiveDescriptorTransport(
	NSString *address,
	unsigned int mode,
	NSMutableArray<NSString *> *trace,
	NSMutableArray<NSString *> *packets) {
	BOOL exactMatch = NO;
	int fd = AAPDiagCopyActiveAACPDescriptorWithMatch(address, &exactMatch);
	if (fd < 0) {
		return @{
			@"available": @NO,
			@"reason": @"no_fresh_active_aacp_fd",
		};
	}
	BOOL fallbackUnique = !exactMatch;
	uint64_t started = AAPDiagTransportMonotonicMicroseconds();
	[trace addObject:[NSString stringWithFormat:
		@"active_fd_selected fd=%d exact=%d fallback_unique=%d",
		fd,
		exactMatch,
		fallbackUnique]];

	NSData *configFrame = AAPDiagFrame(AAPDiagListeningConfigID, 0x0F);
	ssize_t configSent = send(fd, configFrame.bytes, configFrame.length, 0);
	BOOL configOK = configSent == (ssize_t)configFrame.length;
	[trace addObject:[NSString stringWithFormat:
		@"active_fd_tx id=0x%02X value=15 sent=%ld expected=%lu",
		AAPDiagListeningConfigID,
		(long)configSent,
		(unsigned long)configFrame.length]];
	if (!configOK) {
		return @{
			@"available": @YES,
			@"fd": @(fd),
			@"exact_match": @(exactMatch),
			@"fallback_unique": @(fallbackUnique),
			@"config_sent": @NO,
			@"mode_sent": @NO,
			@"mode_ack": @{},
			@"rx_frames": @[],
			@"rx_packets": packets,
			@"tx_confirmed": @NO,
		};
	}

	[NSThread sleepForTimeInterval:0.20];
	uint64_t modeSentAt = AAPDiagTransportMonotonicMicroseconds();
	NSData *modeFrame = AAPDiagFrame(AAPDiagListeningModeID, (uint8_t)mode);
	ssize_t modeSent = send(fd, modeFrame.bytes, modeFrame.length, 0);
	BOOL modeOK = modeSent == (ssize_t)modeFrame.length;
	[trace addObject:[NSString stringWithFormat:
		@"active_fd_tx id=0x%02X value=%u sent=%ld expected=%lu",
		AAPDiagListeningModeID,
		mode,
		(long)modeSent,
		(unsigned long)modeFrame.length]];

	NSArray<NSDictionary<NSString *, id> *> *frames = @[];
	NSDictionary *modeAck = nil;
	NSUInteger modeAckCount = 0;
	if (modeOK) {
		NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:
			(NSTimeInterval)AAP_MODE_WAIT_MS / 1000.0];
		while ([deadline timeIntervalSinceNow] > 0) {
			frames = AAPDiagCopyAACPRXFramesForDescriptor(fd, modeSentAt);
			modeAck = AAPDiagFindSettingInFrames(frames,
				AAPDiagListeningModeID,
				mode,
				&modeAckCount);
			if (modeAck && [modeAck[@"echo_matches"] boolValue]) {
				break;
			}
			[NSThread sleepForTimeInterval:0.05];
		}
	}
	for (NSDictionary *frame in frames) {
		NSString *hex = frame[@"hex"];
		if (hex.length) {
			[packets addObject:hex];
			[trace addObject:[NSString stringWithFormat:
				@"active_fd_rx len=%@ bytes=%@ timestamp_us=%@",
				frame[@"length"] ?: @0,
				hex,
				frame[@"timestamp_us"] ?: @0]];
		}
	}
	BOOL txConfirmed = configOK && modeOK;
	return @{
		@"available": @YES,
		@"fd": @(fd),
		@"exact_match": @(exactMatch),
		@"fallback_unique": @(fallbackUnique),
		@"config_sent": @(configOK),
		@"mode_sent": @(modeOK),
		@"mode_ack": modeAck ?: @{},
		@"mode_ack_count": @(modeAckCount),
		@"rx_frames": frames,
		@"rx_packets": packets,
		@"tx_confirmed": @(txConfirmed),
		@"started_us": @(started),
		@"mode_sent_us": @(modeSentAt),
	};
}
#else
static NSDictionary<NSString *, id> *AAPDiagRunActiveDescriptorTransport(
	NSString *address,
	unsigned int mode,
	NSMutableArray<NSString *> *trace,
	NSMutableArray<NSString *> *packets) {
	(void)address;
	(void)mode;
	(void)packets;
	[trace addObject:@"active_fd_disabled_for_daemon"];
	return @{
		@"available": @NO,
		@"reason": @"compiled_without_active_fd",
	};
}
#endif

#if !defined(AACPDIAG_TRANSPORT_NO_ACTIVE_FD) || \
	!AACPDIAG_TRANSPORT_NO_ACTIVE_FD
static BOOL AAPDiagSendPacket(int fd,
	uint8_t settingID,
	uint8_t value,
	NSMutableArray<NSString *> *trace,
	NSError **error) {
	NSData *frame = AAPDiagFrame(settingID, value);
	ssize_t sent = send(fd, frame.bytes, frame.length, 0);
	if (sent == (ssize_t)frame.length) {
		[trace addObject:[NSString stringWithFormat:
			@"socket_tx id=0x%02X value=%u bytes=%@",
			settingID,
			value,
			AAPDiagHex(frame)]];
		return YES;
	}
	int sendError = errno;
	[trace addObject:[NSString stringWithFormat:
		@"socket_tx_failed id=0x%02X value=%u sent=%ld expected=%lu errno=%d(%s)",
		settingID,
		value,
		(long)sent,
		(unsigned long)frame.length,
		sendError,
		strerror(sendError)]];
	if (error) {
		*error = [NSError errorWithDomain:NSPOSIXErrorDomain
			code:sendError
			userInfo:@{NSLocalizedDescriptionKey:
				[NSString stringWithFormat:@"send failed: %s",
					strerror(sendError)]}];
	}
	return NO;
}

static BOOL AAPDiagWaitForSetting(int fd,
	uint8_t settingID,
	unsigned int requestedMode,
	int timeoutMilliseconds,
	NSMutableArray<NSString *> *trace,
	NSMutableArray<NSString *> *packets,
	NSDictionary<NSString *, id> **matchingPacket) {
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:
		(NSTimeInterval)timeoutMilliseconds / 1000.0];
	BOOL matched = NO;
	while ([deadline timeIntervalSinceNow] > 0) {
		struct pollfd descriptor = {
			.fd = fd,
			.events = POLLIN,
			.revents = 0,
		};
		int remaining = (int)([deadline timeIntervalSinceNow] * 1000.0);
		if (remaining <= 0) {
			break;
		}
		int pollResult = poll(&descriptor, 1, MIN(remaining, 200));
		if (pollResult <= 0) {
			continue;
		}

		uint8_t buffer[512] = {0};
		ssize_t received = recv(fd, buffer, sizeof(buffer), 0);
		if (received <= 0) {
			int receiveError = errno;
			[trace addObject:[NSString stringWithFormat:
				@"earbud_rx_error errno=%d(%s)",
				receiveError,
				strerror(receiveError)]];
			break;
		}

		NSData *packet = [NSData dataWithBytes:buffer
			length:(NSUInteger)received];
		NSString *packetHex = AAPDiagHex(packet);
		[packets addObject:packetHex];
		[trace addObject:[NSString stringWithFormat:
			@"earbud_rx len=%ld bytes=%@",
			(long)received,
			packetHex]];

		NSNumber *echoedMode = nil;
		if (!AAPDiagPacketMatches(packet, settingID, &echoedMode)) {
			continue;
		}
		matched = YES;
		BOOL echoMatches = echoedMode &&
			(echoedMode.unsignedIntValue == requestedMode);
		if (matchingPacket) {
			*matchingPacket = @{
				@"packet": packetHex,
				@"echoed_mode": echoedMode ?: @(-1),
				@"echo_matches": @(echoMatches),
			};
		}
		if (echoMatches) {
			break;
		}
	}
	return matched;
}

static void AAPDiagDrain(int fd,
	NSMutableArray<NSString *> *trace,
	NSMutableArray<NSString *> *packets) {
	uint8_t buffer[512] = {0};
	for (;;) {
		ssize_t received = recv(fd, buffer, sizeof(buffer), MSG_DONTWAIT);
		if (received <= 0) {
			break;
		}
		NSData *packet = [NSData dataWithBytes:buffer
			length:(NSUInteger)received];
		NSString *packetHex = AAPDiagHex(packet);
		[packets addObject:packetHex];
		[trace addObject:[NSString stringWithFormat:
			@"earbud_drain len=%ld bytes=%@",
			(long)received,
			packetHex]];
	}
}
#endif

NSDictionary<NSString *, id> *AAPDiagRunTransportTest(NSString *address,
	unsigned int mode) {
	NSMutableArray<NSString *> *trace = [NSMutableArray array];
	NSMutableArray<NSString *> *packets = [NSMutableArray array];
	NSString *normalized = AAPDiagNormalizeAddress(address);
	[trace addObject:[NSString stringWithFormat:
		@"transport_start address=%@ mode=%u",
		normalized ?: @"nil",
		mode]];
	AAPDiagLog(@"diag_marker source=aacp_transport event=request mode=%u address=%@",
		mode,
		normalized ?: @"nil");

	if (mode < AAPDiagModeNoiseCancellation ||
		mode > AAPDiagModeAdaptive) {
		[trace addObject:@"invalid_mode"];
		return @{
			@"status": @"invalid_mode",
			@"mode": @(mode),
			@"trace": trace,
			@"rx_packets": packets,
		};
	}

	NSDictionary *active = AAPDiagRunActiveDescriptorTransport(
		normalized,
		mode,
		trace,
		packets);
	if ([active[@"available"] boolValue]) {
		NSDictionary *modeAck = active[@"mode_ack"];
		BOOL txConfirmed = [active[@"tx_confirmed"] boolValue];
		NSString *status = nil;
		if (!txConfirmed) {
			status = @"active_aacp_fd_tx_failed";
		} else if ([modeAck isKindOfClass:[NSDictionary class]] &&
			modeAck.count &&
			[modeAck[@"echo_matches"] boolValue]) {
			status = @"protocol_ack";
		} else if ([modeAck isKindOfClass:[NSDictionary class]] &&
			modeAck.count) {
			status = @"protocol_reply_mismatch";
		} else {
			status = @"active_aacp_fd_tx_unconfirmed";
		}
		[trace addObject:[NSString stringWithFormat:
			@"transport_result status=%@ active_fd_used=1",
			status]];
		return @{
			@"status": status,
			@"mode": @(mode),
			@"address": normalized ?: @"",
			@"active_fd_used": @YES,
			@"active_fd_fallback_unique":
				active[@"fallback_unique"] ?: @NO,
			@"active_fd": active[@"fd"] ?: @-1,
			@"active_fd_exact_match":
				active[@"exact_match"] ?: @NO,
			@"tx_confirmed": @(txConfirmed),
			@"config_frame": AAPDiagHex(AAPDiagFrame(
				AAPDiagListeningConfigID, 0x0F)),
			@"mode_frame": AAPDiagHex(AAPDiagFrame(
				AAPDiagListeningModeID, (uint8_t)mode)),
			@"mode_ack": modeAck ?: @{},
			@"mode_ack_count": active[@"mode_ack_count"] ?: @0,
			@"rx_packets": active[@"rx_packets"] ?: @[],
			@"rx_frames": active[@"rx_frames"] ?: @[],
			@"rx_frame_count":
				@([active[@"rx_frames"] count]),
			@"trace": trace,
			@"timestamp": @([[NSDate date] timeIntervalSince1970]),
		};
	}

	[trace addObject:[NSString stringWithFormat:
		@"active_fd_unavailable reason=%@",
		active[@"reason"] ?: @"unknown"]];

#if defined(AACPDIAG_TRANSPORT_NO_ACTIVE_FD) && AACPDIAG_TRANSPORT_NO_ACTIVE_FD
	[trace addObject:@"direct_fallback_disabled"];
	return @{
		@"status": @"active_aacp_fd_tx_unconfirmed",
		@"mode": @(mode),
		@"address": normalized ?: @"",
		@"active_fd_used": @NO,
		@"active_fd_fallback_unique": @NO,
		@"tx_confirmed": @NO,
		@"mode_ack": @{},
		@"rx_packets": packets,
		@"rx_frames": @[],
		@"trace": trace,
		@"timestamp": @([[NSDate date] timeIntervalSince1970]),
	};
#else
	NSString *connectedLayout = nil;
	int fd = AAPDiagConnect(normalized, trace, &connectedLayout);
	if (fd < 0) {
		[trace addObject:@"connect_exhausted"];
		return @{
			@"status": @"connect_failed",
			@"mode": @(mode),
			@"address": normalized ?: @"",
			@"active_fd_used": @NO,
			@"active_fd_fallback_unique": @NO,
			@"tx_confirmed": @NO,
			@"rx_packets": packets,
			@"rx_frames": @[],
			@"trace": trace,
		};
	}

	setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, NULL, 0);
	[trace addObject:[NSString stringWithFormat:
		@"socket_connected variant=%@ fd=%d",
		connectedLayout ?: @"unknown",
		fd]];

	NSError *sendError = nil;
	BOOL configSent = AAPDiagSendPacket(fd,
		AAPDiagListeningConfigID,
		0x0F,
		trace,
		&sendError);
	NSDictionary *configAck = nil;
	if (configSent) {
		AAPDiagWaitForSetting(fd,
			AAPDiagListeningConfigID,
			0x0F,
			AAP_CONFIG_WAIT_MS,
			trace,
			packets,
			&configAck);
	}
	AAPDiagDrain(fd, trace, packets);

	BOOL modeSent = AAPDiagSendPacket(fd,
		AAPDiagListeningModeID,
		(uint8_t)mode,
		trace,
		&sendError);
	NSDictionary *modeAck = nil;
	if (modeSent) {
		AAPDiagWaitForSetting(fd,
			AAPDiagListeningModeID,
			mode,
			AAP_MODE_WAIT_MS,
			trace,
			packets,
			&modeAck);
	}
	close(fd);

	NSString *status = @"no_earbud_ack";
	if (modeAck && [modeAck[@"echo_matches"] boolValue]) {
		status = @"protocol_ack";
	} else if (modeAck) {
		status = @"protocol_reply_mismatch";
	} else if (!configSent || !modeSent) {
		status = @"send_failed";
	}
	[trace addObject:[NSString stringWithFormat:
		@"transport_result status=%@ mode_ack=%d config_ack=%d",
		status,
		modeAck != nil,
		configAck != nil]];

	return @{
		@"status": status,
		@"mode": @(mode),
		@"address": normalized ?: @"",
		@"active_fd_used": @NO,
		@"active_fd_fallback_unique": @NO,
		@"tx_confirmed": @(configSent && modeSent),
		@"socket_variant": connectedLayout ?: @"",
		@"config_frame": AAPDiagHex(AAPDiagFrame(
			AAPDiagListeningConfigID, 0x0F)),
		@"mode_frame": AAPDiagHex(AAPDiagFrame(
			AAPDiagListeningModeID, (uint8_t)mode)),
		@"config_ack": configAck ?: @{},
		@"mode_ack": modeAck ?: @{},
		@"rx_packets": packets,
		@"rx_frames": @[],
		@"trace": trace,
		@"timestamp": @([[NSDate date] timeIntervalSince1970]),
	};
#endif
}
