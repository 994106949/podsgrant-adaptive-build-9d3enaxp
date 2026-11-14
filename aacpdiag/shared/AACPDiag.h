#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const AAPDiagLogPath;
extern NSString *const AAPDiagFallbackLogPath;
extern NSString *const AAPDiagTmpLogPath;
extern NSString *const AAPDiagRequestPath;
extern NSString *const AAPDiagResultPath;
extern NSString *const AAPDiagFallbackRequestPath;
extern NSString *const AAPDiagFallbackResultPath;
extern NSString *const AAPDiagTmpRequestPath;
extern NSString *const AAPDiagTmpResultPath;
extern NSString *const AAPDiagReadyPath;
extern NSString *const AAPDiagFallbackReadyPath;
extern NSString *const AAPDiagTmpReadyPath;
extern NSString *const AAPDiagDarwinNotification;
extern const char *const AAPDiagNotifyName;
extern NSString *const AAPDiagVersion;

typedef NS_ENUM(unsigned int, AAPDiagMode) {
	AAPDiagModeNoiseCancellation = 2,
	AAPDiagModeTransparency = 3,
	AAPDiagModeAdaptive = 4,
};

void AAPDiagLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
void AAPDiagLogToPath(NSString *path, NSString *format, ...) NS_FORMAT_FUNCTION(2, 3);
void AAPDiagSetLogMirroring(BOOL enabled);
NSString * _Nullable AAPDiagNormalizeAddress(NSString * _Nullable address);
NSString *AAPDiagHex(NSData * _Nullable data);
unsigned int AAPDiagReadLocalListeningMode(id _Nullable device, BOOL * _Nullable available);
NSArray<NSString *> *AAPDiagRequestPaths(void);
NSArray<NSString *> *AAPDiagResultPaths(void);
NSArray<NSString *> *AAPDiagReadyPaths(void);

NSDictionary<NSString *, id> *AAPDiagRunTransportTest(NSString *address,
	unsigned int mode);

NSDictionary<NSString *, id> *AAPDiagRunNativeTest(id _Nullable device,
	unsigned int mode);
NSArray *AAPDiagDiscoverDeviceCandidates(NSString * _Nullable expectedAddress);
NSDictionary<NSString *, id> *AAPDiagRunNativeTestOnCandidates(
	NSArray * _Nullable candidates,
	NSString * _Nullable expectedAddress,
	unsigned int mode);

void AAPDiagLogClassInventory(NSString *scope, id _Nullable object);
void AAPDiagInstallRuntimeHooks(void);

BOOL AAPDiagWriteHelperRequest(NSString *address,
	unsigned int mode,
	unsigned long long sequence);
NSDictionary<NSString *, id> * _Nullable AAPDiagReadHelperResult(
	unsigned long long sequence);
NSDictionary<NSString *, id> * _Nullable AAPDiagReadResultForSource(
	unsigned long long sequence,
	NSString * _Nullable source);
NSDictionary<NSString *, id> * _Nullable AAPDiagReadLatestRequest(
	NSString * _Nullable * _Nullable selectedPath);
BOOL AAPDiagWriteTransportResult(
	NSDictionary<NSString *, id> *result,
	unsigned long long sequence,
	NSString *source,
	NSString * _Nullable requestPath);
BOOL AAPDiagRequestIsClaimed(
	unsigned long long sequence,
	NSString * _Nullable * _Nullable claimant);
BOOL AAPDiagClaimRequest(
	unsigned long long sequence,
	NSString *source);
BOOL AAPDiagWritePlistToPaths(NSDictionary<NSString *, id> *plist,
	NSArray<NSString *> *paths);
BOOL AAPDiagWriteHelperReady(NSDictionary<NSString *, id> *ready);
NSDictionary<NSString *, id> * _Nullable AAPDiagReadHelperReady(void);
NSDictionary<NSString *, id> * _Nullable AAPDiagReadReadyForSource(
	NSString * _Nullable source);

void AAPDiagEnsureRuntimeDirectories(void);
void AAPDiagRemoveRequestAndResultPaths(void);

NS_ASSUME_NONNULL_END
