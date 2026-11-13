#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreBluetooth/CoreBluetooth.h>
#import <objc/runtime.h>

#include "../general.h"
#import "AdaptiveAACP.h"

@interface HCSettings : NSObject
- (void)setValue:(id)value forPreferenceKey:(NSString *)key;
- (id)objectValueForKey:(NSString *)key
	withClass:(Class)cls
	andDefaultValue:(id)value;
@end

@interface PASettings : HCSettings
+ (instancetype)sharedInstance;
- (BOOL)adaptiveTransparencyEnabledForAddress:(NSString *)address;
- (void)setAdaptiveTransparencyEnabled:(BOOL)enabled
	forAddress:(NSString *)address;
- (void)_setAdaptiveTransparencyEnabled:(BOOL)enabled
	forAddress:(NSString *)address;
- (BOOL)transparencyCustomizedForAddress:(NSString *)address;
- (void)setTransparencyCustomized:(BOOL)customized
	forAddress:(NSString *)address;
@end

@interface PAAccessoryManager : NSObject
- (NSArray *)peripherals;
- (NSDictionary *)uuidToAddress;
- (void)sendUpdateToAccessory;
@end

@interface BluetoothDevice : NSObject
- (NSString *)address;
- (unsigned int)productId;
@end

@interface BTSDeviceClassic : NSObject
- (BluetoothDevice *)device;
@end

@interface BTSDeviceConfigController : UIViewController
@end

static NSString *AAPNormalizedAddress(NSString *address) {
	if (![address isKindOfClass:[NSString class]]) {
		return nil;
	}
	NSString *normalized = [address
		stringByTrimmingCharactersInSet:
			[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	return normalized.length ? normalized : nil;
}

static NSArray<NSString *> *AAPPreferenceKeys(NSString *address) {
	NSString *normalized = AAPNormalizedAddress(address);
	if (!normalized.length) {
		return @[];
	}
	NSMutableArray<NSString *> *keys = [NSMutableArray arrayWithObject:normalized];
	NSString *compact = [[normalized
		stringByReplacingOccurrencesOfString:@"-" withString:@""]
		stringByReplacingOccurrencesOfString:@":" withString:@""];
	NSString *legacy = [NSString stringWithFormat:@"adaptive:%@",
		compact.uppercaseString];
	for (NSString *key in @[normalized.uppercaseString, legacy]) {
		if (key.length && ![keys containsObject:key]) {
			[keys addObject:key];
		}
	}
	return keys;
}

static BOOL AAPValueForAddress(NSDictionary *values, NSString *address) {
	if (![values isKindOfClass:[NSDictionary class]]) {
		return NO;
	}
	for (NSString *key in AAPPreferenceKeys(address)) {
		id value = values[key];
		if ([value isKindOfClass:[NSNumber class]]) {
			return [value boolValue];
		}
	}
	return NO;
}

static BOOL AAPProductSupported(unsigned int productId) {
	switch (productId) {
		case 8206:
		case 8212:
		case 8219:
		case 8228:
		case 8231:
		case 8232:
			return YES;
		default:
			return NO;
	}
}

static id AAPRawBluetoothDevice(BTSDeviceConfigController *controller) {
	if (!controller) {
		return nil;
	}
	Ivar deviceIvar = class_getInstanceVariable(object_getClass(controller),
		"_device");
	if (!deviceIvar) {
		return nil;
	}
	return object_getIvar(controller, deviceIvar);
}

static BluetoothDevice *AAPBluetoothDevice(
	BTSDeviceConfigController *controller) {
	id rawDevice = AAPRawBluetoothDevice(controller);
	if (!rawDevice) {
		AAPAdaptiveLog(@"BTSDeviceConfigController._device is nil");
		return nil;
	}
	if ([rawDevice respondsToSelector:@selector(device)]) {
		return [rawDevice device];
	}
	return rawDevice;
}

static void AAPSetSwitchOn(UISwitch *toggle, BOOL on) {
	if (!toggle) {
		return;
	}
	dispatch_async(dispatch_get_main_queue(), ^{
		[toggle setOn:on animated:YES];
		toggle.enabled = YES;
	});
}

%group PASettingsHooks

%hook PASettings

%new
- (BOOL)adaptiveTransparencyEnabledForAddress:(NSString *)address {
	NSDictionary *values = [self
		objectValueForKey:@"activeHearingProtectionEnabled"
		withClass:[NSDictionary class]
		andDefaultValue:nil];
	return AAPValueForAddress(values, address);
}

%new
- (void)_setAdaptiveTransparencyEnabled:(BOOL)enabled
	forAddress:(NSString *)address {
	NSDictionary *current = [self
		objectValueForKey:@"activeHearingProtectionEnabled"
		withClass:[NSDictionary class]
		andDefaultValue:nil];
	NSMutableDictionary *values = [NSMutableDictionary dictionary];
	if ([current isKindOfClass:[NSDictionary class]]) {
		[values addEntriesFromDictionary:current];
	}
	for (NSString *key in AAPPreferenceKeys(address)) {
		values[key] = @(enabled);
	}
	[self setValue:values forPreferenceKey:@"activeHearingProtectionEnabled"];
}

%new
- (void)setAdaptiveTransparencyEnabled:(BOOL)enabled
	forAddress:(NSString *)address {
	[self _setAdaptiveTransparencyEnabled:enabled forAddress:address];

	/*
	 * This second write is the IPC nudge used by PodsGrant 0.5.4. It makes
	 * `heard` run PAAccessoryManager and push the native BLE characteristic.
	 */
	SEL getter = @selector(transparencyCustomizedForAddress:);
	SEL setter = @selector(setTransparencyCustomized:forAddress:);
	if ([self respondsToSelector:getter] &&
		[self respondsToSelector:setter]) {
		BOOL customized = [self transparencyCustomizedForAddress:address];
		[self setTransparencyCustomized:customized forAddress:address];
		AAPAdaptiveLog(@"transparencyCustomized refresh address=%@ value=%d",
			address,
			customized);
	} else {
		AAPAdaptiveLog(@"transparencyCustomized selectors unavailable");
	}
}

%end

%end

%group PAAccessoryHooks

/*
 * Preferences only stores the value. `heard` owns the connected
 * CBPeripheral, so the native adaptive-transparency characteristic must be
 * written in that process.
 */
%hook PAAccessoryManager

- (void)sendUpdateToAccessory {
	PASettings *settings = [PASettings sharedInstance];
	NSDictionary *uuidToAddress = [self uuidToAddress];
	CBUUID *adaptiveUUID = [CBUUID
		UUIDWithString:@"a48fec08-3921-43db-82aa-afbce8ebb4fb"];

	for (CBPeripheral *peripheral in [self peripherals]) {
		if (peripheral.state != CBPeripheralStateConnected) {
			continue;
		}
		NSString *address = uuidToAddress[[peripheral.identifier UUIDString]];
		if (![address isKindOfClass:[NSString class]] || !address.length) {
			continue;
		}
		BOOL enabled = [settings adaptiveTransparencyEnabledForAddress:address];
		BOOL wrote = NO;
		for (CBService *service in peripheral.services) {
			for (CBCharacteristic *characteristic in service.characteristics) {
				if (![characteristic.UUID isEqual:adaptiveUUID]) {
					continue;
				}
				uint8_t value = enabled ? 1 : 0;
				[peripheral
					writeValue:[NSData dataWithBytes:&value length:1]
					forCharacteristic:characteristic
					type:CBCharacteristicWriteWithoutResponse];
				wrote = YES;
				AAPAdaptiveLog(@"Adaptive BLE characteristic found address=%@ enabled=%d",
					address,
					enabled);
				break;
			}
			if (wrote) {
				break;
			}
		}
		if (wrote) {
			AAPAdaptiveLog(@"Adaptive characteristic write sent enabled=%d address=%@",
				enabled,
				address);
		} else {
			AAPAdaptiveLog(@"Adaptive BLE characteristic missing address=%@",
				address);
		}
	}
	%orig;
}

%end

%end

%group BluetoothSettingsHooks

%hook BTSDeviceConfigController

- (NSInteger)tableView:(UITableView *)tableView
	numberOfRowsInSection:(NSInteger)section {
	BluetoothDevice *device = AAPBluetoothDevice(self);
	unsigned int productId = [device productId];
	if (section == 6) {
		AAPAdaptiveLog(@"settings productId=%u address=%@ supported=%d",
			productId,
			[device address] ?: @"unknown",
			AAPProductSupported(productId));
		if (AAPProductSupported(productId)) {
			NSBundle *bundle = [NSBundle bundleWithPath:
				@"/System/Library/PreferenceBundles/AccessibilitySettings.bundle"];
			[bundle load];
			[[bundle classNamed:@"AccessibilitySettingsController"] new];
			return %orig + 1;
		}
	}
	return %orig;
}

%new
- (void)setAdaptiveTransparencyMode:(UISwitch *)toggle {
	if (!toggle) {
		return;
	}
	BOOL requested = toggle.isOn;
	BluetoothDevice *device = AAPBluetoothDevice(self);
	NSString *address = [device address];
	if (!device || !address.length) {
		AAPAdaptiveLog(@"toggle failed: no connected BluetoothDevice");
		AAPSetSwitchOn(toggle, !requested);
		return;
	}

	toggle.enabled = NO;
	AAPAdaptiveLog(@"toggle requested enabled=%d productId=%u address=%@",
		requested,
		[device productId],
		address);

	PASettings *settings = [PASettings sharedInstance];
	SEL setter = @selector(setAdaptiveTransparencyEnabled:forAddress:);
	if (![settings respondsToSelector:setter]) {
		AAPSetSwitchOn(toggle, !requested);
		AAPAdaptiveLog(@"toggle failed: PASettings setter unavailable");
		return;
	}
	[settings setAdaptiveTransparencyEnabled:requested forAddress:address];
	AAPSetSwitchOn(toggle, requested);
	AAPAdaptiveLog(@"toggle stored enabled=%d address=%@",
		requested,
		address);
}

- (UITableViewCell *)tableView:(UITableView *)tableView
	cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	BluetoothDevice *device = AAPBluetoothDevice(self);
	NSString *address = [device address];
	BOOL supported = AAPProductSupported([device productId]);
	NSInteger rowCount = [tableView numberOfRowsInSection:indexPath.section];
	if (indexPath.section != 6 ||
		!supported ||
		indexPath.row != rowCount - 1) {
		return %orig;
	}

	static NSString *cellIdentifier = @"PodsGrant_AdaptiveTransparencyCell";
	UITableViewCell *cell = [tableView
		dequeueReusableCellWithIdentifier:cellIdentifier];
	if (!cell) {
		cell = [[UITableViewCell alloc]
			initWithStyle:UITableViewCellStyleSubtitle
			reuseIdentifier:cellIdentifier];
		cell.selectionStyle = UITableViewCellSelectionStyleNone;
		cell.textLabel.text = @"Adaptive Transparency Mode";
		cell.detailTextLabel.text = @"Automatic ANC / transparency";
		cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
		cell.accessoryView = [[UISwitch alloc] initWithFrame:CGRectZero];
	}

	UISwitch *toggle = (UISwitch *)cell.accessoryView;
	[toggle removeTarget:nil
		action:NULL
		forControlEvents:UIControlEventAllEvents];

	PASettings *settings = [PASettings sharedInstance];
	BOOL enabled = NO;
	SEL getter = @selector(adaptiveTransparencyEnabledForAddress:);
	if ([settings respondsToSelector:getter]) {
		enabled = [settings adaptiveTransparencyEnabledForAddress:
			address];
	}
	toggle.on = enabled;
	toggle.enabled = YES;
	[toggle addTarget:self
		action:@selector(setAdaptiveTransparencyMode:)
		forControlEvents:UIControlEventValueChanged];
	AAPAdaptiveLog(@"cell productId=%u address=%@ enabled=%d",
		[device productId],
		address ?: @"unknown",
		enabled);
	return cell;
}

%end

%end

%ctor {
	AAPAdaptiveLog(@"loaded bundle=%@ pid=%d",
		[[NSBundle mainBundle] bundleIdentifier],
		getpid());
	FILE *settingsFile = fopen(PGS_SETTINGS_FILE, "rb");
	if (settingsFile) {
		int enabled = fgetc(settingsFile);
		fclose(settingsFile);
		if (enabled == 0) {
			AAPAdaptiveLog(@"PodsGrant master switch is disabled");
			return;
		}
	}
	%init(PASettingsHooks);
	%init(PAAccessoryHooks);
	if ([[[NSBundle mainBundle] bundleIdentifier]
		isEqualToString:@"com.apple.Preferences"]) {
		[[NSBundle bundleWithPath:
			@"/System/Library/PreferenceBundles/BluetoothSettings.bundle"] load];
		%init(BluetoothSettingsHooks);
	}
}
