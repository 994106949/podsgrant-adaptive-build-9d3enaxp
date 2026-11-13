#import "AdaptiveAACP.h"

#import <objc/runtime.h>
#import <stdarg.h>
#import <string.h>
#import <unistd.h>

NSString *const AAPAdaptiveLogPath =
	@"/var/mobile/Library/Preferences/com.lns.pogr.adaptive.log";

static const NSUInteger AAPReadbackAttempts = 12;
static const useconds_t AAPReadbackInterval = 100 * 1000;
static const useconds_t AAPConfigSettleDelay = 100 * 1000;

void AAPAdaptiveLog(NSString *format, ...) {
	NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
	formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";

	va_list arguments;
	va_start(arguments, format);
	NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
	va_end(arguments);

	NSString *line = [NSString stringWithFormat:@"%@ [%@] %@\n",
		[formatter stringFromDate:[NSDate date]],
		[[NSProcessInfo processInfo] processName],
		message ?: @""];
	NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
	if (!data) {
		return;
	}

	NSFileManager *fileManager = [NSFileManager defaultManager];
	NSString *directory = [AAPAdaptiveLogPath stringByDeletingLastPathComponent];
	[fileManager createDirectoryAtPath:directory
		withIntermediateDirectories:YES
		attributes:nil
		error:nil];
	if (![fileManager fileExistsAtPath:AAPAdaptiveLogPath]) {
		[fileManager createFileAtPath:AAPAdaptiveLogPath contents:nil attributes:nil];
	}

	NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:AAPAdaptiveLogPath];
	if (!handle) {
		[data writeToFile:AAPAdaptiveLogPath atomically:YES];
		return;
	}
	@try {
		[handle seekToEndOfFile];
		if ([handle offsetInFile] > 512 * 1024) {
			[handle truncateFileAtOffset:0];
			[handle seekToFileOffset:0];
		}
		[handle writeData:data];
	} @catch (__unused NSException *exception) {
	} @finally {
		[handle closeFile];
	}
}

static BOOL AAPInvokeUnsignedSetter(id target,
	SEL selector,
	unsigned int value,
	BOOL *hasReturn,
	BOOL *returnValue,
	NSString **error) {
	if (hasReturn) {
		*hasReturn = NO;
	}
	if (returnValue) {
		*returnValue = YES;
	}
	if (!target || ![target respondsToSelector:selector]) {
		if (error) {
			*error = @"selector is unavailable";
		}
		return NO;
	}

	NSMethodSignature *signature = [target methodSignatureForSelector:selector];
	if (!signature || signature.numberOfArguments < 3) {
		if (error) {
			*error = @"unsupported method signature";
		}
		return NO;
	}

	const char *argumentType = [signature getArgumentTypeAtIndex:2];
	if (!argumentType) {
		if (error) {
			*error = @"missing argument type";
		}
		return NO;
	}

	NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
	invocation.target = target;
	invocation.selector = selector;
	switch (argumentType[0]) {
		case 'c': {
			int8_t argument = (int8_t)value;
			[invocation setArgument:&argument atIndex:2];
			break;
		}
		case 'C':
		case 'B': {
			uint8_t argument = (uint8_t)value;
			[invocation setArgument:&argument atIndex:2];
			break;
		}
		case 's': {
			int16_t argument = (int16_t)value;
			[invocation setArgument:&argument atIndex:2];
			break;
		}
		case 'S': {
			uint16_t argument = (uint16_t)value;
			[invocation setArgument:&argument atIndex:2];
			break;
		}
		case 'i': {
			int32_t argument = (int32_t)value;
			[invocation setArgument:&argument atIndex:2];
			break;
		}
		case 'I': {
			uint32_t argument = (uint32_t)value;
			[invocation setArgument:&argument atIndex:2];
			break;
		}
		case 'l': {
			int64_t argument = (int64_t)value;
			[invocation setArgument:&argument atIndex:2];
			break;
		}
		case 'L': {
			uint64_t argument = (uint64_t)value;
			[invocation setArgument:&argument atIndex:2];
			break;
		}
		case 'q': {
			int64_t argument = (int64_t)value;
			[invocation setArgument:&argument atIndex:2];
			break;
		}
		case 'Q': {
			uint64_t argument = (uint64_t)value;
			[invocation setArgument:&argument atIndex:2];
			break;
		}
		default:
			if (error) {
				*error = [NSString stringWithFormat:@"unsupported argument type %s",
					argumentType];
			}
			return NO;
	}

	@try {
		[invocation invoke];
	} @catch (NSException *exception) {
		if (error) {
			*error = exception.reason ?: @"Objective-C invocation raised an exception";
		}
		return NO;
	}

	BOOL methodHasReturn = signature.methodReturnLength > 0;
	const char *methodReturnType = signature.methodReturnType;
	if (methodReturnType && methodReturnType[0] == 'v') {
		methodHasReturn = NO;
	}
	if (hasReturn) {
		*hasReturn = methodHasReturn;
	}
	if (methodHasReturn && returnValue) {
		uint8_t returnBytes[sizeof(uint64_t)] = {0};
		NSUInteger returnLength = signature.methodReturnLength;
		if (returnLength > sizeof(returnBytes)) {
			returnLength = sizeof(returnBytes);
		}
		[invocation getReturnValue:returnBytes];
		*returnValue = returnBytes[0] != 0;
	}
	return YES;
}

static BOOL AAPReadListeningMode(id target,
	unsigned int *mode,
	NSString **error) {
	SEL selector = NSSelectorFromString(@"listeningMode");
	if (!target || ![target respondsToSelector:selector]) {
		if (error) {
			*error = @"listeningMode selector is unavailable";
		}
		return NO;
	}

	NSMethodSignature *signature = [target methodSignatureForSelector:selector];
	if (!signature || signature.methodReturnLength == 0) {
		if (error) {
			*error = @"listeningMode has no return value";
		}
		return NO;
	}

	NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
	invocation.target = target;
	invocation.selector = selector;
	@try {
		[invocation invoke];
	} @catch (NSException *exception) {
		if (error) {
			*error = exception.reason ?: @"listeningMode invocation raised an exception";
		}
		return NO;
	}

	uint64_t raw = 0;
	NSUInteger returnLength = signature.methodReturnLength;
	if (returnLength > sizeof(raw)) {
		if (error) {
			*error = @"listeningMode returned an unsupported width";
		}
		return NO;
	}
	[invocation getReturnValue:&raw];

	const char *returnType = signature.methodReturnType;
	unsigned int value = 0;
	switch (returnType ? returnType[0] : 'I') {
		case 'c':
			value = (unsigned int)(int8_t)raw;
			break;
		case 'C':
		case 'B':
			value = (unsigned int)(uint8_t)raw;
			break;
		case 's':
			value = (unsigned int)(int16_t)raw;
			break;
		case 'S':
			value = (unsigned int)(uint16_t)raw;
			break;
		case 'i':
			value = (unsigned int)(int32_t)raw;
			break;
		case 'I':
			value = (unsigned int)(uint32_t)raw;
			break;
		case 'q':
		case 'Q':
		case 'l':
		case 'L':
			value = (unsigned int)(uint64_t)raw;
			break;
		default:
			value = (unsigned int)(uint32_t)raw;
			break;
	}

	if (value < AAPListeningModeOff || value > AAPListeningModeAdaptive) {
		if (error) {
			*error = [NSString stringWithFormat:@"listeningMode returned %u", value];
		}
		return NO;
	}
	if (mode) {
		*mode = value;
	}
	return YES;
}

BOOL AAPAdaptiveReadListeningMode(id device, unsigned int *mode) {
	return AAPReadListeningMode(device, mode, nil);
}

static unsigned int AAPTargetMode(BOOL enabled) {
	return enabled ? AAPListeningModeAdaptive : AAPListeningModeTransparency;
}

static void AAPFinishOnMain(AAPAdaptiveCompletion completion,
	BOOL confirmed,
	BOOL sent,
	unsigned int readback,
	NSString *error) {
	if (!completion) {
		return;
	}
	dispatch_async(dispatch_get_main_queue(), ^{
		completion(confirmed, sent, readback, error);
	});
}

static void AAPStartReadbackPolling(id device,
	unsigned int targetMode,
	NSUInteger attempt,
	unsigned int lastReadback,
	NSString *lastError,
	AAPAdaptiveCompletion completion) {
	unsigned int readback = 0;
	NSString *readError = nil;
	if (AAPReadListeningMode(device, &readback, &readError)) {
		lastReadback = readback;
		if (readback == targetMode) {
			AAPAdaptiveLog(@"listeningMode readback confirmed %u", targetMode);
			AAPFinishOnMain(completion, YES, YES, readback, nil);
			return;
		}
		lastError = [NSString stringWithFormat:@"readback reported %u instead of %u",
			readback, targetMode];
		AAPAdaptiveLog(@"listeningMode readback attempt=%lu got=%u expected=%u",
			(unsigned long)(attempt + 1), readback, targetMode);
	} else if (readError) {
		lastError = readError;
	}

	if (attempt + 1 >= AAPReadbackAttempts) {
		if (!lastError) {
			lastError = @"no listeningMode readback was available";
		}
		AAPAdaptiveLog(@"listeningMode readback failed expected=%u last=%u error=%@",
			targetMode, lastReadback, lastError);
		AAPFinishOnMain(completion, NO, YES, lastReadback, lastError);
		return;
	}

	dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
		(int64_t)AAPReadbackInterval * NSEC_PER_USEC),
		dispatch_get_main_queue(), ^{
			AAPStartReadbackPolling(device,
				targetMode,
				attempt + 1,
				lastReadback,
				lastError,
				completion);
		});
}

void AAPAdaptiveRequestListeningMode(id device,
	BOOL enabled,
	AAPAdaptiveCompletion completion) {
	unsigned int targetMode = AAPTargetMode(enabled);
	if (!device) {
		AAPAdaptiveLog(@"request failed: BluetoothDevice is nil");
		AAPFinishOnMain(completion, NO, NO, 0, @"BluetoothDevice is nil");
		return;
	}

	unsigned int initialMode = 0;
	NSString *initialError = nil;
	if (AAPReadListeningMode(device, &initialMode, &initialError) &&
		initialMode == targetMode) {
		AAPAdaptiveLog(@"listeningMode readback confirmed %u (already active)",
			targetMode);
		AAPFinishOnMain(completion, YES, NO, initialMode, nil);
		return;
	}
	if (initialError) {
		AAPAdaptiveLog(@"initial listeningMode unavailable: %@", initialError);
	}

	NSString *configError = nil;
	BOOL configHasReturn = NO;
	BOOL configReturn = YES;
	BOOL configInvoked = AAPInvokeUnsignedSetter(device,
		NSSelectorFromString(@"setListeningModeConfigs:"),
		0x0F,
		&configHasReturn,
		&configReturn,
		&configError);
	AAPAdaptiveLog(@"setListeningModeConfigs:0x0F invoked=%d returned=%d error=%@",
		configInvoked,
		configHasReturn ? (int)configReturn : -1,
		configError ?: @"none");

	SEL setterSelector = NSSelectorFromString(@"setListeningMode:");
	if (![device respondsToSelector:setterSelector]) {
		AAPAdaptiveLog(@"setListeningMode: selector is unavailable");
		AAPFinishOnMain(completion, NO, NO, 0,
			@"BluetoothDevice does not expose setListeningMode:");
		return;
	}

	dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
		(int64_t)AAPConfigSettleDelay * NSEC_PER_USEC),
		dispatch_get_main_queue(), ^{
			NSString *setterError = nil;
			BOOL setterHasReturn = NO;
			BOOL setterReturn = YES;
			BOOL setterInvoked = AAPInvokeUnsignedSetter(device,
				setterSelector,
				targetMode,
				&setterHasReturn,
				&setterReturn,
				&setterError);
			if (!setterInvoked) {
				AAPAdaptiveLog(@"setListeningMode:%u invocation failed error=%@",
					targetMode, setterError ?: @"unknown");
				AAPFinishOnMain(completion, NO, NO, 0, setterError);
				return;
			}
			AAPAdaptiveLog(@"setListeningMode:%u was sent returned=%d",
				targetMode,
				setterHasReturn ? (int)setterReturn : -1);
			AAPStartReadbackPolling(device,
				targetMode,
				0,
				0,
				@"no readback yet",
				completion);
		});
}
