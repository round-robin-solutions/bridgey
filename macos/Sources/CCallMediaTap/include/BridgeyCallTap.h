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
BridgeyCallTap *BridgeyCallTapPrepare(AudioObjectID process, CFStringRef uuid, OSStatus *status);
AudioObjectID BridgeyCallTapObject(const BridgeyCallTap *tap);
AudioObjectID BridgeyCallTapAggregate(const BridgeyCallTap *tap);
OSStatus BridgeyCallTapStart(BridgeyCallTap *tap);
OSStatus BridgeyCallTapArm(BridgeyCallTap *tap);
OSStatus BridgeyCallTapStop(BridgeyCallTap *tap);
bool BridgeyCallTapIsReading(const BridgeyCallTap *tap);
bool BridgeyCallTapIsClosing(const BridgeyCallTap *tap);
const char *BridgeyCallTapLastOperation(const BridgeyCallTap *tap);
// Success consumes the handle. Failure keeps it valid for a later cleanup retry.
OSStatus BridgeyCallTapRelease(BridgeyCallTap *tap);
#ifdef __cplusplus
}
#endif
#endif
