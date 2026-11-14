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

static const char *AAPDiagUnqualifiedType(const char *type) {
	if (!type) {
		return NULL;
	}
	while (*type && strchr("rnNoORV", *type)) {
		type++;
	}
	return type;
}

static BOOL AAPDiagSetNumericInvocationArgument(
	NSInvocation *invocation,
	const char *rawType,
	unsigned int argument,
	NSString **error) {
	const char *type = AAPDiagUnqualifiedType(rawType);
	if (!type || !*type) {
		if (error) {
			*error = @"missing numeric argument type";
		}
		return NO;
	}
	switch (*type) {
		case 'c': {
			int8_t value = (int8_t)argument;
			[invocation setArgument:&value atIndex:2];
			return YES;
		}
		case 'C':
		case 'B': {
			uint8_t value = (uint8_t)argument;
			[invocation setArgument:&value atIndex:2];
			return YES;
		}
		case 's': {
			int16_t value = (int16_t)argument;
			[invocation setArgument:&value atIndex:2];
			return YES;
		}
		case 'S': {
			uint16_t value = (uint16_t)argument;
			[invocation setArgument:&value atIndex:2];
			return YES;
		}
		case 'i': {
			int32_t value = (int32_t)argument;
			[invocation setArgument:&value atIndex:2];
			return YES;
		}
		case 'I': {
			uint32_t value = (uint32_t)argument;
			[invocation setArgument:&value atIndex:2];
			return YES;
		}
		case 'q':
		case 'l': {
			int64_t value = (int64_t)argument;
			[invocation setArgument:&value atIndex:2];
			return YES;
		}
		case 'Q':
		case 'L': {
			uint64_t value = (uint64_t)argument;
			[invocation setArgument:&value atIndex:2];
			return YES;
		}
		case 'f': {
			float value = (float)argument;
			[invocation setArgument:&value atIndex:2];
			return YES;
		}
		case 'd': {
			double value = (double)argument;
			[invocation setArgument:&value atIndex:2];
			return YES;
		}
		default:
			if (error) {
				*error = [NSString stringWithFormat:
					@"unsupported numeric argument type %s", type];
			}
			return NO;
	}
}

static NSString *AAPDiagMethodEncoding(NSMethodSignature *signature) {
	if (!signature) {
		return @"";
	}
	NSMutableArray<NSString *> *arguments = [NSMutableArray array];
	for (NSUInteger index = 0; index < signature.numberOfArguments; index++) {
		const char *type = [signature getArgumentTypeAtIndex:index];
		[arguments addObject:type
			? [NSString stringWithUTF8String:type] ?: @"?"
			: @"?"];
	}
	const char *returnType = signature.methodReturnType;
	return [NSString stringWithFormat:@"return=%s args=%@",
		returnType ?: "", [arguments componentsJoinedByString:@","]];
}

static BOOL AAPDiagScalarReturnSucceeded(
	const char *rawType,
	uint64_t raw) {
	const char *type = AAPDiagUnqualifiedType(rawType);
	if (!type || !*type || *type == 'v') {
		return YES;
	}
	if (*type == '@') {
		return raw != 0;
	}
	if (*type == '*' || *type == '^' || *type == '#') {
		return raw != 0;
	}
	switch (*type) {
		case 'c':
			return (int8_t)raw != 0;
		case 'C':
		case 'B':
			return (uint8_t)raw != 0;
		case 's':
			return (int16_t)raw != 0;
		case 'S':
			return (uint16_t)raw != 0;
		case 'i':
			return (int32_t)raw != 0;
		case 'I':
			return (uint32_t)raw != 0;
		case 'q':
		case 'l':
			return (int64_t)raw != 0;
		case 'Q':
		case 'L':
			return (uint64_t)raw != 0;
		case 'f':
		case 'd':
			return raw != 0;
		default:
			return raw != 0;
	}
}

static BOOL AAPDiagRecordInvocationReturn(
	NSInvocation *invocation,
	NSMethodSignature *signature,
	NSMutableDictionary<NSString *, id> *record) {
	const char *returnType = signature.methodReturnType;
	record[@"return_type"] = returnType
		? [NSString stringWithUTF8String:returnType] ?: @"?"
		: @"";
	if (signature.methodReturnLength == 0 ||
		!returnType || *returnType == 'v') {
		record[@"return"] = @"void";
		record[@"return_success"] = @YES;
		return YES;
	}

	uint64_t raw = 0;
	NSUInteger length = signature.methodReturnLength;
	if (length > sizeof(raw)) {
		length = sizeof(raw);
		record[@"return_truncated"] = @YES;
	}
	[invocation getReturnValue:&raw];
	record[@"return_raw"] = @(raw);
	if (*returnType == '@') {
		__unsafe_unretained id value = nil;
		[invocation getReturnValue:&value];
		record[@"return"] = value
			? [value description] ?: @"<non-nil>"
			: @"nil";
	} else {
		record[@"return"] = [NSString stringWithFormat:@"0x%llx",
			(unsigned long long)raw];
	}
	BOOL success = AAPDiagScalarReturnSucceeded(returnType, raw);
	record[@"return_success"] = @(success);
	return success;
}

static NSDictionary<NSString *, id> *AAPDiagInvokeNumericSetterResult(
	id target,
	SEL selector,
	unsigned int argument) {
	NSMutableDictionary<NSString *, id> *record =
		[NSMutableDictionary dictionary];
	record[@"selector"] = selector ? NSStringFromSelector(selector) : @"";
	record[@"class"] = target
		? NSStringFromClass(object_getClass(target)) ?: @"?"
		: @"nil";
	record[@"pointer"] = [NSString stringWithFormat:@"%p", target];
	record[@"invoked"] = @NO;
	record[@"success"] = @NO;
	record[@"error"] = @"";
	record[@"exception"] = @"";

	if (!target || !selector || ![target respondsToSelector:selector]) {
		record[@"available"] = @NO;
		record[@"error"] = @"selector is unavailable";
		return record;
	}
	record[@"available"] = @YES;
	NSMethodSignature *signature = [target methodSignatureForSelector:selector];
	record[@"type_encoding"] = AAPDiagMethodEncoding(signature);
	if (!signature || signature.numberOfArguments != 3) {
		record[@"error"] = @"unsupported method signature";
		return record;
	}
	const char *argumentType = [signature getArgumentTypeAtIndex:2];
	record[@"argument_type"] = argumentType
		? [NSString stringWithUTF8String:argumentType] ?: @"?"
		: @"";
	NSInvocation *invocation =
		[NSInvocation invocationWithMethodSignature:signature];
	invocation.target = target;
	invocation.selector = selector;
	NSString *argumentError = nil;
	if (!AAPDiagSetNumericInvocationArgument(
			invocation, argumentType, argument, &argumentError)) {
		record[@"error"] = argumentError ?: @"unsupported argument";
		return record;
	}

	record[@"invoked"] = @YES;
	@try {
		[invocation invoke];
	} @catch (NSException *exception) {
		record[@"error"] = exception.reason ?: @"invocation raised an exception";
		record[@"exception"] = exception.name ?: @"NSException";
		return record;
	}
	BOOL returnSuccess =
		AAPDiagRecordInvocationReturn(invocation, signature, record);
	record[@"success"] = @(returnSuccess);
	return record;
}

static BOOL AAPDiagInvokeSetter(id target,
	SEL selector,
	unsigned int argument,
	NSString **returnDescription,
	NSString **error) {
	NSDictionary<NSString *, id> *result =
		AAPDiagInvokeNumericSetterResult(target, selector, argument);
	if (returnDescription) {
		*returnDescription = result[@"return"] ?: @"";
	}
	if (error) {
		*error = result[@"error"] ?: @"";
	}
	return [result[@"invoked"] boolValue];
}

static NSDictionary<NSString *, id> *AAPDiagInvokeListeningModePair(
	id target,
	unsigned int mode) {
	NSMutableDictionary<NSString *, id> *record =
		[NSMutableDictionary dictionary];
	record[@"selector"] = @"setListeningMode:error:";
	record[@"class"] = target
		? NSStringFromClass(object_getClass(target)) ?: @"?"
		: @"nil";
	record[@"pointer"] = [NSString stringWithFormat:@"%p", target];
	record[@"invoked"] = @NO;
	record[@"success"] = @NO;
	record[@"error"] = @"";
	record[@"exception"] = @"";
	SEL selector = NSSelectorFromString(@"setListeningMode:error:");
	if (!target || ![target respondsToSelector:selector]) {
		record[@"available"] = @NO;
		record[@"error"] = @"selector is unavailable";
		return record;
	}
	record[@"available"] = @YES;
	NSMethodSignature *signature = [target methodSignatureForSelector:selector];
	record[@"type_encoding"] = AAPDiagMethodEncoding(signature);
	if (!signature || signature.numberOfArguments != 4) {
		record[@"error"] = @"expected four method arguments";
		return record;
	}
	const char *modeType = [signature getArgumentTypeAtIndex:2];
	const char *errorType = [signature getArgumentTypeAtIndex:3];
	record[@"argument_type"] = modeType
		? [NSString stringWithUTF8String:modeType] ?: @"?"
		: @"";
	record[@"error_argument_type"] = errorType
		? [NSString stringWithUTF8String:errorType] ?: @"?"
		: @"";
	const char *unqualifiedErrorType = AAPDiagUnqualifiedType(errorType);
	if (!unqualifiedErrorType ||
		unqualifiedErrorType[0] != '^' ||
		(unqualifiedErrorType[1] != '@' && unqualifiedErrorType[1] != '#')) {
		record[@"error"] = @"error argument is not an object pointer";
		return record;
	}

	NSInvocation *invocation =
		[NSInvocation invocationWithMethodSignature:signature];
	invocation.target = target;
	invocation.selector = selector;
	NSString *argumentError = nil;
	if (!AAPDiagSetNumericInvocationArgument(
			invocation, modeType, mode, &argumentError)) {
		record[@"error"] = argumentError ?: @"unsupported mode argument";
		return record;
	}
	__autoreleasing NSError *errorObject = nil;
	[invocation setArgument:&errorObject atIndex:3];
	record[@"invoked"] = @YES;
	@try {
		[invocation invoke];
	} @catch (NSException *exception) {
		record[@"error"] = exception.reason ?: @"invocation raised an exception";
		record[@"exception"] = exception.name ?: @"NSException";
		return record;
	}

	__autoreleasing NSError *returnedError = nil;
	[invocation getArgument:&returnedError atIndex:3];
	record[@"error_present"] = @(returnedError != nil);
	record[@"error_domain"] = returnedError.domain ?: @"";
	record[@"error_code"] = @(returnedError.code);
	record[@"error_description"] =
		returnedError.localizedDescription ?: @"";
	if (returnedError) {
		record[@"error"] = [NSString stringWithFormat:@"%@ (%ld): %@",
			returnedError.domain ?: @"?",
			(long)returnedError.code,
			returnedError.localizedDescription ?: @""];
	}
	BOOL returnSuccess =
		AAPDiagRecordInvocationReturn(invocation, signature, record);
	record[@"success"] = @(returnSuccess && returnedError == nil);
	return record;
}

static NSDictionary<NSString *, id> *AAPDiagInvokeNoArgument(
	id target,
	SEL selector) {
	NSMutableDictionary<NSString *, id> *record =
		[NSMutableDictionary dictionary];
	record[@"selector"] = selector ? NSStringFromSelector(selector) : @"";
	record[@"class"] = target
		? NSStringFromClass(object_getClass(target)) ?: @"?"
		: @"nil";
	record[@"pointer"] = [NSString stringWithFormat:@"%p", target];
	record[@"invoked"] = @NO;
	record[@"success"] = @NO;
	record[@"error"] = @"";
	record[@"exception"] = @"";
	if (!target || !selector || ![target respondsToSelector:selector]) {
		record[@"available"] = @NO;
		record[@"error"] = @"selector is unavailable";
		return record;
	}
	record[@"available"] = @YES;
	NSMethodSignature *signature = [target methodSignatureForSelector:selector];
	record[@"type_encoding"] = AAPDiagMethodEncoding(signature);
	if (!signature || signature.numberOfArguments != 2) {
		record[@"error"] = @"expected a no-argument method";
		return record;
	}
	record[@"argument_count"] = @(signature.numberOfArguments);
	NSInvocation *invocation =
		[NSInvocation invocationWithMethodSignature:signature];
	invocation.target = target;
	invocation.selector = selector;
	record[@"invoked"] = @YES;
	@try {
		[invocation invoke];
	} @catch (NSException *exception) {
		record[@"error"] = exception.reason ?: @"invocation raised an exception";
		record[@"exception"] = exception.name ?: @"NSException";
		return record;
	}
	BOOL returnSuccess =
		AAPDiagRecordInvocationReturn(invocation, signature, record);
	record[@"success"] = @(returnSuccess);
	return record;
}

static NSDictionary<NSString *, id> *AAPDiagInvokeSendUpdate(id target) {
	return AAPDiagInvokeNoArgument(
		target,
		NSSelectorFromString(@"sendUpdateToAccessory"));
}

static BOOL AAPDiagListeningModePairUsable(NSDictionary *record) {
	if (![record isKindOfClass:[NSDictionary class]]) {
		return NO;
	}
	if (![record[@"invoked"] boolValue] ||
		![record[@"success"] boolValue]) {
		return NO;
	}
	if ([record[@"error_present"] boolValue] ||
		[record[@"exception"] length]) {
		return NO;
	}
	return YES;
}

static NSDictionary<NSString *, id> *
AAPDiagInvokePreferredListeningModeSetter(id target, unsigned int mode) {
	NSMutableDictionary<NSString *, id> *result =
		[NSMutableDictionary dictionary];
	result[@"pair_selector"] = @"setListeningMode:error:";
	result[@"fallback_selector"] = @"setListeningMode:";
	result[@"used_fallback"] = @NO;

	NSDictionary<NSString *, id> *pair =
		AAPDiagInvokeListeningModePair(target, mode);
	result[@"pair"] = pair;
	NSDictionary<NSString *, id> *fallback = nil;
	if (!AAPDiagListeningModePairUsable(pair)) {
		fallback = AAPDiagInvokeNumericSetterResult(
			target,
			NSSelectorFromString(@"setListeningMode:"),
			mode);
		result[@"used_fallback"] = @YES;
	}
	result[@"fallback"] = fallback ?: @{};

	NSDictionary<NSString *, id> *selected = fallback ?: pair;
	result[@"selector"] = selected[@"selector"] ?: @"";
	result[@"invoked"] = selected[@"invoked"] ?: @NO;
	result[@"success"] = selected[@"success"] ?: @NO;
	result[@"return"] = selected[@"return"] ?: @"";
	result[@"error"] = selected[@"error"] ?: @"";
	result[@"exception"] = selected[@"exception"] ?: @"";
	result[@"error_present"] = selected[@"error_present"] ?: @NO;
	BOOL pairAvailable = [pair[@"available"] boolValue] ||
		[pair[@"invoked"] boolValue];
	BOOL fallbackAvailable = fallback &&
		([fallback[@"available"] boolValue] ||
		 [fallback[@"invoked"] boolValue]);
	result[@"available"] = @(pairAvailable || fallbackAvailable);
	return result;
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

	NSDictionary<NSString *, id> *configResult =
		AAPDiagInvokeNumericSetterResult(
			device,
			NSSelectorFromString(@"setListeningModeConfigs:"),
			0x0F);
	result[@"config"] = configResult;
	result[@"config_setter"] = configResult;
	[trace addObject:[NSString stringWithFormat:
		@"setListeningModeConfigs:0x0F invoked=%d success=%d "
		@"return=%@ error=%@ exception=%@",
		[configResult[@"invoked"] boolValue],
		[configResult[@"success"] boolValue],
		configResult[@"return"] ?: @"",
		configResult[@"error"] ?: @"none",
		configResult[@"exception"] ?: @"none"]];

	[NSThread sleepForTimeInterval:0.15];

	NSDictionary<NSString *, id> *modeResult =
		AAPDiagInvokePreferredListeningModeSetter(device, mode);
	result[@"set_mode"] = modeResult;
	[trace addObject:[NSString stringWithFormat:
		@"listeningMode setter mode=%u selector=%@ invoked=%d "
		@"success=%d return=%@ error=%@ exception=%@ "
		@"pair=%@ fallback=%@",
		mode,
		modeResult[@"selector"] ?: @"none",
		[modeResult[@"invoked"] boolValue],
		[modeResult[@"success"] boolValue],
		modeResult[@"return"] ?: @"",
		modeResult[@"error"] ?: @"none",
		modeResult[@"exception"] ?: @"none",
		modeResult[@"pair_selector"] ?: @"none",
		modeResult[@"fallback_selector"] ?: @"none"]];

	NSDictionary<NSString *, id> *sendUpdateAfterMode =
		AAPDiagInvokeSendUpdate(device);
	result[@"send_update_after_mode"] = sendUpdateAfterMode;
	[trace addObject:[NSString stringWithFormat:
		@"sendUpdateToAccessory after_mode invoked=%d success=%d "
		@"return=%@ error=%@ exception=%@",
		[sendUpdateAfterMode[@"invoked"] boolValue],
		[sendUpdateAfterMode[@"success"] boolValue],
		sendUpdateAfterMode[@"return"] ?: @"",
		sendUpdateAfterMode[@"error"] ?: @"none",
		sendUpdateAfterMode[@"exception"] ?: @"none"]];

	NSDictionary<NSString *, id> *adaptiveResult = @{};
	if (mode == AAPDiagModeAdaptive) {
		adaptiveResult = AAPDiagInvokeNumericSetterResult(
			device,
			NSSelectorFromString(@"setAdaptiveTransparencyEnabled:"),
			1);
		result[@"set_adaptive_transparency"] = adaptiveResult;
		[trace addObject:[NSString stringWithFormat:
			@"setAdaptiveTransparencyEnabled:YES invoked=%d success=%d "
			@"return=%@ error=%@ exception=%@",
			[adaptiveResult[@"invoked"] boolValue],
			[adaptiveResult[@"success"] boolValue],
			adaptiveResult[@"return"] ?: @"",
			adaptiveResult[@"error"] ?: @"none",
			adaptiveResult[@"exception"] ?: @"none"]];

		NSDictionary<NSString *, id> *sendUpdateAfterAdaptive =
			AAPDiagInvokeSendUpdate(device);
		result[@"send_update_after_adaptive"] = sendUpdateAfterAdaptive;
		[trace addObject:[NSString stringWithFormat:
			@"sendUpdateToAccessory after_adaptive invoked=%d success=%d "
			@"return=%@ error=%@ exception=%@",
			[sendUpdateAfterAdaptive[@"invoked"] boolValue],
			[sendUpdateAfterAdaptive[@"success"] boolValue],
			sendUpdateAfterAdaptive[@"return"] ?: @"",
			sendUpdateAfterAdaptive[@"error"] ?: @"none",
			sendUpdateAfterAdaptive[@"exception"] ?: @"none"]];
	}

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
		@"informational_only": @YES,
	};
	BOOL modeSetterAvailable = [modeResult[@"available"] boolValue];
	BOOL modeSetterInvoked = [modeResult[@"invoked"] boolValue];
	BOOL modeSetterSucceeded = [modeResult[@"success"] boolValue];
	BOOL modeSetterFailed = [modeResult[@"exception"] length] > 0 ||
		[modeResult[@"error"] length] > 0;
	if (!modeSetterAvailable) {
		result[@"status"] = @"native_setter_missing";
	} else if (!modeSetterInvoked || !modeSetterSucceeded ||
		modeSetterFailed) {
		result[@"status"] = @"native_setter_failed";
	} else {
		result[@"status"] = @"native_setter_invoked_unconfirmed";
	}
	[trace addObject:[NSString stringWithFormat:
		@"native_result status=%@ requested=%u final=%lld "
		@"getter_informational_only=1",
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
	result[@"status"] = @"native_setter_invoked_unconfirmed";
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
	NSUInteger modeFailureCount = 0;
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

		long long before = 0;
		NSString *beforeDescription = @"";
		NSString *getterError = nil;
		BOOL beforeOK = AAPDiagReadGetter(candidate,
			NSSelectorFromString(@"listeningMode"),
			&before,
			&beforeDescription,
			&getterError);
		record[@"getter_before"] = @{
			@"available": @(beforeOK),
			@"value": @(before),
			@"description": beforeDescription ?: @"",
			@"error": getterError ?: @"",
			@"informational_only": @YES,
		};

		NSDictionary<NSString *, id> *configResult =
			AAPDiagInvokeNumericSetterResult(
				candidate,
				NSSelectorFromString(@"setListeningModeConfigs:"),
				0x0F);
		record[@"config_setter"] = configResult;
		[candidateTrace addObject:[NSString stringWithFormat:
			@"setListeningModeConfigs:0x0F invoked=%d success=%d "
			@"return=%@ error=%@ exception=%@",
			[configResult[@"invoked"] boolValue],
			[configResult[@"success"] boolValue],
			configResult[@"return"] ?: @"",
			configResult[@"error"] ?: @"none",
			configResult[@"exception"] ?: @"none"]];

		[NSThread sleepForTimeInterval:0.15];
		NSDictionary<NSString *, id> *modeResult =
			AAPDiagInvokePreferredListeningModeSetter(candidate, mode);
		record[@"set_mode"] = modeResult;
		[candidateTrace addObject:[NSString stringWithFormat:
			@"listeningMode setter mode=%u selector=%@ invoked=%d "
			@"success=%d return=%@ error=%@ exception=%@ "
			@"pair=%@ fallback=%@",
			mode,
			modeResult[@"selector"] ?: @"none",
			[modeResult[@"invoked"] boolValue],
			[modeResult[@"success"] boolValue],
			modeResult[@"return"] ?: @"",
			modeResult[@"error"] ?: @"none",
			modeResult[@"exception"] ?: @"none",
			modeResult[@"pair_selector"] ?: @"none",
			modeResult[@"fallback_selector"] ?: @"none"]];
		BOOL modeInvoked = [modeResult[@"invoked"] boolValue];
		BOOL modeSucceeded = [modeResult[@"success"] boolValue];
		BOOL modeFailed = [modeResult[@"exception"] length] > 0 ||
			[modeResult[@"error"] length] > 0;
		if (modeInvoked) {
			modeInvocationCount++;
		}
		if (modeFailed || !modeSucceeded) {
			modeFailureCount++;
		}

		NSDictionary<NSString *, id> *sendUpdateAfterMode =
			AAPDiagInvokeSendUpdate(candidate);
		record[@"send_update_after_mode"] = sendUpdateAfterMode;
		[candidateTrace addObject:[NSString stringWithFormat:
			@"sendUpdateToAccessory after_mode invoked=%d success=%d "
			@"return=%@ error=%@ exception=%@",
			[sendUpdateAfterMode[@"invoked"] boolValue],
			[sendUpdateAfterMode[@"success"] boolValue],
			sendUpdateAfterMode[@"return"] ?: @"",
			sendUpdateAfterMode[@"error"] ?: @"none",
			sendUpdateAfterMode[@"exception"] ?: @"none"]];

		if (mode == AAPDiagModeAdaptive) {
			NSDictionary<NSString *, id> *adaptiveResult =
				AAPDiagInvokeNumericSetterResult(
					candidate,
					NSSelectorFromString(
						@"setAdaptiveTransparencyEnabled:"),
					1);
			record[@"set_adaptive_transparency"] = adaptiveResult;
			[candidateTrace addObject:[NSString stringWithFormat:
				@"setAdaptiveTransparencyEnabled:YES invoked=%d "
				@"success=%d return=%@ error=%@ exception=%@",
				[adaptiveResult[@"invoked"] boolValue],
				[adaptiveResult[@"success"] boolValue],
				adaptiveResult[@"return"] ?: @"",
				adaptiveResult[@"error"] ?: @"none",
				adaptiveResult[@"exception"] ?: @"none"]];

			NSDictionary<NSString *, id> *sendUpdateAfterAdaptive =
				AAPDiagInvokeSendUpdate(candidate);
			record[@"send_update_after_adaptive"] =
				sendUpdateAfterAdaptive;
			[candidateTrace addObject:[NSString stringWithFormat:
				@"sendUpdateToAccessory after_adaptive invoked=%d "
				@"success=%d return=%@ error=%@ exception=%@",
				[sendUpdateAfterAdaptive[@"invoked"] boolValue],
				[sendUpdateAfterAdaptive[@"success"] boolValue],
				sendUpdateAfterAdaptive[@"return"] ?: @"",
				sendUpdateAfterAdaptive[@"error"] ?: @"none",
				sendUpdateAfterAdaptive[@"exception"] ?: @"none"]];
		}

		long long after = 0;
		NSString *afterDescription = @"";
		NSString *afterError = nil;
		BOOL afterOK = AAPDiagReadGetter(candidate,
			NSSelectorFromString(@"listeningMode"),
			&after,
			&afterDescription,
			&afterError);
		record[@"getter_after"] = @{
			@"available": @(afterOK),
			@"value": @(after),
			@"description": afterDescription ?: @"",
			@"error": afterError ?: @"",
			@"informational_only": @YES,
		};
		[candidateTrace addObject:[NSString stringWithFormat:
			@"getter informational_only before=%lld after=%lld",
			before,
			after]];

		if (!AAPDiagListeningModePairUsable(modeResult)) {
			/* The selected setter may still have succeeded via fallback. */
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
		@"native_mode_setters invoked=%lu failures=%lu "
		@"(no AACP reply captured here)",
		(unsigned long)modeInvocationCount,
		(unsigned long)modeFailureCount]];
	if (!modeInvocationCount) {
		result[@"status"] = @"native_setter_missing";
	} else if (modeFailureCount == matched.count) {
		result[@"status"] = @"native_setter_failed";
	} else {
		result[@"status"] = @"native_setter_invoked_unconfirmed";
	}
	return result;
}
