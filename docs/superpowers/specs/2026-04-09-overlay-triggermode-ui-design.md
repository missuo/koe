# Overlay Flow, Trigger Mode, and UI Modernization

**Date:** 2026-04-09
**Status:** Approved

## Overview

Three improvements to the Koe voice input experience:

1. **Overlay full-lifecycle display** — keep the overlay visible through ASR finalization and LLM correction, showing results to the user before dismissing.
2. **Trigger mode toggle** — add a config option and UI control to switch between "hold" (press-and-hold) and "toggle" (tap-to-start/stop) trigger modes.
3. **UI modernization** — redesign the Settings window panels in an Arc Browser-inspired style with card-based grouping. Start with Controls panel as pilot.

## 1. Overlay Full-Lifecycle Display

### Problem

After the user releases the trigger key, the overlay transitions through ASR/LLM states but never shows the actual recognized or corrected text. The overlay goes from interim ASR text directly to "Pasting..." and disappears. Users have no visibility into what was recognized or corrected.

### Design

#### Phase Timeline

| Phase | Indicator Color | Status Text | Content Area |
|-------|----------------|-------------|--------------|
| Recording | Red (#FF5252) | Listening... | Real-time ASR interim text (unchanged) |
| ASR finalizing | Orange (#FFC71C) | Recognizing... | Last interim text preserved |
| LLM correcting | Blue (#46C8FF) | Optimizing... | Final ASR text displayed |
| LLM complete | Green (#4DD74D) | Done | Corrected text displayed |
| Pasting + linger | Green (#4DD74D) | Done | Corrected text stays visible |
| Dismiss | — | — | Fade out |

#### Linger Duration

Dynamic based on character count of the final text:

```
linger_seconds = clamp(char_count * 0.03, 0.8, 2.5)
```

- < 27 chars: 0.8s
- 27-83 chars: 0.8s-2.5s (linear)
- > 83 chars: 2.5s cap

#### Implementation Changes

**Rust side (koe-core/src/lib.rs):**
- After ASR finalization completes, call a new FFI callback `invoke_asr_final_text(token, text)` to send the final ASR text to ObjC before starting LLM correction.
- After LLM correction completes, the existing `invoke_final_text_ready` continues to deliver the corrected text.

**ObjC side (SPRustBridge + SPAppDelegate):**
- Add `on_asr_final_text` callback to `SPCallbacks` struct.
- In `rustBridgeDidReceiveAsrFinalText:`, call `overlayPanel.updateInterimText(text)` so the ASR result is shown during the "Optimizing..." phase.
- In `rustBridgeDidReceiveFinalText:`, update the overlay with corrected text and set state to a new "done" state (green checkmark + text visible).
- After paste completes, start linger timer based on text length, then fade out.

**SPOverlayPanel:**
- Add `SPOverlayModeSuccess` variant that shows both checkmark and text content (currently success mode only shows "Pasting..." with no content text).
- Rename existing content display logic: `interimText` is shown during recording + ASR phases; after LLM, set it to the corrected text.
- Add `lingerAndDismiss:` method that waits N seconds then fades out.

## 2. Trigger Mode Toggle

### Problem

The hotkey monitor already supports both hold and tap modes (180ms threshold), but both are always active with no user control. Users may want to use only one mode.

### Design

#### Config

```yaml
hotkey:
  trigger_key: "fn"
  cancel_key: "left_option"
  trigger_mode: "hold"  # "hold" | "toggle"
```

Default: `"hold"` (current default behavior — press and hold to record).

#### Behavior

| Mode | Short press (< 180ms) | Long press (>= 180ms) |
|------|-----------------------|-----------------------|
| `hold` | Ignored (no action) | Start recording; release = stop |
| `toggle` | Tap to start; tap again to stop | Also starts recording; release = stop |

#### Implementation Changes

**Rust side (koe-core/src/config.rs):**
- Add `trigger_mode` field to hotkey config section, with `"hold"` default.
- Validate: must be `"hold"` or `"toggle"`.

**ObjC side (SPHotkeyMonitor):**
- Add `triggerMode` property (enum: `SPTriggerModeHold`, `SPTriggerModeToggle`).
- In `holdTimerFired()`: always proceed (both modes support hold).
- In `handleTriggerUp()` from `SPHotkeyStatePending` (short press): check mode.
  - `hold`: transition back to Idle, do not start recording.
  - `toggle`: transition to `SPHotkeyStateRecordingToggle`, call `hotkeyMonitorDidDetectTapStart`.
- SPAppDelegate reads config on launch and on config change, sets `hotkeyMonitor.triggerMode`.

**UI (SPSetupWizardWindowController):**
- Add `Trigger Mode` popup in Controls panel between Trigger Key and Cancel Key.
- Two items: "Hold (Press & Hold)" and "Toggle (Tap to Start/Stop)".
- Saves to `hotkey.trigger_mode`.

## 3. UI Modernization (Controls Panel Pilot)

### Problem

Current Settings UI uses traditional macOS Preferences style with label-left / control-right two-column layout. Feels dated compared to modern macOS apps.

### Design Direction

Arc Browser-inspired: light background, white rounded-corner card groups, clean separation, generous spacing.

#### Visual Spec

- **Window background:** Light gray (#F5F5F7)
- **Card background:** White (#FFFFFF)
- **Card corner radius:** 12pt
- **Card shadow:** None (rely on background contrast)
- **Card inner padding:** 16pt horizontal, 0pt vertical (rows handle their own padding)
- **Card outer margin:** 24pt from window edges, 16pt between cards
- **Row height:** 44pt
- **Row separator:** 1px line, color #E5E5EA, inset 16pt from left
- **Row label:** SF Pro Text 13pt regular, left-aligned, #1D1D1F
- **Row control:** Right-aligned within row
- **Group title:** SF Pro Text 12pt semibold, uppercase, #86868B, 8pt above card

#### Controls Panel Layout

```
Group: "TRIGGER"
  Row: Trigger Key       [NSPopUpButton]
  ---
  Row: Trigger Mode      [NSPopUpButton]
  ---
  Row: Cancel Key        [NSPopUpButton]

Group: "FEEDBACK SOUNDS"
  Row: Recording starts  [NSSwitch]
  ---
  Row: Recording stops   [NSSwitch]
  ---
  Row: Error occurs      [NSSwitch]
```

#### Implementation Approach

Create reusable helper methods for the card-based layout so other panels can adopt later:

- `cardViewWithRows:title:width:` — builds a card NSView with title and row subviews.
- `cardRow:control:` — builds a single row with label + control.
- `cardSeparator:` — builds a 1px separator line.

Existing checkboxes replaced with `NSSwitch` for a more modern look (available macOS 10.15+).

#### Migration Plan

1. **Phase 1 (this PR):** Controls panel only, plus shared card helpers.
2. **Phase 2 (future):** Migrate ASR, LLM, Dictionary, Prompt, About panels.

## Files to Modify

| File | Changes |
|------|---------|
| `koe-core/src/config.rs` | Add `trigger_mode` field |
| `koe-core/src/lib.rs` | Add `invoke_asr_final_text` callback, linger logic |
| `koe-core/src/ffi.rs` | Add `on_asr_final_text` to callbacks struct |
| `koe-core/src/session.rs` | No changes needed (states already exist) |
| `KoeApp/Koe/Bridge/SPRustBridge.h/.m` | Add `on_asr_final_text` callback, delegate method |
| `KoeApp/Koe/AppDelegate/SPAppDelegate.m` | Handle new callback, linger timer, trigger mode config |
| `KoeApp/Koe/Overlay/SPOverlayPanel.h/.m` | Show text in success mode, add `lingerAndDismiss:` |
| `KoeApp/Koe/Hotkey/SPHotkeyMonitor.h/.m` | Add `triggerMode` property, gate tap behavior |
| `KoeApp/Koe/SetupWizard/SPSetupWizardWindowController.m` | New card-based Controls panel, trigger mode UI |
