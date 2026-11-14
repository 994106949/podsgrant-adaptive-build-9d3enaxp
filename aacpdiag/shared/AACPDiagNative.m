#import "AACPDiag.h"

#import <objc/runtime.h>
#import <stdlib.h>

static BOOL AAPDiagNativeTypeIsSupported(const char *type, BOOL allowVoid) {
	if (!type) {
		return NO;
	}
	while (*type && strchr("rnNoORV", *type)) {
		type++;
	}
	if (!*type) {
		return NO;
	}
	if (allowVoid && *type == 'v') {
		return YES;
	}
	return strchr("@#:cCsSiIlLqQB*^?", *type) != NULL;
}

static NSArray<NSString *> *AAPDiagSelectorCandidates(void) {
	return @[
		@"listeningMode",
		@"setListeningMode:",
		@"setListeningMode:error:",
		@"listeningModeConfigs",
		@"setListeningModeConfigs:",
		@"supportedListeningModes",
		@"supportsListeningMode:",
		@"noiseControlMode",
		@"setNoiseControlMode:",
		@"adaptiveTransparencyEnabled",
		@"setAdaptiveTransparencyEnabled:",
		@"adaptiveTransparencySupported",
		@"supportsAdaptiveTransparency",
		@"transparencyCustomizedForAddress:",
		@"setTransparencyCustomized:forAddress:",
		@"hearingAidEnabled",
		@"setHearingAidEnabled:",
		@"hearingProtectionEnabled",
		@"setHearingProtectionEnabled:",
	];
}

static BOOL AAPDiagSelectorMentionsListening(NSString *selectorName) {
	NSString *lower = selectorName.lowercaseString;
	return [lower containsString:@"listen"] ||
		[lower containsString:@"noise"] ||
		[lower containsString:@"transparen"] ||
		[lower containsString:@"adaptive"] ||
		[lower containsString:@"anc"] ||
		[lower containsString:@"hearing"];
}

static NSArray<NSString *> *AAPDiagMatchingMethods(Class cls) {
	NSMutableArray<NSString *> *result = [NSMutableArray array];
	if (!cls) {
		return result;
	}

	unsigned int count = 0;
	Method *methods = class_copyMethodList(cls, &count);
	for (unsigned int index = 0; index < count; index++) {
		NSString *name = NSStringFromSelector(method_getName(methods[index]));
		if (!AAPDiagSelectorMentionsListening(name)) {
			continue;
		}
		const char *types = method_getTypeEncoding(methods[index]);
		[result addObject:[NSString stringWithFormat:@"-%@ %s",
			name,
			types ?: ""]];
	}
	free(methods);
	return result;
}

static NSArray<NSString *> *AAPDiagMatchingClassMethods(Class cls) {
	NSMutableArray<NSString *> *result = [NSMutableArray array];
	if (!cls) {
		return result;
	}

	unsigned int count = 0;
	Method *methods = class_copyMethodList(object_getClass(cls), &count);
	for (unsigned int index = 0; index < count; index++) {
		NSString *name = NSStringFromSelector(method_getName(methods[index]));
		if (!AAPDiagSelectorMentionsListening(name)) {
			continue;
		}
		const char *types = method_getTypeEncoding(methods[index]);
		[result addObject:[NSString stringWithFormat:@"+%@ %s",
			name,
			types ?: ""]];
	}
	free(methods);
	return result;
}

static NSDictionary<NSString *, id> *AAPDiagClassInventory(id object) {
	if (!object) {
		return @{@"class": @"nil"};
	}
	NSMutableDictionary<NSString *, id> *inventory =
		[NSMutableDictionary dictionary];
	BOOL isClassObject = class_isMetaClass(object_getClass(object));
	Class cls = isClassObject ? (Class)object : object_getClass(object);
	Class rootClass = cls;
	NSString *rootClassName = cls ? NSStringFromClass(cls) : nil;
	NSMutableArray<NSString *> *hierarchy = [NSMutableArray array];
	NSMutableDictionary<NSString *, NSArray<NSString *> *> *methods =
		[NSMutableDictionary dictionary];
	for (NSUInteger depth = 0; cls && depth < 8; depth++) {
		NSString *className = NSStringFromClass(cls);
		[hierarchy addObject:className ?: @"?"];
		NSArray<NSString *> *matching = AAPDiagMatchingMethods(cls);
		if (matching.count) {
			methods[className ?: @"?"] = matching;
		}
		cls = class_getSuperclass(cls);
	}
	inventory[@"class"] = rootClassName ?: @"?";
	inventory[@"is_class"] = @(isClassObject);
	inventory[@"hierarchy"] = hierarchy;
	inventory[@"methods"] = methods;
	if (isClassObject && rootClass) {
		NSArray<NSString *> *classMethods =
			AAPDiagMatchingClassMethods(rootClass);
		if (classMethods.count) {
			inventory[@"class_methods"] = classMethods;
		}
	}
	return inventory;
}

static NSArray<NSString *> *AAPDiagSelectorAvailability(id object) {
	NSMutableArray<NSString *> *result = [NSMutableArray array];
	if (!object) {
		return result;
	}
	for (NSString *name in AAPDiagSelectorCandidates()) {
		SEL selector = NSSelectorFromString(name);
		if (!selector) {
			continue;
		}
		BOOL responds = [object respondsToSelector:selector];
		NSString *marker = responds ? @"YES" : @"NO";
		[result addObject:[NSString stringWithFormat:@"%@=%@", name, marker]];
	}
	return result;
}

static id AAPDiagInvokeObjectGetter(id target, NSString *name) {
	if (!target || !name.length ||
		![target respondsToSelector:NSSelectorFromString(name)]) {
		return nil;
	}
	SEL selector = NSSelectorFromString(name);
	NSMethodSignature *signature =
		[target methodSignatureForSelector:selector];
	if (!signature || signature.numberOfArguments != 2 ||
		signature.methodReturnLength == 0 ||
		signature.methodReturnType[0] != '@') {
		return nil;
	}
	NSInvocation *invocation =
		[NSInvocation invocationWithMethodSignature:signature];
	invocation.target = target;
	invocation.selector = selector;
	@try {
		[invocation invoke];
	} @catch (__unused NSException *exception) {
		return nil;
	}
	__unsafe_unretained id value = nil;
	[invocation getReturnValue:&value];
	return value;
}

static id AAPDiagInvokeClassGetter(Class cls, NSString *name) {
	if (!cls || !name.length) {
		return nil;
	}
	SEL selector = NSSelectorFromString(name);
	if (![(id)cls respondsToSelector:selector]) {
		return nil;
	}
	NSMethodSignature *signature =
		[(id)cls methodSignatureForSelector:selector];
	if (!signature || signature.numberOfArguments != 2 ||
		signature.methodReturnLength == 0 ||
		signature.methodReturnType[0] != '@') {
		return nil;
	}
	NSInvocation *invocation =
		[NSInvocation invocationWithMethodSignature:signature];
	invocation.target = (id)cls;
	invocation.selector = selector;
	@try {
		[invocation invoke];
	} @catch (__unused NSException *exception) {
		return nil;
	}
	__unsafe_unretained id value = nil;
	[invocation getReturnValue:&value];
	return value;
}

static NSString *AAPDiagObjectAddress(id object, NSUInteger depth) {
	if (!object || depth > 3) {
		return nil;
	}
	for (NSString *name in @[
		@"address",
		@"bluetoothAddress",
		@"deviceAddress",
		@"accessoryAddress",
		@"identifier",
		@"btAddress",
		@"btAddressString",
		@"macAddress",
	]) {
		id value = AAPDiagInvokeObjectGetter(object, name);
		if ([value isKindOfClass:[NSString class]]) {
			NSString *normalized = AAPDiagNormalizeAddress(value);
			if (normalized.length) {
				return normalized;
			}
		}
		if ([value isKindOfClass:[NSData class]] &&
			[(NSData *)value length] == 6) {
			const uint8_t *bytes = [(NSData *)value bytes];
			return [NSString stringWithFormat:
				@"%02X:%02X:%02X:%02X:%02X:%02X",
				bytes[0], bytes[1], bytes[2],
				bytes[3], bytes[4], bytes[5]];
		}
	}
	for (NSString *name in @[
		@"device",
		@"bluetoothDevice",
		@"btDevice",
		@"accessory",
		@"underlyingDevice",
	]) {
		id nested = AAPDiagInvokeObjectGetter(object, name);
		if (nested && nested != object) {
			NSString *address = AAPDiagObjectAddress(nested, depth + 1);
			if (address.length) {
				return address;
			}
		}
	}
	return nil;
}

static void AAPDiagFlattenCandidateValue(id value,
	NSMutableArray *output,
	NSUInteger depth) {
	if (!value || depth > 2) {
		return;
	}
	if ([value isKindOfClass:[NSArray class]] ||
		[value isKindOfClass:[NSSet class]]) {
		for (id item in value) {
			AAPDiagFlattenCandidateValue(item, output, depth + 1);
		}
		return;
	}
	if ([value isKindOfClass:[NSDictionary class]]) {
		for (id item in [(NSDictionary *)value allValues]) {
			AAPDiagFlattenCandidateValue(item, output, depth + 1);
		}
		return;
	}
	[output addObject:value];
}

static void AAPDiagAddCandidateAndNestedObjects(id object,
	NSMutableArray *output,
	NSMutableSet<NSString *> *seen,
	NSUInteger depth) {
	if (!object || depth > 2) {
		return;
	}
	NSString *key = [NSString stringWithFormat:@"%p", object];
	if ([seen containsObject:key]) {
		return;
	}
	[seen addObject:key];
	[output addObject:object];

	for (NSString *name in @[
		@"device",
		@"bluetoothDevice",
		@"btDevice",
		@"accessory",
		@"underlyingDevice",
	]) {
		id nested = AAPDiagInvokeObjectGetter(object, name);
		if (nested && nested != object) {
			AAPDiagAddCandidateAndNestedObjects(
				nested,
				output,
				seen,
				depth + 1);
		}
	}
}

static NSArray<NSDictionary<NSString *, id> *> *
AAPDiagSetterCandidates(id object) {
	NSMutableArray<NSDictionary<NSString *, id> *> *result =
		[NSMutableArray array];
	NSMutableSet<NSString *> *seen = [NSMutableSet set];
	Class cls = object ? object_getClass(object) : Nil;
	for (NSUInteger depth = 0; cls && depth < 10;
		depth++, cls = class_getSuperclass(cls)) {
		unsigned int count = 0;
		Method *methods = class_copyMethodList(cls, &count);
		for (unsigned int index = 0; index < count; index++) {
			Method method = methods[index];
			NSString *name = NSStringFromSelector(method_getName(method));
			NSString *lower = name.lowercaseString;
			if (![lower hasPrefix:@"set"] ||
				(![lower containsString:@"listen"] &&
				 ![lower containsString:@"noise"] &&
				 ![lower containsString:@"transparen"] &&
				 ![lower containsString:@"adaptive"] &&
				 ![lower containsString:@"hearing"] &&
				 ![lower containsString:@"anc"])) {
				continue;
			}
			if ([name isEqualToString:@"setListeningMode:"] ||
				[name isEqualToString:@"setListeningModeConfigs:"] ||
				[seen containsObject:name]) {
				continue;
			}
			const char *types = method_getTypeEncoding(method);
			NSMethodSignature *signature = nil;
			@try {
				signature = [NSMethodSignature
					signatureWithObjCTypes:types];
			} @catch (__unused NSException *exception) {
				signature = nil;
			}
			if (!signature || signature.numberOfArguments != 3) {
				continue;
			}
			const char *argumentType =
				[signature getArgumentTypeAtIndex:2];
			if (!AAPDiagNativeTypeIsSupported(argumentType, NO)) {
				continue;
			}
			const char *returnType = signature.methodReturnType;
			if (!AAPDiagNativeTypeIsSupported(returnType, YES)) {
				continue;
			}
			[seen addObject:name];
			[result addObject:@{
				@"name": name,
				@"types": [NSString stringWithUTF8String:types ?: ""] ?:
					@"",
				@"argument_type": [NSString
					stringWithUTF8String:argumentType ?: ""] ?: @"",
				@"class": NSStringFromClass(cls) ?: @"?",
			}];
		}
		free(methods);
	}
	return result;
}

void AAPDiagLogClassInventory(NSString *scope, id object) {
	if (!object) {
		AAPDiagLog(@"inventory scope=%@ object=nil", scope ?: @"?");
		return;
	}
	NSDictionary<NSString *, id> *inventory = AAPDiagClassInventory(object);
	NSString *json = nil;
	NSData *data = [NSJSONSerialization
		dataWithJSONObject:inventory
		options:0
		error:nil];
	if (data) {
		json = [[NSString alloc] initWithData:data
			encoding:NSUTF8StringEncoding];
	}
	AAPDiagLog(@"inventory scope=%@ address=%p class=%@ selectors=%@ "
		@"methods=%@",
		scope ?: @"?",
		object,
		inventory[@"class"] ?: @"?",
		AAPDiagSelectorAvailability(object),
		json ?: @"serialization_failed");
}

static BOOL AAPDiagReadGetter(id target,
	SEL selector,
	long long *value,
	NSString **description,
	NSString **error) {
	if (description) {
		*description = @"";
	}
	if (!target || ![target respondsToSelector:selector]) {
		if (error) {
			*error = @"selector is unavailable";
		}
		return NO;
	}
	NSMethodSignature *signature = [target methodSignatureForSelector:selector];
	if (!signature || signature.methodReturnLength == 0) {
		if (error) {
			*error = @"method has no return value";
		}
		return NO;
	}

	NSInvocation *invocation =
		[NSInvocation invocationWithMethodSignature:signature];
	invocation.target = target;
	invocation.selector = selector;
	@try {
		[invocation invoke];
	} @catch (NSException *exception) {
		if (error) {
			*error = exception.reason ?: @"invocation raised an exception";
		}
		return NO;
	}

	const char *returnType = signature.methodReturnType;
	if (returnType && returnType[0] == '@') {
		__unsafe_unretained id objectValue = nil;
		[invocation getReturnValue:&objectValue];
		if (description) {
			*description = objectValue ? [objectValue description] : @"nil";
		}
		if ([objectValue respondsToSelector:@selector(longLongValue)]) {
			if (value) {
				*value = [(NSNumber *)objectValue longLongValue];
			}
			return YES;
		}
		if (error) {
			*error = @"object return did not expose longLongValue";
		}
		return NO;
	}

	uint64_t raw = 0;
	NSUInteger length = signature.methodReturnLength;
	if (length > sizeof(raw)) {
		length = sizeof(raw);
	}
	[invocation getReturnValue:&raw];
	if (value) {
		switch (returnType ? returnType[0] : 'I') {
			case 'c':
				*value = (int8_t)raw;
				break;
			case 'C':
			case 'B':
				*value = (uint8_t)raw;
				break;
			case 's':
				*value = (int16_t)raw;
				break;
			case 'S':
				*value = (uint16_t)raw;
				break;
			case 'i':
				*value = (int32_t)raw;
				break;
			case 'I':
				*value = (uint32_t)raw;
				break;
			default:
				*value = (long long)raw;
				break;
		}
	}
	if (description) {
		*description = [NSString stringWithFormat:@"%lld", value ? *value : 0];
	}
	return YES;
}

static BOOL AAPDiagInvokeSetter(id target,
	SEL selector,
	unsigned int argument,
	NSString **returnDescription,
	NSString **error) {
	if (returnDescription) {
		*returnDescription = @"";
	}
	if (!target || ![target respondsToSelector:selector]) {
		if (error) {
			*error = @"selector is unavailable";
		}
		return NO;
	}
	NSMethodSignature *signature = [target methodSignatureForSelector:selector];
	if (!signature || signature.numberOfArguments < 3) {
		if (error) {
			*error = @"unsupported method signature";
		}
		return NO;
	}
	const char *argumentType = [signature getArgumentTypeAtIndex:2];
	if (!argumentType) {
		if (error) {
			*error = @"missing argument type";
		}
		return NO;
	}

	NSInvocation *invocation =
		[NSInvocation invocationWithMethodSignature:signature];
	invocation.target = target;
	invocation.selector = selector;
	switch (argumentType[0]) {
		case 'c': {
			int8_t value = (int8_t)argument;
			[invocation setArgument:&value atIndex:2];
			break;
		}
		case 'C':
		case 'B': {
			uint8_t value = (uint8_t)argument;
			[invocation setArgument:&value atIndex:2];
			break;
		}
		case 's': {
			int16_t value = (int16_t)argument;
			[invocation setArgument:&value atIndex:2];
			break;
		}
		case 'S': {
			uint16_t value = (uint16_t)argument;
			[invocation setArgument:&value atIndex:2];
			break;
		}
		case 'i': {
			int32_t value = (int32_t)argument;
			[invocation setArgument:&value atIndex:2];
			break;
		}
		case 'I': {
			uint32_t value = (uint32_t)argument;
			[invocation setArgument:&value atIndex:2];
			break;
		}
		case 'q':
		case 'l': {
			int64_t value = (int64_t)argument;
			[invocation setArgument:&value atIndex:2];
			break;
		}
		case 'Q':
		case 'L': {
			uint64_t value = (uint64_t)argument;
			[invocation setArgument:&value atIndex:2];
			break;
		}
		default:
			if (error) {
				*error = [NSString stringWithFormat:
					@"unsupported argument type %s", argumentType];
			}
			return NO;
	}

	@try {
		[invocation invoke];
	} @catch (NSException *exception) {
		if (error) {
			*error = exception.reason ?: @"invocation raised an exception";
		}
		return NO;
	}

	const char *returnType = signature.methodReturnType;
	if (returnDescription && signature.methodReturnLength > 0 &&
		returnType && returnType[0] != 'v') {
		uint64_t raw = 0;
		NSUInteger length = signature.methodReturnLength;
		if (length > sizeof(raw)) {
			length = sizeof(raw);
		}
		[invocation getReturnValue:&raw];
		*returnDescription = [NSString stringWithFormat:@"0x%llx",
			(unsigned long long)raw];
	}
	return YES;
}

NSDictionary<NSString *, id> *AAPDiagRunNativeTest(id device,
	unsigned int mode) {
	NSMutableArray<NSString *> *trace = [NSMutableArray array];
	NSMutableDictionary<NSString *, id> *result =
		[NSMutableDictionary dictionary];
	result[@"status"] = @"no_confirmation";
	result[@"mode"] = @(mode);
	result[@"trace"] = trace;
	result[@"timestamp"] = @([[NSDate date] timeIntervalSince1970]);

	if (!device) {
		result[@"status"] = @"native_device_missing";
		[trace addObject:@"BluetoothDevice is nil"];
		return result;
	}

	result[@"inventory"] = AAPDiagClassInventory(device);
	result[@"selectors"] = AAPDiagSelectorAvailability(device);
	[trace addObject:[NSString stringWithFormat:
		@"native_device class=%@",
		NSStringFromClass(object_getClass(device)) ?: @"?"]];

	long long before = 0;
	NSString *beforeDescription = @"";
	NSString *getterError = nil;
	BOOL beforeOK = AAPDiagReadGetter(device,
		NSSelectorFromString(@"listeningMode"),
		&before,
		&beforeDescription,
		&getterError);
	result[@"before"] = @{
		@"available": @(beforeOK),
		@"value": @(before),
		@"description": beforeDescription ?: @"",
		@"error": getterError ?: @"",
	};
	[trace addObject:[NSString stringWithFormat:
		@"listeningMode before available=%d value=%lld desc=%@ error=%@",
		beforeOK,
		before,
		beforeDescription ?: @"",
		getterError ?: @"none"]];

	long long supported = 0;
	NSString *supportedDescription = @"";
	NSString *supportedError = nil;
	BOOL supportedOK = AAPDiagReadGetter(device,
		NSSelectorFromString(@"supportedListeningModes"),
		&supported,
		&supportedDescription,
		&supportedError);
	result[@"supported_modes"] = @{
		@"available": @(supportedOK),
		@"value": @(supported),
		@"description": supportedDescription ?: @"",
		@"error": supportedError ?: @"",
	};
	[trace addObject:[NSString stringWithFormat:
		@"supportedListeningModes available=%d value=%lld desc=%@ error=%@",
		supportedOK,
		supported,
		supportedDescription ?: @"",
		supportedError ?: @"none"]];

	NSString *configReturn = @"";
	NSString *configError = nil;
	BOOL configOK = AAPDiagInvokeSetter(device,
		NSSelectorFromString(@"setListeningModeConfigs:"),
		0x0F,
		&configReturn,
		&configError);
	result[@"config"] = @{
		@"invoked": @(configOK),
		@"return": configReturn ?: @"",
		@"error": configError ?: @"",
	};
	[trace addObject:[NSString stringWithFormat:
		@"setListeningModeConfigs:0x0F invoked=%d return=%@ error=%@",
		configOK,
		configReturn ?: @"",
		configError ?: @"none"]];

	[NSThread sleepForTimeInterval:0.15];

	NSString *modeReturn = @"";
	NSString *modeError = nil;
	BOOL modeOK = AAPDiagInvokeSetter(device,
		NSSelectorFromString(@"setListeningMode:"),
		mode,
		&modeReturn,
		&modeError);
	BOOL setterAvailable =
		[device respondsToSelector:NSSelectorFromString(@"setListeningMode:")];
	result[@"set_mode"] = @{
		@"invoked": @(modeOK),
		@"available": @(setterAvailable),
		@"return": modeReturn ?: @"",
		@"error": modeError ?: @"",
	};
	[trace addObject:[NSString stringWithFormat:
		@"setListeningMode:%u invoked=%d return=%@ error=%@",
		mode,
		modeOK,
		modeReturn ?: @"",
		modeError ?: @"none"]];

	long long last = before;
	NSString *lastDescription = beforeDescription ?: @"";
	BOOL confirmed = NO;
	for (NSUInteger attempt = 0; attempt < 15; attempt++) {
		[NSThread sleepForTimeInterval:0.1];
		long long value = 0;
		NSString *valueDescription = @"";
		NSString *readError = nil;
		BOOL readOK = AAPDiagReadGetter(device,
			NSSelectorFromString(@"listeningMode"),
			&value,
			&valueDescription,
			&readError);
		if (readOK) {
			last = value;
			lastDescription = valueDescription ?: @"";
			[trace addObject:[NSString stringWithFormat:
				@"readback attempt=%lu value=%lld desc=%@",
				(unsigned long)(attempt + 1),
				value,
				valueDescription ?: @""]];
			if (value == (long long)mode) {
				confirmed = YES;
				break;
			}
		} else if (readError) {
			[trace addObject:[NSString stringWithFormat:
				@"readback attempt=%lu error=%@",
				(unsigned long)(attempt + 1),
				readError]];
		}
	}
	result[@"after"] = @{
		@"value": @(last),
		@"description": lastDescription ?: @"",
		@"matches": @(confirmed),
		@"requested": @(mode),
	};
	if (!setterAvailable) {
		result[@"status"] = @"native_setter_missing";
	} else if (!modeOK) {
		result[@"status"] = @"native_setter_failed";
	} else {
		result[@"status"] = @"local_getter_only";
	}
	[trace addObject:[NSString stringWithFormat:
		@"native_result status=%@ requested=%u final=%lld (getter is not device confirmation)",
		result[@"status"],
		mode,
		last]];
	return result;
}

static BOOL AAPDiagObjectAddressMatches(id object,
	NSString *expectedAddress) {
	NSString *expected = AAPDiagNormalizeAddress(expectedAddress);
	NSString *actual = AAPDiagObjectAddress(object, 0);
	if (!expected.length || !actual.length) {
		return NO;
	}
	return [expected isEqualToString:actual];
}

NSArray *AAPDiagDiscoverDeviceCandidates(NSString *expectedAddress) {
	NSMutableArray *all = [NSMutableArray array];
	NSMutableSet<NSString *> *seen = [NSMutableSet set];
	NSString *expected = AAPDiagNormalizeAddress(expectedAddress);
	NSMutableArray *classCandidates = [NSMutableArray array];
	for (NSString *className in @[
		@"BTSDevice",
		@"BTSDeviceClassic",
		@"BluetoothDevice",
	]) {
		Class cls = objc_getClass(className.UTF8String);
		if (cls) {
			[classCandidates addObject:(id)cls];
		}
	}
	for (id classObject in classCandidates) {
		for (NSString *name in @[
			@"pairedDevices",
			@"connectedDevices",
			@"devices",
			@"allDevices",
		]) {
			SEL selector = NSSelectorFromString(name);
			Class cls = (Class)classObject;
			if (![cls respondsToSelector:selector]) {
				continue;
			}
			NSMethodSignature *signature =
				[cls methodSignatureForSelector:selector];
			if (!signature || signature.numberOfArguments != 2 ||
				signature.methodReturnLength == 0 ||
				signature.methodReturnType[0] != '@') {
				continue;
			}
			NSInvocation *invocation =
				[NSInvocation invocationWithMethodSignature:signature];
			invocation.target = classObject;
			invocation.selector = selector;
			@try {
				[invocation invoke];
				__unsafe_unretained id value = nil;
				[invocation getReturnValue:&value];
				AAPDiagFlattenCandidateValue(value, all, 0);
			} @catch (__unused NSException *exception) {
			}
		}
	}
	Class managerClass = objc_getClass("BluetoothManager");
	if (managerClass) {
		id manager = AAPDiagInvokeClassGetter(
			managerClass,
			@"sharedInstance");
		if (!manager) {
			manager = AAPDiagInvokeClassGetter(
				managerClass,
				@"defaultInstance");
		}
		AAPDiagAddCandidateAndNestedObjects(manager, all, seen, 0);
		for (NSString *name in @[
			@"pairedDevices",
			@"connectedDevices",
			@"devices",
			@"allDevices",
		]) {
			id value = AAPDiagInvokeObjectGetter(manager, name);
			AAPDiagFlattenCandidateValue(value, all, 0);
		}
		if (expected.length) {
			SEL lookup = NSSelectorFromString(@"deviceForAddress:");
			if (manager && [manager respondsToSelector:lookup]) {
				NSMethodSignature *signature =
					[manager methodSignatureForSelector:lookup];
				if (signature && signature.numberOfArguments == 3 &&
					signature.methodReturnLength > 0 &&
					signature.methodReturnType[0] == '@') {
					NSInvocation *invocation =
						[NSInvocation invocationWithMethodSignature:signature];
					invocation.target = manager;
					invocation.selector = lookup;
					NSString *argument = expected;
					[invocation setArgument:&argument atIndex:2];
					@try {
						[invocation invoke];
						__unsafe_unretained id value = nil;
						[invocation getReturnValue:&value];
						AAPDiagFlattenCandidateValue(value, all, 0);
					} @catch (__unused NSException *exception) {
					}
				}
			}
		}
	}

	NSMutableSet<NSString *> *expandedSeen = [NSMutableSet set];
	NSMutableArray *expanded = [NSMutableArray array];
	for (id candidate in all) {
		AAPDiagAddCandidateAndNestedObjects(
			candidate,
			expanded,
			expandedSeen,
			0);
	}

	NSMutableArray *matched = [NSMutableArray array];
	NSMutableArray *unmatched = [NSMutableArray array];
	for (id candidate in expanded) {
		NSString *address = AAPDiagObjectAddress(candidate, 0);
		if (expected.length && address.length &&
			![expected isEqualToString:address]) {
			continue;
		}
		[matched addObject:candidate];
		if (!expected.length) {
			[unmatched addObject:candidate];
		}
	}
	if (expected.length) {
		NSMutableArray *exact = [NSMutableArray array];
		for (id candidate in matched) {
			if (AAPDiagObjectAddressMatches(candidate, expected)) {
				[exact addObject:candidate];
			}
		}
		return exact;
	}
	return unmatched;
}

NSDictionary<NSString *, id> *AAPDiagRunNativeTestOnCandidates(
	NSArray *candidates,
	NSString *expectedAddress,
	unsigned int mode) {
	NSMutableArray<NSString *> *trace = [NSMutableArray array];
	NSMutableDictionary<NSString *, id> *result =
		[NSMutableDictionary dictionary];
	result[@"status"] = @"native_setters_invoked_unconfirmed";
	result[@"mode"] = @(mode);
	result[@"expected_address"] =
		AAPDiagNormalizeAddress(expectedAddress) ?: @"";
	result[@"trace"] = trace;
	result[@"timestamp"] = @([[NSDate date] timeIntervalSince1970]);

	NSMutableArray *flattened = [NSMutableArray array];
	NSMutableSet<NSString *> *seen = [NSMutableSet set];
	for (id value in candidates ?: @[]) {
		AAPDiagFlattenCandidateValue(value, flattened, 0);
	}
	NSMutableArray *unique = [NSMutableArray array];
	for (id candidate in flattened) {
		NSString *key = [NSString stringWithFormat:@"%p", candidate];
		if ([seen containsObject:key]) {
			continue;
		}
		[seen addObject:key];
		[unique addObject:candidate];
	}

	NSMutableArray *matched = [NSMutableArray array];
	NSString *expected = AAPDiagNormalizeAddress(expectedAddress);
	for (id candidate in unique) {
		NSString *address = AAPDiagObjectAddress(candidate, 0);
		BOOL addressMatches = expected.length && address.length &&
			[expected isEqualToString:address];
		if (expected.length && !addressMatches) {
			continue;
		}
		[matched addObject:candidate];
	}
	result[@"candidate_count"] = @(unique.count);
	result[@"matched_count"] = @(matched.count);
	[trace addObject:[NSString stringWithFormat:
		@"candidate flatten=%lu unique=%lu matched=%lu expected=%@",
		(unsigned long)flattened.count,
		(unsigned long)unique.count,
		(unsigned long)matched.count,
		expected ?: @"any"]];
	if (!matched.count) {
		result[@"status"] = @"native_device_missing";
		return result;
	}

	NSMutableArray<NSDictionary *> *records = [NSMutableArray array];
		NSUInteger modeInvocationCount = 0;
	for (id candidate in matched) {
		NSMutableDictionary *record = [NSMutableDictionary dictionary];
		NSString *className =
			NSStringFromClass(object_getClass(candidate)) ?: @"?";
		NSString *address = AAPDiagObjectAddress(candidate, 0) ?: @"";
		record[@"class"] = className;
		record[@"pointer"] = [NSString stringWithFormat:@"%p", candidate];
		record[@"address"] = address;
		record[@"inventory"] = AAPDiagClassInventory(candidate);
		record[@"selectors"] = AAPDiagSelectorAvailability(candidate);
		record[@"setters"] = AAPDiagSetterCandidates(candidate);
		NSMutableArray<NSString *> *candidateTrace =
			[NSMutableArray array];
		AAPDiagLog(@"ui_candidate index=%lu class=%@ pointer=%p address=%@",
			(unsigned long)[matched indexOfObjectIdenticalTo:candidate],
			className,
			candidate,
			address);

		NSString *configReturn = @"";
		NSString *configError = nil;
		BOOL configInvoked = AAPDiagInvokeSetter(
			candidate,
			NSSelectorFromString(@"setListeningModeConfigs:"),
			0x0F,
			&configReturn,
			&configError);
		[candidateTrace addObject:[NSString stringWithFormat:
			@"setListeningModeConfigs:0x0F invoked=%d return=%@ error=%@",
			configInvoked,
			configReturn ?: @"",
			configError ?: @"none"]];
		NSString *modeReturn = @"";
		NSString *modeError = nil;
		BOOL modeInvoked = AAPDiagInvokeSetter(
			candidate,
			NSSelectorFromString(@"setListeningMode:"),
			mode,
			&modeReturn,
			&modeError);
		record[@"set_mode"] = @{
			@"requested": @(mode),
			@"invoked": @(modeInvoked),
			@"return": modeReturn ?: @"",
			@"error": modeError ?: @"",
		};
		[candidateTrace addObject:[NSString stringWithFormat:
			@"setListeningMode:%u invoked=%d return=%@ error=%@",
			mode,
			modeInvoked,
			modeReturn ?: @"",
			modeError ?: @"none"]];
		if (modeInvoked) {
			modeInvocationCount++;
		}

		if (mode == AAPDiagModeAdaptive) {
			NSString *adaptiveReturn = @"";
			NSString *adaptiveError = nil;
			BOOL adaptiveInvoked = AAPDiagInvokeSetter(
				candidate,
				NSSelectorFromString(
					@"setAdaptiveTransparencyEnabled:"),
				1,
				&adaptiveReturn,
				&adaptiveError);
			record[@"set_adaptive_transparency"] = @{
				@"invoked": @(adaptiveInvoked),
				@"return": adaptiveReturn ?: @"",
				@"error": adaptiveError ?: @"",
			};
			[candidateTrace addObject:[NSString stringWithFormat:
				@"setAdaptiveTransparencyEnabled:YES invoked=%d "
				@"return=%@ error=%@",
				adaptiveInvoked,
				adaptiveReturn ?: @"",
				adaptiveError ?: @"none"]];
		}
		record[@"trace"] = candidateTrace;
		[records addObject:record];
		AAPDiagLog(@"ui_candidate_result class=%@ pointer=%p address=%@ "
			@"trace=%@",
			className,
			candidate,
			address,
			candidateTrace);
	}

	result[@"devices"] = records;
		result[@"setter_invocations"] = @(modeInvocationCount);
		[trace addObject:[NSString stringWithFormat:
			@"native_mode_setters invoked=%lu (no AACP reply captured here)",
			(unsigned long)modeInvocationCount]];
		if (!modeInvocationCount) {
			result[@"status"] = @"native_setter_missing";
		}
	return result;
}
