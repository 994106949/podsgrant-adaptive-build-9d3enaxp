#import <Foundation/Foundation.h>

#import <mach-o/dyld.h>
#import <notify.h>
#import <os/log.h>
#import <string.h>
#import <sys/stat.h>

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

static void AAPDiagWriteResult(NSDictionary<NSString *, id> *result) {
	NSMutableDictionary *payload = [result mutableCopy] ?: [NSMutableDictionary dictionary];
	payload[@"source"] = AAPDiagHelperSource();
	BOOL written = AAPDiagWritePlistToPaths(payload, AAPDiagResultPaths());
	AAPDiagLog(@"helper result_write=%d source=%@ sequence=%llu status=%@ "
		@"variant=%@ rx_count=%lu",
		written,
		AAPDiagHelperSource(),
		[payload[@"sequence"] unsignedLongLongValue],
		payload[@"status"] ?: @"unknown",
		payload[@"socket_variant"] ?: @"none",
		(unsigned long)[payload[@"rx_packets"] count]);
	notify_post(AAPDiagNotifyName);
}

static void AAPDiagHandleRequest(void) {
	@autoreleasepool {
		NSData *data = nil;
		NSString *requestPath = nil;
		for (NSString *path in AAPDiagRequestPaths()) {
			NSData *candidate = [NSData dataWithContentsOfFile:path];
			if (candidate.length) {
				data = candidate;
				requestPath = path;
				break;
			}
		}
		if (!data.length) {
			return;
		}
		id plist = [NSPropertyListSerialization
			propertyListWithData:data
			options:NSPropertyListImmutable
			format:nil
			error:nil];
		if (![plist isKindOfClass:[NSDictionary class]]) {
			AAPDiagLog(@"helper request plist invalid path=%@", requestPath);
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
		AAPDiagLog(@"helper request_path=%@", requestPath);
		AAPDiagLog(@"diag_marker source=helper event=request_received "
			@"process=%@ sequence=%llu address=%@ mode=%u",
			AAPDiagHelperSource(),
			sequence,
			address ?: @"nil",
			mode);
		if (!address.length || sequence == 0) {
			NSMutableDictionary *invalid = [@{
				@"status": @"invalid_request",
				@"mode": @(mode),
				@"sequence": @(sequence),
				@"address": address ?: @"",
				@"trace": @[
					address.length ? @"invalid_sequence" : @"invalid_address",
				],
				@"rx_packets": @[],
				@"timestamp": @([[NSDate date] timeIntervalSince1970]),
			} mutableCopy];
			AAPDiagWriteResult(invalid);
			return;
		}

		AAPDiagLog(@"helper_transport_start source=%@ sequence=%llu "
			@"address=%@ mode=%u",
			AAPDiagHelperSource(),
			sequence,
			address,
			mode);
		NSDictionary *transport = AAPDiagRunTransportTest(address, mode);
		NSMutableDictionary *result = [transport mutableCopy];
		result[@"sequence"] = @(sequence);
		result[@"request_path"] = requestPath ?: @"";
		AAPDiagLog(@"helper_transport_done source=%@ sequence=%llu "
			@"status=%@ variant=%@ tx_bytes=%@ rx_count=%lu",
			AAPDiagHelperSource(),
			sequence,
			result[@"status"] ?: @"unknown",
			result[@"socket_variant"] ?: @"none",
			result[@"mode_frame"] ?: @"none",
			(unsigned long)[result[@"rx_packets"] count]);
		AAPDiagWriteResult(result);
	}
}

static void AAPDiagPollRequests(void) {
	static unsigned long long lastSequence;
	@autoreleasepool {
		for (NSString *path in AAPDiagRequestPaths()) {
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
			unsigned long long sequence =
				[plist[@"sequence"] unsignedLongLongValue];
			if (sequence == lastSequence) {
				continue;
			}
			lastSequence = sequence;
			AAPDiagLog(@"helper_poll picked sequence=%llu path=%@",
				sequence,
				path);
			AAPDiagHandleRequest();
			return;
		}
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
			AAPDiagPollRequests();
		});
}

static void AAPDiagNotifyCallback(int token) {
	(void)token;
	dispatch_async(
		dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
			AAPDiagPollRequests();
		});
}

static void AAPDiagStartWatchdog(void) {
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		dispatch_queue_t queue = dispatch_queue_create(
			"com.lns.pogr.aacpdiag.helper-watchdog",
			DISPATCH_QUEUE_SERIAL);
		dispatch_source_t timer = dispatch_source_create(
			DISPATCH_SOURCE_TYPE_TIMER,
			0,
			0,
			queue);
		uint64_t interval = 250ULL * NSEC_PER_MSEC;
		dispatch_source_set_timer(timer,
			dispatch_time(DISPATCH_TIME_NOW, (int64_t)interval),
			interval,
			50ULL * NSEC_PER_MSEC);
		dispatch_source_set_event_handler(timer, ^{
			AAPDiagPollRequests();
		});
		dispatch_resume(timer);

		int token = 0;
		int status = notify_register_dispatch(
			AAPDiagNotifyName,
			&token,
			dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0),
			^(int notifiedToken) {
				AAPDiagNotifyCallback(notifiedToken);
			});
		AAPDiagLog(@"helper_watchdog started source=%@ interval_ms=250 "
			@"notify_status=%d notify_token=%d",
			AAPDiagHelperSource(),
			status,
			token);
	});
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
		@"version": @"0.5.7~adts3diag5",
	});
	AAPDiagLog(@"helper_loaded executable=%@ process=%@ source=%@",
		executable,
		processName,
		AAPDiagHelperSource());

	AAPDiagInstallRuntimeHooks();
	CFNotificationCenterAddObserver(
		CFNotificationCenterGetDarwinNotifyCenter(),
		NULL,
		AAPDiagDarwinCallback,
		(__bridge CFStringRef)AAPDiagDarwinNotification,
		NULL,
		CFNotificationSuspensionBehaviorDeliverImmediately);
	AAPDiagStartWatchdog();
	AAPDiagWriteHelperReady(@{
		@"status": @"helper_ready",
		@"executable": executable,
		@"is_bluetoothd": @(isBluetoothd),
		@"is_heard": @(isHeard),
		@"source": AAPDiagHelperSource(),
		@"version": @"0.5.7~adts3diag5",
	});
}
