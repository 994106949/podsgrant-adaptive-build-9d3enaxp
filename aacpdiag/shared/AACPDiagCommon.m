#import "AACPDiag.h"

#import <errno.h>
#import <fcntl.h>
#import <notify.h>
#import <os/log.h>
#import <stdarg.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>

NSString *const AAPDiagLogPath =
	@"/var/mobile/Library/Preferences/com.lns.pogr.aacpdiag.log";
NSString *const AAPDiagFallbackLogPath =
	@"/var/tmp/com.lns.pogr.aacpdiag/helper-boot.log";
NSString *const AAPDiagTmpLogPath =
	@"/tmp/com.lns.pogr.aacpdiag/helper-boot.log";
NSString *const AAPDiagRequestPath =
	@"/var/mobile/Library/Preferences/com.lns.pogr.aacpdiag.request.plist";
NSString *const AAPDiagResultPath =
	@"/var/mobile/Library/Preferences/com.lns.pogr.aacpdiag.result.plist";
NSString *const AAPDiagFallbackRequestPath =
	@"/var/tmp/com.lns.pogr.aacpdiag/request.plist";
NSString *const AAPDiagFallbackResultPath =
	@"/var/tmp/com.lns.pogr.aacpdiag/result.plist";
NSString *const AAPDiagTmpRequestPath =
	@"/tmp/com.lns.pogr.aacpdiag/request.plist";
NSString *const AAPDiagTmpResultPath =
	@"/tmp/com.lns.pogr.aacpdiag/result.plist";
NSString *const AAPDiagReadyPath =
	@"/var/mobile/Library/Preferences/com.lns.pogr.aacpdiag.helper.plist";
NSString *const AAPDiagFallbackReadyPath =
	@"/var/tmp/com.lns.pogr.aacpdiag/helper.plist";
NSString *const AAPDiagTmpReadyPath =
	@"/tmp/com.lns.pogr.aacpdiag/helper.plist";
NSString *const AAPDiagDarwinNotification =
	@"com.lns.pogr.aacpdiag.request";
const char *const AAPDiagNotifyName =
	"com.lns.pogr.aacpdiag.request.notify";
NSString *const AAPDiagVersion = @"0.5.7~adts3diag6";

static void AAPDiagAppendLine(NSString *path, NSString *message) {
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

	NSString *directory = [path stringByDeletingLastPathComponent];
	if (directory.length) {
		mkdir(directory.fileSystemRepresentation, 0777);
		chmod(directory.fileSystemRepresentation, 0777);
	}

	int fd = open(path.fileSystemRepresentation,
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
	chmod(path.fileSystemRepresentation, 0666);
}

void AAPDiagLogToPath(NSString *path, NSString *format, ...) {
	if (!path.length) {
		return;
	}
	va_list arguments;
	va_start(arguments, format);
	NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
	va_end(arguments);
	AAPDiagAppendLine(path, message);
}

void AAPDiagLog(NSString *format, ...) {
	va_list arguments;
	va_start(arguments, format);
	NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
	va_end(arguments);

	const char *mirrorValue = getenv("AACPDIAG_CONSOLE_LOG");
	if (mirrorValue && strcmp(mirrorValue, "0") != 0) {
		os_log_with_type(OS_LOG_DEFAULT,
			OS_LOG_TYPE_DEFAULT,
			"[PodsGrantAACPDiag] %{public}@",
			message ?: @"");
	}

	static dispatch_once_t pathsOnce;
	static NSArray<NSString *> *paths;
	dispatch_once(&pathsOnce, ^{
		paths = @[
			AAPDiagLogPath,
			AAPDiagFallbackLogPath,
			AAPDiagTmpLogPath,
		];
	});

	BOOL wrote = NO;
	for (NSString *path in paths) {
		NSFileManager *manager = [NSFileManager defaultManager];
		BOOL existed = [manager fileExistsAtPath:path];
		AAPDiagAppendLine(path, message);
		if (!existed && [manager fileExistsAtPath:path]) {
			wrote = YES;
		}
		if (existed) {
			wrote = YES;
		}
	}
	if (!wrote) {
		os_log_with_type(OS_LOG_DEFAULT,
			OS_LOG_TYPE_ERROR,
			"[PodsGrantAACPDiag] log unavailable paths=%{public}@ message=%{public}@",
			paths.description,
			message ?: @"");
	}
}

void AAPDiagSetLogMirroring(BOOL enabled) {
	setenv("AACPDIAG_CONSOLE_LOG", enabled ? "1" : "0", 0);
}

static BOOL AAPDiagEnsureParentDirectory(NSString *path) {
	NSString *directory = [path stringByDeletingLastPathComponent];
	if (!directory.length) {
		return NO;
	}
	if (mkdir(directory.fileSystemRepresentation, 0777) != 0 &&
		errno != EEXIST) {
		return NO;
	}
	chmod(directory.fileSystemRepresentation, 0777);
	return YES;
}

void AAPDiagEnsureRuntimeDirectories(void) {
	for (NSString *directory in @[
		@"/var/tmp/com.lns.pogr.aacpdiag",
		@"/tmp/com.lns.pogr.aacpdiag",
		@"/var/mobile/Library/Preferences",
	]) {
		mkdir(directory.fileSystemRepresentation, 0777);
		chmod(directory.fileSystemRepresentation, 0777);
	}
	for (NSString *path in @[
		AAPDiagLogPath,
		AAPDiagFallbackLogPath,
		AAPDiagTmpLogPath,
	]) {
		chmod(path.fileSystemRepresentation, 0666);
	}
}

void AAPDiagRemoveRequestAndResultPaths(void) {
	for (NSString *path in [AAPDiagRequestPaths()
		arrayByAddingObjectsFromArray:AAPDiagResultPaths()]) {
		unlink(path.fileSystemRepresentation);
	}
}

NSArray<NSString *> *AAPDiagRequestPaths(void) {
	return @[
		AAPDiagFallbackRequestPath,
		AAPDiagRequestPath,
		AAPDiagTmpRequestPath,
	];
}

NSArray<NSString *> *AAPDiagResultPaths(void) {
	return @[
		AAPDiagFallbackResultPath,
		AAPDiagResultPath,
		AAPDiagTmpResultPath,
	];
}

NSArray<NSString *> *AAPDiagReadyPaths(void) {
	return @[
		AAPDiagFallbackReadyPath,
		AAPDiagReadyPath,
		AAPDiagTmpReadyPath,
	];
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
	BOOL written = NO;
	for (NSString *path in AAPDiagRequestPaths()) {
		AAPDiagEnsureParentDirectory(path);
		unlink(path.fileSystemRepresentation);
		BOOL current = [data writeToFile:path
			options:NSDataWritingAtomic
			error:nil];
		if (current) {
			chmod(path.fileSystemRepresentation, 0666);
			written = YES;
		} else {
			AAPDiagLog(@"helper request write failed path=%@", path);
		}
	}
	return written;
}

NSDictionary<NSString *, id> *AAPDiagReadResultForSource(
	unsigned long long sequence,
	NSString *source) {
	for (NSString *path in AAPDiagResultPaths()) {
		NSData *data = [NSData dataWithContentsOfFile:path];
		if (!data.length) {
			continue;
		}
		id plist = [NSPropertyListSerialization
			propertyListWithData:data
			options:NSPropertyListImmutable
			format:nil
			error:nil];
		if (![plist isKindOfClass:[NSDictionary class]]) {
			continue;
		}
		NSDictionary *result = plist;
		if ([result[@"sequence"] unsignedLongLongValue] != sequence) {
			continue;
		}
		if (source.length &&
			![result[@"source"] isEqual:source]) {
			continue;
		}
		if (result) {
			return result;
		}
	}
	return nil;
}

NSDictionary<NSString *, id> *AAPDiagReadHelperResult(
	unsigned long long sequence) {
	return AAPDiagReadResultForSource(sequence, nil);
}

BOOL AAPDiagWritePlistToPaths(NSDictionary<NSString *, id> *plist,
	NSArray<NSString *> *paths) {
	NSData *data = [NSPropertyListSerialization
		dataWithPropertyList:plist
		format:NSPropertyListBinaryFormat_v1_0
		options:0
		error:nil];
	if (!data) {
		return NO;
	}
	BOOL written = NO;
	for (NSString *path in paths) {
		if (!AAPDiagEnsureParentDirectory(path)) {
			AAPDiagLog(@"plist directory unavailable path=%@", path);
			continue;
		}
		BOOL current = [data writeToFile:path
			options:NSDataWritingAtomic
			error:nil];
		if (current) {
			chmod(path.fileSystemRepresentation, 0666);
			written = YES;
		} else {
			AAPDiagLog(@"plist write failed path=%@", path);
		}
	}
	return written;
}

BOOL AAPDiagWriteHelperReady(NSDictionary<NSString *, id> *ready) {
	NSMutableDictionary *payload = [ready mutableCopy] ?: [NSMutableDictionary dictionary];
	payload[@"pid"] = @(getpid());
	payload[@"updated"] = @([[NSDate date] timeIntervalSince1970]);
	BOOL written = AAPDiagWritePlistToPaths(payload, AAPDiagReadyPaths());
	int token = 0;
	if (notify_register_check(AAPDiagNotifyName, &token) == NOTIFY_STATUS_OK) {
		uint64_t state = payload[@"sequence"]
			? [payload[@"sequence"] unsignedLongLongValue]
			: 1;
		notify_set_state(token, state);
		notify_cancel(token);
	}
	notify_post(AAPDiagNotifyName);
	return written;
}

NSDictionary<NSString *, id> *AAPDiagReadReadyForSource(NSString *source) {
	NSDictionary *latest = nil;
	double latestTime = 0;
	for (NSString *path in AAPDiagReadyPaths()) {
		NSData *data = [NSData dataWithContentsOfFile:path];
		if (!data.length) {
			continue;
		}
		id plist = [NSPropertyListSerialization
			propertyListWithData:data
			options:NSPropertyListImmutable
			format:nil
			error:nil];
		if (![plist isKindOfClass:[NSDictionary class]]) {
			continue;
		}
		NSDictionary *candidate = plist;
		if (source.length &&
			![candidate[@"source"] isEqual:source]) {
			continue;
		}
		double updated = [candidate[@"updated"] doubleValue];
		if (!latest || updated > latestTime) {
			latest = candidate;
			latestTime = updated;
		}
	}
	return latest;
}

NSDictionary<NSString *, id> *AAPDiagReadHelperReady(void) {
	return AAPDiagReadReadyForSource(nil);
}
