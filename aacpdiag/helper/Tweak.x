#import <Foundation/Foundation.h>

#import <mach-o/dyld.h>
#import <string.h>
#import <sys/stat.h>

#import "../shared/AACPDiag.h"

static void AAPDiagWriteResult(NSDictionary<NSString *, id> *result) {
	NSData *data = [NSPropertyListSerialization
		dataWithPropertyList:result
		format:NSPropertyListBinaryFormat_v1_0
		options:0
		error:nil];
	if (!data) {
		AAPDiagLog(@"helper result serialization failed");
		return;
	}
	BOOL written = [data writeToFile:AAPDiagResultPath
		options:NSDataWritingAtomic
		error:nil];
	if (written) {
		chmod(AAPDiagResultPath.fileSystemRepresentation, 0644);
	}
	AAPDiagLog(@"helper result_write=%d sequence=%llu status=%@",
		written,
		[result[@"sequence"] unsignedLongLongValue],
		result[@"status"] ?: @"unknown");
}

static void AAPDiagHandleRequest(void) {
	@autoreleasepool {
		NSData *data = [NSData dataWithContentsOfFile:AAPDiagRequestPath];
		if (!data.length) {
			AAPDiagLog(@"helper request missing path=%@", AAPDiagRequestPath);
			return;
		}
		id plist = [NSPropertyListSerialization
			propertyListWithData:data
			options:NSPropertyListImmutable
			format:nil
			error:nil];
		if (![plist isKindOfClass:[NSDictionary class]]) {
			AAPDiagLog(@"helper request plist invalid");
			return;
		}

		NSDictionary *request = plist;
		NSString *address = AAPDiagNormalizeAddress(request[@"address"]);
		unsigned int mode = [request[@"mode"] unsignedIntValue];
		unsigned long long sequence =
			[request[@"sequence"] unsignedLongLongValue];
		AAPDiagLog(@"helper request sequence=%llu address=%@ mode=%u",
			sequence,
			address ?: @"nil",
			mode);
		AAPDiagLog(@"diag_marker source=helper event=request_received "
			@"sequence=%llu address=%@ mode=%u",
			sequence,
			address ?: @"nil",
			mode);
		if (!address.length || sequence == 0) {
			return;
		}

		NSDictionary *transport = AAPDiagRunTransportTest(address, mode);
		NSMutableDictionary *result = [transport mutableCopy];
		result[@"sequence"] = @(sequence);
		result[@"source"] = @"bluetoothd";
		AAPDiagWriteResult(result);
	}
}

static void AAPDiagDarwinCallback(CFNotificationCenterRef center,
	void *observer,
	CFStringRef name,
	const void *object,
	CFDictionaryRef userInfo) {
	(void)center;
	(void)observer;
	(void)name;
	(void)object;
	(void)userInfo;
	dispatch_async(
		dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
			AAPDiagHandleRequest();
		});
}

%ctor {
	char executablePath[1024] = {0};
	uint32_t length = sizeof(executablePath);
	_NSGetExecutablePath(executablePath, &length);
	if (!strstr(executablePath, "bluetoothd")) {
		return;
	}

	AAPDiagLog(@"helper_loaded executable=%s", executablePath);
	AAPDiagInstallRuntimeHooks();
	CFNotificationCenterAddObserver(
		CFNotificationCenterGetDarwinNotifyCenter(),
		NULL,
		AAPDiagDarwinCallback,
		(__bridge CFStringRef)AAPDiagDarwinNotification,
		NULL,
		CFNotificationSuspensionBehaviorDeliverImmediately);
}
