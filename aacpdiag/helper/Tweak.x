#import <Foundation/Foundation.h>

#import <mach-o/dyld.h>
#import <os/log.h>
#import <string.h>

#import "../shared/AACPDiag.h"

static BOOL AAPDiagHelperIsBluetoothd;
static BOOL AAPDiagHelperIsHeard;

static NSString *AAPDiagHelperSource(void) {
	if (AAPDiagHelperIsBluetoothd) {
		return @"bluetoothd";
	}
	if (AAPDiagHelperIsHeard) {
		return @"heard";
	}
	return @"unknown";
}

%ctor {
	char executablePath[1024] = {0};
	uint32_t length = sizeof(executablePath);
	_NSGetExecutablePath(executablePath, &length);
	NSString *executable = executablePath[0]
		? [NSString stringWithUTF8String:executablePath]
		: @"unknown";
	NSString *processName = NSProcessInfo.processInfo.processName ?: @"";
	AAPDiagSetLogMirroring(YES);
	AAPDiagLog(@"diag_marker source=helper event=dylib_ctor "
		@"executable=%@ process=%@ pid=%d",
		executable,
		processName,
		getpid());

	BOOL isBluetoothd =
		strstr(executablePath, "bluetoothd") != NULL ||
		[processName isEqualToString:@"bluetoothd"];
	BOOL isHeard =
		strstr(executablePath, "heard") != NULL ||
		[processName isEqualToString:@"heard"];
	if (!isBluetoothd && !isHeard) {
		AAPDiagLog(@"helper_ctor_skip executable=%@ process=%@",
			executable,
			processName);
		return;
	}
	AAPDiagHelperIsBluetoothd = isBluetoothd;
	AAPDiagHelperIsHeard = isHeard;

	AAPDiagWriteHelperReady(@{
		@"status": @"helper_loaded",
		@"executable": executable,
		@"is_bluetoothd": @(isBluetoothd),
		@"is_heard": @(isHeard),
		@"source": AAPDiagHelperSource(),
		@"version": AAPDiagVersion,
	});
	AAPDiagLog(@"helper_loaded executable=%@ process=%@ source=%@",
		executable,
		processName,
		AAPDiagHelperSource());

	AAPDiagInstallRuntimeHooks();
	AAPDiagWriteHelperReady(@{
		@"status": @"helper_ready",
		@"executable": executable,
		@"is_bluetoothd": @(isBluetoothd),
		@"is_heard": @(isHeard),
		@"source": AAPDiagHelperSource(),
		@"version": AAPDiagVersion,
	});
}
