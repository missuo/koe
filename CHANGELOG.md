# Changelog

All notable user-facing changes to Koe are documented here.

## Unreleased

### Fixed

- **The live caption now always shows up over full-screen apps.** If you switched Spaces while the caption was still on screen — for example, it was lingering after a paste and you swiped into a full-screen app — macOS could leave it stuck on the previous Space. The next time you dictated, the caption was invisible until you switched windows. Koe now moves the caption (and the template buttons) to the Space you are on before showing it, and again whenever you switch Spaces while it is visible.

## 1.0.32 - 2026-08-31

### Fixed

- **Doubao IME no longer types everything twice.** 1.0.31's reconnection fix switched to the official IME app's identity, and under that identity the server reports each result in two parallel tracks — the full transcript so far, plus per-segment entries the IME app uses for its own display. Koe still parsed the reply the old way and joined both tracks together, so saying "你好" pasted "你好，你好". Koe now reads just the full-transcript track. This also handles the server retroactively fixing punctuation across sentence boundaries (an early "你好。" becomes "你好，" once you keep talking), which could have duplicated text a second way. If you use Doubao IME, this update is required: 1.0.30 and earlier can no longer connect at all, and 1.0.31 duplicates every utterance.

## 1.0.31 - 2026-08-29

### Fixed

- **The built-in Doubao IME speech recognizer works again.** It had stopped connecting. Device registration and the token fetch went through ByteDance hosts on the `snssdk.com` domain, which ad/tracking blocklists — and proxy rules like Surge or Clash — reject outright; and even when those hosts were reachable, recognition failed to start because the app key Koe used had been retired on the server. Koe now registers through the same endpoint the current Doubao IME app uses and authenticates with that app's current key, so it connects without needing any blocklist or proxy changes.

### Changed

- **Dictation can now be pasted into a different app than the one you started it in.** Before, if the frontmost app changed between starting dictation and the text being ready — for example, you triggered it from a terminal but wanted the result in a chat box — Koe left the text on the clipboard instead of pasting. It now pastes into whichever app is frontmost when the text is ready. (A leftover paste from an earlier session still cannot fire into a newer one.)

## 1.0.30 - 2026-08-08

### Fixed

- **The phantom key presses at quit are actually fixed this time — root cause found and proven.** Since the earliest releases, Koe's Input Monitoring permission check probed by creating a system event tap and then failed to destroy it properly, leaking one orphaned, enabled tap into WindowServer at every launch **and every time the status-bar menu was opened**. When Koe exited, WindowServer's cleanup of each orphaned tap emitted one synthetic modifier-key event indistinguishable from real hardware input — which other apps' hotkey detectors (dictation tools, screenshot utilities) treated as real presses. Live capture confirmed the mechanism exactly: an instance with four leaked taps emitted four phantom Fn events in the same millisecond at quit, and a build with the corrected teardown emitted none. The probe now invalidates its tap port, so no orphans are ever left behind. (The 1.0.29 change was aimed at the same symptom but at the wrong mechanism; its passive-listener architecture remains, as it is good hygiene regardless.)

## 1.0.29 - 2026-08-08

### Fixed

- **Quitting Koe should no longer trigger phantom key presses in other apps.** After long dictation sessions, quitting (or restarting for an update) could make other apps see key presses nobody made — a phantom Fn tap, or even another app's shortcut like a screenshot hotkey firing. The 1.0.21 mitigation kept Koe's keyboard listener in a passive mode that cannot cause this, but two features added in 1.0.22 — accepting the raw transcript with Return during LLM correction, and the template number shortcuts — quietly switched it back to an intercepting mode around every correction and every template window. Those keys are now captured through the system's hotkey facility instead, so the keyboard listener stays passive for its entire lifetime when the trigger is a modifier key (Fn, Option, …). The Return accept and number shortcuts work exactly as before.

## 1.0.28 - 2026-08-07

### Changed

- **The settings window has been redesigned.** Navigation moved from the top toolbar to a sidebar that groups the panes by what they configure (Recognition, Input, Text), and everything now sits on translucent cards floating over a soft diagonal gradient, in both light and dark. The window is also a fixed size instead of resizing itself to every pane, so the content no longer jumps when you switch sections — longer panes scroll — and Save/Cancel stay pinned at the bottom instead of scrolling away.
- **LLM correction is now off by default for new installs.** A fresh install had it switched on with no API key configured, so every dictation ended in an error until you set up a profile. Turn it on in Settings → LLM once a profile has credentials. Existing installs are untouched and keep whatever the setting was.

### Fixed

- The ASR connection test result is visible again for the providers with a short settings form (DoubaoIME, Apple Speech, WeType). The result line was positioned for the tallest form, so for these it was drawn past the bottom of the window and a failed test appeared to do nothing.
- The LLM profile list no longer clips the protocol subtitle under each profile name.

## 1.0.27 - 2026-08-07

### Added

- **Start and stop voice input from the status bar menu.** The menu's status section now has a toggle item, so dictation still works when the global hotkey is unavailable (another app grabbed the trigger key, Accessibility permission not granted yet, …). A menu-started session behaves exactly like a hotkey-started one — same overlay, ASR, correction and paste — and either input can end it: the trigger key stops a session the menu started, and the menu stops one the trigger key started.

## 1.0.26 - 2026-08-05

### Improved

- **WeType (On-Device) now streams live, low-latency results.** The offline model previously showed its transcript only after you stopped talking. It now uses the model's native KV-cache streaming to emit interim results while you speak (a fast, low-latency pass), then finalizes a full-quality transcript when you stop — so the overlay pill updates live like the cloud providers.

## 1.0.25 - 2026-08-05

### Added

- **WeType (On-Device) — a fully on-device Chinese voice input.** Reverse-engineered from WeChat Input Method's offline voice model and reimplemented in pure Rust: everything runs locally (no network, no account, no server round-trip), about 180 MB, faster than real-time on Apple Silicon. Pick "WeType (On-Device)" as your ASR provider and download the model once from Settings.

## 1.0.23 - 2026-07-19

### Fixed

- **Fixed DoubaoIME producing duplicated, ever-growing transcripts (regression in 1.0.22).** A change meant to fix the live-caption freeze after a speech pause assumed the server only sends per-segment text, but DoubaoIME responses often carry the full cumulative transcript — the committed-text prefix then doubled the output at every finalized segment. The change is reverted; DoubaoIME behaves as in 1.0.21 again (including the cosmetic caption-freeze quirk, which needs a different fix).

## 1.0.22 - 2026-07-19

### Added

- Added an LLM auto-paste toggle (`llm.auto_paste_processed_text`, on by default) in the LLM pane. When off, the processed text is copied to the clipboard and the overlay shows it with a "✓ Copied" badge instead of pasting into the focused app — for workflows where you want to review before inserting.
- While the LLM correction is running ("Thinking…"), you can now accept the raw ASR transcript immediately by pressing Return or clicking the overlay. The correction is cancelled and the raw text is delivered right away — useful when the correction is slow and the transcript is already good enough.

### Fixed

- The overlay pill no longer shows blank rows during voice input. Two causes fixed: the transcript document kept a stale (taller) height when the live transcript shrank, pinning the leftover space into view; and trailing whitespace/newlines in ASR or LLM output rendered as phantom empty lines.
- The live caption no longer freezes after a speech pause when a new sentence happens to begin with the same character as the previous one (DoubaoIME segment tracking).
- GLM and MiMo transcriptions no longer lose results at stream end: internal streaming state was reset between reads, which could drop the final transcript (and any updates buffered in the same network read) — most visible as a session ending with no text despite a successful recognition.

## 1.0.21 - 2026-07-16

### Fixed

- Further hardened the phantom-keypress-on-quit fix: the hotkey event tap now runs in listen-only mode whenever nothing needs to be consumed (which is all the time for modifier triggers like Fn or Option), upgrading to a consuming tap only while the template selector's number shortcuts are on screen. Quitting after long real-world use previously could still emit phantom Fn events from the long-lived consuming tap's teardown — listen-only taps demonstrably never do this.

## 1.0.20 - 2026-07-16

### Fixed

- Fixed a regression introduced in 1.0.19 where a quick tap of the trigger key (Fn, Option, …) started dictation and immediately ended it — the trigger only survived if held noticeably long. Fast taps now reliably start and stop recording.
- Trigger handling no longer freezes while a modal dialog (such as a Sparkle update prompt) is on screen.

## 1.0.19 - 2026-07-16

### Added

- The in-app update dialog now shows what changed in the new version: Sparkle appcast entries carry the release's changelog section as formatted release notes (effective for updates released from this version on).

### Fixed

- Fixed the long-standing phantom-keypress-on-quit bug: quitting Koe after a period of use could fire other apps' Fn/Globe hotkeys (screenshot tools, other dictation apps). The hotkey event tap ran on the main thread, so main-thread stalls (ASR finalization, pasting) could swallow in-flight modifier events; WindowServer then accumulated stale modifier state and flushed corrective Fn key events into the session when the tap was destroyed at quit. The tap now runs on a dedicated thread that never stalls, and it is torn down before any slow shutdown work. This also fixes real keystrokes being silently dropped for 1–2 seconds while Koe was quitting.
- Pending synthetic paste events are now cancelled on every termination path (Sparkle update relaunch, logout, shutdown), not just the status-bar Quit.

## 1.0.18 - 2026-07-16

### Added

- Added an optional "Press Return after paste" setting (`paste.auto_return`, off by default) in the Controls pane. When enabled, Koe presses Return automatically after the dictated text is pasted, so messages to chat-style apps (Claude Code, Codex, IM inputs) are sent hands-free the moment you release the trigger key.
- Added an experimental paste-ASR-first mode (`experimental.paste_asr_first`, off by default): the raw ASR text is pasted the moment recognition finishes, and the LLM correction is applied in place once it returns — eliminating the wait for correction. In-place replacement only happens when it is provably safe (same focused element, caret untouched, raw text still present); otherwise the raw text is left alone and the correction is delivered via the clipboard.
- The clipboard restoration delay after automatic paste is now configurable via `clipboard.restore_delay_ms` in `config.yaml` (default 1500, range 0–60000; 0 restores immediately after the paste completes). Both the normal paste flow and the experimental ASR-first flow honor the setting; invalid values fall back to 1500 with a warning without affecting other configuration.
- History now records the raw ASR transcript, the ASR provider, and whether LLM correction was actually applied, alongside the final text. Existing history databases are migrated in place.
- Added `koe dict suggest`, which mines dictionary candidates from the raw-ASR/corrected pairs in history: recurring corrections are ranked with proper nouns, acronyms, and camelCase terms first, shown with their misheard forms and an example sentence. Nothing is added automatically — confirm entries with `koe dict add <term>`.
- Added `koe benchmark <corpus-dir>`, which runs configured ASR providers over an audio corpus with reference transcripts and reports token error rate (WER/CER/mixed), latency, and real-time factor as Markdown or JSON. `koe transcribe` gains a `--provider` flag.

### Changed

- Reordered the built-in user prompt so stable dictionary context precedes per-request ASR content, improving exact-prefix cache reuse for compatible LLM providers when the rendered dictionary remains unchanged. Existing custom `user_prompt.txt` files are not overwritten.
- The Anthropic protocol now sends `cache_control` prompt-caching breakpoints on the system prompt and on the stable dictionary prefix of the user prompt, so Anthropic models benefit from prefix caching as well.

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
