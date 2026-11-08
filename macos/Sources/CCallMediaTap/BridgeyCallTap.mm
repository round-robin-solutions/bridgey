#import "BridgeyCallTap.h"
#import <CoreAudio/CATapDescription.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#include <atomic>
#include <cstring>
#include <new>

// The IO block owns this independently of the control handle. No audio samples or pointers
// are saved. Its steady-state path only loads an atomic; readiness is signalled once.
@interface BridgeyTapReadiness : NSObject {
@public
    std::atomic_bool received;
    dispatch_semaphore_t first;
}
@end
@implementation BridgeyTapReadiness
- (instancetype)init {
    if ((self = [super init])) {
        received.store(false, std::memory_order_relaxed);
        first = dispatch_semaphore_create(0);
    }
    return self;
}
@end

struct BridgeyCallTap {
    AudioObjectID process = kAudioObjectUnknown;
    AudioObjectID tap = kAudioObjectUnknown;
    AudioObjectID aggregate = kAudioObjectUnknown;
    AudioDeviceIOProcID io = nullptr;
    NSString *__strong tapUID = nil;
    NSString *__strong aggregateUID = nil;
    NSUUID *__strong uuid = nil;
    BridgeyTapReadiness *__strong readiness = nil;
    OSStatus preparation = noErr;
    const char *operation = "prepare";
    bool started = false;
    bool closing = false;
};

static AudioObjectPropertyAddress address(AudioObjectPropertySelector selector,
    AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal) {
    return {selector, scope, kAudioObjectPropertyElementMain};
}
static OSStatus stringProperty(AudioObjectID object, AudioObjectPropertySelector selector, NSString **value) {
    auto property = address(selector);
    CFStringRef raw = nullptr;
    UInt32 size = sizeof(raw);
    OSStatus status = AudioObjectGetPropertyData(object, &property, 0, nullptr, &size, &raw);
    if (status != noErr) return status;
    if (raw == nullptr) return kAudioHardwareUnspecifiedError;
    *value = CFBridgingRelease(raw);
    return noErr;
}
// A recycled/missing object is already released. Other read failures retain ownership.
static OSStatus owned(AudioObjectID object, AudioObjectPropertySelector selector, NSString *uid, bool *present) {
    *present = false;
    if (object == kAudioObjectUnknown) return noErr;
    if (uid == nil) return kAudioHardwareNotReadyError;
    NSString *current = nil;
    OSStatus status = stringProperty(object, selector, &current);
    if (status == kAudioHardwareBadObjectError || status == kAudioHardwareUnknownPropertyError) return noErr;
    if (status != noErr) return status;
    *present = [current isEqualToString:uid];
    return noErr;
}
static OSStatus streamCount(AudioObjectID object, AudioObjectPropertyScope scope, UInt32 *count) {
    auto property = address(kAudioDevicePropertyStreams, scope);
    UInt32 bytes = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(object, &property, 0, nullptr, &bytes);
    if (status != noErr) return status;
    if (bytes % sizeof(AudioObjectID) != 0) return kAudioHardwareUnspecifiedError;
    *count = bytes / sizeof(AudioObjectID);
    return noErr;
}
static OSStatus noPhysicalSubdevices(AudioObjectID aggregate) {
    auto property = address(kAudioAggregateDevicePropertyFullSubDeviceList);
    CFArrayRef subdevices = nullptr;
    UInt32 size = sizeof(subdevices);
    OSStatus status = AudioObjectGetPropertyData(aggregate, &property, 0, nullptr, &size, &subdevices);
    if (status != noErr) return status;
    bool empty = subdevices != nullptr && CFArrayGetCount(subdevices) == 0;
    if (subdevices != nullptr) CFRelease(subdevices);
    return empty ? noErr : kAudioHardwareUnsupportedOperationError;
}
static OSStatus setMute(BridgeyCallTap *tap, CATapMuteBehavior mode) {
    if (@available(macOS 14.2, *)) {
        bool present = false;
        OSStatus status = owned(tap->tap, kAudioTapPropertyUID, tap->tapUID, &present);
        if (status != noErr || !present) return status == noErr ? kAudioHardwareBadObjectError : status;
        auto property = address(kAudioTapPropertyDescription);
        CFTypeRef raw = nullptr;
        UInt32 size = sizeof(raw);
        status = AudioObjectGetPropertyData(tap->tap, &property, 0, nullptr, &size, &raw);
        if (status != noErr) return status;
        CATapDescription *description = CFBridgingRelease(raw);
        if (description == nil || ![description.UUID isEqual:tap->uuid] ||
            description.processes.count != 1 || description.processes.firstObject.unsignedIntValue != tap->process ||
            description.exclusive || !description.privateTap) return kAudioHardwareBadObjectError;
        if (@available(macOS 26.0, *)) if (description.processRestoreEnabled) return kAudioHardwareIllegalOperationError;
        description.muteBehavior = mode;
        raw = (__bridge CFTypeRef)description;
        status = AudioObjectSetPropertyData(tap->tap, &property, 0, nullptr, sizeof(raw), &raw);
        if (status != noErr) return status;
        raw = nullptr; size = sizeof(raw);
        status = AudioObjectGetPropertyData(tap->tap, &property, 0, nullptr, &size, &raw);
        if (status != noErr) return status;
        CATapDescription *observed = CFBridgingRelease(raw);
        return observed != nil && observed.muteBehavior == mode ? noErr : kAudioHardwareNotReadyError;
    }
    return kAudioHardwareUnsupportedOperationError;
}

BridgeyCallTap *BridgeyCallTapPrepare(AudioObjectID process, CFStringRef uuid, OSStatus *status) {
    *status = kAudioHardwareUnsupportedOperationError;
    if (@available(macOS 14.2, *)) {
        if (process == kAudioObjectUnknown) { *status = kAudioHardwareIllegalOperationError; return nullptr; }
        auto tap = new (std::nothrow) BridgeyCallTap();
        if (tap == nullptr) { *status = kAudioHardwareUnspecifiedError; return nullptr; }
        tap->uuid = [[NSUUID alloc] initWithUUIDString:(__bridge NSString *)uuid];
        tap->process = process;
        if (tap->uuid == nil) { delete tap; *status = kAudioHardwareIllegalOperationError; return nullptr; }
        CATapDescription *description = [[CATapDescription alloc] initStereoMixdownOfProcesses:@[@(process)]];
        description.UUID = tap->uuid;
        description.name = @"Bridgey temporary media mute";
        description.privateTap = YES;
        description.exclusive = NO;
        description.muteBehavior = CATapUnmuted;
        if (@available(macOS 26.0, *)) description.processRestoreEnabled = NO;
        *status = AudioHardwareCreateProcessTap(description, &tap->tap);
        if (*status != noErr || tap->tap == kAudioObjectUnknown) {
            if (*status == noErr) *status = kAudioHardwareUnspecifiedError;
            delete tap; return nullptr;
        }
        // From here, return partial resources to the owner even after an error. Nothing can
        // mute yet: preparation and reader startup both keep the tap explicitly unmuted.
        tap->operation = "tap UID";
        NSString *tapUID = nil;
        *status = stringProperty(tap->tap, kAudioTapPropertyUID, &tapUID);
        tap->tapUID = tapUID;
        if (*status != noErr) { tap->preparation = *status; return tap; }
        tap->aggregateUID = [NSUUID UUID].UUIDString;
        NSDictionary *composition = @{
            @kAudioAggregateDeviceNameKey: @"Bridgey temporary media mute",
            @kAudioAggregateDeviceUIDKey: tap->aggregateUID,
            @kAudioAggregateDeviceIsPrivateKey: @YES,
            @kAudioAggregateDeviceTapAutoStartKey: @NO,
            @kAudioAggregateDeviceTapListKey: @[@{
                @kAudioSubTapUIDKey: tap->tapUID,
                @kAudioSubTapDriftCompensationKey: @YES
            }]
        };
        tap->operation = "create input-only aggregate";
        *status = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)composition, &tap->aggregate);
        if (*status != noErr) { tap->preparation = *status; return tap; }
        NSString *aggregateUID = nil;
        *status = stringProperty(tap->aggregate, kAudioDevicePropertyDeviceUID, &aggregateUID);
        if (*status != noErr) { tap->preparation = *status; return tap; }
        tap->aggregateUID = aggregateUID;
        UInt32 inputs = 0, outputs = 0;
        *status = streamCount(tap->aggregate, kAudioObjectPropertyScopeInput, &inputs);
        if (*status == noErr) *status = streamCount(tap->aggregate, kAudioObjectPropertyScopeOutput, &outputs);
        if (*status == noErr) *status = noPhysicalSubdevices(tap->aggregate);
        if (*status == noErr && (inputs == 0 || outputs != 0)) *status = kAudioHardwareUnsupportedOperationError;
        if (*status != noErr) { tap->preparation = *status; return tap; }
        tap->readiness = [BridgeyTapReadiness new];
        BridgeyTapReadiness *ready = tap->readiness;
        tap->operation = "create discard reader";
        dispatch_queue_t ioQueue = dispatch_queue_create("in.roundrobin.bridgey.call-media-io", DISPATCH_QUEUE_SERIAL);
        *status = AudioDeviceCreateIOProcIDWithBlock(&tap->io, tap->aggregate, ioQueue,
            ^(const AudioTimeStamp *, const AudioBufferList *input, const AudioTimeStamp *,
              AudioBufferList *output, const AudioTimeStamp *) {
                // No physical output is attached; zero any unexpected output defensively.
                if (output != nullptr) for (UInt32 i = 0; i < output->mNumberBuffers; ++i) {
                    if (output->mBuffers[i].mData != nullptr)
                        std::memset(output->mBuffers[i].mData, 0, output->mBuffers[i].mDataByteSize);
                }
                if (ready->received.load(std::memory_order_acquire) || input == nullptr) return;
                for (UInt32 i = 0; i < input->mNumberBuffers; ++i) {
                    if (input->mBuffers[i].mData != nullptr && input->mBuffers[i].mDataByteSize > 0) {
                        if (!ready->received.exchange(true, std::memory_order_acq_rel))
                            dispatch_semaphore_signal(ready->first);
                        break;
                    }
                }
            });
        tap->preparation = *status;
        return tap;
    }
    return nullptr;
}

AudioObjectID BridgeyCallTapObject(const BridgeyCallTap *tap) { return tap->tap; }
AudioObjectID BridgeyCallTapAggregate(const BridgeyCallTap *tap) { return tap->aggregate; }
const char *BridgeyCallTapLastOperation(const BridgeyCallTap *tap) { return tap->operation; }
bool BridgeyCallTapIsClosing(const BridgeyCallTap *tap) { return tap->closing; }
bool BridgeyCallTapIsReading(const BridgeyCallTap *tap) {
    return tap->started && tap->readiness != nil && tap->readiness->received.load(std::memory_order_acquire);
}
OSStatus BridgeyCallTapStart(BridgeyCallTap *tap) {
    if (tap->closing || tap->preparation != noErr || tap->io == nullptr)
        return tap->preparation != noErr ? tap->preparation : kAudioHardwareNotReadyError;
    tap->operation = "start system-audio reader";
    bool present = false;
    OSStatus status = owned(tap->aggregate, kAudioDevicePropertyDeviceUID, tap->aggregateUID, &present);
    if (status != noErr || !present) return status == noErr ? kAudioHardwareBadObjectError : status;
    status = AudioDeviceStart(tap->aggregate, tap->io);
    if (status != noErr) return status;
    tap->started = true;
    tap->operation = "confirm system-audio reader";
    if (!tap->readiness->received.load(std::memory_order_acquire) &&
        dispatch_semaphore_wait(tap->readiness->first, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) != 0)
        return kAudioHardwareNotReadyError;
    return noErr;
}
OSStatus BridgeyCallTapArm(BridgeyCallTap *tap) {
    if (tap->closing || !BridgeyCallTapIsReading(tap)) return kAudioHardwareNotReadyError;
    tap->operation = "mute while reader is active";
    return setMute(tap, CATapMutedWhenTapped);
}
OSStatus BridgeyCallTapStop(BridgeyCallTap *tap) {
    tap->closing = true;
    if (!tap->started || tap->io == nullptr || tap->aggregate == kAudioObjectUnknown) { tap->started = false; return noErr; }
    tap->operation = "stop system-audio reader";
    bool present = false;
    OSStatus status = owned(tap->aggregate, kAudioDevicePropertyDeviceUID, tap->aggregateUID, &present);
    if (status != noErr) return status;
    if (!present) { tap->io = nullptr; tap->aggregate = kAudioObjectUnknown; tap->started = false; return noErr; }
    status = AudioDeviceStop(tap->aggregate, tap->io);
    if (status == noErr || status == kAudioHardwareBadObjectError) { tap->started = false; return noErr; }
    return status;
}
OSStatus BridgeyCallTapRelease(BridgeyCallTap *tap) {
    tap->closing = true;
    // Giving back audibility takes priority over deleting handles. A stopped reader releases
    // CATapMutedWhenTapped even if later object destruction needs a retry.
    (void)setMute(tap, CATapUnmuted);
    OSStatus status = BridgeyCallTapStop(tap);
    if (status != noErr) return status;
    if (tap->io != nullptr) {
        tap->operation = "destroy reader";
        bool present = false;
        status = owned(tap->aggregate, kAudioDevicePropertyDeviceUID, tap->aggregateUID, &present);
        if (status != noErr) return status;
        if (present) {
            status = AudioDeviceDestroyIOProcID(tap->aggregate, tap->io);
            if (status != noErr && status != kAudioHardwareBadObjectError) return status;
        } else { tap->aggregate = kAudioObjectUnknown; }
        tap->io = nullptr;
    }
    if (tap->aggregate != kAudioObjectUnknown) {
        tap->operation = "destroy aggregate";
        bool present = false;
        status = owned(tap->aggregate, kAudioDevicePropertyDeviceUID, tap->aggregateUID, &present);
        if (status != noErr) return status;
        if (present) {
            status = AudioHardwareDestroyAggregateDevice(tap->aggregate);
            if (status != noErr && status != kAudioHardwareBadObjectError) return status;
        }
        // Core Audio documents asynchronous aggregate destruction after acceptance. No IO
        // callback remains, and this private device has no physical output path.
        tap->aggregate = kAudioObjectUnknown;
    }
    bool present = false;
    tap->operation = "destroy tap";
    if (tap->tapUID == nil) {
        // A transient UID-read failure during unmuted preparation must remain recoverable.
        // Bind only after verifying the original random description UUID, never just an ID.
        auto property = address(kAudioTapPropertyDescription);
        CFTypeRef raw = nullptr;
        UInt32 size = sizeof(raw);
        status = AudioObjectGetPropertyData(tap->tap, &property, 0, nullptr, &size, &raw);
        if (status == kAudioHardwareBadObjectError || status == kAudioHardwareUnknownPropertyError) {
            delete tap; return noErr;
        }
        if (status != noErr) return status;
        CATapDescription *description = CFBridgingRelease(raw);
        if (description == nil || ![description.UUID isEqual:tap->uuid]) { delete tap; return noErr; }
        NSString *uid = nil;
        status = stringProperty(tap->tap, kAudioTapPropertyUID, &uid);
        if (status != noErr) return status;
        tap->tapUID = uid;
    }
    status = owned(tap->tap, kAudioTapPropertyUID, tap->tapUID, &present);
    if (status != noErr) return status;
    if (present) {
        if (@available(macOS 14.2, *)) status = AudioHardwareDestroyProcessTap(tap->tap);
        if (status != noErr && status != kAudioHardwareBadObjectError) return status;
    }
    delete tap;
    return noErr;
}
