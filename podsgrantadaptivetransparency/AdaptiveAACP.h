#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(unsigned int, AAPListeningMode) {
	AAPListeningModeOff = 1,
	AAPListeningModeNoiseCancellation = 2,
	AAPListeningModeTransparency = 3,
	AAPListeningModeAdaptive = 4,
};

typedef void (^AAPAdaptiveCompletion)(BOOL confirmed,
	BOOL sent,
	unsigned int readback,
	NSString * _Nullable error);

extern NSString *const AAPAdaptiveLogPath;

void AAPAdaptiveLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

BOOL AAPAdaptiveReadListeningMode(id _Nullable device, unsigned int * _Nullable mode);

/*
 * Requests a listening mode through the private BluetoothDevice API.
 *
 * Adaptive uses the same sequence as the Control Center implementation:
 * setListeningModeConfigs: argument 0x0F, then setListeningMode: argument 4.
 * Turning the feature off selects Transparency (3).
 *
 * Completion is called on the main queue only after listeningMode reports
 * the requested value, or after the bounded readback window expires.
 */
void AAPAdaptiveRequestListeningMode(id _Nullable device,
	BOOL enabled,
	AAPAdaptiveCompletion completion);

NS_ASSUME_NONNULL_END
