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

static NSString *AAPDiagReadySummary(NSDictionary *ready) {
	if (![ready isKindOfClass:[NSDictionary class]]) {
		return @"daemon_not_loaded";
	}
	NSString *status = ready[@"status"] ?: @"daemon_unknown";
	NSString *executable = ready[@"executable"] ?: @"?";
	NSString *version = ready[@"version"] ?: @"?";
	return [NSString stringWithFormat:@"%@ source=%@ version=%@ exe=%@ pid=%@",
		status,
		ready[@"source"] ?: @"?",
		version,
		executable.lastPathComponent ?: executable,
		ready[@"pid"] ?: @"?"];
}

static BOOL AAPDiagResultHasProtocolACK(NSDictionary *result) {
	return [result[@"status"] isEqualToString:@"protocol_ack"];
}

static NSDictionary *AAPDiagWaitForDaemonResult(
	unsigned long long sequence,
	NSTimeInterval timeout) {
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
	while ([deadline timeIntervalSinceNow] > 0) {
		NSDictionary *result =
			AAPDiagReadResultForSource(sequence, @"aacpdiagd");
		if (result) {
			return result;
		}
		[NSThread sleepForTimeInterval:0.1];
	}
	return nil;
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

	NSDictionary *daemonResult = nil;
	if (address.length) {
		BOOL posted = AAPDiagWriteHelperRequest(address, mode, sequence);
		AAPDiagLog(@"daemon_request posted=%d sequence=%llu mode=%u",
			posted,
			sequence,
			mode);
		if (posted) {
			NSDictionary *readyBefore =
				AAPDiagReadReadyForSource(@"aacpdiagd");
			combined[@"daemon_ready"] = readyBefore ?: @{
				@"status": @"daemon_not_loaded",
			};
			CFNotificationCenterPostNotification(
				CFNotificationCenterGetDarwinNotifyCenter(),
				(__bridge CFStringRef)AAPDiagDarwinNotification,
				NULL,
				NULL,
				true);
			notify_post(AAPDiagNotifyName);
			daemonResult = AAPDiagWaitForDaemonResult(sequence, 4.0);
			if (!daemonResult) {
				NSDictionary *readyAfter =
					AAPDiagReadReadyForSource(@"aacpdiagd");
				combined[@"daemon_ready_after"] = readyAfter ?: @{};
				daemonResult = @{
					@"status": readyAfter
						? @"daemon_loaded_no_reply"
						: @"daemon_not_loaded",
					@"source": @"aacpdiagd",
				};
			}
			combined[@"daemon"] = daemonResult;
			AAPDiagLog(@"ui_daemon_result mode=%u summary=%@",
				mode,
				AAPDiagStatusSummary(daemonResult));
		} else {
			combined[@"daemon"] = @{
				@"status": @"request_write_failed",
				@"source": @"aacpdiagd",
			};
		}
	}

	NSDictionary *daemonFinal = combined[@"daemon"];
	BOOL daemonACK = AAPDiagResultHasProtocolACK(daemonFinal);
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
	combined[@"status"] = daemonACK
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
	AAPDiagLog(@"ui_combined_result mode=%u status=%@ native=%@ daemon=%@",
		mode,
		combined[@"status"],
		nativeStatus ?: @"unknown",
		AAPDiagStatusSummary(daemonFinal));
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
	NSString *message = [NSString stringWithFormat:
		@"Native: %@\nLocal getter (informational only): %@ -> %@\n"
		@"Daemon: %@\nReady: %@\n\nLog: %@",
		native[@"status"] ?: @"none",
		before[@"description"] ?: @"unavailable",
		after[@"description"] ?: @"unavailable",
		AAPDiagStatusSummary(result[@"daemon"]),
		AAPDiagReadySummary(result[@"daemon_ready_after"] ?:
			result[@"daemon_ready"]),
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
