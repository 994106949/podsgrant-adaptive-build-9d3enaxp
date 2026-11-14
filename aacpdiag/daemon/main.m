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
		@"source": @"aacpdiagd",
		@"version": AAPDiagVersion,
	});
}

static void AAPDiagDaemonProcessRequest(
	NSDictionary<NSString *, id> *request,
	NSString *path,
	unsigned long long sequence) {
	NSString *address = AAPDiagNormalizeAddress(request[@"address"]);
	unsigned int mode = [request[@"mode"] unsignedIntValue];
	AAPDiagLog(@"diag_marker source=aacpdiagd event=request_received "
		@"sequence=%llu address=%@ mode=%u request_path=%@",
		sequence,
		address ?: @"nil",
		mode,
		path);
	if (!address.length || sequence == 0) {
		AAPDiagWriteTransportResult(@{
			@"status": @"invalid_request",
			@"mode": @(mode),
			@"address": address ?: @"",
			@"trace": @[
				address.length ? @"invalid_sequence" : @"invalid_address",
			],
			@"rx_packets": @[],
			@"timestamp": @([[NSDate date] timeIntervalSince1970]),
		}, sequence, @"aacpdiagd", path);
		return;
	}

	AAPDiagLog(@"helper_transport_start source=aacpdiagd "
		@"sequence=%llu address=%@ mode=%u",
		sequence,
		address,
		mode);
	NSDictionary *transport = AAPDiagRunTransportTest(address, mode);
	AAPDiagWriteTransportResult(transport,
		sequence,
		@"aacpdiagd",
		path);
}

static NSMutableSet<NSNumber *> *AAPDiagDaemonObservedSequences;
static NSMutableSet<NSNumber *> *AAPDiagDaemonQueuedSequences;
static NSMutableSet<NSNumber *> *AAPDiagDaemonHandledSequences;
static dispatch_queue_t AAPDiagDaemonPollQueue;

static void AAPDiagDaemonRemember(
	NSMutableSet<NSNumber *> * __strong *set,
	unsigned long long sequence) {
	if (!*set) {
		*set = [NSMutableSet set];
	}
	[*set addObject:@(sequence)];
}

static BOOL AAPDiagDaemonContains(NSMutableSet<NSNumber *> *set,
	unsigned long long sequence) {
	return [set containsObject:@(sequence)];
}

static void AAPDiagDaemonFallback(NSNumber *sequenceNumber,
	NSString *requestPath) {
	@autoreleasepool {
		unsigned long long sequence = sequenceNumber.unsignedLongLongValue;
		NSString *currentPath = nil;
		NSDictionary<NSString *, id> *latest =
			AAPDiagReadLatestRequest(&currentPath);
		unsigned long long currentSequence =
			[latest[@"sequence"] unsignedLongLongValue];
		if (currentSequence != sequence) {
			AAPDiagLog(@"diag_marker source=aacpdiagd "
				@"event=fallback_superseded sequence=%llu current=%llu "
				@"request_path=%@",
				sequence,
				currentSequence,
				requestPath ?: @"");
			return;
		}

		NSDictionary<NSString *, id> *existing =
			AAPDiagReadHelperResult(sequence);
		if (existing) {
			AAPDiagDaemonRemember(&AAPDiagDaemonHandledSequences,
				sequence);
			AAPDiagLog(@"diag_marker source=aacpdiagd "
				@"event=fallback_skipped reason=result_present "
				@"sequence=%llu producer=%@ status=%@",
				sequence,
				existing[@"source"] ?: @"unknown",
				existing[@"status"] ?: @"unknown");
			return;
		}

		NSString *claimant = nil;
		BOOL claimed = AAPDiagRequestIsClaimed(sequence, &claimant);
		BOOL daemonOwnsClaim =
			[claimant containsString:@"source=aacpdiagd"];
		if (claimed && !daemonOwnsClaim) {
			AAPDiagDaemonRemember(&AAPDiagDaemonHandledSequences,
				sequence);
			AAPDiagLog(@"diag_marker source=aacpdiagd "
				@"event=fallback_skipped reason=helper_claimed "
				@"sequence=%llu claimant=%@",
				sequence,
				claimant ?: @"unknown");
			return;
		}
		if (!claimed &&
			!AAPDiagClaimRequest(sequence, @"aacpdiagd")) {
			AAPDiagRequestIsClaimed(sequence, &claimant);
			AAPDiagLog(@"diag_marker source=aacpdiagd "
				@"event=fallback_claim_failed sequence=%llu "
				@"claimant=%@",
				sequence,
				claimant ?: @"unknown");
			return;
		}

		AAPDiagDaemonRemember(&AAPDiagDaemonHandledSequences, sequence);
		AAPDiagLog(@"diag_marker source=aacpdiagd "
			@"event=fallback_claimed sequence=%llu request_path=%@",
			sequence,
			currentPath ?: @"");
		AAPDiagDaemonProcessRequest(latest,
			currentPath,
			sequence);
	}
}

static void AAPDiagDaemonPoll(void) {
	@autoreleasepool {
		NSString *selectedPath = nil;
		NSDictionary<NSString *, id> *request =
			AAPDiagReadLatestRequest(&selectedPath);
		unsigned long long sequence =
			[request[@"sequence"] unsignedLongLongValue];
		if (!request || sequence == 0) {
			return;
		}
		if (AAPDiagDaemonContains(AAPDiagDaemonHandledSequences,
				sequence) ||
			AAPDiagDaemonContains(AAPDiagDaemonQueuedSequences,
				sequence)) {
			return;
		}

		if (!AAPDiagDaemonContains(AAPDiagDaemonObservedSequences,
				sequence)) {
			AAPDiagDaemonRemember(&AAPDiagDaemonObservedSequences,
				sequence);
			AAPDiagLog(@"diag_marker source=aacpdiagd "
				@"event=request_poll sequence=%llu path=%@",
				sequence,
				selectedPath ?: @"");
		}

		NSDictionary<NSString *, id> *existing =
			AAPDiagReadHelperResult(sequence);
		if (existing) {
			AAPDiagDaemonRemember(&AAPDiagDaemonHandledSequences,
				sequence);
			AAPDiagLog(@"diag_marker source=aacpdiagd "
				@"event=request_completed sequence=%llu producer=%@ "
				@"status=%@",
				sequence,
				existing[@"source"] ?: @"unknown",
				existing[@"status"] ?: @"unknown");
			return;
		}

		NSString *claimant = nil;
		if (AAPDiagRequestIsClaimed(sequence, &claimant) &&
			![claimant containsString:@"source=aacpdiagd"]) {
			AAPDiagDaemonRemember(&AAPDiagDaemonHandledSequences,
				sequence);
			AAPDiagLog(@"diag_marker source=aacpdiagd "
				@"event=request_claimed sequence=%llu claimant=%@",
				sequence,
				claimant ?: @"unknown");
			return;
		}

		AAPDiagDaemonRemember(&AAPDiagDaemonQueuedSequences, sequence);
		NSNumber *sequenceNumber = @(sequence);
		NSString *requestPath = [selectedPath copy];
		dispatch_after(
			dispatch_time(DISPATCH_TIME_NOW, 750ULL * NSEC_PER_MSEC),
			AAPDiagDaemonPollQueue,
			^{
				if (AAPDiagDaemonQueuedSequences) {
					[AAPDiagDaemonQueuedSequences
						removeObject:sequenceNumber];
				}
				AAPDiagDaemonFallback(sequenceNumber, requestPath);
			});
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

		AAPDiagDaemonPollQueue = dispatch_queue_create(
			"com.lns.pogr.aacpdiagd.poll",
			DISPATCH_QUEUE_SERIAL);
		int token = 0;
		int notifyStatus = notify_register_dispatch(
			AAPDiagNotifyName,
			&token,
			AAPDiagDaemonPollQueue,
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
			AAPDiagDaemonPollQueue);
		uint64_t interval = 250ULL * NSEC_PER_MSEC;
		dispatch_source_set_timer(timer,
			dispatch_time(DISPATCH_TIME_NOW, (int64_t)interval),
			interval,
			50ULL * NSEC_PER_MSEC);
		dispatch_source_set_event_handler(timer, ^{
			AAPDiagDaemonPoll();
		});
		dispatch_resume(timer);
		dispatch_async(AAPDiagDaemonPollQueue, ^{
			AAPDiagDaemonPoll();
		});
		dispatch_main();
	}
	return 0;
}
