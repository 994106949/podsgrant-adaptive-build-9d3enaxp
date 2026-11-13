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

static BluetoothDevice *AAPDeviceForAddress(NSString *address) {
        Class managerClass = objc_getClass("BluetoothManager");
        if (!managerClass) {
                dlopen("/System/Library/PrivateFrameworks/BluetoothManager.framework/BluetoothManager",
                        RTLD_LAZY);
                managerClass = objc_getClass("BluetoothManager");
        }
        SEL sharedSelector = NSSelectorFromString(@"sharedInstance");
        if (!managerClass || ![managerClass respondsToSelector:sharedSelector]) {
                return nil;
        }
        id manager = [(id)managerClass sharedInstance];
        SEL devicesSelector = NSSelectorFromString(@"pairedDevices");
        if (![manager respondsToSelector:devicesSelector]) {
                devicesSelector = NSSelectorFromString(@"connectedDevices");
        }
        if (![manager respondsToSelector:devicesSelector]) {
                return nil;
        }
        id devices = ((id (*)(id, SEL))objc_msgSend)(manager, devicesSelector);
        if (![devices isKindOfClass:[NSArray class]]) {
                return nil;
        }
        for (BluetoothDevice *device in devices) {
                if (![device respondsToSelector:@selector(address)]) {
                        continue;
                }
                NSString *candidate = [device address];
                if ([candidate caseInsensitiveCompare:address] == NSOrderedSame) {
                        return device;
                }
        }
        return nil;
}

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

static NSString *const AAPAdaptivePreferencesPath =
	@"/var/mobile/Library/Preferences/com.lns.pogr.adaptive.plist";

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

static BOOL AAPAdaptiveEnabledForAddress(NSString *address) {
	return AAPValueForAddress(AAPReadAdaptivePreferences(), address);
}

static BOOL AAPSetAdaptiveEnabledForAddress(NSString *address, BOOL enabled) {
	NSMutableDictionary *values = [AAPReadAdaptivePreferences() mutableCopy];
	if (!values) {
		values = [NSMutableDictionary dictionary];
	}
	for (NSString *key in AAPPreferenceKeys(address)) {
		values[key] = @(enabled);
	}
	return AAPWriteAdaptivePreferences(values);
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

static BOOL AAPPASettingsAdaptiveEnabled(id self, SEL _cmd, NSString *address) {
	(void)self;
	(void)_cmd;
	return AAPAdaptiveEnabledForAddress(address);
}

static void AAPPASettingsSetAdaptiveEnabled(id self,
	SEL _cmd,
	BOOL enabled,
	NSString *address) {
	(void)_cmd;
	AAPSetAdaptiveEnabledForAddress(address, enabled);

	/*
	 * Re-apply the existing transparency preference after the plist write.
	 * This is the IPC nudge used by PodsGrant 0.5.4 and keeps `heard`
	 * scheduling its native accessory update.
	 */
	SEL getter = NSSelectorFromString(@"transparencyCustomizedForAddress:");
	SEL setter = NSSelectorFromString(@"setTransparencyCustomized:forAddress:");
	if (![self respondsToSelector:getter] ||
		![self respondsToSelector:setter]) {
		AAPAdaptiveLog(@"transparencyCustomized selectors unavailable");
		return;
	}

	BOOL customized = ((BOOL (*)(id, SEL, NSString *))objc_msgSend)(
		self,
		getter,
		address);
	((void (*)(id, SEL, BOOL, NSString *))objc_msgSend)(
		self,
		setter,
		customized,
		address);
	AAPAdaptiveLog(@"transparencyCustomized refresh address=%@ value=%d",
		address,
		customized);
}

static void AAPPASettingsApplyRuntimeMethods(void) {
	Class settingsClass = objc_getClass("PASettings");
	if (!settingsClass) {
		AAPAdaptiveLog(@"PASettings unavailable; using adaptive plist only");
		return;
	}

	class_addMethod(settingsClass,
		NSSelectorFromString(@"adaptiveTransparencyEnabledForAddress:"),
		(IMP)AAPPASettingsAdaptiveEnabled,
		"B@:@");
	class_addMethod(settingsClass,
		NSSelectorFromString(@"_setAdaptiveTransparencyEnabled:forAddress:"),
		(IMP)AAPPASettingsSetAdaptiveEnabled,
		"v@:B@");
	class_addMethod(settingsClass,
		NSSelectorFromString(@"setAdaptiveTransparencyEnabled:forAddress:"),
		(IMP)AAPPASettingsSetAdaptiveEnabled,
		"v@:B@");
}

%group PAAccessoryHooks

static NSMutableSet<NSString *> *AAPDiscoveryRequests(void) {
	static NSMutableSet<NSString *> *requests;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		requests = [NSMutableSet set];
	});
	return requests;
}

static CBCharacteristic *AAPAdaptiveCharacteristic(CBPeripheral *peripheral) {
	CBUUID *adaptiveUUID = [CBUUID
		UUIDWithString:@"a48fec08-3921-43db-82aa-afbce8ebb4fb"];
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
		(properties & CBCharacteristicPropertyWrite)
		? CBCharacteristicWriteWithResponse
		: CBCharacteristicWriteWithoutResponse;
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
	AAPAdaptiveLog(@"adaptive BLE discovery requested address=%@", address);
	[peripheral discoverServices:nil];

	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
		dispatch_get_main_queue(), ^{
			[requests removeObject:key];
			CBCharacteristic *characteristic =
				AAPAdaptiveCharacteristic(peripheral);
			if (characteristic) {
				AAPWriteAdaptiveCharacteristic(peripheral,
					characteristic,
					AAPAdaptiveEnabledForAddress(address),
					address);
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

/*
 * Preferences only stores the value. `heard` owns the connected
 * CBPeripheral, so the native adaptive-transparency characteristic must be
 * written in that process.
 */
%hook PAAccessoryManager

- (void)sendUpdateToAccessory {
	%orig;
	NSDictionary *uuidToAddress = [self uuidToAddress];

	for (CBPeripheral *peripheral in [self peripherals]) {
		if (peripheral.state != CBPeripheralStateConnected) {
			continue;
		}
		NSString *address = uuidToAddress[[peripheral.identifier UUIDString]];
		if (![address isKindOfClass:[NSString class]] || !address.length) {
			continue;
		}
		BOOL enabled = AAPAdaptiveEnabledForAddress(address);
		CBCharacteristic *characteristic =
			AAPAdaptiveCharacteristic(peripheral);
		if (characteristic) {
			AAPWriteAdaptiveCharacteristic(peripheral,
				characteristic,
				enabled,
				address);
		} else {
			AAPAdaptiveLog(@"adaptive BLE characteristic missing address=%@ services=%lu",
				address,
				(unsigned long)peripheral.services.count);
			AAPRequestCharacteristicDiscovery(peripheral, address);
		}
	}
}

%end

%end

%group PACharacteristicDiscoveryHooks

%hook PAAccessoryManager

- (void)peripheral:(CBPeripheral *)peripheral
	didDiscoverCharacteristicsForService:(CBService *)service
	error:(NSError *)error {
	if (error) {
		AAPAdaptiveLog(@"adaptive BLE discovery error=%@ service=%@",
			error.localizedDescription,
			service.UUID.UUIDString ?: @"unknown");
		return;
	}
	CBCharacteristic *characteristic =
		AAPAdaptiveCharacteristic(peripheral);
	if (!characteristic) {
		return;
	}
	NSDictionary *uuidToAddress = [self uuidToAddress];
	NSString *address = uuidToAddress[peripheral.identifier.UUIDString ?: @""];
	if (![address isKindOfClass:[NSString class]] || !address.length) {
		AAPAdaptiveLog(@"adaptive BLE discovered but address is unknown peripheral=%@",
			peripheral.identifier.UUIDString ?: @"unknown");
		return;
	}
	AAPWriteAdaptiveCharacteristic(peripheral,
		characteristic,
		AAPAdaptiveEnabledForAddress(address),
		address);
}

%end

%group BluetoothSettingsHooks

%hook BTSDeviceConfigController

- (NSInteger)tableView:(UITableView *)tableView
	numberOfRowsInSection:(NSInteger)section {
	BluetoothDevice *device = AAPBluetoothDevice(self);
	unsigned int productId = [device productId];
	NSInteger sectionCount = [tableView numberOfSections];
	if (sectionCount > 0 && section == sectionCount - 1) {
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
	AAPSetAdaptiveEnabledForAddress(address, requested);

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
				AAPSetSwitchOn(toggle, confirmed ? requested : !requested);
			});
	});
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
	NSInteger sectionCount = [tableView numberOfSections];
	if (sectionCount <= 0 ||
		indexPath.section != sectionCount - 1 ||
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

	BOOL enabled = AAPAdaptiveEnabledForAddress(address);
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
	NSString *bundleIdentifier = [[NSBundle mainBundle] bundleIdentifier];
	if ([bundleIdentifier isEqualToString:@"com.apple.Preferences"]) {
		Class settingsClass = objc_getClass("PASettings");
		if (settingsClass) {
			AAPPASettingsApplyRuntimeMethods();
		} else {
			AAPAdaptiveLog(@"PASettings unavailable; using adaptive plist only");
		}
		[[NSBundle bundleWithPath:
			@"/System/Library/PreferenceBundles/BluetoothSettings.bundle"] load];
		%init(BluetoothSettingsHooks);
	}
	%init(PAAccessoryHooks);
	Class managerClass = objc_getClass("PAAccessoryManager");
	SEL discoverySelector = @selector(peripheral:
		didDiscoverCharacteristicsForService:
		error:);
	if (managerClass &&
		class_getInstanceMethod(managerClass, discoverySelector)) {
		%init(PACharacteristicDiscoveryHooks);
	} else {
		AAPAdaptiveLog(@"characteristic discovery callback unavailable");
	}
}
