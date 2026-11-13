#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreBluetooth/CoreBluetooth.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>

#include "../general.h"
#import "AdaptiveAACP.h"

@interface HCSettings : NSObject
- (void)setValue:(id)value forPreferenceKey:(NSString *)key;
- (id)objectValueForKey:(NSString *)key
	withClass:(Class)cls
	andDefaultValue:(id)value;
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

static NSString *const AAPAdaptivePreferencesPath =
	@"/var/mobile/Library/Preferences/com.lns.pogr.adaptive.plist";
static NSString *const AAPSystemHearingProtectionKey =
	@"activeHearingProtectionEnabled";
static NSString *const AAPAdaptiveCharacteristicUUID =
	@"a48fec08-3921-43db-82aa-afbce8ebb4fb";

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

	NSMutableArray<NSString *> *keys =
		[NSMutableArray arrayWithObject:normalized];
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

static NSDictionary *AAPReadAdaptivePreferences(void) {
	NSDictionary *values = [NSDictionary dictionaryWithContentsOfFile:
		AAPAdaptivePreferencesPath];
	return [values isKindOfClass:[NSDictionary class]] ? values : @{};
}

static BOOL AAPWriteAdaptivePreferences(NSDictionary *values) {
	if (![values isKindOfClass:[NSDictionary class]]) {
		return NO;
	}
	BOOL written = [values writeToFile:AAPAdaptivePreferencesPath
		atomically:YES];
	if (!written) {
		AAPAdaptiveLog(@"adaptive preference write failed path=%@",
			AAPAdaptivePreferencesPath);
	}
	return written;
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

static BOOL AAPStoreAdaptivePreference(NSString *address, BOOL enabled) {
	NSMutableDictionary *values = [AAPReadAdaptivePreferences() mutableCopy];
	if (!values) {
		values = [NSMutableDictionary dictionary];
	}
	for (NSString *key in AAPPreferenceKeys(address)) {
		values[key] = @(enabled);
	}
	return AAPWriteAdaptivePreferences(values);
}

static id AAPSharedPASettings(void) {
	Class settingsClass = objc_getClass("PASettings");
	if (!settingsClass) {
		dlopen("/System/Library/PrivateFrameworks/Preferences.framework/Preferences",
			RTLD_LAZY);
		settingsClass = objc_getClass("PASettings");
	}
	if (!settingsClass) {
		return nil;
	}

	SEL sharedSelector = NSSelectorFromString(@"sharedInstance");
	if (![settingsClass respondsToSelector:sharedSelector]) {
		return nil;
	}
	return ((id (*)(id, SEL))objc_msgSend)((id)settingsClass,
		sharedSelector);
}

static id AAPPreferenceValueForKey(id settings, NSString *key) {
	if (!settings || !key.length) {
		return nil;
	}
	SEL getter = @selector(objectValueForKey:withClass:andDefaultValue:);
	if (![settings respondsToSelector:getter]) {
		return nil;
	}
	return ((id (*)(id, SEL, NSString *, Class, id))objc_msgSend)(
		settings,
		getter,
		key,
		[NSDictionary class],
		nil);
}

static BOOL AAPReadSystemHearingProtection(NSString *address,
	BOOL *found) {
	if (found) {
		*found = NO;
	}

	id settings = AAPSharedPASettings();
	id value = AAPPreferenceValueForKey(settings,
		AAPSystemHearingProtectionKey);
	if (![value isKindOfClass:[NSDictionary class]]) {
		return NO;
	}

	for (NSString *key in AAPPreferenceKeys(address)) {
		id candidate = ((NSDictionary *)value)[key];
		if ([candidate isKindOfClass:[NSNumber class]]) {
			if (found) {
				*found = YES;
			}
			return [candidate boolValue];
		}
	}
	return NO;
}

static BOOL AAPAdaptiveEnabledForAddress(NSString *address) {
	BOOL found = NO;
	BOOL enabled = AAPReadSystemHearingProtection(address, &found);
	if (found) {
		return enabled;
	}
	return AAPValueForAddress(AAPReadAdaptivePreferences(), address);
}

static BOOL AAPWriteSystemHearingProtection(id settings,
	NSString *address,
	BOOL enabled,
	BOOL notifyHeard) {
	if (!settings || !address.length) {
		return NO;
	}

	SEL setter = @selector(setValue:forPreferenceKey:);
	if (![settings respondsToSelector:setter]) {
		AAPAdaptiveLog(@"PASettings setValue:forPreferenceKey: unavailable");
		return NO;
	}

	id current = AAPPreferenceValueForKey(settings,
		AAPSystemHearingProtectionKey);
	NSMutableDictionary *values =
		[current isKindOfClass:[NSDictionary class]]
		? [current mutableCopy]
		: [NSMutableDictionary dictionary];
	values[address] = @(enabled);
	((void (*)(id, SEL, id, NSString *))objc_msgSend)(settings,
		setter,
		values,
		AAPSystemHearingProtectionKey);
	AAPAdaptiveLog(@"system preference address=%@ enabled=%d",
		address,
		enabled);

	if (!notifyHeard) {
		return YES;
	}

	SEL customizedGetter =
		NSSelectorFromString(@"transparencyCustomizedForAddress:");
	SEL customizedSetter =
		NSSelectorFromString(@"setTransparencyCustomized:forAddress:");
	if ([settings respondsToSelector:customizedGetter] &&
		[settings respondsToSelector:customizedSetter]) {
		BOOL customized =
			((BOOL (*)(id, SEL, NSString *))objc_msgSend)(settings,
				customizedGetter,
				address);
		((void (*)(id, SEL, BOOL, NSString *))objc_msgSend)(settings,
			customizedSetter,
			customized,
			address);
		AAPAdaptiveLog(@"heard refresh address=%@ customized=%d",
			address,
			customized);
	} else {
		AAPAdaptiveLog(@"transparencyCustomized selectors unavailable");
	}
	return YES;
}

static BOOL AAPPASettingsAdaptiveEnabled(id self, SEL _cmd,
	NSString *address) {
	(void)self;
	(void)_cmd;
	return AAPAdaptiveEnabledForAddress(address);
}

static void AAPPASettingsSetAdaptiveEnabled(id self, SEL _cmd,
	BOOL enabled,
	NSString *address) {
	(void)_cmd;
	NSString *normalized = AAPNormalizedAddress(address);
	if (!normalized.length) {
		return;
	}
	AAPStoreAdaptivePreference(normalized, enabled);
	AAPWriteSystemHearingProtection(self, normalized, enabled, YES);
}

static void AAPInstallPASettingsMethods(void) {
	Class settingsClass = objc_getClass("PASettings");
	if (!settingsClass) {
		dlopen("/System/Library/PrivateFrameworks/Preferences.framework/Preferences",
			RTLD_LAZY);
		settingsClass = objc_getClass("PASettings");
	}
	if (!settingsClass) {
		AAPAdaptiveLog(@"PASettings unavailable; adaptive plist fallback active");
		return;
	}

	class_addMethod(settingsClass,
		NSSelectorFromString(@"adaptiveTransparencyEnabledForAddress:"),
		(IMP)AAPPASettingsAdaptiveEnabled,
		"B@:@");
	class_addMethod(settingsClass,
		NSSelectorFromString(@"setAdaptiveTransparencyEnabled:forAddress:"),
		(IMP)AAPPASettingsSetAdaptiveEnabled,
		"v@:B@");
	class_addMethod(settingsClass,
		NSSelectorFromString(@"_setAdaptiveTransparencyEnabled:forAddress:"),
		(IMP)AAPPASettingsSetAdaptiveEnabled,
		"v@:B@");
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
	Class controllerClass = object_getClass(controller);
	Ivar deviceIvar = class_getInstanceVariable(controllerClass, "_device");
	while (!deviceIvar && controllerClass) {
		controllerClass = class_getSuperclass(controllerClass);
		deviceIvar = class_getInstanceVariable(controllerClass, "_device");
	}
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
		return ((BTSDeviceClassic *)rawDevice).device;
	}
	return rawDevice;
}

static BluetoothDevice *AAPDeviceForAddress(NSString *address) {
	Class managerClass = objc_getClass("BluetoothManager");
	if (!managerClass) {
		dlopen("/System/Library/PrivateFrameworks/BluetoothManager.framework/BluetoothManager",
			RTLD_LAZY);
		managerClass = objc_getClass("BluetoothManager");
	}
	SEL sharedSelector = NSSelectorFromString(@"sharedInstance");
	if (!managerClass ||
		![managerClass respondsToSelector:sharedSelector]) {
		return nil;
	}
	id manager = ((id (*)(id, SEL))objc_msgSend)((id)managerClass,
		sharedSelector);
	SEL devicesSelector = NSSelectorFromString(@"pairedDevices");
	if (![manager respondsToSelector:devicesSelector]) {
		devicesSelector = NSSelectorFromString(@"connectedDevices");
	}
	if (![manager respondsToSelector:devicesSelector]) {
		return nil;
	}
	id devices = ((id (*)(id, SEL))objc_msgSend)(manager,
		devicesSelector);
	if (![devices isKindOfClass:[NSArray class]]) {
		return nil;
	}

	for (BluetoothDevice *device in devices) {
		if (![device respondsToSelector:@selector(address)]) {
			continue;
		}
		NSString *candidate = device.address;
		if ([candidate caseInsensitiveCompare:address] == NSOrderedSame) {
			return device;
		}
	}
	return nil;
}

static void AAPKickstartHearing(void) {
	static id accessibilityController;
	dispatch_async(dispatch_get_main_queue(), ^{
		if (accessibilityController) {
			return;
		}
		NSBundle *bundle = [NSBundle bundleWithPath:
			@"/System/Library/PreferenceBundles/AccessibilitySettings.bundle"];
		[bundle load];
		Class controllerClass =
			[bundle classNamed:@"AccessibilitySettingsController"];
		if (controllerClass) {
			accessibilityController = [controllerClass new];
			AAPAdaptiveLog(@"AccessibilitySettingsController created");
		} else {
			AAPAdaptiveLog(@"AccessibilitySettingsController unavailable");
		}
	});
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

static NSMutableSet<NSString *> *AAPDiscoveryRequests(void) {
	static NSMutableSet<NSString *> *requests;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		requests = [NSMutableSet set];
	});
	return requests;
}

static CBCharacteristic *AAPAdaptiveCharacteristic(CBPeripheral *peripheral) {
	CBUUID *adaptiveUUID =
		[CBUUID UUIDWithString:AAPAdaptiveCharacteristicUUID];
	for (CBService *service in peripheral.services) {
		for (CBCharacteristic *characteristic in service.characteristics) {
			if ([characteristic.UUID isEqual:adaptiveUUID]) {
				return characteristic;
			}
		}
	}
	return nil;
}

static void AAPWriteAdaptiveCharacteristic(CBPeripheral *peripheral,
	CBCharacteristic *characteristic,
	BOOL enabled,
	NSString *address) {
	if (!peripheral || !characteristic) {
		return;
	}

	uint8_t value = enabled ? 1 : 0;
	CBCharacteristicProperties properties = characteristic.properties;
	CBCharacteristicWriteType writeType =
		(properties & CBCharacteristicPropertyWriteWithoutResponse)
		? CBCharacteristicWriteWithoutResponse
		: CBCharacteristicWriteWithResponse;
	[peripheral
		writeValue:[NSData dataWithBytes:&value length:1]
		forCharacteristic:characteristic
		type:writeType];
	AAPAdaptiveLog(@"adaptive BLE write address=%@ enabled=%d properties=0x%lx type=%ld",
		address,
		enabled,
		(unsigned long)properties,
		(long)writeType);
}

static void AAPWriteCharacteristicIfAvailable(CBPeripheral *peripheral,
	NSString *address) {
	CBCharacteristic *characteristic =
		AAPAdaptiveCharacteristic(peripheral);
	if (!characteristic) {
		AAPAdaptiveLog(@"adaptive BLE characteristic missing address=%@ services=%lu",
			address,
			(unsigned long)peripheral.services.count);
		return;
	}
	BOOL enabled = AAPAdaptiveEnabledForAddress(address);
	AAPWriteAdaptiveCharacteristic(peripheral,
		characteristic,
		enabled,
		address);
}

static void AAPRequestCharacteristicDiscovery(CBPeripheral *peripheral,
	NSString *address) {
	if (!peripheral || !address.length) {
		return;
	}
	NSString *key = peripheral.identifier.UUIDString ?: address;
	NSMutableSet<NSString *> *requests = AAPDiscoveryRequests();
	if ([requests containsObject:key]) {
		return;
	}
	[requests addObject:key];
	AAPAdaptiveLog(@"adaptive BLE discovery requested address=%@",
		address);
	[peripheral discoverServices:nil];

	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
		dispatch_get_main_queue(), ^{
			[requests removeObject:key];
			if (AAPAdaptiveCharacteristic(peripheral)) {
				AAPWriteCharacteristicIfAvailable(peripheral, address);
				return;
			}
			for (CBService *service in peripheral.services) {
				if (service.characteristics.count == 0) {
					[peripheral discoverCharacteristics:nil
						forService:service];
				}
			}
		});
}

%group PAAccessoryHooks

%hook PAAccessoryManager

- (void)sendUpdateToAccessory {
	%orig;
	NSDictionary *uuidToAddress = [self uuidToAddress];
	for (CBPeripheral *peripheral in [self peripherals]) {
		if (peripheral.state != CBPeripheralStateConnected) {
			continue;
		}
		NSString *address =
			uuidToAddress[peripheral.identifier.UUIDString ?: @""];
		if (![address isKindOfClass:[NSString class]] ||
			!address.length) {
			continue;
		}

		if (AAPAdaptiveCharacteristic(peripheral)) {
			AAPWriteCharacteristicIfAvailable(peripheral, address);
		} else {
			AAPRequestCharacteristicDiscovery(peripheral, address);
		}
	}
}

- (void)peripheral:(CBPeripheral *)peripheral
	didDiscoverCharacteristicsForService:(CBService *)service
	error:(NSError *)error {
	%orig;
	if (error) {
		AAPAdaptiveLog(@"adaptive BLE discovery error=%@ service=%@",
			error.localizedDescription,
			service.UUID.UUIDString ?: @"unknown");
		return;
	}
	if (!AAPAdaptiveCharacteristic(peripheral)) {
		return;
	}

	NSDictionary *uuidToAddress = [self uuidToAddress];
	NSString *address =
		uuidToAddress[peripheral.identifier.UUIDString ?: @""];
	if (![address isKindOfClass:[NSString class]] ||
		!address.length) {
		AAPAdaptiveLog(@"adaptive BLE discovered without address peripheral=%@",
			peripheral.identifier.UUIDString ?: @"unknown");
		return;
	}
	AAPWriteCharacteristicIfAvailable(peripheral, address);
}

%end

%end

%group BluetoothSettingsHooks

%hook BTSDeviceConfigController

- (NSInteger)tableView:(UITableView *)tableView
	numberOfRowsInSection:(NSInteger)section {
	if (section == 6) {
		BluetoothDevice *device = AAPBluetoothDevice(self);
		unsigned int productId = device.productId;
		NSString *address = device.address;
		BOOL supported = AAPProductSupported(productId);
		AAPAdaptiveLog(@"settings section=%ld productId=%u address=%@ supported=%d",
			(long)section,
			productId,
			address ?: @"unknown",
			supported);
		if (supported) {
			AAPKickstartHearing();
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
	NSString *address = device.address;
	if (!device || !address.length) {
		AAPAdaptiveLog(@"toggle failed: no BluetoothDevice address");
		AAPSetSwitchOn(toggle, !requested);
		return;
	}

	toggle.enabled = NO;
	AAPAdaptiveLog(@"toggle requested enabled=%d productId=%u address=%@",
		requested,
		device.productId,
		address);
	AAPStoreAdaptivePreference(address, requested);

	id settings = AAPSharedPASettings();
	if (settings) {
		SEL setter =
			NSSelectorFromString(@"setAdaptiveTransparencyEnabled:forAddress:");
		if ([settings respondsToSelector:setter]) {
			((void (*)(id, SEL, BOOL, NSString *))objc_msgSend)(settings,
				setter,
				requested,
				address);
		} else {
			AAPWriteSystemHearingProtection(settings,
				address,
				requested,
				YES);
		}
	} else {
		AAPAdaptiveLog(@"PASettings sharedInstance unavailable");
	}

	BluetoothDevice *runtimeDevice = AAPDeviceForAddress(address);
	if (!runtimeDevice) {
		runtimeDevice = device;
	}
	dispatch_async(dispatch_get_main_queue(), ^{
		AAPAdaptiveRequestListeningMode(runtimeDevice,
			requested,
			^(BOOL confirmed,
			  BOOL sent,
			  unsigned int readback,
			  NSString *error) {
				AAPAdaptiveLog(@"native request finished confirmed=%d sent=%d readback=%u error=%@",
					confirmed,
					sent,
					readback,
					error ?: @"none");
				AAPSetSwitchOn(toggle,
					confirmed ? requested : !requested);
			});
	});
}

- (UITableViewCell *)tableView:(UITableView *)tableView
	cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	if (indexPath.section == 6 && indexPath.row == 1) {
		BluetoothDevice *device = AAPBluetoothDevice(self);
		if (AAPProductSupported(device.productId)) {
			static NSString *cellIdentifier =
				@"PodsGrant_AdaptiveTransparencyCell";
			UITableViewCell *cell = [tableView
				dequeueReusableCellWithIdentifier:cellIdentifier];
			if (!cell) {
				cell = [[UITableViewCell alloc]
					initWithStyle:UITableViewCellStyleSubtitle
					reuseIdentifier:cellIdentifier];
				cell.selectionStyle =
					UITableViewCellSelectionStyleNone;
				cell.textLabel.text = @"Adaptive Transparency Mode";
				cell.detailTextLabel.text =
					@"Automatic ANC / transparency";
				cell.detailTextLabel.textColor =
					[UIColor secondaryLabelColor];
				cell.accessoryView =
					[[UISwitch alloc] initWithFrame:CGRectZero];
			}

			UISwitch *toggle = (UISwitch *)cell.accessoryView;
			[toggle removeTarget:nil
				action:NULL
				forControlEvents:UIControlEventAllEvents];
			BOOL enabled = AAPAdaptiveEnabledForAddress(device.address);
			toggle.on = enabled;
			toggle.enabled = YES;
			[toggle addTarget:self
				action:@selector(setAdaptiveTransparencyMode:)
				forControlEvents:UIControlEventValueChanged];
			AAPKickstartHearing();
			AAPAdaptiveLog(@"cell productId=%u address=%@ enabled=%d",
				device.productId,
				device.address ?: @"unknown",
				enabled);
			return cell;
		}
	}
	return %orig;
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

	NSString *bundleIdentifier =
		[[NSBundle mainBundle] bundleIdentifier];
	if ([bundleIdentifier isEqualToString:@"com.apple.Preferences"]) {
		AAPInstallPASettingsMethods();
		[[NSBundle bundleWithPath:
			@"/System/Library/PreferenceBundles/BluetoothSettings.bundle"] load];
		%init(BluetoothSettingsHooks);
	}

	%init(PAAccessoryHooks);
}
