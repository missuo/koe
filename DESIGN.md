# GUI-Free macOS Voice Input Tool Design Document

## 1. Document Objective

This document defines the complete design of a voice input tool that runs on macOS as a background-first app with no persistent main window. The tool's goals are:

- The user focuses the cursor in any app's input field.
- The user holds down a designated hotkey to start speaking, and releases the hotkey to end the current input.
- The user can also tap the designated hotkey once to start speaking, and press the same hotkey again to end the current input.
- The tool streams audio in real time to a WebSocket-based streaming speech recognition model.
- After obtaining the final recognition text, the tool passes the result to a large language model for error correction.
- During correction, the user dictionary is injected, and filler words are removed according to rules.
- The final text is inserted into the current input field via the clipboard combined with a simulated paste action.

The implementation approach adopted in this document is:

- macOS shell: `Objective-C`
- Core logic: `Rust`
- Product form: windowless `Agent App`
- Configuration file: `YAML`
- User dictionary: `TXT`

This document is not a requirements sketch but an implementation design document. It covers permissions, packaging form, module decomposition, state machine, complete timing sequence, configuration format, error handling, logging, and deployment strategy.

## 2. Core Conclusions

### 2.1 It Is Possible to Have a Background-First UI

Yes. The product should be built as a macOS Agent App with no Dock icon and no always-open main window.

Recommended form:

- `LSUIElement=1`
- No main window at launch
- Menu bar status UI is part of the product
- Optional lightweight settings window opened from the menu bar
- All configuration maintained through local files under `~/.koe/`
- Floating overlay only during active sessions

From the user's perspective, this still behaves like a background utility rather than a normal docked application.

### 2.2 Not Recommended as a Bare Binary

Although the business logic can be completed in Rust, permissions, event listening, accessibility control, and system identity still require a standard macOS app bundle. Otherwise, you will encounter the following problems:

- Microphone permissions cannot be granted to your product in a stable, distributable manner
- System privacy settings have difficulty stably identifying and displaying a bare binary
- Authorization and persistence behavior for global input monitoring and accessibility control are unstable
- Launch-at-login, signing, notarization, and user trust chain all degrade

Therefore, the correct product form for this project is not "a Rust CLI," but rather:

- Outer layer: macOS Agent App written in Objective-C
- Inner layer: core logic library written in Rust

### 2.3 Language Selection Conclusion

This project does not require all code to be in Swift or Objective-C. As long as the macOS shell is a standard app bundle and can correctly call native frameworks, that is sufficient.

This design chooses:

- `Objective-C` for all native macOS capabilities
- `Rust` for all core business capabilities

Reasons:

- `Objective-C` is the most direct way to call AppKit, AVFoundation, ApplicationServices, and Accessibility API
- `Rust` is well-suited for configuration parsing, WebSocket client, state machine, streaming aggregation, LLM calls, logging, and error modeling
- The boundary between the two is clear, making it maintainable from an engineering perspective

## 3. Goals and Non-Goals

### 3.1 Goals

- Minimal visible GUI (menu bar icon, floating status overlay, and an optional settings window only when needed)
- Support hold-to-talk, release-to-end
- Support tap-to-start, tap-again-to-end
- Support streaming WebSocket speech recognition
- Support LLM secondary error correction
- Support user dictionary
- Support removal of spoken filler words
- Support pasting results directly into the current input field
- Support maintaining all behavior through text configuration files

### 3.2 Non-Goals

- No dock-based main application shell
- No recording file management interface
- No multi-turn conversational voice assistant
- No voice wake word
- No dependency on input method framework

## 4. Product Form

### 4.1 Runtime Form

The application name can tentatively be `Koe.app`, but the name does not affect the design itself.

Runtime behavior:

- The user places the `.app` in `/Applications`
- After first launch, the application runs persistently in the background
- No Dock icon is displayed
- No main window is created at launch
- The user is not required to open any interface, though a settings window is available from the menu bar when needed

### 4.2 Menu Bar UI

Instead of a CLI tool, the app provides a menu bar dropdown with:

- **Status section**: current status, version/build when idle, and the resolved trigger/cancel hotkeys
- **Statistics section**: total characters, words, recording time, session count, and input speed
- **Permissions section**: shows granted/missing status for Microphone, Accessibility, Input Monitoring, and Notifications
- **Microphone section**: a submenu listing all available audio input devices; "System Default" is always present as the first option; the currently selected device is indicated with a checkmark; selection persists across app restarts via `NSUserDefaults`
- **Utility actions**: `Setup Wizard...`, `Open Config Folder...`, `Check for Updates...`, `Launch at Login`, and `Quit Koe`

Section headers use custom `NSView` with bold labels (not selectable, not grayed out). The idle icon is a 5-bar audio waveform for easy recognition.

### 4.3 Floating Overlay

A borderless, non-activating `NSPanel` positioned at the bottom-center of the screen above the Dock. It appears across all spaces and ignores mouse events. The pill background uses an `NSVisualEffectView` with HUD material and behind-window blending for a frosted-glass appearance that adapts to the desktop. The pill shape is applied via `maskImage` with nine-part cap insets.

The overlay displays the current session state:

- **Recording**: animated waveform icon with real-time interim ASR text (falls back to "Listening…" before the first interim result arrives). The pill expands horizontally as text grows but never shrinks within a session, up to the screen width minus margins. Interim text auto-wraps to multiple lines when it exceeds the maximum width, and the layout avoids visible jitter while the transcript stabilizes.
- **Connecting / Recognizing / Thinking**: pulsing dots with a status label
- **Pasting**: animated checkmark
- **Error**: cross mark

The overlay fades in when a session begins and fades out when it completes or returns to idle.

## 5. Required Permissions

This project requires at least the following permissions.

### 5.1 Microphone Permission

Purpose:

- Record the user's spoken audio
- Send the audio stream to streaming ASR

Without this permission:

- Cannot start recording
- The entire main pipeline is unavailable

Implementation requirements:

- The app bundle must include `NSMicrophoneUsageDescription`
- Authorization status should be checked before the first recording
- When unauthorized, the Objective-C shell triggers the system authorization flow

### 5.2 Input Monitoring Permission

Purpose:

- Monitor global keyboard events while other apps are in the foreground
- Detect "hold to start, release to end" actions
- Detect "tap to start, tap again to end" actions

Without this permission:

- Cannot reliably monitor global hotkeys
- Even if the application is running in the background, it may not receive key events

Special note:

- This is a hard prerequisite for all global-hotkey-based voice input modes
- If this permission is missing, the application cannot reliably detect whether the user pressed or released the hotkey

### 5.3 Accessibility Permission

Purpose:

- Check whether the currently focused control is a text input control
- Determine whether the current input control is a secure text field
- After correction is complete, simulate sending `Cmd+V` to the foreground app

Without this permission:

- Recognition and correction can still be performed
- But text cannot be reliably auto-pasted into other apps' input fields
- Falls back to "write result to clipboard without auto-pasting"

### 5.4 Permissions Not Required

Typically not needed:

- Camera permission
- Screen recording permission
- Contacts permission
- Calendar permission

Network access does not require additional TCC-style privacy authorization, but the application obviously needs to be able to access the network.

## 6. Permission and Distribution Strategy

### 6.1 Must Be a Standard App Bundle

The application must have:

- `Info.plist`
- A stable bundle identifier
- A signable executable
- An app identity recognizable by system privacy settings

### 6.2 Recommended Signing and Distribution Method

Recommended:

- Sign with `Developer ID Application`
- Enable `Hardened Runtime`
- Perform notarization
- Distribute through official website or own channels

### 6.3 App Sandbox Strategy

Recommended:

- Do not enable App Sandbox

Reasons:

- This tool needs to monitor global input
- This tool needs to control input behavior of other apps
- This tool depends on Accessibility and Input Monitoring

The product form of such tools is closer to window managers, hotkey tools, and automation tools, rather than a strictly sandboxed content app.

## 7. Design Considerations for `Fn` as a Dual-Mode Input Key

### 7.1 Target Behavior

A single `Fn` key needs to support two interaction semantics simultaneously.

The first semantic is "hold to talk":

- Start the current recording session
- Begin sending audio to streaming recognition

When the user releases `Fn`:

- End the current recording session
- End streaming recognition input
- Wait for the final recognition result
- Enter LLM correction
- Auto-paste the final text

The second semantic is "tap to toggle":

- The user quickly taps `Fn` once
- The application starts a hands-free recording session
- The user does not need to keep holding the key
- After the user finishes speaking, they press `Fn` again
- The application ends the current recording session
- Proceeds to ASR final convergence, LLM correction, and auto-paste

### 7.2 Method for Distinguishing Tap from Hold

For a single key to support two semantics, a clear duration threshold must be defined.

Recommended configuration:

- `tap_max_ms: 180`
- `hold_threshold_ms: 180`

Decision rules:

- If the duration from `keyDown -> keyUp` is less than or equal to `tap_max_ms`, it is treated as a tap
- If the `keyDown` duration exceeds `hold_threshold_ms`, it is treated as entering hold mode

Implementation notes:

- `tap_max_ms` and `hold_threshold_ms` should be kept identical to avoid decision gaps
- The hotkey listening layer needs a `Pending` state and cannot arbitrarily decide on the first millisecond of `keyDown` whether this is a tap or a hold

### 7.3 Final Decision Logic for Dual-Mode Compatibility

#### In Idle State

When the system is in `Idle`:

1. Receive `Fn keyDown`
2. Enter `HotkeyDecisionPending`
3. Start a `hold_threshold_ms` timer
4. If `keyUp` is received within the threshold, determine it as "tap to start"
5. If the threshold is exceeded without receiving `keyUp`, determine it as "hold to start"

#### Tap to Start

When a tap occurs while in `Idle`:

1. Confirm the input as a tap at the moment of `keyUp`
2. Start a new recording session
3. Enter "hands-free recording" state
4. The user speaks freely from this point
5. When the next `Fn keyDown` occurs, end the current session

#### Hold to Start

When a hold occurs while in `Idle`:

1. Confirm the input as a hold when the threshold is exceeded
2. Immediately start a recording session
3. The user continues holding the key while speaking
4. End the current session on `keyUp`

#### In Hands-Free Recording State

When the system is already in the "hands-free recording state initiated by tap":

1. The next `Fn keyDown` is directly treated as "end current recording"
2. This `keyDown` is consumed and does not serve as the start of the next recording segment
3. To avoid double-triggering, the immediately following `keyUp` is also consumed and ignored

The reasons for this design:

- Fully matches the user's mental model of "tap once to start, tap again to end"
- The end action occurs at the instant of the second press, providing faster response
- No need to wait for the second key release

### 7.4 Recording Start Timing

After dual-mode compatibility, the recording start timing must be differentiated:

- Hold mode: starts at the moment "hold is confirmed"
- Tap mode: starts "after the first tap release"

This means:

- Hold mode is suitable for users who start speaking immediately after pressing
- Tap mode is suitable for users who tap once first, then naturally speak a full sentence

### 7.5 Key Risks

`Fn` is not a regular character key. On different keyboards and system settings, it may behave as:

- `Fn`
- `Globe`
- Occupied by the system as the emoji/globe key
- Bound by the system to system dictation
- Bound by the system to input method switching

Therefore, while the `Fn` approach can serve as the preferred target, it cannot be designed as the only available option.

### 7.6 Final Design

Default support:

- `Fn` as the preferred dual-mode input key
- The same key supports both hold mode and tap toggle mode

Required fallbacks:

- `left_option`
- `right_option`
- `left_command`
- `right_command`

Configuration requirements:

- The hotkey must be configurable
- The default value can be `fn`
- The cancel key must be configurable and separate from the trigger key
- Must support having both "hold mode" and "tap toggle mode" enabled simultaneously
- The decision threshold can remain fixed at 180ms
- Documentation and diagnostic tools must indicate: if `Fn` is intercepted by the system, the user should switch to a fallback key

### 7.7 Limitations That Must Be Clearly Stated in User Documentation

If the user's system has already bound the `Fn/Globe` key to any of the following behaviors:

- Dictation
- Emoji & Symbols
- Input method switching
- Other system shortcut functions

Then this application may not be able to reliably receive press and release events for that key. In such cases, the user must switch to a different hotkey.

## 8. Complete User Flow

### 8.1 First Installation and Setup

1. The user installs `Koe.app`
2. The user launches the application for the first time
3. The application checks whether the configuration file exists
4. If it does not exist, it generates a default configuration file and default dictionary file under `~/.koe/`
5. The application checks microphone permission, Input Monitoring permission, and Accessibility permission
6. If permissions are missing, then:
   - Microphone: trigger system microphone authorization
   - Accessibility: trigger accessibility authorization guidance
   - Input Monitoring: prompt the user to manually enable it in System Settings
7. Once all permissions are satisfied, the application enters persistent standby state

### 8.2 User-Perspective Flow of a Complete Input

This system supports two parallel user interaction paths.

#### Path A: Hold to Start, Release to End

1. The user places the cursor in any app's input field
2. The user holds down `Fn`
3. The application determines this is a hold
4. The application starts recording and connects to streaming ASR
5. The user speaks while holding the key
6. The application continuously uploads audio and receives streaming interim results
7. The floating overlay displays interim recognition text in real time as the user speaks
8. The user finishes speaking and releases `Fn`
9. The application ends the audio stream and waits for the ASR final text
10. The application sends the ASR text, user dictionary, and cleanup rules to LLM for correction
11. The application obtains the corrected final text
12. The application checks that a pasteable foreground input field still exists
13. The application backs up the current clipboard
14. The application writes the final text to the clipboard
15. The application simulates sending `Cmd+V`
16. The application restores the original clipboard at the appropriate time
17. This input is complete; the application returns to standby state

#### Path B: Tap to Start, Tap Again to End

1. The user places the cursor in any app's input field
2. The user quickly taps `Fn` once
3. The application determines this is a tap to start
4. The application starts recording and connects to streaming ASR
5. The user releases the key and speaks freely
6. The application continuously uploads audio and receives streaming interim results
7. The floating overlay displays interim recognition text in real time as the user speaks
8. After the user finishes speaking, they press `Fn` again
9. The application ends the audio stream at the instant of the second press
10. The application waits for the ASR final text
11. The application sends the ASR text, user dictionary, and cleanup rules to LLM for correction
12. The application obtains the corrected final text
13. The application checks that a pasteable foreground input field still exists
14. The application backs up the current clipboard
15. The application writes the final text to the clipboard
16. The application simulates sending `Cmd+V`
17. The application restores the original clipboard at the appropriate time
18. This input is complete; the application returns to standby state

## 9. Key Design Clarifications

### 9.1 The Same `Fn` Key Must First Determine "Tap" or "Hold"

Because the same key carries two semantics, the system cannot immediately decide the recording mode on the first `keyDown`.

It must first enter a brief decision window:

- If the user releases quickly, treat it as a tap to start
- If the user continues holding beyond the threshold, treat it as a hold to start

This step is the most critical foundation of the entire interaction layer and must not be omitted.

### 9.2 WebSocket Streaming ASR Must Work During Speech

Although the requirements description mentions "connecting to a WebSocket streaming model after the user finishes speaking," true streaming ASR does not upload only after speaking ends. Instead:

- After the hotkey is pressed, a recognition session is established
- Audio frames are continuously uploaded during speech
- After the hotkey is released, an end signal is sent
- The final result converges after the end signal

If you wait until the user finishes speaking before connecting the WebSocket, then it is no longer streaming recognition but an "record first, upload later" offline batch processing path.

Therefore, this design adopts:

- Real-time streaming upload during recording
- Wait for the final result after key release

### 9.3 No GUI Does Not Mean No Interaction Feedback

Since there are no windows, the application still needs minimal feedback. Recommended:

- Hold mode recording starts: short cue sound
- Tap mode recording starts: short cue sound
- Recording ends: short cue sound
- Recognition failure: error sound
- Missing permission: error sound plus log entry

Cue sounds can be enabled by users who want stronger feedback, but the shipped defaults can stay off to keep the runtime quiet.

## 10. Overall Architecture

```text
┌─────────────────────────────────────────────────────────┐
│ Objective-C Agent Shell                                │
│                                                         │
│ - App lifecycle                                         │
│ - Permission checks                                     │
│ - Global hotkey monitor                                 │
│ - Audio capture (AVFoundation)                          │
│ - Accessibility / paste                                 │
│ - Clipboard backup / restore                            │
│ - Menu bar UI + status icon                             │
│ - Usage statistics (SQLite history.db)                  │
│ - Rust FFI bridge                                       │
└─────────────────────────────────────────────────────────┘
                          │
                          │ C ABI / FFI
                          ▼
┌─────────────────────────────────────────────────────────┐
│ Rust Core                                               │
│                                                         │
│ - Config loader                                         │
│ - Dictionary loader                                     │
│ - Session state machine                                 │
│ - Streaming ASR 2.0 client (two-pass recognition)      │
│ - Transcript aggregator (interim → definite → final)   │
│ - LLM corrector (with interim history context)          │
│ - Prompt builder                                        │
│ - Error model                                           │
│ - Logging                                               │
└─────────────────────────────────────────────────────────┘
```

### 10.1 Objective-C Responsibilities

- Application lifecycle management
- Native permission checks and authorization triggering
- Global keyboard event monitoring
- Audio recording
- Clipboard operations
- Simulated paste
- Accessibility checks with the foreground app
- Pushing audio frames to Rust
- Receiving the final text returned by Rust

### 10.2 Rust Responsibilities

- Reading and validating YAML configuration
- Loading the user dictionary
- Managing the state machine for a "dual-mode hotkey voice input" session
- Establishing and maintaining WebSocket ASR connections
- Aggregating streaming interim results and final results
- Organizing LLM requests
- Constructing correction prompts based on the dictionary
- Outputting final text or errors

## 11. Module Breakdown

### 11.1 Objective-C Modules

Suggested modules:

- `SPAppDelegate`
- `SPPermissionManager`
- `SPHotkeyMonitor`
- `SPAudioCaptureManager`
- `SPAccessibilityManager`
- `SPPasteManager`
- `SPClipboardManager`
- `SPRustBridge`
- `SPCuePlayer`
- `SPAudioDeviceManager` — CoreAudio input device enumeration and selection persistence
- `SPStatusBarManager` — menu bar icon and dropdown with stats/permissions
- `SPHistoryManager` — SQLite usage statistics storage

### 11.2 Rust Modules

Suggested modules:

- `config`
- `dictionary`
- `session`
- `audio_buffer`
- `asr`
- `transcript`
- `llm`
- `prompt`
- `errors`
- `telemetry`

## 12. Boundary Between Objective-C and Rust

### 12.1 Boundary Principle

Native system capabilities go in Objective-C; pure business logic goes in Rust.

This approach has three benefits:

- macOS native APIs do not need to be forcefully bridged in Rust
- The Rust core remains pure enough for easy testing
- Permissions, events, and paste logic are concentrated in the system layer, making debugging more straightforward

### 12.2 Recommended FFI Directions

Objective-C calls Rust:

- `sp_core_create(config_path)`
- `sp_core_destroy()`
- `sp_core_reload_config()`
- `sp_core_session_begin(session_context)`
- `sp_core_push_audio(frame, len, timestamp)`
- `sp_core_session_end()`

Rust calls back to Objective-C:

- `on_session_ready`
- `on_session_error`
- `on_final_text_ready`
- `on_log_event`

### 12.3 Audio Capture Boundary

Audio capture is done directly by Objective-C; Rust does not drive the microphone.

Reasons:

- `AVAudioEngine` and `AVAudioSession` style capabilities are more natural in the Objective-C layer
- Permission requests and device switching are also more convenient in Objective-C
- Rust only needs to process PCM frames; it does not need to understand the AppKit runtime

Input device selection is handled entirely in the Objective-C layer:

- `SPAudioDeviceManager` enumerates available input devices via CoreAudio (`AudioObjectGetPropertyData` with `kAudioHardwarePropertyDevices`)
- The selected device UID is persisted in `NSUserDefaults`, not in `config.yaml`, because Rust has no need to know which physical device is in use
- Before each capture session, `SPAudioCaptureManager` applies the selected device by calling `AudioUnitSetProperty` with `kAudioOutputUnitProperty_CurrentDevice` on the input node's AudioUnit — this must happen before querying the hardware format
- Aggregate devices (transport type `kAudioDeviceTransportTypeAggregate`) are filtered out of the device list — these are internal system devices (e.g., `CADefaultDeviceAggregate`) created by macOS for virtual audio routing and should not be shown to the user; note that this also filters user-created aggregate devices from Audio MIDI Setup, which is a deliberate trade-off for simplicity
- The selected device UID and display name are both persisted so the UI can show the device name even when it is disconnected; the preference is never cleared by a menu refresh — if the device is temporarily unavailable, it appears as a greyed-out "(Unavailable)" item, and `resolvedDeviceID` silently falls back to the macOS default input device at recording time
- `AVAudioEngine` is recreated at the start of each capture session and released on stop — this avoids stale device references that would otherwise persist after a Bluetooth device disconnects and reconnects (CoreAudio assigns a new `AudioDeviceID`, but the old engine's internal AudioUnit still points to the dead device)
- `SPAudioDeviceManager` registers a CoreAudio `kAudioHardwarePropertyDevices` property listener at launch to detect device arrivals and removals in real time; changes are dispatched to the main thread and forwarded to `SPAppDelegate` via the `SPAudioDeviceManagerDelegate` protocol
- When a device disconnect is detected mid-recording via the device list listener, `SPAppDelegate` stops capture, ends the Rust session, resets the hotkey state machine to idle, plays an error cue, shows a brief error state, and auto-recovers to idle after 2 seconds

## 13. File and Directory Layout

### 13.1 Suggested Directory

All user-editable files should be placed in:

`~/.koe/`

Directory structure:

```text
~/.koe/
├── config.yaml          # Main configuration
├── dictionary.txt       # User dictionary (hotwords + LLM correction)
├── system_prompt.txt    # LLM system prompt (customizable)
├── user_prompt.txt      # LLM user prompt template
└── history.db           # Usage statistics (SQLite, auto-created)
```

### 13.2 Why YAML for Configuration and TXT for Dictionary

Final recommendation:

- Main configuration: `config.yaml`
- User dictionary: `dictionary.txt`

Rationale:

#### `config.yaml`

Suitable for:

- ASR WebSocket URL
- API key
- API host
- Model name
- Hotkey configuration
- Logging configuration
- Paste strategy
- LLM prompt parameters
- Timeout parameters

YAML advantages:

- Well-suited for expressing hierarchical configuration
- Good human readability
- Easy to extend fields later

#### `dictionary.txt`

Suitable for:

- User-specific terms
- Personal names
- Place names
- Product names
- Company names
- Project names
- Technical terms

TXT advantages:

- One entry per line, matching the original intent of the requirement
- No additional syntax burden
- Does not force users to write JSON arrays or YAML lists
- Lowest user maintenance cost

### 13.3 Not Recommended to Put Dictionary Inside YAML

Although YAML can express a dictionary list, this is not recommended. Reasons:

- User dictionaries typically grow longer over time
- Mixed with the main configuration, readability degrades rapidly
- A dictionary is more like a "data file," not a "configuration item"
- A separate TXT file is better suited for hot updates, editor search, and batch maintenance

Conclusion:

- `config.yaml` manages configuration
- `dictionary.txt` manages the dictionary

## 14. `config.yaml` Design

### 14.1 Example

```yaml
asr:
  # ASR provider selection. Currently only "doubao" is implemented.
  provider: "doubao"

  # Doubao ASR 2.0 (优化版双向流式)
  doubao:
    url: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async"
    app_key: ""              # Volcengine App ID
    access_key: ""           # Volcengine Access Token
    resource_id: "volc.seedasr.sauc.duration"
    connect_timeout_ms: 3000
    final_wait_timeout_ms: 5000
    enable_ddc: true         # 语义顺滑 (disfluency removal)
    enable_itn: true         # 文本规范化 (inverse text normalization)
    enable_punc: true        # 自动标点
    enable_nonstream: true   # 二遍识别 (two-pass: streaming + re-recognition)

llm:
  enabled: true
  base_url: ""             # OpenAI-compatible endpoint
  api_key: "${LLM_API_KEY}"
  model: ""
  temperature: 0
  top_p: 1
  timeout_ms: 8000
  max_output_tokens: 1024
  max_token_parameter: "max_completion_tokens"
  dictionary_max_candidates: 0  # 0 = send all entries to LLM
  system_prompt_path: "system_prompt.txt"
  user_prompt_path: "user_prompt.txt"

feedback:
  start_sound: false
  stop_sound: false
  error_sound: false

dictionary:
  path: "dictionary.txt"

hotkey:
  trigger_key: "fn"
  cancel_key: "left_option"
```

> **Note:** The tap/hold threshold (180ms), audio framing, and paste timing are still hardcoded. Hotkeys, provider credentials, and cue sounds are user-configurable.

### 14.2 Configuration Rules

- Use UTF-8
- Support environment variable substitution, e.g., `${LLM_API_KEY}`
- All relative paths are relative to the configuration directory
- Unknown fields are silently ignored for forward/backward compatibility
- If configuration loading fails, the application must not enter standby state

### 14.3 Hotkey Behavior

The hotkey layer now exposes both a configurable `trigger_key` and a separate
`cancel_key`. Supported values are:

- `fn`
- `left_option`
- `right_option`
- `left_command`
- `right_command`

Behavior:

- `trigger_key` supports both **hold to talk** and **tap to toggle**
- `cancel_key` aborts the current session immediately without producing output
- The tap/hold boundary remains fixed at **180ms**
- If the configured trigger and cancel keys collide, the config loader normalizes them and persists a valid pair back to `config.yaml`

When the system is already in hands-free recording (tap mode), the next trigger `keyDown` immediately ends the session without waiting for key release.

## 15. `dictionary.txt` Design

### 15.1 Format

`dictionary.txt` uses UTF-8 encoding, with one entry per line.

Example:

```text
豆包
火山引擎
扣子
Claude Code
Cursor
OpenAI
Anthropic
MCP
WebSocket
Rust
Objective-C
```

### 15.2 Semantic Definition

Each line is a "prioritize retention and correction" entry. It does not include replacement rules, conditional expressions, or source information.

Allowed entry types:

- Single words
- Proper nouns
- Phrases
- English terms
- Mixed Chinese-English terms

### 15.3 Parsing Rules

- Empty lines are ignored
- Lines containing only whitespace are ignored
- Lines starting with `#` are treated as comments and ignored
- Leading and trailing whitespace is trimmed from each line
- Duplicates are removed
- Original casing is preserved

### 15.4 How the Dictionary Participates in Correction

The dictionary does not serve as a "replacement table" but rather as a "priority reference term list."

How it works:

1. When constructing the LLM correction prompt, the dictionary is passed in as a high-priority terminology list
2. The model is instructed to preferentially correct ASR misrecognized words to entries in the dictionary
3. The model is instructed not to rewrite dictionary entries into homophones or similar-looking characters
4. If the target ASR provides hotword or term biasing capabilities, the same dictionary can be reused for upstream enhancement

### 15.5 Things Not to Do

This version does not implement:

- `wrong word -> correct word` manual mappings
- Regex replacement
- Conditional replacement
- Context rule DSL

Reasons:

- Would cause the system to balloon from a "corrector" into a "rule engine"
- User maintenance complexity would increase dramatically
- Conflicts with the original intent of "one entry per line"

## 16. Filler Word Removal Strategy

### 16.1 Goal

Remove meaningless spoken filler words without changing the original meaning, for example:

- 嗯 (um)
- 啊 (ah)
- 哦 (oh)
- 呃 (uh)
- 唉 (sigh)
- 这个 (this/like)
- 那个 (that/um)

### 16.2 Principles

Only remove "semantically non-contributing" spoken filler words; do not remove words that genuinely carry meaning.

For example:

- "嗯我觉得这个方案可以" should be corrected to "我觉得这个方案可以"
- "那个叫《啊，朋友再见》" must not have the "啊" in the book title or lyrics deleted
- "哦姆定律" (Ohm's Law) must not have the "哦" incorrectly deleted

### 16.3 Implementation Approach

This design uses an LLM-driven approach rather than applying strong rule-based replacement first.

Reasons:

- Pure rules easily cause incorrect deletions
- Whether a Chinese filler word carries meaning depends on context
- LLM is better suited for "minimal necessary rewriting"

### 16.4 Prompt Requirements

The correction prompt must explicitly state:

- Remove standalone, semantically valueless filler words
- Preserve the original meaning
- Do not expand or elaborate
- Do not summarize
- Do not polish into a different writing style

## 17. LLM Correction Design

### 17.1 Input

LLM input includes:

- ASR final text (best available from TranscriptAggregator)
- ASR interim revision history (last 10 unique interim texts, showing how the transcript evolved — helps LLM identify uncertain/misrecognized words)
- User dictionary candidate entries
- Language and style constraints

### 17.2 Output

The LLM outputs only the final corrected text -- no explanations, no JSON, no tags.

### 17.3 Prompt Principles

The system prompt should be strongly constrained to:

- You are a dictation error corrector
- You can only make minimal necessary corrections
- You must prioritize the user dictionary
- You must remove meaningless filler words
- You must not add new information
- You must not omit substantive information
- You must not answer questions; you can only output the corrected text

### 17.4 Recommended System Prompt

```text
You are a Chinese speech-to-text error corrector. Your task is to make minimal necessary corrections to ASR results.

Rules:
1. Preserve the original sentence meaning. Do not expand, summarize, or change the writing style.
2. Prioritize terms, proper nouns, and English spellings from the user dictionary.
3. Remove spoken filler words that contribute no semantic value, such as "嗯, 啊, 哦, 呃, 这个, 那个."
4. If a word clearly belongs to a name, term, title, quoted content, or fixed expression, do not mistakenly delete it.
5. Output only the final corrected text. Do not output explanations, JSON, or quotation marks.
```

### 17.5 User Prompt Template

```text
ASR transcript:
{{asr_text}}

ASR interim revisions (earlier drafts, may reveal uncertain words):
{{interim_history}}

User dictionary:
{{dictionary_entries}}

Output the corrected text only.
```

### 17.6 Dictionary Candidate Trimming

By default (`dictionary_max_candidates: 0`), all dictionary entries are sent to the LLM. This works well for dictionaries under ~500 entries.

When a limit is set (`dictionary_max_candidates: N` where N > 0), Rust filters candidate entries:

- Entries with character overlap with the ASR text are prioritized
- English words use case-insensitive matching
- Terms with shorter edit distance to ASR tokens are prioritized
- The final count is kept within `dictionary_max_candidates`

This step does not alter dictionary content; it only reduces prompt size.

## 18. ASR Design

### 18.1 ASR Provider

This design uses Doubao (豆包) ASR 2.0 via the `bigmodel_async` endpoint (optimized bidirectional streaming). The implementation uses a trait-based abstraction to allow future provider additions.

Rust defines a unified `AsrProvider` trait:

- `connect(config)` — establish WebSocket connection with auth headers
- `send_audio(frame)` — send gzip-compressed PCM audio frame
- `finish_input()` — send last-packet flag to signal end of audio
- `next_event()` — receive next event: `Interim`, `Definite`, `Final`, `Closed`, or `Error`
- `close()` — close WebSocket connection

### 18.1.1 Two-Pass Recognition

When `enable_nonstream: true`, the ASR performs two-pass recognition:

1. **First pass (streaming)**: fast real-time results as `Interim` events
2. **Second pass (non-streaming)**: re-recognizes confirmed segments with higher accuracy, emitted as `Definite` events (utterances with `definite: true`)

The `TranscriptAggregator` merges these with priority: `Final` > `Definite` > `Interim`.

### 18.1.2 Binary Protocol

The Doubao WebSocket uses a custom binary framing protocol:

- 4-byte header: version, message type, serialization format, compression
- Payload: gzip-compressed JSON (for requests/responses) or PCM audio
- Message types: full client request (0x1), audio-only (0x2), server response (0x9), error (0xF)

### 18.1.3 Hotwords

Dictionary entries are sent to ASR as hotwords via the `corpus.context` field in the full client request. The format is a JSON string containing a hotwords array:

```json
{"corpus": {"context": "{\"hotwords\": [{\"word\": \"Cloudflare\"}, {\"word\": \"PostgreSQL\"}]}"}}
```

### 18.2 ASR Lifecycle of a Single Session

Hold mode:

1. The user presses the hotkey
2. The system enters the key decision window
3. Once confirmed as a hold, Rust creates a new recognition session
4. Objective-C starts microphone capture
5. Rust establishes the WebSocket connection
6. Objective-C continuously sends audio frames to Rust
7. Rust sends the audio frames to ASR
8. Rust continuously receives interim results
9. The user releases the hotkey
10. Objective-C stops capture and notifies Rust that input has ended
11. Rust sends the end frame or end message
12. Rust waits for the final recognition result
13. Rust closes the current ASR connection

Tap mode:

1. The user quickly presses and releases the hotkey
2. The system confirms this is a tap to start
3. Rust creates a new recognition session
4. Objective-C starts microphone capture
5. Rust establishes the WebSocket connection
6. Objective-C continuously sends audio frames to Rust
7. Rust sends the audio frames to ASR
8. Rust continuously receives interim results
9. The user presses the hotkey again
10. Objective-C immediately notifies Rust that input has ended
11. Objective-C stops capture
12. Rust sends the end frame or end message
13. Rust waits for the final recognition result
14. Rust closes the current ASR connection

### 18.3 Audio Parameters

Default recommendations:

- Mono
- `16kHz`
- `PCM 16-bit little-endian`
- `20ms` per frame

Specific parameters should follow the target ASR vendor's requirements, but the entire system should express them through configuration rather than hardcoding.

### 18.4 First-Word Truncation Issue

To avoid the first word being truncated when the user starts speaking immediately after pressing the hotkey, it is recommended to implement a brief startup buffer in the Objective-C layer.

This is primarily used for hold mode. Tap mode does not need this pre-capture by default, unless subsequent testing reveals that tap mode also has noticeable first-word truncation:

- Start capture immediately when the key is pressed
- Audio is first written to a local memory buffer
- After the WebSocket connection is established, replay the buffer first, then continue with the real-time stream

Recommended buffer:

- `startup_buffer_ms: 300`

## 19. Session State Machine

Suggested states:

- `Idle`
- `HotkeyDecisionPending`
- `ConnectingAsr`
- `RecordingHold`
- `RecordingToggle`
- `FinalizingAsr`
- `Correcting`
- `PreparingPaste`
- `Pasting`
- `RestoringClipboard`
- `Completed`
- `Failed`

State transitions:

```text
Idle
  -> HotkeyDecisionPending
  -> (ConnectingAsr -> RecordingHold)
   or (ConnectingAsr -> RecordingToggle)
  -> FinalizingAsr
  -> Correcting
  -> PreparingPaste
  -> Pasting
  -> RestoringClipboard
  -> Completed
  -> Idle
```

On failure:

```text
Any state -> Failed -> Idle
```

### 19.1 Hold Mode State Flow

```text
Idle
  -> HotkeyDecisionPending
  -> ConnectingAsr
  -> RecordingHold
  -> FinalizingAsr
  -> Correcting
  -> PreparingPaste
  -> Pasting
  -> RestoringClipboard
  -> Completed
  -> Idle
```

### 19.2 Tap Mode State Flow

```text
Idle
  -> HotkeyDecisionPending
  -> ConnectingAsr
  -> RecordingToggle
  -> FinalizingAsr
  -> Correcting
  -> PreparingPaste
  -> Pasting
  -> RestoringClipboard
  -> Completed
  -> Idle
```

## 20. Complete Technical Flow from Hotkey Press to Paste Completion

This section is the most critical timing specification of the entire system.

### 20.1 Prerequisites

Before starting an input, the following must be satisfied:

- The application has launched and is running persistently
- `config.yaml` loaded successfully
- `dictionary.txt` loaded successfully
- Microphone permission has been granted
- Input Monitoring permission has been granted
- Accessibility permission has been granted, or degradation to copy-only without pasting is allowed
- The user has already placed the cursor in the target input field

### 20.2 T0: User Presses the Hotkey for the First Time

1. Objective-C's global event listener receives `Fn keyDown`
2. The hotkey matcher confirms this is the voice input key from the configuration
3. If the system already has a "hands-free recording session from tap mode," this `keyDown` directly enters the "end current session" branch and does not go through the initial decision flow
4. If the system is currently `Idle`, it enters `HotkeyDecisionPending`
5. Record the current foreground app's bundle ID, PID, and timestamp
6. If configuration requires input field verification, pre-read the currently focused element
7. Start a `hold_threshold_ms` timer
8. If hold-mode startup buffering is enabled, begin a temporary audio buffer that exists only in local memory, but do not formally create a session yet

### 20.3 Decision Window: Distinguishing Tap from Hold

In the `HotkeyDecisionPending` state:

1. If `keyUp` is received within `hold_threshold_ms`, determine it as "tap to start"
2. If `hold_threshold_ms` is exceeded without receiving `keyUp`, determine it as "hold to start"
3. Only after the decision is made does the system allow formal session creation

### 20.4 Hold Start Path

When the system confirms this is a hold:

1. Objective-C notifies Rust: start a new hold session
2. Rust creates a session context and unique `session_id`
3. Objective-C starts microphone capture
4. Objective-C begins writing audio frames to the startup buffer
5. Rust initiates the WebSocket connection in parallel
6. If cue sounds are enabled, play the "hold recording started" cue sound
7. Rust confirms the WebSocket is connected
8. Rust sends the session initialization message
9. Objective-C replays the audio from the startup buffer to Rust
10. Objective-C continues pushing real-time PCM frames
11. Rust continuously sends audio frames to ASR
12. Rust continuously reads ASR interim results
13. Rust maintains the current interim transcription text

### 20.5 Tap Start Path

When the system confirms this is a tap:

1. Confirm "tap to start" at the instant of the first `keyUp`
2. If a temporary buffer was started for hold-mode decision, discard that buffer
3. Objective-C notifies Rust: start a new tap session
4. Rust creates a session context and unique `session_id`
5. Objective-C starts microphone capture
6. Rust initiates the WebSocket connection in parallel
7. If cue sounds are enabled, play the "tap recording started" cue sound
8. Rust confirms the WebSocket is connected
9. Rust sends the session initialization message
10. Objective-C continues pushing real-time PCM frames
11. Rust continuously sends audio frames to ASR
12. Rust continuously reads ASR interim results
13. Rust maintains the current interim transcription text
14. The system enters `RecordingToggle`
15. The user no longer needs to hold the key and can speak naturally

### 20.6 Rules During Recording

#### Hold Mode

- As long as the hotkey is held, recording continues
- Even if there are pauses, recording does not end automatically
- The session ends when the user releases the key

#### Tap Mode

- After the first tap starts recording, the system continues recording
- The user does not need to keep holding the key
- The next `Fn keyDown` directly ends the session
- The end trigger occurs at the instant of the second press, not the instant of the second release

#### General Rules

- The system does not rely on "user pause detection" to end sessions
- Optionally, local silence detection can be performed, but silence detection is only used for optimization, not for determining session end

### 20.7 Session End Trigger

#### Hold Mode End

1. Objective-C receives `Fn keyUp`
2. Objective-C immediately stops capturing new audio
3. Objective-C pushes the last batch of buffered audio to Rust
4. Objective-C notifies Rust: input has ended
5. Rust sends the end message to ASR
6. If cue sounds are enabled, play the "recording ended" cue sound

#### Tap Mode End

1. Objective-C receives the next `Fn keyDown` while in `RecordingToggle` state
2. Objective-C immediately interprets this `keyDown` as "end current session"
3. Objective-C stops capturing new audio
4. Objective-C pushes the last batch of buffered audio to Rust
5. Objective-C notifies Rust: input has ended
6. Rust sends the end message to ASR
7. If cue sounds are enabled, play the "recording ended" cue sound
8. To prevent the next `keyUp` from causing a false trigger, the system must consume and ignore the `keyUp` corresponding to this ending key press

### 20.8 Waiting for ASR Final Result

1. Rust enters `FinalizingAsr`
2. Rust waits for the server to return the final transcription
3. If the final result is received within `final_wait_timeout_ms`, proceed to correction
4. If it times out but usable text is available, use the current most reliable text as the candidate result and continue
5. If there is no text at all, this session fails and returns to `Idle`

### 20.9 LLM Correction Phase

1. Rust reads the best available text from TranscriptAggregator (final > definite > interim)
2. Rust collects the interim revision history (last 10 unique interim texts)
3. Rust selects candidate entries from the dictionary
4. Rust constructs the correction prompt (ASR text + interim history + dictionary)
5. Rust calls the LLM API
5. LLM returns the corrected final text
6. Rust performs basic output sanitization, such as removing extra quotation marks and trimming leading/trailing whitespace
7. If the LLM call fails, decide based on configuration:
   - Fall back directly to the ASR final text
   - Or fail this session

Recommended default:

- Fall back to ASR final text on LLM failure

### 20.10 Paste Preparation Phase

1. Objective-C receives the final text returned by Rust
2. Objective-C re-acquires the current foreground app and currently focused element
3. If `require_same_frontmost_app=true`, compare whether it is still the same foreground app as when the hotkey was pressed
4. If the foreground app has changed, do not auto-paste by default; only copy to clipboard
5. If `verify_focused_text_input=true`, verify whether the current focus is still a text input control
6. If `deny_secure_text_field=true` and the focus is a secure text field, prohibit auto-paste

### 20.11 Clipboard Backup and Write

1. Read the current system clipboard contents, backing up along with the `changeCount`
2. Write the final text to the system clipboard
3. Record an internal marker indicating "this application just wrote to the clipboard"

### 20.12 Execute Paste

1. Objective-C sends `Cmd+V` via system event injection
2. The sending sequence must be complete:
   - `Command key down`
   - `V key down`
   - `V key up`
   - `Command key up`
3. After sending, wait for a very short stabilization window

### 20.13 Restore Clipboard

After pasting:

1. Wait for 1500ms
2. Check whether the current clipboard still contains the content written by this application
3. If the user copied new content during this period, do not restore, to avoid overwriting the user's new clipboard contents
4. If the clipboard is unchanged, restore to the pre-session contents

### 20.14 Session End

1. Rust cleans up the session object
2. Objective-C cleans up local state
3. The application returns to `Idle`

## 21. Focused Input Field Verification Strategy

### 21.1 Why Verification Is Required

Without verifying the currently focused control, the system may paste text to the wrong location, for example:

- The user has already switched to a different app
- The current focus is not an input field at all
- The current focus is a password field
- The current focus is a non-editable area

### 21.2 Allowed Paste Targets

Control types that allow pasting can include:

- Standard text fields
- Multi-line text fields
- Search fields
- Editable web input controls

### 21.3 Prohibited Paste Targets

Auto-paste must be prohibited for:

- Secure text fields
- Password fields
- Focus objects whose editability cannot be confirmed

If the target cannot be confirmed, the recommended default is:

- Copy to clipboard only
- Do not auto-paste

## 22. Degradation and Failure Handling

### 22.1 Missing Microphone Permission

Behavior:

- Do not allow recording to start
- Log an error
- Prompt the user to grant permission

### 22.2 Missing Input Monitoring Permission

Behavior:

- Background global hold mode is unavailable
- Background global tap toggle mode is also unavailable
- The `doctor` command must clearly report the error

### 22.3 Missing Accessibility Permission

Behavior:

- Allow recording, recognition, and correction to complete
- Only write to clipboard at the end
- Do not automatically send `Cmd+V`

### 22.4 ASR Connection Failure

Behavior:

- This session fails
- Play error sound
- Write to log

### 22.5 LLM Correction Failure

Behavior:

- Fall back to ASR final text by default
- Continue with subsequent paste flow

### 22.6 Foreground App Changed

Behavior:

- Do not auto-paste by default
- Copy to clipboard only

### 22.7 Current Focus Is Not a Text Field

Behavior:

- Do not auto-paste by default
- Copy to clipboard only

### 22.8 Audio Device Disconnected Mid-Recording

This covers the case where a manually selected audio input device (e.g. Bluetooth AirPods) disconnects during an active recording session.

Detection:

- CoreAudio `kAudioHardwarePropertyDevices` listener — fires when any system audio device is added or removed; `SPAppDelegate` checks whether the selected device UID is still present

Behavior:

- Stop audio capture immediately
- End the Rust session
- Reset the hotkey state machine to idle (prevents stuck recording state)
- Play error cue sound
- Show error state in status bar and overlay
- Send a system notification with the error
- Auto-recover to idle after 2 seconds

If the device reconnects before the next recording session, it is automatically picked up — `AVAudioEngine` is recreated per session and `resolvedDeviceID` re-queries the device list by UID each time.

## 23. Privacy and Security Design

### 23.1 API Key Storage

Allowed:

- Written directly in `config.yaml`
- Injected via environment variables

Recommended:

- Configuration file supports `${ENV_VAR}` format
- Production environments should prefer environment variables or Keychain

If the user insists on placing them in YAML:

- File permissions should be restricted to owner-readable only
- Recommend `chmod 600`

### 23.2 Log Redaction

Recommended defaults:

- Do not fully log the original transcription text in logs
- Do not fully log the LLM final text in logs
- Only log length, duration, status codes, and error types

If debug mode is enabled:

- Allow logging of partial text
- Must clearly indicate this is development mode

### 23.3 Transport Security

- Both ASR and LLM must use TLS
- Plaintext WebSocket is prohibited
- If `ws://` or `http://` appears in the configuration, a warning should be issued at startup

## 24. Configuration Hot Reload

### 24.1 Hot-Reloadable Content

Hot-reloadable:

- Dictionary
- LLM model parameters
- ASR connection parameters
- Prompt templates
- Log level
- Paste strategy

### 24.2 Content Not Recommended for Hot Reload

Not recommended for hot reload mid-session:

- Hotkey definitions
- Audio device
- Core permission status

### 24.3 Implementation Approach

Recommended:

- File change monitoring
- Or app restart (config is re-read at each session start)

Hot reload effective timing:

- New configuration only affects the next session
- Does not interrupt the currently ongoing session

## 25. Logging and Observability

### 25.1 Information to Log Per Session

- `session_id`
- Hotkey start time
- Hotkey end time
- Total recording duration
- ASR connection latency
- ASR final result latency
- LLM correction latency
- Whether auto-paste succeeded
- Whether clipboard was restored
- Error type

### 25.2 Log Levels

- `error`
- `warn`
- `info`
- `debug`

### 25.3 Log File Location

Recommended:

Rust core uses `env_logger` which outputs to stderr. To view logs, run the app from terminal with `RUST_LOG=info`.

## 26. Startup and Persistent Residence Strategy

### 26.1 Launch at Login

Support for launch at login is recommended and is implemented with `SMAppService`.

`LaunchAgent` is not required for the current product shape.

### 26.2 Persistent Residence Strategy

After application startup:

- Initialize configuration
- Check permissions
- Create hotkey listener
- Enter standby

When idle:

- Do not occupy the microphone
- Do not maintain ASR connections
- Only maintain event listening and lightweight persistent residence

## 27. Recommended Implementation Order

### 27.1 Phase 1: Complete the Main Pipeline

Goal:

- Fixed hotkey
- Fixed single ASR
- Fixed single LLM
- Able to go from hotkey press all the way to auto-paste

### 27.2 Phase 2: Add Configuration and Dictionary

Goal:

- Integrate `config.yaml`
- Integrate `dictionary.txt`
- Support configuration hot reload

### 27.3 Phase 3: Enhance Stability

Goal:

- Permission diagnostics
- Foreground app consistency verification
- Clipboard restoration
- Input field verification
- Failure degradation

### 27.4 Phase 4: Expand Provider Support

Goal:

- Additional ASR providers on top of the existing abstraction
- Additional LLM backends where needed

## 28. Test Plan

### 28.1 Functional Tests

Must cover:

- Hold hotkey to start recording
- Release after hold to end recording
- Tap once to start recording
- In tap mode, second press ends recording
- The `keyUp` after the second press is correctly consumed
- ASR returns text
- LLM corrects properly
- Auto-paste succeeds
- Clipboard restoration succeeds

### 28.2 Permission Tests

Test separately:

- Microphone not authorized
- Input Monitoring not authorized
- Accessibility not authorized

### 28.3 Input Target Tests

Test targets include:

- Native app text fields
- Browser web input fields
- Multi-line input fields
- Search fields
- Password fields

### 28.4 Exception Tests

Test scenarios include:

- Network disconnects during speech
- ASR connection timeout
- LLM timeout
- Misjudgment near the tap/hold threshold boundary
- Double-trigger issue with `keyDown` and `keyUp` when ending tap mode
- User switches foreground app immediately after speaking
- User copies new content before clipboard restoration

## 29. Final Recommended Approach

The final recommended implementation approach is as follows:

- Form: windowless macOS Agent App
- Runtime UI: menu bar item, floating overlay, optional settings window
- Shell language: Objective-C
- Core language: Rust
- Configuration file: `config.yaml`
- User dictionary: `dictionary.txt`
- Hotkey mode: default `Fn` trigger plus `left_option` cancel, configurable with supported fallback keys
- Recording strategy: hold to record and release to end, or tap to start and tap again to end
- ASR: provider-based config, currently backed by Doubao WebSocket streaming recognition
- Correction: LLM minimal necessary correction
- Filler words: removed by LLM in context
- Input injection: clipboard + `Cmd+V`
- Permissions: Microphone + Input Monitoring + Accessibility
- Distribution: standard app bundle, signed, notarized, no visible GUI

## 30. Local ASR Support

### 30.1 Provider Architecture

The `AsrProvider` trait defines a uniform interface for all ASR backends:

- **Cloud providers**: Doubao (WebSocket binary protocol), Qwen (WebSocket JSON protocol)
- **Local providers**: MLX (Swift FFI to KoeMLX package, Apple Silicon), sherpa-onnx (dedicated worker thread, CPU)

All providers emit the same event types (`Connected`, `Interim`, `Definite`, `Final`, `Closed`, `Error`), making them interchangeable via `config.yaml`.

Local providers receive configuration through their constructor (`new(config)`), not through the shared `AsrConfig` parameter in `connect()`. This avoids polluting the cloud-oriented `AsrConfig` with local-specific fields.

### 30.2 Model Management

Models are stored under `~/.koe/models/` and discovered via `.koe-manifest.json` files:

```
~/.koe/models/<any-path>/.koe-manifest.json
```

Each manifest describes the provider, model files, sizes, sha256 checksums, and download URLs. The model directory path serves as the unique identifier — no separate id field is needed.

Default manifests are embedded in the binary and installed on first launch via `ensure_defaults()`. The `koe` CLI provides `model list`, `model pull`, `model status`, and `manifest generate` commands for model management.

### 30.3 Setup Wizard Integration

The Setup Wizard's ASR pane includes local provider support. When the user selects MLX or Sherpa-ONNX as the provider:

- Cloud credential fields (App Key, Access Key, API Key) are hidden
- A **Model dropdown** appears, populated by scanning `~/.koe/models/` for manifests matching the selected provider
- A **status label** shows the installation state of the selected model (Installed / Incomplete / Not installed)
- A **download button** (right of the model dropdown) starts an async download with a progress bar; during download, it becomes a stop button
- A **delete button** (right of the status label) removes downloaded files while keeping the manifest
- Both buttons are always visible but grayed out when not applicable (e.g., download is disabled when installed, delete is disabled when not installed)
- A **progress bar** with bytes/total display appears below the status row during downloads
- Multiple models can be downloaded concurrently; switching models in the dropdown shows the correct status and progress for each
- On save, if the selected model is not installed, a confirmation alert warns the user that ASR will not work

Model management is exposed from Rust to Objective-C via C FFI functions (`sp_core_scan_models_json`, `sp_core_check_model_status`, `sp_core_download_model`, etc.) wrapped by `SPRustBridge`.

### 30.4 Feature Flags

Local ASR providers are compile-time gated:

- `mlx` — MLX provider (no Rust crate dependency; resolved at link time via KoeMLX Swift package)
- `sherpa-onnx` — sherpa-onnx provider (`sherpa-onnx` crate dependency)

Both are enabled by default in `koe-core`. Builds without local ASR can use `--no-default-features`.

## 31. One-Sentence Summary

This project is an Objective-C background macOS Agent App + Rust core library + Swift MLX package + YAML configuration + TXT dictionary + SQLite usage statistics + a voice input pipeline with configurable trigger/cancel hotkeys, multi-provider ASR (cloud: Doubao/Qwen, local: MLX/sherpa-onnx), and an OpenAI-compatible LLM for correction.
