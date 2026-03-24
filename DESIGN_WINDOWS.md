# Koe Windows Support Design Document

## 1. Context

Koe is a macOS voice input tool with a two-layer architecture:

- **koe-core** (Rust, ~2300 lines) — Platform-agnostic core: ASR (Doubao WebSocket), LLM correction, session state machine, configuration management. Compiles to a C static library.
- **KoeApp** (Objective-C, ~1200 lines) — macOS-specific shell: audio capture, hotkey, clipboard, paste, system tray, floating status panel.

The FFI boundary is clean: 9 C functions + 5 structs/enums, zero platform-specific types. The Rust core is fully platform-agnostic; only the ~1200-line native shell needs to be rewritten for Windows.

## 2. Technical Approach: C++ / Win32 API

The recommended approach is C++ calling Win32 API directly. Rationale:

1. **Direct FFI linking** — Rust compiles to `koe_core.lib`, C++ includes `koe_core.h` and links directly, identical to the Objective-C approach.
2. **Zero runtime dependencies** — Standalone .exe, no .NET/Chromium/Node, consistent with Koe's lightweight philosophy (<15 MB).
3. **Mirrors macOS architecture** — Objective-C is to macOS API as C++ is to Win32 API; the maintenance model is consistent.
4. **Full GUI capability** — GDI+ custom-drawn animated icons, layered windows for the floating panel, Shell_NotifyIcon for the system tray.

### 2.1 Alternatives Considered (Not Recommended)

| Approach | Issue |
|----------|-------|
| Rust + windows-rs | Verbose COM/GDI+ interop, slow Win32 UI debugging, safety guarantees add limited value for ~1500 lines of UI glue code |
| C# + WPF | Adds .NET runtime (100+ MB), complex P/Invoke FFI, disproportionate to project size |
| Tauri/Electron | Binary size explosion, violates lightweight design |

---

## 3. Rust Core Changes (Minimal)

### 3.1 `config_dir()` Windows Path Support

File: `koe-core/src/config.rs`

```rust
pub fn config_dir() -> PathBuf {
    #[cfg(target_os = "windows")]
    {
        let appdata = std::env::var("APPDATA")
            .unwrap_or_else(|_| "C:\\".into());
        PathBuf::from(appdata).join("koe")
    }
    #[cfg(not(target_os = "windows"))]
    {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".into());
        PathBuf::from(home).join(".koe")
    }
}
```

Result: On Windows, the config directory is `%APPDATA%\koe\`.

### 3.2 Hotkey Resolution with Windows Platform Support

File: `koe-core/src/config.rs`

`HotkeySection::resolve()` currently returns macOS Carbon key codes. A `#[cfg(target_os = "windows")]` branch returns Windows virtual key codes instead.

**Key constraint**: The Fn key is not available on Windows (intercepted by keyboard firmware, no system events generated). The Windows default hotkey is **Right Ctrl** (`VK_RCONTROL = 0xA3`).

The `trigger_key` field in config.yaml supports Windows values:

```yaml
hotkey:
  # macOS: fn | left_option | right_option | left_command | right_command
  # Windows: right_ctrl | left_ctrl | caps_lock | scroll_lock
  trigger_key: "right_ctrl"
```

### 3.3 Build Targets (Dual Architecture: x64 + ARM64)

`Cargo.toml` already specifies `crate-type = ["staticlib"]`, which produces `.lib` under the MSVC toolchain. `reqwest` uses `rustls-tls`, avoiding Windows Schannel dependency. No Cargo.toml changes needed.

Both Rust targets must be compiled:

- `x86_64-pc-windows-msvc` — Traditional x64 devices
- `aarch64-pc-windows-msvc` — ARM64 devices (Surface Pro X, Snapdragon laptops, etc.)

The C++ shell code is fully architecture-agnostic (Win32 API interfaces are identical on x64/ARM64); only the CMake generator/architecture configuration differs.

---

## 4. Windows Shell: Component-by-Component Design

### 4.0 Directory Structure

```
KoeWin/
  src/
    main.cpp             # WinMain, message loop
    app.h/cpp            # Application coordinator (~ SPAppDelegate)
    bridge.h/cpp         # Rust FFI bridge (~ SPRustBridge)
    audio.h/cpp          # WASAPI audio capture (~ SPAudioCaptureManager)
    audio_device.h/cpp   # MMDevice enumeration (~ SPAudioDeviceManager)
    hotkey.h/cpp         # Low-level keyboard hook (~ SPHotkeyMonitor)
    clipboard.h/cpp      # Win32 clipboard (~ SPClipboardManager)
    paste.h/cpp          # SendInput Ctrl+V (~ SPPasteManager)
    tray.h/cpp           # System tray + animated icons (~ SPStatusBarManager)
    overlay.h/cpp        # Layered topmost window (~ SPOverlayPanel)
    cue.h/cpp            # PlaySound (~ SPCuePlayer)
    history.h/cpp        # SQLite (~ SPHistoryManager)
    resource.h/rc        # Icon, version info
  CMakeLists.txt
  Makefile
```

### 4.1 Entry Point (main.cpp)

- `WinMain` entry, Win32 GUI application (no console window).
- `CoInitializeEx` initializes COM (required by WASAPI).
- Creates a hidden message window as the message pump.
- Standard Win32 message loop (equivalent to Cocoa Run Loop).
- Rust callbacks dispatch to the main thread via `PostMessage` (equivalent to `dispatch_async(main_queue)`).

### 4.2 FFI Bridge (bridge.cpp)

Structurally identical to the Objective-C version. C callback functions receive Rust strings and dispatch them to the main thread via `PostMessage` with custom message IDs (`WM_APP+1` through `WM_APP+6`).

`SPSessionContext.frontmost_bundle_id`: Uses `GetForegroundWindow()` + `GetWindowThreadProcessId()` + `QueryFullProcessImageNameW()` to obtain the foreground application's executable path.

### 4.3 Audio Capture (audio.cpp) — WASAPI

macOS `AVAudioEngine` maps to Windows **WASAPI**:

1. `IMMDeviceEnumerator::GetDefaultAudioEndpoint(eCapture)` obtains the default microphone (or a specific device via `GetDevice()` if configured).
2. `IAudioClient` initializes in shared mode, obtaining the device's native format (typically 48kHz).
3. `IAudioCaptureClient::GetBuffer()` loops in a dedicated capture thread.
4. Resamples to 16kHz mono with linear interpolation for common rates (44.1kHz/48kHz).
5. Float32 to Int16 LE conversion (same clamping logic as macOS).
6. Accumulates into 200ms frames (3200 samples = 6400 bytes) then delivers via `sp_core_push_audio()`.

### 4.4 Microphone Input Device Selection (audio_device.cpp)

macOS `CoreAudio` device enumeration maps to Windows **MMDevice API**.

**AudioDeviceManager** enumerates capture endpoints:

1. `IMMDeviceEnumerator::EnumAudioEndpoints(eCapture, DEVICE_STATE_ACTIVE)` retrieves all active capture devices.
2. For each device, queries `IPropertyStore` for `PKEY_Device_FriendlyName` (display name) and `IMMDevice::GetId()` (endpoint ID).
3. Returns a list of `AudioInputDevice { id, name }` sorted by name.

**Persistence**: The selected device endpoint ID is stored in the Windows registry at `HKCU\SOFTWARE\Koe\SelectedAudioDeviceId`. The value is a `REG_SZ` string containing the MMDevice endpoint ID. Deleting the value (or setting it to empty) reverts to the system default.

**Fallback**: `resolvedDeviceId()` checks whether the saved device is still present in the active device list. If not found, it logs a warning and returns empty (system default). This handles device disconnection gracefully.

**Integration with AudioCapture**: `AudioCapture::setDeviceId(id)` must be called before `start()`. In `captureLoop()`, if a device ID is set, `enumerator->GetDevice(id, &device)` is used instead of `GetDefaultAudioEndpoint()`. If `GetDevice()` fails, it falls back to the default.

**Tray menu integration**: The "Microphone" submenu is populated fresh each time the tray menu opens (handles hot-plugging). Menu structure:

```
Microphone >
  System Default  [checkmark if no selection]
  ──────────────
  Device 1 Name   [checkmark if selected]
  Device 2 Name
  ...
```

### 4.5 Hotkey Monitoring (hotkey.cpp) — Low-Level Keyboard Hook

macOS `CGEventTap + NSEvent` maps to Windows `SetWindowsHookExW(WH_KEYBOARD_LL)`.

Reuses the macOS version's state machine logic:

```
Idle -> Pending (key down) --[180ms timer]--> RecordingHold (held)
                           \--[released]----> RecordingToggle (tap)
```

- The hook callback must return quickly (Windows has a timeout limit); it only calls `PostMessage`.
- Actual logic runs on the main thread.
- Default key: Right Ctrl (`VK_RCONTROL`), configurable to CapsLock, ScrollLock, etc.
- Note: `RegisterHotKey` is not suitable because it does not support single-key hold/tap differentiation.

### 4.6 Clipboard (clipboard.cpp)

- **Backup**: `OpenClipboard()` -> `EnumClipboardFormats()` -> `GetClipboardData()` deep copy, records `GetClipboardSequenceNumber()`.
- **Write**: `EmptyClipboard()` -> `SetClipboardData(CF_UNICODETEXT, ...)` — note UTF-8 to UTF-16 conversion via `MultiByteToWideChar`.
- **Restore**: Compare sequence number; restore only if unchanged.

### 4.7 Paste Simulation (paste.cpp)

`SendInput` simulates Ctrl+V (4 INPUT events: Ctrl down, V down, V up, Ctrl up). No special permissions required (unlike macOS which needs Accessibility permission).

### 4.8 System Tray (tray.cpp) — Most Complex UI Component

macOS `NSStatusBar` + custom NSBezierPath drawing maps to Windows `Shell_NotifyIconW` + GDI+ drawing.

**Animated icons** (visual effects consistent with macOS):

- **Idle**: Static 5-bar waveform
- **Recording**: Sine wave animation (SetTimer at 150ms intervals)
- **Processing**: 3 cascading pulsing dots (SetTimer at 200ms intervals)
- **Success**: Checkmark
- **Error**: X mark

Implementation: GDI+ draws to a DIB -> `CreateIconIndirect()` -> `Shell_NotifyIconW(NIM_MODIFY)` updates the icon.

**Dark/light mode adaptation**: Reads registry `HKCU\...\Themes\Personalize\SystemUsesLightTheme` to determine icon color.

**DPI awareness**: `SetProcessDpiAwareness(PROCESS_PER_MONITOR_DPI_AWARE)` at startup, `GetSystemMetricsForDpi(SM_CXSMICON)` queries actual icon size.

**Right-click menu**: `CreatePopupMenu()` + `AppendMenuW()` + `TrackPopupMenu()`, displaying statistics, microphone selection, "Open Config Folder", "Launch at Login", "Quit".

### 4.9 Floating Status Panel (overlay.cpp)

macOS `NSPanel` maps to Windows layered window.

Window styles:

- `WS_EX_TOPMOST` — Always on top
- `WS_EX_LAYERED` — Per-pixel transparency support
- `WS_EX_TRANSPARENT` — Click-through
- `WS_EX_TOOLWINDOW` — Not shown in taskbar
- `WS_EX_NOACTIVATE` — Does not steal focus

Drawing: `UpdateLayeredWindow()` with 32-bit ARGB bitmap, GDI+ draws a pill-shaped background (70% black translucent), waveform/pulsing dots/text (Segoe UI font).

Position: Bottom center of primary monitor (`GetMonitorInfoW()`).

Animation: `SetTimer` at 33ms (30 FPS), consistent with macOS `kAnimInterval = 1.0/30.0`. Fade in/out via alpha value animation.

### 4.10 Audio Feedback (cue.cpp)

`PlaySoundW()` plays system sounds or embedded WAV resources. Maps macOS Tink/Pop/Basso to Windows DeviceConnect/DeviceDisconnect/SystemHand.

### 4.11 History (history.cpp)

Compiles the SQLite amalgamation (`sqlite3.c`) directly, using the same schema and logic as macOS. Cross-platform.

### 4.12 Permissions

The Windows permission model is much simpler than macOS:

- **Microphone**: Windows 10/11 has privacy settings; the system automatically prompts an authorization dialog on first use, no proactive request needed.
- **Keyboard hook**: No permission required (but antivirus software may intervene; code signing is recommended).
- **SendInput**: No permission required.
- **No UAC elevation needed**.

---

## 5. Build System

### 5.1 CMakeLists.txt

Automatically selects the corresponding Rust static library path based on the target architecture:

```cmake
cmake_minimum_required(VERSION 3.20)
project(Koe LANGUAGES CXX C)
set(CMAKE_CXX_STANDARD 17)

# Select Rust target from the -A flag (CMAKE_GENERATOR_PLATFORM)
if(CMAKE_GENERATOR_PLATFORM STREQUAL "ARM64")
    set(RUST_TARGET "aarch64-pc-windows-msvc")
else()
    set(RUST_TARGET "x86_64-pc-windows-msvc")
endif()

set(RUST_LIB_DIR ${CMAKE_SOURCE_DIR}/../target/${RUST_TARGET}/release)

add_executable(Koe WIN32 src/main.cpp src/app.cpp ...)

target_include_directories(Koe PRIVATE ${CMAKE_SOURCE_DIR}/../koe-core/target)
target_link_libraries(Koe PRIVATE
    ${RUST_LIB_DIR}/koe_core.lib
    ws2_32 userenv bcrypt ntdll advapi32 crypt32  # Rust runtime deps
    winmm ole32 shell32 gdiplus                   # Windows APIs
)
```

### 5.2 Makefile (KoeWin/)

```makefile
# ARM64 build
build-arm64: build-rust-arm64 build-cmake-arm64
build-rust-arm64:
    cargo build --manifest-path ../koe-core/Cargo.toml --release --target aarch64-pc-windows-msvc
build-cmake-arm64:
    cmake -B build-arm64 -S . -G "Visual Studio 17 2022" -A ARM64
    cmake --build build-arm64 --config Release

# x64 build
build-x64: build-rust-x64 build-cmake-x64
build-rust-x64:
    cargo build --manifest-path ../koe-core/Cargo.toml --release --target x86_64-pc-windows-msvc
build-cmake-x64:
    cmake -B build-x64 -S . -G "Visual Studio 17 2022" -A x64
    cmake --build build-x64 --config Release

# Build both architectures
build: build-arm64 build-x64
```

---

## 6. Development Workflow

### 6.1 Dual-Machine Collaboration

macOS and Windows each have Claude Code installed, synchronized via git. KoeApp and KoeWin are fully independent.

| Platform | Responsibility | Claude Code |
|----------|---------------|-------------|
| macOS | `koe-core/` development + `KoeApp/` maintenance | Yes |
| Windows (ARM64) | `koe-core/` development + `KoeWin/` development | Yes |

The Rust core (`koe-core/`) can be modified on either machine, synchronized via git. Each machine verifies compilation for its respective platform locally.

### 6.2 Windows Development Environment Setup

All tools are installed via `winget` from a PowerShell terminal.

#### 1. Git

```powershell
winget install Git.Git
```

#### 2. Rust Toolchain

```powershell
# Install rustup (automatically installs MSVC-edition Rust)
winget install Rustlang.Rustup

# Add dual-architecture targets
rustup target add x86_64-pc-windows-msvc
rustup target add aarch64-pc-windows-msvc
```

#### 3. Visual Studio 2022 Build Tools

```powershell
winget install Microsoft.VisualStudio.2022.BuildTools
```

After installation, open Visual Studio Installer and select:

- **"Desktop development with C++"** workload
- Individual component: **"MSVC v143 - VS 2022 C++ ARM64/ARM64EC build tools"**
- Individual component: **"MSVC v143 - VS 2022 C++ x64/x86 build tools"**

> For GUI debugging (breakpoints, render inspection), install the full Visual Studio 2022 Community instead:
> `winget install Microsoft.VisualStudio.2022.Community`

#### 4. CMake

```powershell
winget install Kitware.CMake
```

#### 5. LLVM/Clang (Required for ARM64 Rust builds)

```powershell
winget install LLVM.LLVM
```

The `ring` crate (dependency of `rustls`) requires `clang` for ARM64 assembly compilation. After installation, **add LLVM to the system PATH permanently**:

- Open Settings > System > About > Advanced system settings > Environment Variables
- Under "User variables", edit `Path` and add: `C:\Program Files\LLVM\bin`

Alternatively, set it per-session in PowerShell: `$env:Path += ";C:\Program Files\LLVM\bin"`

> Note: LLVM is only needed for ARM64 builds. x64-only builds do not require it.

#### 6. Make (Optional)

```powershell
winget install GnuWin32.Make
```

Installs to `C:\Program Files (x86)\GnuWin32\bin`. Add this to `Path` as well. This enables running `make build-arm64` etc. from the `KoeWin/` directory. Not required if you prefer running `cargo` and `cmake` commands directly.

#### 7. Node.js (Required for Claude Code)

```powershell
winget install OpenJS.NodeJS.LTS
npm install -g @anthropic-ai/claude-code
```

#### Summary

| Tool | Install Command | Purpose |
|------|----------------|---------|
| Git | `winget install Git.Git` | Version control |
| Rust | `winget install Rustlang.Rustup` | Compile koe-core to static library |
| VS Build Tools | `winget install Microsoft.VisualStudio.2022.BuildTools` | MSVC compiler + Windows SDK |
| CMake | `winget install Kitware.CMake` | Build system for KoeWin C++ shell |
| LLVM | `winget install LLVM.LLVM` | Clang for `ring` crate ARM64 assembly |
| Make | `winget install GnuWin32.Make` | Optional: `Makefile` convenience targets |
| Node.js | `winget install OpenJS.NodeJS.LTS` | Claude Code runtime |

#### 8. Verify Environment

```powershell
# Clone repository
git clone <repo-url> koe && cd koe

# Verify Rust compilation (ensure LLVM/bin is on PATH)
cargo build --manifest-path koe-core/Cargo.toml --target aarch64-pc-windows-msvc

# Verify CMake + MSVC
cd KoeWin
cmake -B build -S . -G "Visual Studio 17 2022" -A ARM64
cmake --build build --config Debug
```

### 6.3 Windows Local Build

- ARM64 native build (primary development/debugging):
  - `cargo build --release --target aarch64-pc-windows-msvc`
  - `cmake -B build -S KoeWin -G "Visual Studio 17 2022" -A ARM64`
  - Open `build/Koe.sln` in VS, F5 for native compile + debug
- x64 cross-build (verification):
  - `cargo build --release --target x86_64-pc-windows-msvc`
  - `cmake -B build-x64 -S KoeWin -G "Visual Studio 17 2022" -A x64`
  - ARM64 Windows can run x64 .exe via its built-in x86/x64 emulation layer

### 6.4 CI (GitHub Actions)

- Dual-architecture matrix build + release artifact packaging
- ARM64 via x64 runner cross-compilation (Rust `--target aarch64-pc-windows-msvc` + CMake `-A ARM64`)

---

## 7. Implementation Notes

### 7.1 UTF-8 / UTF-16 Conversion

The Rust core uses UTF-8 exclusively (`*const c_char`). Windows APIs use UTF-16 (`LPCWSTR`). Every FFI boundary requires `MultiByteToWideChar` / `WideCharToMultiByte` conversion.

### 7.2 Foreground Application Detection

macOS `frontmostApplication.bundleIdentifier` maps to Windows `GetForegroundWindow()` + `QueryFullProcessImageNameW()`. Used for logging only; does not affect behavior.

### 7.3 Antivirus Software

Low-level keyboard hooks may be flagged by antivirus software. Code signing is recommended. A `RegisterHotKey` fallback can be provided (but only supports key combinations like Ctrl+Shift+Space, not single-key hold/tap).

### 7.4 Distribution (Dual Architecture)

- Portable: `Koe-win-x64.zip` and `Koe-win-arm64.zip`, each containing a standalone .exe (SQLite statically linked).
- Installer: Inno Setup or WiX, either a single installer with architecture auto-detection or separate installers.
- "Launch at Login": Via registry `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`.
- ARM64 devices can run the x64 version via x86 emulation, but the native ARM64 version offers better performance and lower power consumption.

---

## 8. Implementation Phases

### Phase 1: Foundation — Rust Core + Skeleton

1. Modify `config_dir()` to support Windows.
2. Verify `cargo build --target x86_64-pc-windows-msvc` and `--target aarch64-pc-windows-msvc` both pass.
3. Create `KoeWin/` directory + CMakeLists.txt (supporting x64/ARM64 dual architecture).
4. Implement main.cpp (WinMain + message loop) + bridge.cpp (FFI callbacks).
5. Verify Rust core initializes and loads config on Windows.

### Phase 2: Core Functionality — End-to-End Voice Input

6. Implement audio.cpp (WASAPI capture + resampling).
7. Implement hotkey.cpp (keyboard hook + hold/tap state machine).
8. Implement clipboard.cpp + paste.cpp.
9. Implement cue.cpp.
10. End-to-end test: hotkey -> recording -> ASR -> LLM -> paste.

### Phase 3: GUI — System Tray + Floating Panel

11. Implement tray.cpp (system tray + animated icons + menu).
12. Implement overlay.cpp (layered window + animation).
13. Implement history.cpp (SQLite statistics).
14. Dark/light mode, DPI adaptation.

### Phase 4: Polish

15. Implement audio_device.cpp (microphone selection).
16. Config file monitoring.
17. Launch at login.
18. Code signing.
19. CI — GitHub Actions dual-architecture matrix.
20. Release two zips: `Koe-win-x64.zip`, `Koe-win-arm64.zip`.

## 9. Verification

1. `cargo build --target x86_64-pc-windows-msvc` and `--target aarch64-pc-windows-msvc` both compile successfully on Windows.
2. CMake builds with `-A x64` and `-A ARM64` both succeed, producing standalone .exe files.
3. System tray icon appears on launch; right-click menu functions correctly.
4. Hold Right Ctrl -> floating panel shows recording status -> release -> ASR -> LLM -> text pasted into Notepad.
5. Tap Right Ctrl to toggle recording (toggle mode).
6. Animated icons display correctly in recording/processing/success/error states.
7. Icon colors adapt under dark and light taskbars.
8. Microphone submenu lists available devices; selection persists across restarts.
