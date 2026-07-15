# Changelog

All notable user-facing changes to Koe are documented here.

## Unreleased

### Changed

- Reordered the built-in user prompt so stable dictionary context precedes per-request ASR content, improving exact-prefix cache reuse for compatible LLM providers when the rendered dictionary remains unchanged. Existing custom `user_prompt.txt` files are not overwritten.

## 1.0.17 - 2026-07-14

### Added

- Added an optional setting to mute system audio while recording (off by default). When enabled, other apps' playback is silenced for the duration of the capture so it neither distracts the speaker nor bleeds into the microphone. The exact device is restored on stop (including app quit while recording), and a device the user had already muted is left untouched.
- Release builds are now signed with a Developer ID certificate and notarized by Apple, so Gatekeeper opens them without warnings.
- Switched in-app updates to Sparkle: updates now download, verify (EdDSA-signed), and install in place instead of opening a browser download.
- Added a `double_tap` trigger mode that starts dictation on a double tap and
  stops it on the next single tap, with protection against treating normal
  Command-key shortcuts as trigger taps.
- Added protocol-specific LLM profiles: in addition to OpenAI Chat Completions, profiles can now target the OpenAI Responses API and the Anthropic Messages API.

### Fixed

- Fixed text clipping and overflow across the settings window (measured label widths, multi-line re-measure, growing test-result labels, ASR pane alignment) and clamped the overlay template button bar to the screen width near display edges.
- Dropped the redundant first-launch alerts for Accessibility and Input Monitoring — macOS shows its own prompt, and the status bar menu already offers grant actions.

### Changed

- Renamed the build variants: the former lite build is now the standard **Koe** app (what most users should install), and the former full build is now **Koe MLX** (adds on-device MLX model support). Both keep the same bundle identifier and update on their own Sparkle channels.
- Upgraded all dependencies: mlx-swift 0.30.6 → 0.31.6, mlx-swift-lm 2.30.6 → 3.31.4, mlx-audio-swift pinned to v0.1.3 (was an unpinned `main` branch that had drifted into a version conflict), and all Rust crates refreshed to their latest semver-compatible versions.
- Start prepared microphone hardware on the initial trigger-down and retain a
  short hold-mode pre-roll, reducing Bluetooth headset activation delay without
  keeping the microphone active while Koe is idle.

### Removed

- Removed the x86_64 (Intel) build target; Koe is Apple Silicon only.

## 1.0.14 - 2026-04-09

### Added

- Added a full overlay lifecycle that now shows interim ASR text, final ASR text, corrected text, and optional post-processing actions without disappearing too early.
- Added an Overlay settings pane for choosing the live transcript font family, text size, bottom offset, and long-text visibility rules.
- Added a Templates settings pane for managing prompt templates, including add, remove, edit, reorder, and per-template visibility control.
- Added overlay rewrite templates with click, hover, and contextual `1-9` shortcuts for fast second-pass rewriting.
- Added configurable trigger modes so users can choose `hold` or `toggle`.
- Added custom shortcut recording for trigger shortcuts, including modifier combinations.
- Added inline character-level diff animation for text correction transitions — deleted chars fade out in soft red, inserted chars highlight in blue-lavender, and adjacent delete+insert pairs merge into clean replacements before settling to the final text.
- Added automatic overlay dismissal on any key press (except template shortcuts `1-9`) after text is pasted, so users can continue typing without the overlay lingering.

### Changed

- Changed Overlay settings to preview directly in the real desktop overlay position instead of maintaining a second in-window mock preview.
- Changed long live transcript rendering so the overlay can either stay capped to `3-5` visible lines or expand fully, depending on user preference.
- Changed overlay spacing, corner radius, and text layout to scale with the selected font for a more consistent appearance.
- Simplified the hotkey model to a single trigger shortcut that handles both start and stop behavior.
- Standardized the settings experience so Controls, LLM, and Templates use more consistent native AppKit switches, segmented controls, spacing, and card surfaces.
- Reduced the built-in prompt template set to a minimal default starter template for English translation.
- Changed template rewrites to copy the rewritten result to the clipboard instead of auto-pasting it immediately.
- Changed ASR test result messages from Chinese to English to match the overall UI language.
- Changed overlay preview sample text to a more natural conversational example.

### Fixed

- Fixed long interim transcript overflow so capped overlays now scroll within the bubble instead of spilling outside the frame.
- Fixed overlay edge artifacts during long-text scrolling, including dark bands and fade masks that obscured text near the bubble edges.
- Fixed overlay preview cleanup so unsaved style changes no longer leak after closing Settings or switching panes.
- Fixed prompt template editor state sync so prompt content no longer leaks between rows or disappears when switching templates.
- Fixed overlay template visibility and prompt restoration when creating new templates and switching back to existing ones.
- Fixed number shortcut handling so `1-9` template shortcuts no longer leak digits into the focused app.
- Fixed recorded trigger combinations so modifier shortcuts no longer leak characters like `®` into the focused app.
- Fixed keyboard and mouse interaction polish for template buttons and overlay selection states.
- Fixed overlay blocking clicks on the app underneath during linger/dismiss by keeping the main panel click-through at all times.
- Fixed template editor silently converting file-backed prompts (`system_prompt_path`) to inline prompts — edits are now written back to the referenced file.
- Fixed diff animation performance for long transcriptions by adding a 500-character threshold (falls back to crossfade) and replacing O(n²) backtracking with O(n) reverse.
- Fixed ASR test result label being hidden behind configuration fields — now displayed inline next to the Test button.
- Fixed Save button closing the settings window — Save now only persists changes, users close via the window's close button.

### Contributors

- Vincent Yang
- luolei

## 1.0.13 - 2026-04-05

### Added

- Added Apple Speech provider for zero-config on-device ASR on macOS 26+.
- Added custom HTTP headers support for third-party ASR WebSocket endpoints.
- Added `no_reasoning_control` for LLM providers that need reasoning/thinking suppression.

### Fixed

- Fixed repeated accessibility permission prompts and added direct grant actions from the menu.
- Fixed clipboard restore behavior when the pre-dictation clipboard was empty.
- Fixed state machine races between Rust and Objective-C after text delivery.
- Fixed audio capture startup failures and session startup error handling.
- Fixed the hotkey race window between menu close and quit.
- Reduced privacy exposure by redacting transcription text from INFO logs.
- Hardened config writes with atomic file replacement.
- Centralized workspace dependencies for more consistent builds.
