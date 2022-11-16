/*
 *  Copyright 2016 The WebRTC Project Authors. All rights reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#import "voice_processing_audio_unit.h"

#include "rtc_base/checks.h"
#include "system_wrappers/include/metrics.h"

#import "base/RTCLogging.h"
#import "sdk/objc/components/audio/RTCAudioSession.h"
#import "sdk/objc/components/audio/RTCAudioSessionConfiguration.h"


#if !defined(NDEBUG)
static void LogStreamDescription(AudioStreamBasicDescription description) {
  char formatIdString[5];
  UInt32 formatId = CFSwapInt32HostToBig(description.mFormatID);
  bcopy(&formatId, formatIdString, 4);
  formatIdString[4] = '\0';
  RTCLog(@"AudioStreamBasicDescription: {\n"
          "  mSampleRate: %.2f\n"
          "  formatIDString: %s\n"
          "  mFormatFlags: 0x%X\n"
          "  mBytesPerPacket: %u\n"
          "  mFramesPerPacket: %u\n"
          "  mBytesPerFrame: %u\n"
          "  mChannelsPerFrame: %u\n"
          "  mBitsPerChannel: %u\n"
          "  mReserved: %u\n}",
         description.mSampleRate, formatIdString,
         static_cast<unsigned int>(description.mFormatFlags),
         static_cast<unsigned int>(description.mBytesPerPacket),
         static_cast<unsigned int>(description.mFramesPerPacket),
         static_cast<unsigned int>(description.mBytesPerFrame),
         static_cast<unsigned int>(description.mChannelsPerFrame),
         static_cast<unsigned int>(description.mBitsPerChannel),
         static_cast<unsigned int>(description.mReserved));
}
#endif

namespace webrtc {
namespace ios_adm {

// Calls to AudioUnitInitialize() can fail if called back-to-back on different
// ADM instances. A fall-back solution is to allow multiple sequential calls
// with as small delay between each. This factor sets the max number of allowed
// initialization attempts.
static const int kMaxNumberOfAudioUnitInitializeAttempts = 5;
// A VP I/O unit's bus 1 connects to input hardware (microphone).
static const AudioUnitElement kInputBus = 1;
// A VP I/O unit's bus 0 connects to output hardware (speaker).
static const AudioUnitElement kOutputBus = 0;

// Returns the automatic gain control (AGC) state on the processed microphone
// signal. Should be on by default for Voice Processing audio units.
static OSStatus GetAGCState(AudioUnit audio_unit, UInt32* enabled) {
  RTC_DCHECK(audio_unit);
  UInt32 size = sizeof(*enabled);
  OSStatus result = AudioUnitGetProperty(audio_unit,
                                         kAUVoiceIOProperty_VoiceProcessingEnableAGC,
                                         kAudioUnitScope_Global,
                                         kInputBus,
                                         enabled,
                                         &size);
  RTCLog(@"VPIO unit AGC: %u", static_cast<unsigned int>(*enabled));
  return result;
}

static volatile int MicOwning = false;

VoiceProcessingAudioUnit::VoiceProcessingAudioUnit(bool bypass_voice_processing,
                                                   VoiceProcessingAudioUnitObserver* observer)
    : bypass_voice_processing_(bypass_voice_processing),
      observer_(observer),
      vpio_unit_(nullptr),
      state_(kUninitialized),
      sample_rate_(),
      playout_enabled_(false),
      recording_enabled_(false){
  RTC_DCHECK(observer);
}

VoiceProcessingAudioUnit::~VoiceProcessingAudioUnit() {
  DisposeAudioUnit();
}

const UInt32 VoiceProcessingAudioUnit::kBytesPerSample = 2;

bool VoiceProcessingAudioUnit::CanRecord() const {
  RTC_OBJC_TYPE(RTCAudioSession) *session = [RTC_OBJC_TYPE(RTCAudioSession) sharedInstance];
  return
    [session.category isEqualToString: AVAudioSessionCategoryPlayAndRecord] &&
    !rtc::AtomicOps::AcquireLoad(&MicOwning);
}

void VoiceProcessingAudioUnit::InitializeSampleRate(Float64 sample_rate)
{
  RTC_DCHECK_GE(state_, kUninitialized);
  RTCLog(@"Initializing audio unit sample rate: %f", sample_rate);

  sample_rate_ = sample_rate;
}

bool VoiceProcessingAudioUnit::Initialize(Float64 sample_rate, bool enable_playout, bool enable_recording)
{
  RTC_DCHECK_GE(state_, kUninitialized);
  RTC_DCHECK(!vpio_unit_);
  RTC_DCHECK(enable_playout || enable_recording);
  RTCLog(@"Initializing audio unit with sample rate: %f", sample_rate_);

  if (!enable_recording && !enable_playout) {
    RTCLogError(@"It's not possible to create not playing nor recording audio unit");
    return false;
  }

  sample_rate_ = sample_rate;
  playout_enabled_ = enable_playout;
  recording_enabled_ = enable_recording;

  RTC_OBJC_TYPE(RTCAudioSession) *session = [RTC_OBJC_TYPE(RTCAudioSession) sharedInstance];
  if (enable_recording && ![session.category isEqualToString: AVAudioSessionCategoryPlayAndRecord]) {
    RTCLogError(@"Trying to record without PlayAndRecord AVAudioSession category enabled");
    return false;
  }
  if (enable_recording && rtc::AtomicOps::CompareAndSwap(&MicOwning, false, true)) {
    RTCLogError(@"Trying to acquire mic second time");
    return false;
  }

  // Playout should be always enabled.
  // * For recording: to avoid glitches in mic input on playback enable/disable
  // * For playback: you creating it for playback, or why you creating it at all?
  enable_playout = true; // playout always enabled

  bool auCreated;

  if(enable_recording) {
    auCreated = CreateVoiceProcessingAU();
  } else {
    auCreated = CreatePlaybackAU();
  }

  if(!auCreated) {
    if(enable_recording)
      rtc::AtomicOps::ReleaseStore(&MicOwning, false);
    return false;
  }

  OSStatus result = noErr;

  if(enable_recording) {
    // Enable input on the input scope of the input element.
    UInt32 enable_input = enable_recording ? 1 : 0;
    result = AudioUnitSetProperty(vpio_unit_, kAudioOutputUnitProperty_EnableIO,
                                  kAudioUnitScope_Input, kInputBus, &enable_input,
                                  sizeof(enable_input));
    if (result != noErr) {
      DisposeAudioUnit();
      RTCLogError(@"Failed to enable input on input scope of input element. "
                   "Error=%ld.",
                  (long)result);
      return false;
    }
  }

  // Enable output on the output scope of the output element.
  UInt32 enable_output = enable_playout ? 1 : 0;
  result = AudioUnitSetProperty(vpio_unit_, kAudioOutputUnitProperty_EnableIO,
                                kAudioUnitScope_Output, kOutputBus,
                                &enable_output, sizeof(enable_output));
  if (result != noErr) {
    DisposeAudioUnit();
    RTCLogError(@"Failed to enable output on output scope of output element. "
                 "Error=%ld.",
                (long)result);
    return false;
  }

  // Specify the callback function that provides audio samples to the audio
  // unit.
  AURenderCallbackStruct render_callback;
  render_callback.inputProc = OnGetPlayoutData;
  render_callback.inputProcRefCon = this;
  result = AudioUnitSetProperty(
      vpio_unit_, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input,
      kOutputBus, &render_callback, sizeof(render_callback));
  if (result != noErr) {
    DisposeAudioUnit();
    RTCLogError(@"Failed to specify the render callback on the output bus. "
                 "Error=%ld.",
                (long)result);
    return false;
  }

  if(enable_recording) {
    // Disable AU buffer allocation for the recorder, we allocate our own.
    // TODO(henrika): not sure that it actually saves resource to make this call.
    UInt32 flag = 0;
    result = AudioUnitSetProperty(
        vpio_unit_, kAudioUnitProperty_ShouldAllocateBuffer,
        kAudioUnitScope_Output, kInputBus, &flag, sizeof(flag));
    if (result != noErr) {
      DisposeAudioUnit();
      RTCLogError(@"Failed to disable buffer allocation on the input bus. "
                   "Error=%ld.",
                  (long)result);
      return false;
    }

    // Specify the callback to be called by the I/O thread to us when input audio
    // is available. The recorded samples can then be obtained by calling the
    // AudioUnitRender() method.
    AURenderCallbackStruct input_callback;
    input_callback.inputProc = OnDeliverRecordedData;
    input_callback.inputProcRefCon = this;
    result = AudioUnitSetProperty(vpio_unit_,
                                  kAudioOutputUnitProperty_SetInputCallback,
                                  kAudioUnitScope_Global, kInputBus,
                                  &input_callback, sizeof(input_callback));
    if (result != noErr) {
      DisposeAudioUnit();
      RTCLogError(@"Failed to specify the input callback on the input bus. "
                   "Error=%ld.",
                  (long)result);
      return false;
    }
  }

  AudioStreamBasicDescription format = GetFormat(sample_rate_);
  UInt32 size = sizeof(format);
#if !defined(NDEBUG)
  LogStreamDescription(format);
#endif

  if(enable_recording) {
    // Set the format on the output scope of the input element/bus.
    result =
        AudioUnitSetProperty(vpio_unit_, kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Output, kInputBus, &format, size);
    if (result != noErr) {
      DisposeAudioUnit();
      RTCLogError(@"Failed to set format on output scope of input bus. "
                   "Error=%ld.",
                  (long)result);
      return false;
    }
  }

  // Set the format on the input scope of the output element/bus.
  result =
      AudioUnitSetProperty(vpio_unit_, kAudioUnitProperty_StreamFormat,
                           kAudioUnitScope_Input, kOutputBus, &format, size);
  if (result != noErr) {
    DisposeAudioUnit();
    RTCLogError(@"Failed to set format on input scope of output bus. "
                 "Error=%ld.",
                (long)result);
    return false;
  }

  // Initialize the audio unit instance.
  // Calls to AudioUnitInitialize() can fail if called back-to-back on
  // different ADM instances. The error message in this case is -66635 which is
  // undocumented. Tests have shown that calling AudioUnitInitialize a second
  // time, after a short sleep, avoids this issue.
  // See webrtc:5166 for details.
  int failed_initalize_attempts = 0;
  result = AudioUnitInitialize(vpio_unit_);
  while (result != noErr) {
    RTCLogError(@"Failed to initialize the audio unit. "
                 "Error=%ld.",
                (long)result);
    ++failed_initalize_attempts;
    if (failed_initalize_attempts == kMaxNumberOfAudioUnitInitializeAttempts) {
      DisposeAudioUnit();
      // Max number of initialization attempts exceeded, hence abort.
      RTCLogError(@"Too many initialization attempts.");
      return false;
    }
    RTCLog(@"Pause 100ms and try audio unit initialization again...");
    [NSThread sleepForTimeInterval:0.1f];
    result = AudioUnitInitialize(vpio_unit_);
  }
  if (result == noErr) {
    RTCLog(@"Audio unit is now initialized.");
  }

  if (bypass_voice_processing_ && enable_recording) {
    // Attempt to disable builtin voice processing.
    UInt32 toggle = 1;
    result = AudioUnitSetProperty(vpio_unit_,
                                  kAUVoiceIOProperty_BypassVoiceProcessing,
                                  kAudioUnitScope_Global,
                                  kInputBus,
                                  &toggle,
                                  sizeof(toggle));
    if (result == noErr) {
      RTCLog(@"Successfully bypassed voice processing.");
    } else {
      RTCLogError(@"Failed to bypass voice processing. Error=%ld.", (long)result);
    }
    state_ = kInitialized;
    return true;
  }

  state_ = kInitialized;

  if(!enable_recording) {
    return true;
  }

  // AGC should be enabled by default for Voice Processing I/O units but it is
  // checked below and enabled explicitly if needed. This scheme is used
  // to be absolutely sure that the AGC is enabled since we have seen cases
  // where only zeros are recorded and a disabled AGC could be one of the
  // reasons why it happens.
  int agc_was_enabled_by_default = 0;
  UInt32 agc_is_enabled = 0;
  result = GetAGCState(vpio_unit_, &agc_is_enabled);
  if (result != noErr) {
    RTCLogError(@"Failed to get AGC state (1st attempt). "
                 "Error=%ld.",
                (long)result);
    // Example of error code: kAudioUnitErr_NoConnection (-10876).
    // All error codes related to audio units are negative and are therefore
    // converted into a postive value to match the UMA APIs.
    RTC_HISTOGRAM_COUNTS_SPARSE_100000(
        "WebRTC.Audio.GetAGCStateErrorCode1", (-1) * result);
  } else if (agc_is_enabled) {
    // Remember that the AGC was enabled by default. Will be used in UMA.
    agc_was_enabled_by_default = 1;
  } else {
    // AGC was initially disabled => try to enable it explicitly.
    UInt32 enable_agc = 1;
    result =
        AudioUnitSetProperty(vpio_unit_,
                             kAUVoiceIOProperty_VoiceProcessingEnableAGC,
                             kAudioUnitScope_Global, kInputBus, &enable_agc,
                             sizeof(enable_agc));
    if (result != noErr) {
      RTCLogError(@"Failed to enable the built-in AGC. "
                   "Error=%ld.",
                  (long)result);
      RTC_HISTOGRAM_COUNTS_SPARSE_100000(
          "WebRTC.Audio.SetAGCStateErrorCode", (-1) * result);
    }
    result = GetAGCState(vpio_unit_, &agc_is_enabled);
    if (result != noErr) {
      RTCLogError(@"Failed to get AGC state (2nd attempt). "
                   "Error=%ld.",
                  (long)result);
      RTC_HISTOGRAM_COUNTS_SPARSE_100000(
          "WebRTC.Audio.GetAGCStateErrorCode2", (-1) * result);
    }
  }

  // Track if the built-in AGC was enabled by default (as it should) or not.
  RTC_HISTOGRAM_BOOLEAN("WebRTC.Audio.BuiltInAGCWasEnabledByDefault",
                        agc_was_enabled_by_default);
  RTCLog(@"WebRTC.Audio.BuiltInAGCWasEnabledByDefault: %d",
         agc_was_enabled_by_default);
  // As a final step, add an UMA histogram for tracking the AGC state.
  // At this stage, the AGC should be enabled, and if it is not, more work is
  // needed to find out the root cause.
  RTC_HISTOGRAM_BOOLEAN("WebRTC.Audio.BuiltInAGCIsEnabled", agc_is_enabled);
  RTCLog(@"WebRTC.Audio.BuiltInAGCIsEnabled: %u",
         static_cast<unsigned int>(agc_is_enabled));

  return true;
}

bool VoiceProcessingAudioUnit::CreatePlaybackAU() {
  RTC_DCHECK_EQ(state_, kUninitialized);
  RTC_DCHECK(!vpio_unit_);

  RTCLog(@"Creating Playback audio unit...");

  // Create an audio component description to identify the Playback
  // I/O audio unit.
  AudioComponentDescription vpio_unit_description;
  vpio_unit_description.componentType = kAudioUnitType_Output;
  vpio_unit_description.componentSubType = kAudioUnitSubType_RemoteIO;
  vpio_unit_description.componentManufacturer = kAudioUnitManufacturer_Apple;
  vpio_unit_description.componentFlags = 0;
  vpio_unit_description.componentFlagsMask = 0;

  // Obtain an audio unit instance given the description.
  AudioComponent found_vpio_unit_ref =
      AudioComponentFindNext(nullptr, &vpio_unit_description);

  // Create a Playback audio unit.
  OSStatus result = noErr;
  result = AudioComponentInstanceNew(found_vpio_unit_ref, &vpio_unit_);
  if (result != noErr) {
    vpio_unit_ = nullptr;
    RTCLogError(@"AudioComponentInstanceNew failed. Error=%ld.", (long)result);
    return false;
  }

  return true;
}

bool VoiceProcessingAudioUnit::CreateVoiceProcessingAU() {
  RTC_DCHECK_EQ(state_, kUninitialized);
  RTC_DCHECK(!vpio_unit_);

  RTCLog(@"Creating Voice Processing audio unit...");

  // Create an audio component description to identify the Voice Processing
  // I/O audio unit.
  AudioComponentDescription vpio_unit_description;
  vpio_unit_description.componentType = kAudioUnitType_Output;
  vpio_unit_description.componentSubType = kAudioUnitSubType_VoiceProcessingIO;
  vpio_unit_description.componentManufacturer = kAudioUnitManufacturer_Apple;
  vpio_unit_description.componentFlags = 0;
  vpio_unit_description.componentFlagsMask = 0;

  // Obtain an audio unit instance given the description.
  AudioComponent found_vpio_unit_ref =
      AudioComponentFindNext(nullptr, &vpio_unit_description);

  // Create a Voice Processing IO audio unit.
  OSStatus result = noErr;
  result = AudioComponentInstanceNew(found_vpio_unit_ref, &vpio_unit_);
  if (result != noErr) {
    vpio_unit_ = nullptr;
    RTCLogError(@"AudioComponentInstanceNew failed. Error=%ld.", (long)result);
    return false;
  }

  return true;
}

VoiceProcessingAudioUnit::State VoiceProcessingAudioUnit::GetState() const {
  return state_;
}

bool VoiceProcessingAudioUnit::StartPlayout() {
  switch (state_) {
    case kUninitialized:
      break;
    case kInitialized:
      if(playout_enabled_ || recording_enabled_) { // already configured (recording always enables playout), just need to start
          playout_enabled_ = true;
          return Start() == noErr;
      }
      break;
    case kStarted:
      if(playout_enabled_ || recording_enabled_) { // already playing (recording always enables playout), nothing to do
          playout_enabled_ = true;
          return true;
      }
      break;
  }

  RTC_DCHECK(!vpio_unit_ && state_ == kUninitialized); // other state is just not possible here...
  DisposeAudioUnit(); // useless here, but just to be sure...

  if(!Initialize(sample_rate_, true, false)) {
      return false;
  }

  return Start() == noErr;
}

bool VoiceProcessingAudioUnit::StopPlayout() {
  if(recording_enabled_) { // playout always enabled if recording is enabled
      playout_enabled_ = false;
      return true;
  }

  switch (state_) {
    case kUninitialized:
      break;
    case kInitialized:
      [[fallthrough]];
    case kStarted:
      if(!playout_enabled_) // not playig, nothing to stop
        return true;
      break;
  }

  DisposeAudioUnit();

  return true;
}

bool VoiceProcessingAudioUnit::StartRecording() {
  if(!CanRecord()) {
    RTCLogError(@"VoiceProcessingAudioUnit is not ready to start recording");
    return false;
  }

  const bool playout_was_enabled = playout_enabled_;

  switch(state_) {
    case kUninitialized:
      break;
    case kInitialized:
      if(recording_enabled_) // already configured, just need to start
          return Start() == noErr;
      break;
    case kStarted:
      if(recording_enabled_) // already recording, nothing to do
          return true;
      break;
  }

  DisposeAudioUnit();

  if(!Initialize(sample_rate_, playout_was_enabled, true)) {
      return false;
  }

  return Start() == noErr;
}

bool VoiceProcessingAudioUnit::StopRecording() {
  const bool playout_was_enabled = playout_enabled_;
  const bool was_started = (state_ == kStarted);

  switch(state_) {
    case kUninitialized:
      return true; // nothing to stop
    case kInitialized:
      [[fallthrough]];
    case kStarted:
      if(!recording_enabled_) // not recording, nothing to stop
        return true;
      break;
  }

  DisposeAudioUnit();

  if(playout_was_enabled) {
    // if playout was active it's required to recreate audio unit to restore playout
    if(!Initialize(sample_rate_, true, false))
      return false;

    if(was_started)
      return Start() == noErr;
  }

  return true;
}

OSStatus VoiceProcessingAudioUnit::Start() {
  RTC_DCHECK_GE(state_, kUninitialized);
  RTCLog(@"Starting audio unit.");

  OSStatus result = AudioOutputUnitStart(vpio_unit_);
  if (result != noErr) {
    RTCLogError(@"Failed to start audio unit. Error=%ld", (long)result);
    return result;
  } else {
    RTCLog(@"Started audio unit");
  }
  state_ = kStarted;
  return noErr;
}

bool VoiceProcessingAudioUnit::Stop() {
  RTC_DCHECK_GE(state_, kUninitialized);
  RTCLog(@"Stopping audio unit.");

  OSStatus result = AudioOutputUnitStop(vpio_unit_);
  if (result != noErr) {
    RTCLogError(@"Failed to stop audio unit. Error=%ld", (long)result);
    return false;
  } else {
    RTCLog(@"Stopped audio unit");
  }

  state_ = kInitialized;
  return true;
}

void VoiceProcessingAudioUnit::UninitializeAudioUnit() {
  RTC_DCHECK_GE(state_, kUninitialized);
  RTCLog(@"Unintializing audio unit.");

  OSStatus result = AudioUnitUninitialize(vpio_unit_);
  if (result != noErr) {
    RTCLogError(@"Failed to uninitialize audio unit. Error=%ld", (long)result);
  } else {
    RTCLog(@"Uninitialized audio unit.");
  }

  state_ = kUninitialized;
}

void VoiceProcessingAudioUnit::Uninitialize() {
  DisposeAudioUnit();
}

OSStatus VoiceProcessingAudioUnit::Render(AudioUnitRenderActionFlags* flags,
                                          const AudioTimeStamp* time_stamp,
                                          UInt32 output_bus_number,
                                          UInt32 num_frames,
                                          AudioBufferList* io_data) {
  RTC_DCHECK(vpio_unit_) << "Init() not called.";

  OSStatus result = AudioUnitRender(vpio_unit_, flags, time_stamp,
                                    output_bus_number, num_frames, io_data);
  if (result != noErr) {
    RTCLogError(@"Failed to render audio unit. Error=%ld", (long)result);
  }
  return result;
}

OSStatus VoiceProcessingAudioUnit::OnGetPlayoutData(
    void* in_ref_con,
    AudioUnitRenderActionFlags* flags,
    const AudioTimeStamp* time_stamp,
    UInt32 bus_number,
    UInt32 num_frames,
    AudioBufferList* io_data) {
  VoiceProcessingAudioUnit* audio_unit =
      static_cast<VoiceProcessingAudioUnit*>(in_ref_con);
  return audio_unit->NotifyGetPlayoutData(flags, time_stamp, bus_number,
                                          num_frames, io_data);
}

OSStatus VoiceProcessingAudioUnit::OnDeliverRecordedData(
    void* in_ref_con,
    AudioUnitRenderActionFlags* flags,
    const AudioTimeStamp* time_stamp,
    UInt32 bus_number,
    UInt32 num_frames,
    AudioBufferList* io_data) {
  VoiceProcessingAudioUnit* audio_unit =
      static_cast<VoiceProcessingAudioUnit*>(in_ref_con);
  return audio_unit->NotifyDeliverRecordedData(flags, time_stamp, bus_number,
                                               num_frames, io_data);
}

OSStatus VoiceProcessingAudioUnit::NotifyGetPlayoutData(
    AudioUnitRenderActionFlags* flags,
    const AudioTimeStamp* time_stamp,
    UInt32 bus_number,
    UInt32 num_frames,
    AudioBufferList* io_data) {
  return observer_->OnGetPlayoutData(flags, time_stamp, bus_number, num_frames,
                                     io_data);
}

OSStatus VoiceProcessingAudioUnit::NotifyDeliverRecordedData(
    AudioUnitRenderActionFlags* flags,
    const AudioTimeStamp* time_stamp,
    UInt32 bus_number,
    UInt32 num_frames,
    AudioBufferList* io_data) {
  return observer_->OnDeliverRecordedData(flags, time_stamp, bus_number,
                                          num_frames, io_data);
}

AudioStreamBasicDescription VoiceProcessingAudioUnit::GetFormat(
    Float64 sample_rate) const {
  // Set the application formats for input and output:
  // - use same format in both directions
  // - avoid resampling in the I/O unit by using the hardware sample rate
  // - linear PCM => noncompressed audio data format with one frame per packet
  // - no need to specify interleaving since only mono is supported
  AudioStreamBasicDescription format;
  RTC_DCHECK_EQ(1, kRTCAudioSessionPreferredNumberOfChannels);
  format.mSampleRate = sample_rate;
  format.mFormatID = kAudioFormatLinearPCM;
  format.mFormatFlags =
      kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
  format.mBytesPerPacket = kBytesPerSample;
  format.mFramesPerPacket = 1;  // uncompressed.
  format.mBytesPerFrame = kBytesPerSample;
  format.mChannelsPerFrame = kRTCAudioSessionPreferredNumberOfChannels;
  format.mBitsPerChannel = 8 * kBytesPerSample;
  return format;
}

void VoiceProcessingAudioUnit::DisposeAudioUnit() {
  RTC_DCHECK((vpio_unit_ == nullptr) == (state_ == kUninitialized));

  if (vpio_unit_) {
    const bool recording_was_enabled = recording_enabled_;

    switch (state_) {
      case kStarted:
        Stop();
        [[fallthrough]];
      case kInitialized:
        UninitializeAudioUnit();
        break;
      case kUninitialized:
        break;
    }

    if(recording_was_enabled)
      RTCLog(@"Disposing Voice Processing audio unit.");
    else
      RTCLog(@"Disposing Playback audio unit.");

    OSStatus result = AudioComponentInstanceDispose(vpio_unit_);
    if (result != noErr) {
      RTCLogError(@"AudioComponentInstanceDispose failed. Error=%ld.",
                  (long)result);
    }
    vpio_unit_ = nullptr;

    playout_enabled_ = false;
    recording_enabled_ = false;

    if(recording_was_enabled)
      rtc::AtomicOps::ReleaseStore(&MicOwning, false);
  }
}

}  // namespace ios_adm
}  // namespace webrtc
