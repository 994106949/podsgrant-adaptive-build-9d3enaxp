#import "AACPDiag.h"

#import <errno.h>
#import <fcntl.h>
#import <poll.h>
#import <stdint.h>
#import <string.h>
#import <sys/socket.h>
#import <unistd.h>

#define AAP_AF_BLUETOOTH 32
#define AAP_SOCK_SEQPACKET 5
#define AAP_BTPROTO_L2CAP 0
#define AAP_AACP_PSM 0x1001
#define AAP_CONNECT_TIMEOUT_MS 900
#define AAP_CONFIG_WAIT_MS 350
#define AAP_MODE_WAIT_MS 2200

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

static const uint8_t AAPDiagAACPHeader[] = {0x04, 0x00, 0x04, 0x00};
static const uint8_t AAPDiagListeningConfigID = 0x1A;
static const uint8_t AAPDiagListeningModeID = 0x0D;

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
							@"%s/%s/%s/len=%lu/%s errno=%d(%s)",
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
	if (modeValue && packet.length > 7) {
		*modeValue = @(bytes[7]);
	}
	return YES;
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

NSDictionary<NSString *, id> *AAPDiagRunTransportTest(NSString *address,
	unsigned int mode) {
	NSMutableArray<NSString *> *trace = [NSMutableArray array];
	NSMutableArray<NSString *> *packets = [NSMutableArray array];
	NSString *normalized = AAPDiagNormalizeAddress(address);
	[trace addObject:[NSString stringWithFormat:
		@"transport_start address=%@ mode=%u",
		normalized ?: @"nil",
		mode]];

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

	NSString *connectedLayout = nil;
	int fd = AAPDiagConnect(normalized, trace, &connectedLayout);
	if (fd < 0) {
		[trace addObject:@"connect_exhausted"];
		return @{
			@"status": @"connect_failed",
			@"mode": @(mode),
			@"address": normalized ?: @"",
			@"trace": trace,
			@"rx_packets": packets,
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
			mode,
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
	if (modeAck) {
		status = @"protocol_ack";
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
		@"socket_variant": connectedLayout ?: @"",
		@"config_frame": AAPDiagHex(AAPDiagFrame(
			AAPDiagListeningConfigID, 0x0F)),
		@"mode_frame": AAPDiagHex(AAPDiagFrame(
			AAPDiagListeningModeID, (uint8_t)mode)),
		@"config_ack": configAck ?: @{},
		@"mode_ack": modeAck ?: @{},
		@"rx_packets": packets,
		@"trace": trace,
		@"timestamp": @([[NSDate date] timeIntervalSince1970]),
	};
}
