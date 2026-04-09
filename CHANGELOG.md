# Changelog

All notable user-facing changes to Koe are documented here.

## 1.0.14 - 2026-04-09

### Added

- Added a full overlay lifecycle that now shows interim ASR text, final ASR text, corrected text, and optional post-processing actions without disappearing too early.
- Added a Templates settings pane for managing prompt templates, including add, remove, edit, reorder, and per-template visibility control.
- Added overlay rewrite templates with click, hover, and contextual `1-9` shortcuts for fast second-pass rewriting.
- Added configurable trigger modes so users can choose `hold` or `toggle`.
- Added custom shortcut recording for trigger shortcuts, including modifier combinations.

### Changed

- Simplified the hotkey model to a single trigger shortcut that handles both start and stop behavior.
- Standardized the settings experience so Controls, LLM, and Templates use more consistent native AppKit switches, segmented controls, spacing, and card surfaces.
- Reduced the built-in prompt template set to a minimal default starter template for English translation.
- Changed template rewrites to copy the rewritten result to the clipboard instead of auto-pasting it immediately.

### Fixed

- Fixed prompt template editor state sync so prompt content no longer leaks between rows or disappears when switching templates.
- Fixed overlay template visibility and prompt restoration when creating new templates and switching back to existing ones.
- Fixed number shortcut handling so `1-9` template shortcuts no longer leak digits into the focused app.
- Fixed recorded trigger combinations so modifier shortcuts no longer leak characters like `®` into the focused app.
- Fixed keyboard and mouse interaction polish for template buttons and overlay selection states.

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
