#import <Foundation/Foundation.h>

#import <math.h>
#import <notify.h>
#import <signal.h>
#import <unistd.h>

#import "../shared/AACPDiag.h"

static void AAPDiagDaemonWriteReady(NSString *status) {
	AAPDiagWriteHelperReady(@{
		@"status": status,
		@"executable": NSProcessInfo.processInfo.arguments.firstObject
			?: @"/var/jb/usr/bin/aacpdiagd",
		@"is_bluetoothd": @NO,
		@"is_heard": @NO,
		@"source": @"aacpdiagd",
		@"version": AAPDiagVersion,
	});
}

static void AAPDiagDaemonWriteResult(NSDictionary<NSString *, id> *result,
	unsigned long long sequence,
	NSString *requestPath) {
	NSMutableDictionary *payload =
		[result mutableCopy] ?: [NSMutableDictionary dictionary];
	payload[@"source"] = @"aacpdiagd";
	payload[@"version"] = AAPDiagVersion;
	payload[@"sequence"] = @(sequence);
	payload[@"request_path"] = requestPath ?: @"";
	BOOL written = AAPDiagWritePlistToPaths(payload, AAPDiagResultPaths());
	AAPDiagLog(@"diag_marker source=aacpdiagd event=result_written "
		@"sequence=%llu written=%d status=%@ variant=%@ rx_count=%lu",
		sequence,
		written,
		payload[@"status"] ?: @"unknown",
		payload[@"socket_variant"] ?: @"none",
		(unsigned long)[payload[@"rx_packets"] count]);
	notify_post(AAPDiagNotifyName);
}

static BOOL AAPDiagDaemonHandleRequest(NSString *path) {
	NSData *data = [NSData dataWithContentsOfFile:path];
	if (!data.length) {
		return NO;
	}
	id plist = [NSPropertyListSerialization
		propertyListWithData:data
		options:NSPropertyListImmutable
		format:nil
		error:nil];
	if (![plist isKindOfClass:[NSDictionary class]]) {
		AAPDiagLog(@"diag_marker source=aacpdiagd "
			@"event=request_plist_invalid path=%@", path);
		return NO;
	}

	NSDictionary *request = plist;
	NSString *address = AAPDiagNormalizeAddress(request[@"address"]);
	unsigned int mode = [request[@"mode"] unsignedIntValue];
	unsigned long long sequence =
		[request[@"sequence"] unsignedLongLongValue];
	AAPDiagLog(@"diag_marker source=aacpdiagd event=request_received "
		@"sequence=%llu address=%@ mode=%u request_path=%@",
		sequence,
		address ?: @"nil",
		mode,
		path);
	if (!address.length || sequence == 0) {
		AAPDiagDaemonWriteResult(@{
			@"status": @"invalid_request",
			@"mode": @(mode),
			@"address": address ?: @"",
			@"trace": @[
				address.length ? @"invalid_sequence" : @"invalid_address",
			],
			@"rx_packets": @[],
			@"timestamp": @([[NSDate date] timeIntervalSince1970]),
		}, sequence, path);
		return YES;
	}

	AAPDiagLog(@"helper_transport_start source=aacpdiagd "
		@"sequence=%llu address=%@ mode=%u",
		sequence,
		address,
		mode);
	NSDictionary *transport = AAPDiagRunTransportTest(address, mode);
	AAPDiagDaemonWriteResult(transport, sequence, path);
	return YES;
}

static NSDictionary<NSString *, id> *AAPDiagDaemonReadRequest(NSString *path) {
	NSData *data = [NSData dataWithContentsOfFile:path];
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
	return plist;
}

static void AAPDiagDaemonPoll(void) {
	@autoreleasepool {
		NSString *selectedPath = nil;
		double selectedCreated = 0;
		unsigned long long selectedSequence = 0;
		NSArray<NSString *> *paths = AAPDiagRequestPaths();
		for (NSString *path in paths) {
			NSDictionary *request = AAPDiagDaemonReadRequest(path);
			if (!request) {
				continue;
			}
			double created = [request[@"created"] doubleValue];
			unsigned long long sequence =
				[request[@"sequence"] unsignedLongLongValue];
			BOOL newer = created > selectedCreated + 0.000001;
			BOOL sameTime = fabs(created - selectedCreated) <= 0.000001;
			if (!selectedPath || newer ||
				(sameTime && sequence > selectedSequence)) {
				selectedCreated = created;
				selectedPath = path;
				selectedSequence = sequence;
			}
		}
		if (!selectedPath) {
			return;
		}
		NSString *requestKey = [NSString stringWithFormat:@"created=%.6f sequence=%llu",
			selectedCreated,
			selectedSequence];
		static NSString *lastRequestKey;
		if ([lastRequestKey isEqualToString:requestKey]) {
			return;
		}
		lastRequestKey = requestKey;
		AAPDiagLog(@"diag_marker source=aacpdiagd event=request_poll "
			@"sequence=%llu path=%@", selectedSequence, selectedPath);
		AAPDiagDaemonHandleRequest(selectedPath);
	}
}

static void AAPDiagDaemonSignal(int signalNumber) {
	AAPDiagLog(@"diag_marker source=aacpdiagd event=signal number=%d",
		signalNumber);
	exit(0);
}

int main(int argc, char **argv) {
	@autoreleasepool {
		(void)argc;
		(void)argv;
		AAPDiagSetLogMirroring(YES);
		AAPDiagEnsureRuntimeDirectories();
		AAPDiagLog(@"diag_marker source=aacpdiagd event=helper_loaded "
			@"version=%@ pid=%d executable=%@",
			AAPDiagVersion,
			getpid(),
			NSProcessInfo.processInfo.arguments.firstObject ?: @"?");
		AAPDiagLog(@"helper_loaded source=aacpdiagd version=%@ pid=%d",
			AAPDiagVersion,
			getpid());
		AAPDiagDaemonWriteReady(@"helper_loaded");

		signal(SIGTERM, AAPDiagDaemonSignal);
		signal(SIGINT, AAPDiagDaemonSignal);
		signal(SIGHUP, SIG_IGN);

		dispatch_queue_t pollQueue = dispatch_queue_create(
			"com.lns.pogr.aacpdiagd.poll",
			DISPATCH_QUEUE_SERIAL);
		int token = 0;
		int notifyStatus = notify_register_dispatch(
			AAPDiagNotifyName,
			&token,
			pollQueue,
			^(int notifiedToken) {
				(void)notifiedToken;
				AAPDiagDaemonPoll();
			});
		AAPDiagLog(@"diag_marker source=aacpdiagd "
			@"event=helper_watchdog interval_ms=250 "
			@"notify_status=%d notify_token=%d version=%@",
			notifyStatus,
			token,
			AAPDiagVersion);
		AAPDiagLog(@"helper_watchdog source=aacpdiagd interval_ms=250 "
			@"notify_status=%d version=%@",
			notifyStatus,
			AAPDiagVersion);
		AAPDiagDaemonWriteReady(@"helper_watchdog");

		dispatch_source_t timer = dispatch_source_create(
			DISPATCH_SOURCE_TYPE_TIMER,
			0,
			0,
			pollQueue);
		uint64_t interval = 250ULL * NSEC_PER_MSEC;
		dispatch_source_set_timer(timer,
			dispatch_time(DISPATCH_TIME_NOW, (int64_t)interval),
			interval,
			50ULL * NSEC_PER_MSEC);
		dispatch_source_set_event_handler(timer, ^{
			AAPDiagDaemonPoll();
		});
		dispatch_resume(timer);
		dispatch_async(pollQueue, ^{
			AAPDiagDaemonPoll();
		});
		dispatch_main();
	}
	return 0;
}
