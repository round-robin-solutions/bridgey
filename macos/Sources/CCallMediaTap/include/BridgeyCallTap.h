#ifndef BRIDGEY_CALL_TAP_H
#define BRIDGEY_CALL_TAP_H
#include <CoreAudio/AudioHardware.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif
typedef struct BridgeyCallTap BridgeyCallTap;
// After a tap is allocated, even partial preparation returns an owned handle. Start reports
// preparation failures; release must succeed before the caller discards that handle.
BridgeyCallTap *_Nullable BridgeyCallTapPrepare(AudioObjectID process, CFStringRef _Nonnull uuid, OSStatus *_Nonnull status);
AudioObjectID BridgeyCallTapObject(const BridgeyCallTap *_Nonnull tap);
AudioObjectID BridgeyCallTapAggregate(const BridgeyCallTap *_Nonnull tap);
OSStatus BridgeyCallTapStart(BridgeyCallTap *_Nonnull tap);
OSStatus BridgeyCallTapArm(BridgeyCallTap *_Nonnull tap);
OSStatus BridgeyCallTapStop(BridgeyCallTap *_Nonnull tap);
bool BridgeyCallTapIsReading(const BridgeyCallTap *_Nonnull tap);
bool BridgeyCallTapIsClosing(const BridgeyCallTap *_Nonnull tap);
const char *_Nonnull BridgeyCallTapLastOperation(const BridgeyCallTap *_Nonnull tap);
// Success consumes the handle. Failure keeps it valid for a later cleanup retry.
OSStatus BridgeyCallTapRelease(BridgeyCallTap *_Nonnull tap);
#ifdef __cplusplus
}
#endif
#endif
