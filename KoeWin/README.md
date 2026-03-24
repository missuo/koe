# KoeWin

The Windows shell for [Koe](../README.md). A C++/Win32 native implementation that mirrors the macOS Objective-C shell, sharing the same Rust core (`koe-core`) via C FFI.

## How It Differs from macOS

| | macOS (KoeApp) | Windows (KoeWin) |
|---|---|---|
| Language | Objective-C | C++ / Win32 API |
| Audio capture | AVAudioEngine | WASAPI |
| Hotkey | CGEventTap (default: **Fn**) | WH_KEYBOARD_LL hook (default: **Right Ctrl**) |
| Clipboard + paste | NSPasteboard + CGEvent | Win32 Clipboard + SendInput |
| System tray | NSStatusBar | Shell_NotifyIcon |
| Floating panel | NSPanel | Layered window (WS_EX_LAYERED) |
| Icon drawing | NSBezierPath | GDI+ |
| Config directory | `~/.koe/` | `%APPDATA%\koe\` |
| Permissions | Microphone + Accessibility + Input Monitoring | Microphone only (auto-prompted) |

The Fn key is not available on Windows (intercepted by keyboard firmware). The default trigger key is **Right Ctrl**. Configurable alternatives: `left_ctrl`, `caps_lock`, `scroll_lock`.

## Build from Source

### Prerequisites

- Windows 10/11
- [Rust toolchain](https://rustup.rs/) with dual targets:
  ```powershell
  rustup target add x86_64-pc-windows-msvc
  rustup target add aarch64-pc-windows-msvc
  ```
- [Visual Studio 2022 Build Tools](https://visualstudio.microsoft.com/downloads/) with **"Desktop development with C++"** workload, including ARM64 and x64 MSVC build tools
- [CMake](https://cmake.org/) 3.20+
- [LLVM](https://llvm.org/) (required for ARM64 builds — the `ring` crate needs `clang` for assembly compilation)

### Build

```powershell
cd KoeWin

# ARM64
make build-arm64

# x64
make build-x64

# Both
make build
```

Or run the commands directly without Make:

```powershell
# Build Rust core (pick your target)
cargo build --manifest-path ../koe-core/Cargo.toml --release --target aarch64-pc-windows-msvc

# Build C++ shell
cmake -B build-arm64 -S . -G "Visual Studio 17 2022" -A ARM64
cmake --build build-arm64 --config Release
```

The output binary is at `build-arm64/Release/Koe.exe` (or `build-x64/Release/Koe.exe`).

### Dual Architecture

| Target | Rust target | CMake `-A` | Output |
|---|---|---|---|
| ARM64 | `aarch64-pc-windows-msvc` | `ARM64` | `build-arm64/Release/Koe.exe` |
| x64 | `x86_64-pc-windows-msvc` | `x64` | `build-x64/Release/Koe.exe` |

ARM64 devices can run the x64 build via emulation, but the native ARM64 build offers better performance and lower power consumption.

## Permissions

Windows requires only **microphone access**. The system prompts automatically on first use — no manual setup needed. Unlike macOS, no Accessibility or Input Monitoring permissions are required.

> Low-level keyboard hooks may be flagged by antivirus software. Code signing is recommended for distribution.

## Architecture

```
┌──────────────────────────────────────────────────────┐
│  Windows (C++ / Win32)                               │
│  ┌───────────┐ ┌──────────┐ ┌──────────────────────┐ │
│  │ Hotkey    │ │ Audio    │ │ Clipboard + Paste    │ │
│  │ LL Hook   │ │ WASAPI   │ │ SendInput Ctrl+V     │ │
│  └─────┬─────┘ └────┬─────┘ └──────────▲───────────┘ │
│        │             │                  │             │
│  ┌─────▼─────────────▼──────────────────┴───────────┐ │
│  │              Bridge (FFI + PostMessage)           │ │
│  └──────────────────┬───────────────────────────────┘ │
│                     │                                 │
│  ┌──────────────────┴────────┐  ┌─────────────────┐   │
│  │ System Tray + Overlay     │  │ History Store   │   │
│  │ (Shell_NotifyIcon + GDI+) │  │ (SQLite)        │   │
│  └───────────────────────────┘  └─────────────────┘   │
└──────────────────────┼────────────────────────────────┘
                       │ C ABI
┌──────────────────────▼────────────────────────────────┐
│  Rust Core (koe_core.lib)                             │
│  ┌──────────────┐ ┌────────┐ ┌──────────────────┐     │
│  │ ASR 2.0      │ │ LLM    │ │ Config + Dict    │     │
│  │ (WebSocket)  │ │ (HTTP) │ │ + Prompts        │     │
│  └──────────────┘ └────────┘ └──────────────────┘     │
└───────────────────────────────────────────────────────┘
```

## Source Layout

```
KoeWin/
  CMakeLists.txt
  Makefile
  src/
    main.cpp           # WinMain, hidden message window, message loop
    app.cpp/h          # Application coordinator
    bridge.cpp/h       # Rust FFI callbacks via PostMessage
    audio.cpp/h        # WASAPI capture, resample to 16kHz mono
    audio_device.cpp/h # MMDevice enumeration, registry persistence
    hotkey.cpp/h       # WH_KEYBOARD_LL hook, hold/tap state machine
    clipboard.cpp/h    # Backup/write/restore with sequence tracking
    paste.cpp/h        # SendInput Ctrl+V simulation
    cue.cpp/h          # PlaySound system audio feedback
    tray.cpp/h         # System tray, GDI+ animated icons, context menu
    overlay.cpp/h      # Layered window, GDI+ pill rendering, animations
    history.cpp/h      # SQLite session recording + aggregate stats
    sqlite3.c/h        # SQLite amalgamation (vendored)
```
