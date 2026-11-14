#import <Foundation/Foundation.h>

#import <mach-o/dyld.h>
#import <os/log.h>
#import <string.h>

#import "../shared/AACPDiag.h"

static BOOL AAPDiagHelperIsBluetoothd;
static BOOL AAPDiagHelperIsHeard;
static unsigned long long AAPDiagHelperLastSequence;
static NSTimeInterval AAPDiagHelperLastReadyTime;
static dispatch_queue_t AAPDiagHelperPollQueue;

static NSString *AAPDiagHelperSource(void) {
	if (AAPDiagHelperIsBluetoothd) {
		return @"bluetoothd";
	}
	if (AAPDiagHelperIsHeard) {
		return @"heard";
	}
	return @"unknown";
}

static void AAPDiagHelperPublishPolling(NSString *status,
	unsigned long long lastSequence) {
	AAPDiagWriteHelperReady(@{
		@"status": status ?: @"helper_polling",
		@"source": AAPDiagHelperSource(),
		@"version": AAPDiagVersion,
		@"interval_ms": @250,
		@"last_sequence": @(lastSequence),
	});
	AAPDiagHelperLastReadyTime = [[NSDate date] timeIntervalSince1970];
}

static NSDictionary<NSString *, id> *AAPDiagHelperInvalidRequest(
	NSDictionary<NSString *, id> *request,
	NSString *path,
	NSString *reason) {
	return @{
		@"status": @"invalid_request",
		@"mode": request[@"mode"] ?: @0,
		@"address": AAPDiagNormalizeAddress(request[@"address"]) ?: @"",
		@"trace": @[reason ?: @"invalid_request", path ?: @""],
		@"rx_packets": @[],
		@"timestamp": @([[NSDate date] timeIntervalSince1970]),
	};
}

static void AAPDiagHelperPoll(void) {
	@autoreleasepool {
		NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
		if (now - AAPDiagHelperLastReadyTime >= 2.0) {
			AAPDiagHelperPublishPolling(@"helper_polling",
				AAPDiagHelperLastSequence);
		}

		NSString *path = nil;
		NSDictionary<NSString *, id> *request =
			AAPDiagReadLatestRequest(&path);
		if (!request) {
			return;
		}
		unsigned long long sequence =
			[request[@"sequence"] unsignedLongLongValue];
		if (sequence == 0 || sequence == AAPDiagHelperLastSequence) {
			return;
		}
		AAPDiagHelperLastSequence = sequence;

		NSString *source = AAPDiagHelperSource();
		NSString *claimant = nil;
		if (AAPDiagRequestIsClaimed(sequence, &claimant)) {
			NSString *expected = [NSString stringWithFormat:
				@"source=%@", source];
			if (![claimant containsString:expected]) {
				AAPDiagLog(@"helper_request_skip sequence=%llu "
					@"source=%@ claimant=%@ path=%@",
					sequence,
					source,
					claimant ?: @"unknown",
					path ?: @"");
				return;
			}
		} else if (!AAPDiagClaimRequest(sequence, source)) {
			AAPDiagRequestIsClaimed(sequence, &claimant);
			AAPDiagLog(@"helper_request_claim_failed sequence=%llu "
				@"source=%@ claimant=%@ path=%@",
				sequence,
				source,
				claimant ?: @"unknown",
				path ?: @"");
			return;
		}

		NSString *address = AAPDiagNormalizeAddress(request[@"address"]);
		unsigned int mode = [request[@"mode"] unsignedIntValue];
		AAPDiagLog(@"helper_request_poll sequence=%llu source=%@ "
			@"address=%@ mode=%u path=%@",
			sequence,
			source,
			address ?: @"nil",
			mode,
			path ?: @"");
		AAPDiagLog(@"helper_transport_start source=%@ sequence=%llu "
			@"address=%@ mode=%u",
			source,
			sequence,
			address ?: @"nil",
			mode);

		NSDictionary<NSString *, id> *transport = nil;
		if (!address.length || sequence == 0) {
			transport = AAPDiagHelperInvalidRequest(request,
				path,
				address.length ? @"invalid_sequence" : @"invalid_address");
		} else {
			transport = AAPDiagRunTransportTest(address, mode);
		}
		AAPDiagWriteTransportResult(transport,
			sequence,
			source,
			path);
		AAPDiagHelperPublishPolling(@"helper_polling", sequence);
	}
}

static void AAPDiagStartRequestPoller(void) {
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		AAPDiagHelperPollQueue = dispatch_queue_create(
			"com.lns.pogr.aacpdiag.helper.poll",
			DISPATCH_QUEUE_SERIAL);
		AAPDiagHelperPublishPolling(@"helper_polling", 0);
		dispatch_source_t timer = dispatch_source_create(
			DISPATCH_SOURCE_TYPE_TIMER,
			0,
			0,
			AAPDiagHelperPollQueue);
		uint64_t interval = 250ULL * NSEC_PER_MSEC;
		dispatch_source_set_timer(timer,
			dispatch_time(DISPATCH_TIME_NOW, (int64_t)interval),
			interval,
			50ULL * NSEC_PER_MSEC);
		dispatch_source_set_event_handler(timer, ^{
			AAPDiagHelperPoll();
		});
		dispatch_resume(timer);
		dispatch_async(AAPDiagHelperPollQueue, ^{
			AAPDiagHelperPoll();
		});
		AAPDiagLog(@"helper_polling_started source=%@ "
			@"interval_ms=250 version=%@",
			AAPDiagHelperSource(),
			AAPDiagVersion);
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
	AAPDiagStartRequestPoller();
}
