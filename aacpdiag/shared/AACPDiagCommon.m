#import "AACPDiag.h"

#import <fcntl.h>
#import <stdarg.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>

NSString *const AAPDiagLogPath =
	@"/var/mobile/Library/Preferences/com.lns.pogr.aacpdiag.log";
NSString *const AAPDiagRequestPath =
	@"/var/mobile/Library/Preferences/com.lns.pogr.aacpdiag.request.plist";
NSString *const AAPDiagResultPath =
	@"/var/mobile/Library/Preferences/com.lns.pogr.aacpdiag.result.plist";
NSString *const AAPDiagDarwinNotification =
	@"com.lns.pogr.aacpdiag.request";

void AAPDiagLog(NSString *format, ...) {
	va_list arguments;
	va_start(arguments, format);
	NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
	va_end(arguments);

	NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
	formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
	NSString *line = [NSString stringWithFormat:@"%@ pid=%d [%@] %@\n",
		[formatter stringFromDate:[NSDate date]],
		getpid(),
		[[NSProcessInfo processInfo] processName],
		message ?: @""];
	NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
	if (!data) {
		return;
	}

	int fd = open(AAPDiagLogPath.fileSystemRepresentation,
		O_WRONLY | O_CREAT | O_APPEND,
		0644);
	if (fd < 0) {
		return;
	}
	const uint8_t *bytes = data.bytes;
	NSUInteger remaining = data.length;
	while (remaining > 0) {
		ssize_t written = write(fd, bytes, remaining);
		if (written <= 0) {
			break;
		}
		bytes += written;
		remaining -= (NSUInteger)written;
	}
	close(fd);
}

NSString *AAPDiagNormalizeAddress(NSString *address) {
	if (![address isKindOfClass:[NSString class]]) {
		return nil;
	}
	NSString *normalized = [address
		stringByTrimmingCharactersInSet:
			[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	return normalized.length ? normalized.uppercaseString : nil;
}

NSString *AAPDiagHex(NSData *data) {
	if (!data.length) {
		return @"";
	}
	const uint8_t *bytes = data.bytes;
	NSMutableString *result =
		[NSMutableString stringWithCapacity:data.length * 3];
	for (NSUInteger index = 0; index < data.length; index++) {
		[result appendFormat:index ? @" %02X" : @"%02X", bytes[index]];
	}
	return result;
}

static BOOL AAPDiagInvokeModeGetter(id target, unsigned int *mode) {
	if (!target || !mode) {
		return NO;
	}
	SEL selector = NSSelectorFromString(@"listeningMode");
	if (![target respondsToSelector:selector]) {
		return NO;
	}
	NSMethodSignature *signature =
		[target methodSignatureForSelector:selector];
	if (!signature || signature.methodReturnLength == 0) {
		return NO;
	}

	NSInvocation *invocation =
		[NSInvocation invocationWithMethodSignature:signature];
	invocation.target = target;
	invocation.selector = selector;
	@try {
		[invocation invoke];
	} @catch (__unused NSException *exception) {
		return NO;
	}

	uint64_t raw = 0;
	if (signature.methodReturnLength > sizeof(raw)) {
		return NO;
	}
	[invocation getReturnValue:&raw];
	const char *type = signature.methodReturnType;
	switch (type ? type[0] : 'I') {
		case 'c':
			*mode = (unsigned int)(int8_t)raw;
			break;
		case 'C':
		case 'B':
			*mode = (unsigned int)(uint8_t)raw;
			break;
		case 's':
			*mode = (unsigned int)(int16_t)raw;
			break;
		case 'S':
			*mode = (unsigned int)(uint16_t)raw;
			break;
		case 'i':
			*mode = (unsigned int)(int32_t)raw;
			break;
		case 'I':
			*mode = (unsigned int)(uint32_t)raw;
			break;
		case 'q':
		case 'Q':
		case 'l':
		case 'L':
			*mode = (unsigned int)(uint64_t)raw;
			break;
		default:
			*mode = (unsigned int)(uint32_t)raw;
			break;
	}
	return YES;
}

unsigned int AAPDiagReadLocalListeningMode(id device, BOOL *available) {
	unsigned int mode = 0;
	BOOL ok = AAPDiagInvokeModeGetter(device, &mode);
	if (available) {
		*available = ok;
	}
	return ok ? mode : 0;
}

BOOL AAPDiagWriteHelperRequest(NSString *address,
	unsigned int mode,
	unsigned long long sequence) {
	NSString *normalized = AAPDiagNormalizeAddress(address);
	if (!normalized.length) {
		return NO;
	}
	NSDictionary *request = @{
		@"address": normalized,
		@"mode": @(mode),
		@"sequence": @(sequence),
		@"created": @([[NSDate date] timeIntervalSince1970]),
	};
	NSData *data = [NSPropertyListSerialization
		dataWithPropertyList:request
		format:NSPropertyListBinaryFormat_v1_0
		options:0
		error:nil];
	if (!data) {
		return NO;
	}
	unlink(AAPDiagRequestPath.fileSystemRepresentation);
	BOOL written = [data writeToFile:AAPDiagRequestPath
		options:NSDataWritingAtomic
		error:nil];
	if (written) {
		chmod(AAPDiagRequestPath.fileSystemRepresentation, 0644);
	}
	return written;
}

NSDictionary<NSString *, id> *AAPDiagReadHelperResult(
	unsigned long long sequence) {
	NSData *data = [NSData dataWithContentsOfFile:AAPDiagResultPath];
	if (!data.length) {
		return nil;
	}
	id plist = [NSPropertyListSerialization
		propertyListWithData:data
		options:NSPropertyListImmutable
		format:nil
		error:nil];
	if (![plist isKindOfClass:[NSDictionary class]]) {
		return nil;
	}
	NSDictionary *result = plist;
	if ([result[@"sequence"] unsignedLongLongValue] != sequence) {
		return nil;
	}
	return result;
}
