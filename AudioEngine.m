#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#import <CoreAudio/CATapDescription.h>
#import <CoreAudio/AudioHardwareTapping.h>
#include "AudioEngine.h"
#include <stdatomic.h>
#include <math.h>
#include <unistd.h>

static AudioObjectID tapID, aggregateID;
static AudioDeviceIOProcID ioProc;
static _Atomic(float) targetGain = 1.0f, inputPeak, outputPeak;
static _Atomic(uint64_t) callbackCount;
static float smoothGain = 1.0f;
static char errorText[256];

const char *audio_error(void) { return errorText; }
uint64_t audio_callbacks(void) { return atomic_load(&callbackCount); }
float audio_input_peak(void) { return atomic_load(&inputPeak); }
float audio_output_peak(void) { return atomic_load(&outputPeak); }
void audio_set_level(float level) { atomic_store(&targetGain, fminf(1, fmaxf(0, level))); }

static bool check(OSStatus status, const char *operation) {
    if (status == noErr) return true;
    snprintf(errorText, sizeof(errorText), "%s: %d (0x%08x)", operation, status, status);
    return false;
}

static bool get(AudioObjectID object, AudioObjectPropertySelector selector,
                AudioObjectPropertyScope scope, void *value, UInt32 size) {
    AudioObjectPropertyAddress address = {selector, scope, kAudioObjectPropertyElementMain};
    return check(AudioObjectGetPropertyData(object, &address, 0, NULL, &size, value), "Read audio property");
}

// No allocations, locks, logging or Objective-C calls in the real-time callback.
// The tap and physical output share the same aggregate clock. Both are stereo Float32.
static OSStatus render(AudioObjectID device, const AudioTimeStamp *now,
    const AudioBufferList *input, const AudioTimeStamp *inTime,
    AudioBufferList *output, const AudioTimeStamp *outTime, void *context) {
    (void)device; (void)now; (void)inTime; (void)outTime; (void)context;
    float inMax = 0, outMax = 0;
    float goal = atomic_load_explicit(&targetGain, memory_order_relaxed);
    float *src[2] = {NULL, NULL}, *dst[2] = {NULL, NULL};
    UInt32 inStride[2] = {0}, outStride[2] = {0};
    UInt32 frames = UINT32_MAX, channels = 0;
    for (UInt32 b = 0; b < input->mNumberBuffers && channels < 2; b++) {
        const AudioBuffer *buffer = &input->mBuffers[b];
        if (!buffer->mData || !buffer->mNumberChannels) continue;
        UInt32 n = buffer->mDataByteSize / (sizeof(float) * buffer->mNumberChannels);
        frames = MIN(frames, n);
        for (UInt32 c = 0; c < buffer->mNumberChannels && channels < 2; c++, channels++) {
            src[channels] = (float *)buffer->mData + c;
            inStride[channels] = buffer->mNumberChannels;
        }
    }
    channels = 0;
    for (UInt32 b = 0; b < output->mNumberBuffers; b++) {
        AudioBuffer *buffer = &output->mBuffers[b];
        if (!buffer->mData || !buffer->mNumberChannels) continue;
        memset(buffer->mData, 0, buffer->mDataByteSize);
        UInt32 n = buffer->mDataByteSize / (sizeof(float) * buffer->mNumberChannels);
        frames = MIN(frames, n);
        for (UInt32 c = 0; c < buffer->mNumberChannels && channels < 2; c++, channels++) {
            dst[channels] = (float *)buffer->mData + c;
            outStride[channels] = buffer->mNumberChannels;
        }
    }
    if (src[0] && src[1] && dst[0] && dst[1] && frames != UINT32_MAX) {
        for (UInt32 frame = 0; frame < frames; frame++) {
            // Ramp changes to avoid clicks. Exact zero for mute after ramp-down.
            smoothGain += fminf(0.004f, fmaxf(-0.004f, goal - smoothGain));
            for (int c = 0; c < 2; c++) {
                float sample = src[c][frame * inStride[c]];
                float scaled = sample * smoothGain;
                dst[c][frame * outStride[c]] = scaled;
                inMax = fmaxf(inMax, fabsf(sample)); outMax = fmaxf(outMax, fabsf(scaled));
            }
        }
    }
    atomic_store_explicit(&inputPeak, inMax, memory_order_relaxed);
    atomic_store_explicit(&outputPeak, outMax, memory_order_relaxed);
    atomic_fetch_add_explicit(&callbackCount, 1, memory_order_relaxed);
    return noErr;
}

void audio_stop(void) {
    if (ioProc) {
        AudioDeviceStop(aggregateID, ioProc);
        AudioDeviceDestroyIOProcID(aggregateID, ioProc);
        ioProc = NULL;
    }
    if (aggregateID) { AudioHardwareDestroyAggregateDevice(aggregateID); aggregateID = 0; }
    if (tapID) { AudioHardwareDestroyProcessTap(tapID); tapID = 0; }
}

bool audio_start(uint32_t outputDevice) {
    audio_stop(); errorText[0] = 0;
    CFStringRef uid = NULL;
    if (!get(outputDevice, kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal, &uid, sizeof(uid))) return false;
    NSString *deviceUID = CFBridgingRelease(uid);
    // Exclude our own output to prevent a feedback loop.
    pid_t pid = getpid(); AudioObjectID process = 0; UInt32 size = sizeof(process);
    AudioObjectPropertyAddress address = {kAudioHardwarePropertyTranslatePIDToProcessObject,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    if (!check(AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, sizeof(pid), &pid, &size, &process), "Resolve own audio process") || !process) return false;
    CATapDescription *description = [[CATapDescription alloc] initExcludingProcesses:@[@(process)] andDeviceUID:deviceUID withStream:0];
    description.name = @"MonitorKeys volume";
    description.privateTap = YES;
    description.muteBehavior = CATapMutedWhenTapped;
    if (!check(AudioHardwareCreateProcessTap(description, &tapID), "Create audio tap")) goto failure;
    AudioStreamBasicDescription tapFormat = {0}, outFormat = {0};
    if (!get(tapID, kAudioTapPropertyFormat, kAudioObjectPropertyScopeGlobal, &tapFormat, sizeof(tapFormat)) ||
        !get(outputDevice, kAudioDevicePropertyStreamFormat, kAudioObjectPropertyScopeOutput, &outFormat, sizeof(outFormat))) goto failure;
    if (tapFormat.mFormatID != kAudioFormatLinearPCM || outFormat.mFormatID != kAudioFormatLinearPCM ||
        !(tapFormat.mFormatFlags & kAudioFormatFlagIsFloat) || !(outFormat.mFormatFlags & kAudioFormatFlagIsFloat) ||
        tapFormat.mBitsPerChannel != 32 || outFormat.mBitsPerChannel != 32 ||
        tapFormat.mChannelsPerFrame != 2 || outFormat.mChannelsPerFrame != 2 ||
        tapFormat.mSampleRate != outFormat.mSampleRate) {
        snprintf(errorText, sizeof(errorText), "This minimal helper requires matching stereo Float32 formats.");
        goto failure;
    }
    {
        NSDictionary *config = @{
            @kAudioAggregateDeviceNameKey: @"MonitorKeys (private)",
            @kAudioAggregateDeviceUIDKey: NSUUID.UUID.UUIDString,
            @kAudioAggregateDeviceIsPrivateKey: @YES,
            @kAudioAggregateDeviceIsStackedKey: @NO,
            @kAudioAggregateDeviceMainSubDeviceKey: deviceUID,
            @kAudioAggregateDeviceSubDeviceListKey: @[@{@kAudioSubDeviceUIDKey: deviceUID}],
            @kAudioAggregateDeviceTapListKey: @[@{@kAudioSubTapUIDKey: description.UUID.UUIDString,
                                                @kAudioSubTapDriftCompensationKey: @YES}],
            @kAudioAggregateDeviceTapAutoStartKey: @YES
        };
        if (!check(AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)config, &aggregateID), "Create private aggregate")) goto failure;
    }
    smoothGain = atomic_load(&targetGain);
    atomic_store(&callbackCount, 0);
    if (!check(AudioDeviceCreateIOProcID(aggregateID, render, NULL, &ioProc), "Create audio callback")) goto failure;
    if (!check(AudioDeviceStart(aggregateID, ioProc), "Start audio (check system audio permission)")) goto failure;
    return true;
failure:
    audio_stop(); return false;
}

bool audio_self_test(void) {
    float in[] = {0.5f, -0.5f, 0.25f, -0.25f}, out[4] = {0};
    AudioBufferList source = {1, {{2, sizeof(in), in}}};
    AudioBufferList dest = {1, {{2, sizeof(out), out}}};
    smoothGain = 0.5f; audio_set_level(0.5f);
    render(0, NULL, &source, NULL, &dest, NULL, NULL);
    bool ok = out[0] == 0.25f && out[1] == -0.25f && out[2] == 0.125f;
    smoothGain = 0; audio_set_level(0);
    render(0, NULL, &source, NULL, &dest, NULL, NULL);
    ok = ok && out[0] == 0 && out[1] == 0;
    audio_set_level(1); smoothGain = 1;
    return ok;
}
