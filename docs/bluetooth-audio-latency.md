# macOS Bluetooth microphone startup latency

## Question and conclusion

Before this change, Koe started the selected microphone only after a recording
gesture had been recognized. With a Bluetooth headset, this put the transition
into its bidirectional speech mode on the user's critical path.

There is no documented, application-level macOS API that asks a Bluetooth
headset to "fast start" or prewarms its speech profile. A continuously running
input stream is the only public-API technique that can guarantee warm hardware,
but that does not match the target behavior: the microphone privacy indicator
must remain off while Koe is idle and appear as soon as the trigger is pressed.

The selected design therefore removes application work from the critical path
without continuously using the microphone: create and configure an inactive
`AudioQueue` after permission is granted, call `AudioQueueStart` on the initial
trigger-down (before tap/hold classification), and retain a bounded PCM pre-roll
until the gesture is confirmed. This cannot make an inherently slow Bluetooth
profile transition disappear, but it starts that transition at the earliest
available user signal and removes Koe's previous 180 ms decision delay plus
queue construction/allocation from the activation path.

Apple does not document WeChat Input's implementation. The explanation that it
keeps an input stream active, keeps one active for a grace period, or begins
activation earlier in the gesture is an **inference**, not a verified fact.

## What the platform documentation establishes

### Bluetooth changes mode when an app uses the headset microphone

Apple describes two Bluetooth headphone modes on macOS: one for higher-quality
listening, and one for simultaneous microphone input and listening. Opening an
app that uses the headset microphone switches to the second mode, and audio
quality remains reduced until the microphone is no longer in use. Apple does
not state a duration for this transition. This mode switch is consistent with
the observed cold-start delay, but attributing the full measured delay to it
would require instrumentation. See [Apple Support: If sound quality is reduced
when using Bluetooth headphones with your Mac](https://support.apple.com/en-us/102217).
The Bluetooth SIG defines headset voice connections in the [Hands-Free Profile
specification](https://www.bluetooth.com/specifications/specs/hands-free-profile-1-7-2/).

### Starting, stopping, and disposing an Audio Queue have hardware consequences

An Audio Queue connects to audio hardware and manages recording. Apple's SDK
contract for `AudioQueueStart` says it starts the audio hardware when the
hardware is not already running. Conversely, `AudioQueueStop` resets the queue
and stops its associated audio hardware if no other audio service is using it.
`AudioQueueDispose` releases the queue and its resources, including buffers.
See [Audio Queue Services](https://developer.apple.com/documentation/audiotoolbox/audio-queue-services),
[`AudioQueueStop`](https://developer.apple.com/documentation/audiotoolbox/audioqueuestop%28_%3A_%3A%29),
and [`AudioQueueDispose`](https://developer.apple.com/documentation/audiotoolbox/audioqueuedispose%28_%3A_%3A%29).

`AudioQueuePause` preserves queue buffers and can be resumed with
`AudioQueueStart`, but Apple's contract does not promise that pause keeps the
Bluetooth transport or hardware active. It must therefore be measured rather
than treated as a guaranteed Bluetooth warm state. By comparison,
`AVAudioEngine.pause()` explicitly stops the engine's audio hardware while
retaining prepared resources. See [`AVAudioEngine.pause()`](https://developer.apple.com/documentation/avfaudio/avaudioengine/pause%28%29).

### Preparing an engine is not the same as starting the hardware

If Koe later returns to `AVAudioEngine`, `prepare()` preallocates many resources
so that startup is more responsive, while `start()` is the operation that starts
the input/output audio hardware. Preparation can remove allocation and graph
setup from the hot path, but it does not by itself establish a warm Bluetooth
speech link. See [`AVAudioEngine.prepare()`](https://developer.apple.com/documentation/avfaudio/avaudioengine/prepare%28%29)
and [`AVAudioEngine.start()`](https://developer.apple.com/documentation/avfaudio/avaudioengine/start%28%29).

Apple exposes a `Prewarm` start/stop flag in AudioDriverKit specifically to let
a capable *driver* minimize hardware start/stop time before normal I/O. The
device must report that it supports prewarming. This is driver-facing API, not
an application-level Core Audio or AVFoundation switch available to Koe. See
[`IOUserAudioStartStopFlags::Prewarm`](https://developer.apple.com/documentation/audiodriverkit/audiodriverkit/iouseraudiostartstopflags/prewarm)
and [`GetSupportsPrewarming`](https://developer.apple.com/documentation/audiodriverkit/iouseraudioclockdevice/getsupportsprewarming).

### Privacy and energy are part of the design

macOS displays an orange privacy indicator when the microphone is in use and
Control Center identifies the app using it. A continuously running input queue
will therefore be visible to the user as ongoing microphone use. See [Apple's
Mac User Guide: Control access to the microphone on Mac](https://support.apple.com/guide/mac-help/control-access-to-the-microphone-on-mac-mchla1b1e1fe/mac)
and [Requesting authorization for media capture on macOS](https://developer.apple.com/documentation/bundleresources/requesting-authorization-for-media-capture-on-macos).

Apple also presents automatic audio-hardware shutdown as an energy-saving
feature: when an engine has been idle, shutdown can stop the hardware, and the
next rendering request starts it again. Keeping input running deliberately
trades energy for response time. See [`AVAudioEngine.isAutoShutdownEnabled`](https://developer.apple.com/documentation/avfaudio/avaudioengine/isautoshutdownenabled)
and [WWDC22: What's new in AVFAudio](https://developer.apple.com/videos/play/wwdc2022/10083/?time=841).

## How this applies to Koe

The implementation before this change had two distinct sources of latency:

1. **Hardware cold start.** Every session creates a new `AudioQueue`, selects
   the device, allocates buffers, and calls `AudioQueueStart` in
   [`SPAudioCaptureManager.m`](../KoeApp/Koe/Audio/SPAudioCaptureManager.m).
   On stop it immediately calls `AudioQueueStop(..., true)` and
   `AudioQueueDispose(..., true)`, explicitly returning the hardware and queue
   to a cold state.
2. **Application batching.** Queue buffers represent 50 ms, but Koe accumulates
   four of them and forwards 200 ms PCM chunks to Rust. Even after hardware is
   producing samples, the first ASR frame cannot be sent until that accumulator
   fills. This is separate from Bluetooth activation and should be reported as
   a separate metric.

The hotkey state machine adds an opportunity for partial latency hiding. Hold
mode does not call the recording delegate until its 180 ms hold timer fires;
toggle mode starts on key release. Starting hardware on the initial trigger-down
event could move some cold-start work earlier, but cannot guarantee an instant
first capture if the Bluetooth transition is longer than the gesture. See
[`SPHotkeyMonitor.m`](../KoeApp/Koe/Hotkey/SPHotkeyMonitor.m).

The current design also intentionally recreates capture state to recover from a
Bluetooth disconnect/reconnect. A persistent warm queue must retain that
recovery behavior: on explicit-device removal, default-input changes, or queue
failure, dispose the stale queue, resolve the current device UID again, and
rebuild it. Core Audio exposes Bluetooth as a device transport type, so this
behavior can be scoped to Bluetooth devices. See
[`kAudioDevicePropertyTransportType`](https://developer.apple.com/documentation/coreaudio/kaudiodevicepropertytransporttype),
[`kAudioDeviceTransportTypeBluetooth`](https://developer.apple.com/documentation/coreaudio/kaudiodevicetransporttypebluetooth),
and [`AudioObjectAddPropertyListener`](https://developer.apple.com/documentation/coreaudio/audioobjectaddpropertylistener%28_%3A_%3A_%3A_%3A%29).

## Implementation direction

### 1. Measure the actual timeline first

Log monotonic timestamps for:

- initial trigger down;
- recording-mode decision;
- return from `AudioQueueNewInput`;
- return from `AudioQueueStart`;
- `kAudioQueueProperty_IsRunning` changing to running;
- first queue callback with packets;
- first 200 ms frame forwarded to Rust.

Run cold and warm trials for the built-in microphone and at least two Bluetooth
headsets. `kAudioQueueProperty_IsRunning` is preferable to treating the return
from `AudioQueueStart` as proof that samples are already flowing, because Apple
documents it as reflecting when the audio device starts or stops, which is not
necessarily when the start/stop function was called. See
[`AudioQueuePropertyID`](https://developer.apple.com/documentation/audiotoolbox/audioqueuepropertyid).

This separates Bluetooth/hardware activation from Koe's 200 ms batching and
from ASR connection time. No fixed "0.5 seconds" should be encoded as a platform
guarantee.

### 2. Start a prepared queue on trigger-down

For the privacy-indicator behavior described above:

- Prepare the queue after microphone authorization, but do not start it.
- Notify the capture manager on the initial trigger-down, before the 180 ms
  hold decision or toggle key-up, and call `AudioQueueStart` immediately.
- Buffer at most 300 ms of PCM in memory while the gesture is pending.
- When the gesture is confirmed, deliver pre-roll before live PCM so the first
  word is not truncated.
- When the gesture is rejected, or recording ends, stop hardware immediately
  and prepare a fresh inactive queue for the next trigger.
- On input-device selection or loss, discard the prepared queue and rebuild it
  against the newly resolved device.

This design keeps the orange privacy indicator off at idle and moves its onset
to trigger-down. Actual first-sample latency must still be measured on real
Bluetooth headsets.

### 3. Alternative: keep the input queue running

Refactor `SPAudioCaptureManager` so hardware lifetime and recording lifetime are
different states:

- **Warm hardware:** create, configure, allocate, enqueue, and start one input
  queue after microphone permission is already granted.
- **Idle:** callbacks immediately re-enqueue their buffers and discard bytes;
  do not convert or retain idle PCM.
- **Recording armed:** atomically install the frame consumer, clear the session
  accumulator, and begin conversion/accumulation on the already-running queue.
- **Recording stopped:** flush only the armed session's remainder, clear the
  consumer, and return to discarding callbacks without stopping the queue.
- **Device change/termination:** stop and dispose the queue, resolve the device
  again, and rebuild when appropriate.

Do not silently capture an idle rolling buffer. Immediate discard makes the
privacy boundary simpler: the hardware is still in use (and macOS will show
that), but Koe does not retain or process idle audio. A pre-roll ring buffer can
protect speech that begins fractionally before the armed flag changes, but that
is a separate privacy-sensitive feature requiring an explicit decision.

Because always-warm input changes headset playback quality and privacy UI, gate
it behind a clearly explained opt-in setting, preferably only when the resolved
input transport is Bluetooth. If enabled, warm only after permission is granted,
and tear down on app termination, selected-device loss, or user disablement.

### 4. Other fallbacks

If continuous microphone use is unacceptable, two fallbacks are reasonable:

- **Grace period:** keep the queue running for a measured period after each
  dictation, then stop and dispose it. This makes follow-up dictation fast, but
  cannot improve the first dictation after idle.
- **Gesture prewarm without queue preparation:** start I/O on trigger-down but
  leave queue construction on that path. This is simpler but retains avoidable
  application latency.

`AudioQueuePause` is worth benchmarking as an implementation experiment, but the
public contract is insufficient to promise that it preserves a warm Bluetooth
route. The acceptance test must be time to the first nonempty callback on real
headsets, not merely a successful return code.

## Likely polished-app technique (inference)

There is no public evidence establishing what WeChat Input does. Based on the
documented lifecycle above, the plausible public-API explanations are:

1. it keeps microphone I/O running while its voice-input feature is available
   and gates consumption of buffers;
2. it keeps I/O running for a grace period between dictations; or
3. it starts I/O on an earlier interaction signal than the visible recording
   state.

Only the first option can reliably remove a cold Bluetooth mode transition from
an otherwise unpredictable hotkey press. A private Bluetooth API is not needed
to explain the observed behavior, and no supported application-level fast-start
API was found in the Apple documentation or SDK headers reviewed for this note.

## Acceptance criteria

- On a Bluetooth input, time from trigger-down to privacy-indicator onset and
  first nonempty queue callback is measured against the previous cold baseline.
- Built-in and USB inputs do not regress.
- The microphone is not running while idle; pending-gesture PCM is bounded to
  300 ms and reaches Rust only after a session is confirmed.
- A device disconnect/reconnect rebuilds the queue without retaining a stale
  `AudioDeviceID`.
- Permission denial and first permission grant remain safe; warming never occurs
  before authorization.
- A rejected trigger and normal session end both turn the privacy indicator off.
- Metrics distinguish hardware startup, first callback, 200 ms frame batching,
  ASR connection, and first recognition result.
