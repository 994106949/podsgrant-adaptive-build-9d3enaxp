#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const AAPDiagLogPath;
extern NSString *const AAPDiagRequestPath;
extern NSString *const AAPDiagResultPath;
extern NSString *const AAPDiagDarwinNotification;

typedef NS_ENUM(unsigned int, AAPDiagMode) {
	AAPDiagModeNoiseCancellation = 2,
	AAPDiagModeTransparency = 3,
	AAPDiagModeAdaptive = 4,
};

void AAPDiagLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
NSString * _Nullable AAPDiagNormalizeAddress(NSString * _Nullable address);
NSString *AAPDiagHex(NSData * _Nullable data);
unsigned int AAPDiagReadLocalListeningMode(id _Nullable device, BOOL * _Nullable available);

NSDictionary<NSString *, id> *AAPDiagRunTransportTest(NSString *address,
	unsigned int mode);

NSDictionary<NSString *, id> *AAPDiagRunNativeTest(id _Nullable device,
	unsigned int mode);

BOOL AAPDiagWriteHelperRequest(NSString *address,
	unsigned int mode,
	unsigned long long sequence);
NSDictionary<NSString *, id> * _Nullable AAPDiagReadHelperResult(
	unsigned long long sequence);

NS_ASSUME_NONNULL_END
