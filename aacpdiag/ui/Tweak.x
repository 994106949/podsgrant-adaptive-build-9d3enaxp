#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import <objc/runtime.h>
#import <notify.h>
#import <unistd.h>

#import "../shared/AACPDiag.h"

@interface BluetoothDevice : NSObject
- (NSString *)address;
- (unsigned int)productId;
@end

@interface BTSDeviceClassic : NSObject
- (BluetoothDevice *)device;
@end

@interface BTSDeviceConfigController : UIViewController
- (void)pgsDiagRunMode:(NSNumber *)modeNumber;
- (void)pgsDiagShowMenu:(UIBarButtonItem *)sender;
@end

static const void *AAPDiagButtonKey = &AAPDiagButtonKey;
static const void *AAPDiagBusyKey = &AAPDiagBusyKey;
static unsigned long long AAPDiagSequence = 1;

static NSString *AAPDiagModeName(unsigned int mode) {
	switch (mode) {
		case AAPDiagModeNoiseCancellation:
			return @"ANC";
		case AAPDiagModeTransparency:
			return @"Transparency";
		case AAPDiagModeAdaptive:
			return @"Adaptive";
		default:
			return [NSString stringWithFormat:@"mode %u", mode];
	}
}

static id AAPDiagRawDevice(BTSDeviceConfigController *controller) {
	Class currentClass = object_getClass(controller);
	while (currentClass) {
		Ivar ivar = class_getInstanceVariable(currentClass, "_device");
		if (ivar) {
			return object_getIvar(controller, ivar);
		}
		currentClass = class_getSuperclass(currentClass);
	}
	return nil;
}

static BluetoothDevice *AAPDiagBluetoothDevice(
	BTSDeviceConfigController *controller) {
	id rawDevice = AAPDiagRawDevice(controller);
	if (!rawDevice) {
		return nil;
	}
	if ([rawDevice respondsToSelector:@selector(device)]) {
		return ((BTSDeviceClassic *)rawDevice).device;
	}
	return rawDevice;
}

static NSString *AAPDiagFirstPacket(NSDictionary *result) {
	NSArray *packets = result[@"rx_packets"];
	if (![packets isKindOfClass:[NSArray class]] || !packets.count) {
		return @"none";
	}
	return [packets componentsJoinedByString:@" | "];
}

static NSString *AAPDiagStatusSummary(NSDictionary *result) {
	if (![result isKindOfClass:[NSDictionary class]]) {
		return @"no result";
	}
	NSString *status = result[@"status"] ?: @"unknown";
	NSDictionary *modeAck = result[@"mode_ack"];
	NSString *echo = @"";
	if ([modeAck isKindOfClass:[NSDictionary class]] &&
		modeAck.count) {
		echo = [NSString stringWithFormat:@" echo=%@",
			modeAck[@"echoed_mode"] ?: @"?"];
	}
	return [NSString stringWithFormat:@"%@%@ rx=%@",
		status,
		echo,
		AAPDiagFirstPacket(result)];
}

static BOOL AAPDiagResultHasProtocolACK(NSDictionary *result) {
	return [result[@"status"] isEqualToString:@"protocol_ack"];
}

static NSArray<NSString *> *AAPDiagTransportSources(void) {
	return @[@"bluetoothd", @"heard", @"aacpdiagd"];
}

static NSDictionary<NSString *, id> *AAPDiagReadTransportReadiness(void) {
	NSMutableDictionary<NSString *, id> *readiness =
		[NSMutableDictionary dictionary];
	for (NSString *source in AAPDiagTransportSources()) {
		readiness[source] =
			AAPDiagReadReadyForSource(source) ?: @{
				@"status": @"not_loaded",
				@"source": source,
			};
	}
	return readiness;
}

static NSString *AAPDiagTransportReadinessSummary(
	NSDictionary<NSString *, id> *readiness) {
	NSMutableArray<NSString *> *parts = [NSMutableArray array];
	if (![readiness isKindOfClass:[NSDictionary class]]) {
		return @"invalid";
	}
	for (NSString *source in AAPDiagTransportSources()) {
		id value = readiness[source];
		if (![value isKindOfClass:[NSDictionary class]]) {
			[parts addObject:[NSString stringWithFormat:@"%@:invalid",
				source]];
			continue;
		}
		NSDictionary *ready = value;
		NSString *status = ready[@"status"] ?: @"unknown";
		[parts addObject:[NSString stringWithFormat:@"%@:%@",
			source,
			status]];
	}
	return parts.count
		? [parts componentsJoinedByString:@" "]
		: @"none";
}

static NSInteger AAPDiagTransportResultPriority(NSDictionary *result) {
	if (![result isKindOfClass:[NSDictionary class]]) {
		return -1;
	}
	NSString *status = result[@"status"];
	if ([status isEqualToString:@"protocol_ack"]) {
		return 100;
	}
	if ([status isEqualToString:@"protocol_reply_mismatch"]) {
		return 80;
	}
	if ([status isEqualToString:@"invalid_request"]) {
		return 60;
	}
	if ([status isEqualToString:@"timed_out"]) {
		return 50;
	}
	if ([status isEqualToString:@"connect_failed"]) {
		return 40;
	}
	return 20;
}

static NSDictionary *AAPDiagWaitForTransportResult(
	unsigned long long sequence,
	NSTimeInterval timeout,
	NSDictionary<NSString *, id> **resultsBySource,
	NSDictionary<NSString *, id> **readinessAfter) {
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
	NSMutableDictionary<NSString *, NSDictionary *> *results =
		[NSMutableDictionary dictionary];
	while ([deadline timeIntervalSinceNow] > 0) {
		for (NSString *source in AAPDiagTransportSources()) {
			if (results[source]) {
				continue;
			}
			NSDictionary *result =
				AAPDiagReadResultForSource(sequence, source);
			if (result) {
				results[source] = result;
				AAPDiagLog(@"transport_result source=%@ sequence=%llu "
					@"summary=%@",
					source,
					sequence,
					AAPDiagStatusSummary(result));
			}
		}
		for (NSDictionary *result in results.allValues) {
			if (AAPDiagResultHasProtocolACK(result)) {
				if (resultsBySource) {
					*resultsBySource = results;
				}
				if (readinessAfter) {
					*readinessAfter =
						AAPDiagReadTransportReadiness();
				}
				return result;
			}
		}
		[NSThread sleepForTimeInterval:0.1];
	}
	NSDictionary *best = nil;
	NSInteger bestPriority = -1;
	for (NSDictionary *result in results.allValues) {
		NSInteger priority = AAPDiagTransportResultPriority(result);
		if (priority > bestPriority) {
			best = result;
			bestPriority = priority;
		}
	}
	if (resultsBySource) {
		*resultsBySource = results;
	}
	if (readinessAfter) {
		*readinessAfter = AAPDiagReadTransportReadiness();
	}
	return best;
}

static NSDictionary *AAPDiagRunCombinedTest(
	BluetoothDevice *device,
	unsigned int mode) {
	NSString *address = AAPDiagNormalizeAddress(device.address);

	BOOL initialGetterAvailable = NO;
	unsigned int initialGetter =
		AAPDiagReadLocalListeningMode(device, &initialGetterAvailable);
	AAPDiagLog(@"local_getter before available=%d value=%u mode=%u address=%@",
		initialGetterAvailable,
		initialGetter,
		mode,
		address);

	NSArray *candidates = AAPDiagDiscoverDeviceCandidates(address);
	NSMutableArray *testCandidates = [NSMutableArray array];
	for (id candidate in candidates ?: @[]) {
		BOOL duplicate = NO;
		for (id existing in testCandidates) {
			if (existing == candidate) {
				duplicate = YES;
				break;
			}
		}
		if (!duplicate) {
			[testCandidates addObject:candidate];
		}
	}
	BOOL devicePresent = NO;
	for (id existing in testCandidates) {
		if (existing == device) {
			devicePresent = YES;
			break;
		}
	}
	if (device && !devicePresent) {
		[testCandidates addObject:device];
	}
	AAPDiagLog(@"ui_candidates mode=%u expected=%@ count=%lu "
		@"merged_device=%d",
		mode,
		address ?: @"",
		(unsigned long)testCandidates.count,
		device ? 1 : 0);
	NSDictionary *nativeResult = testCandidates.count
		? AAPDiagRunNativeTestOnCandidates(testCandidates, address, mode)
		: AAPDiagRunNativeTest(device, mode);
	AAPDiagLog(@"ui_native_result mode=%u status=%@ before=%@ after=%@ "
		@"candidates=%lu",
		mode,
		nativeResult[@"status"] ?: @"unknown",
		nativeResult[@"before"] ?: @{},
		nativeResult[@"after"] ?: @{},
		(unsigned long)testCandidates.count);

	unsigned long long sequence =
		(unsigned long long)([[NSDate date] timeIntervalSince1970] * 1000.0) +
		AAPDiagSequence++;
	NSMutableDictionary *combined = [@{
		@"status": @"pending",
		@"mode": @(mode),
		@"address": address ?: @"",
		@"sequence": @(sequence),
		@"native": nativeResult,
	} mutableCopy];

	NSDictionary *transportResult = nil;
	NSDictionary<NSString *, id> *transportResults = @{};
	NSDictionary<NSString *, id> *transportReadinessAfter = @{};
	if (address.length) {
		BOOL posted = AAPDiagWriteHelperRequest(address, mode, sequence);
		AAPDiagLog(@"transport_request posted=%d sequence=%llu mode=%u",
			posted,
			sequence,
			mode);
		if (posted) {
			NSDictionary<NSString *, id> *readyBefore =
				AAPDiagReadTransportReadiness();
			combined[@"transport_ready"] = readyBefore;
			AAPDiagLog(@"ui_transport_ready_before sequence=%llu %@",
				sequence,
				AAPDiagTransportReadinessSummary(readyBefore));
			CFNotificationCenterPostNotification(
				CFNotificationCenterGetDarwinNotifyCenter(),
				(__bridge CFStringRef)AAPDiagDarwinNotification,
				NULL,
				NULL,
				true);
			notify_post(AAPDiagNotifyName);
			transportResult = AAPDiagWaitForTransportResult(
				sequence,
				30.0,
				&transportResults,
				&transportReadinessAfter);
			combined[@"transport_results"] = transportResults;
			combined[@"transport_ready_after"] =
				transportReadinessAfter;
			AAPDiagLog(@"ui_transport_ready_after sequence=%llu %@",
				sequence,
				AAPDiagTransportReadinessSummary(
					transportReadinessAfter));
			if (!transportResult) {
				NSDictionary<NSString *, id> *readyAfter =
					transportReadinessAfter;
				BOOL anyLoaded = NO;
				for (id value in readyAfter.allValues) {
					if (![value isKindOfClass:[NSDictionary class]]) {
						continue;
					}
					NSDictionary *ready = value;
					NSString *status = ready[@"status"];
					if (status &&
						![status isEqualToString:@"not_loaded"]) {
						anyLoaded = YES;
						break;
					}
				}
				transportResult = @{
					@"status": anyLoaded
						? @"transport_no_reply"
						: @"transport_not_loaded",
					@"source": @"none",
				};
			}
			combined[@"transport"] = transportResult;
			combined[@"transport_source"] =
				transportResult[@"source"] ?: @"none";
			combined[@"transport_ready"] = transportReadinessAfter;
			AAPDiagLog(@"ui_transport_result mode=%u source=%@ "
				@"summary=%@ results=%lu",
				mode,
				combined[@"transport_source"],
				AAPDiagStatusSummary(transportResult),
				(unsigned long)transportResults.count);
		} else {
			transportResult = @{
				@"status": @"request_write_failed",
				@"source": @"none",
			};
			combined[@"transport"] = transportResult;
			combined[@"transport_source"] = @"none";
		}
	}

	BOOL transportACK =
		AAPDiagResultHasProtocolACK(transportResult);
	NSString *nativeStatus = nativeResult[@"status"];
	BOOL nativeInvoked =
		[nativeStatus isEqualToString:
			@"native_setters_invoked_unconfirmed"] ||
		[nativeStatus isEqualToString:@"local_getter_only"];
	BOOL deviceMissing =
		[nativeStatus isEqualToString:@"native_device_missing"] ||
		[nativeStatus isEqualToString:@"device_missing"];
	BOOL setterMissing =
		[nativeStatus isEqualToString:@"native_setter_missing"] ||
		[nativeStatus isEqualToString:@"setter_missing"];
	combined[@"status"] = transportACK
		? @"protocol_ack"
		: (nativeInvoked
			? @"native_setter_invoked_unconfirmed"
			: (deviceMissing
				? @"device_missing"
				: (setterMissing
					? @"setter_missing"
					: @"no_confirmation")));

	BOOL finalGetterAvailable = NO;
	unsigned int finalGetter =
		AAPDiagReadLocalListeningMode(device, &finalGetterAvailable);
	combined[@"local_getter_before"] = @{
		@"available": @(initialGetterAvailable),
		@"value": @(initialGetter),
	};
	combined[@"local_getter_after"] = @{
		@"available": @(finalGetterAvailable),
		@"value": @(finalGetter),
	};
	AAPDiagLog(@"local_getter after available=%d value=%u (not used as success)",
		finalGetterAvailable,
		finalGetter);
	AAPDiagLog(@"getter is not device confirmation");
	AAPDiagLog(@"ui_combined_result mode=%u status=%@ native=%@ "
		@"transport=%@ source=%@",
		mode,
		combined[@"status"],
		nativeStatus ?: @"unknown",
		AAPDiagStatusSummary(transportResult),
		combined[@"transport_source"] ?: @"none");
	return combined;
}

static NSString *AAPDiagConfirmationTitle(NSDictionary *result) {
	NSString *status = result[@"status"] ?: @"unknown";
	if ([status isEqualToString:@"protocol_ack"]) {
		return @"Protocol ACK";
	}
	if ([status isEqualToString:
		@"native_setter_invoked_unconfirmed"]) {
		return @"Native Setter Invoked / Unconfirmed";
	}
	if ([status isEqualToString:@"local_getter_only"]) {
		return @"Local Getter Only";
	}
	if ([status isEqualToString:@"device_missing"]) {
		return @"Device Missing";
	}
	if ([status isEqualToString:@"setter_missing"]) {
		return @"Setter Missing";
	}
	return @"No Confirmation";
}

static void AAPDiagShowResult(BTSDeviceConfigController *controller,
	UIBarButtonItem *button,
	unsigned int mode,
	NSDictionary *result) {
	objc_setAssociatedObject(controller,
		AAPDiagBusyKey,
		@NO,
		OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	button.enabled = YES;
	button.title = @"AACP";

	BOOL ack = AAPDiagResultHasProtocolACK(result);
	NSString *title = [NSString stringWithFormat:@"AACP %@: %@",
		AAPDiagModeName(mode),
		AAPDiagConfirmationTitle(result)];
	NSDictionary *native = [result[@"native"] isKindOfClass:[NSDictionary class]]
		? result[@"native"]
		: @{};
	NSDictionary *before = [native[@"before"] isKindOfClass:[NSDictionary class]]
		? native[@"before"]
		: @{};
	NSDictionary *after = [native[@"after"] isKindOfClass:[NSDictionary class]]
		? native[@"after"]
		: @{};
	NSDictionary *transportReady =
		[result[@"transport_ready"] isKindOfClass:[NSDictionary class]]
			? result[@"transport_ready"]
			: @{};
	NSDictionary *transportResults =
		[result[@"transport_results"] isKindOfClass:[NSDictionary class]]
			? result[@"transport_results"]
			: @{};
	NSArray<NSString *> *resultSources = transportResults.allKeys ?: @[];
	NSString *message = [NSString stringWithFormat:
		@"Native: %@\nLocal getter (informational only): %@ -> %@\n"
		@"Transport: %@\nSource: %@\nReady: %@\n"
		@"Result sources: %@\n\nLog: %@",
		native[@"status"] ?: @"none",
		before[@"description"] ?: @"unavailable",
		after[@"description"] ?: @"unavailable",
		AAPDiagStatusSummary(result[@"transport"]),
		result[@"transport_source"] ?: @"none",
		AAPDiagTransportReadinessSummary(
			transportReady),
		resultSources.count
			? [resultSources componentsJoinedByString:@", "]
			: @"none",
		AAPDiagLogPath];
	if (!ack && [result[@"status"] isEqualToString:@"device_missing"]) {
		message = [message stringByAppendingString:
			@"\n\nIf Device Missing: manually switch ANC/Transparency "
			@"once in Settings, return here, then retry."];
	}
	UIAlertController *alert = [UIAlertController
		alertControllerWithTitle:title
		message:message
		preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:@"OK"
		style:UIAlertActionStyleDefault
		handler:nil]];
	[controller presentViewController:alert animated:YES completion:nil];
}

%group AAPDiagHooks

%hook BTSDeviceConfigController

- (void)viewDidAppear:(BOOL)animated {
	%orig;
	BluetoothDevice *device = AAPDiagBluetoothDevice(self);
	NSString *address = AAPDiagNormalizeAddress(device.address);
	UIBarButtonItem *existing =
		objc_getAssociatedObject(self, AAPDiagButtonKey);
	if (existing || !address.length) {
		return;
	}

	UIBarButtonItem *button = [[UIBarButtonItem alloc]
		initWithTitle:@"AACP"
		style:UIBarButtonItemStylePlain
		target:self
		action:@selector(pgsDiagShowMenu:)];
	button.accessibilityHint = @"Test AirPods AACP listening modes";
	NSMutableArray<UIBarButtonItem *> *items =
		[self.navigationItem.rightBarButtonItems mutableCopy];
	if (!items) {
		items = [NSMutableArray array];
	}
	[items insertObject:button atIndex:0];
	self.navigationItem.rightBarButtonItems = items;
	objc_setAssociatedObject(self,
		AAPDiagButtonKey,
		button,
		OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	AAPDiagLog(@"ui_button_installed productId=%u address=%@",
		device.productId,
		address);
}

%new
- (void)pgsDiagRunMode:(NSNumber *)modeNumber {
	BluetoothDevice *device = AAPDiagBluetoothDevice(self);
	UIBarButtonItem *button =
		objc_getAssociatedObject(self, AAPDiagButtonKey);
	if (!device || !button) {
		return;
	}
	if ([objc_getAssociatedObject(self, AAPDiagBusyKey) boolValue]) {
		return;
	}
	objc_setAssociatedObject(self,
		AAPDiagBusyKey,
		@YES,
		OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	unsigned int mode = modeNumber.unsignedIntValue;
	AAPDiagLog(@"diag_marker source=aacp_ui event=test_start mode=%u",
		mode);
	button.enabled = NO;
	button.title = [NSString stringWithFormat:@"Testing %@",
		AAPDiagModeName(mode)];

	dispatch_async(
		dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
			NSDictionary *result =
				AAPDiagRunCombinedTest(device, mode);
			dispatch_async(dispatch_get_main_queue(), ^{
				AAPDiagShowResult(self, button, mode, result);
			});
		});
}

%new
- (void)pgsDiagRunAll:(UIAlertController *)alert {
	[alert dismissViewControllerAnimated:YES completion:^{
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
			(3 + 2) * NSEC_PER_SEC),
			dispatch_get_main_queue(), ^{
				[self pgsDiagRunMode:@(AAPDiagModeNoiseCancellation)];
			});
	}];
}

%new
- (void)pgsDiagShowMenu:(UIBarButtonItem *)sender {
	BluetoothDevice *device = AAPDiagBluetoothDevice(self);
	NSString *address = AAPDiagNormalizeAddress(device.address);
	if (!address.length) {
		return;
	}
	UIAlertController *sheet = [UIAlertController
		alertControllerWithTitle:@"AACP Diagnostic"
		message:[NSString stringWithFormat:
			@"%@\nproductId=%u\n\nEach test writes 0x0F, sets the mode, then reads it back.",
			address,
			device.productId]
		preferredStyle:UIAlertControllerStyleActionSheet];
	for (NSNumber *mode in @[
		@(AAPDiagModeNoiseCancellation),
		@(AAPDiagModeTransparency),
		@(AAPDiagModeAdaptive),
	]) {
		NSString *label = [NSString stringWithFormat:@"Test %@ (0x%02X)",
			AAPDiagModeName(mode.unsignedIntValue),
			mode.unsignedIntValue];
		[sheet addAction:[UIAlertAction actionWithTitle:label
			style:UIAlertActionStyleDefault
			handler:^(__unused UIAlertAction *action) {
				[self pgsDiagRunMode:mode];
			}]];
	}
	[sheet addAction:[UIAlertAction actionWithTitle:@"Cancel"
		style:UIAlertActionStyleCancel
		handler:nil]];
	if (sheet.popoverPresentationController) {
		sheet.popoverPresentationController.barButtonItem = sender;
	}
	[self presentViewController:sheet animated:YES completion:nil];
}

%end

%end

%ctor {
	NSString *bundleIdentifier =
		[[NSBundle mainBundle] bundleIdentifier];
	AAPDiagLog(@"ui_loaded bundle=%@ pid=%d",
		bundleIdentifier ?: @"unknown",
		getpid());
	if ([bundleIdentifier isEqualToString:@"com.apple.Preferences"]) {
		[[NSBundle bundleWithPath:
			@"/System/Library/PreferenceBundles/BluetoothSettings.bundle"]
			load];
		%init(AAPDiagHooks);
		AAPDiagInstallRuntimeHooks();
	}
}
