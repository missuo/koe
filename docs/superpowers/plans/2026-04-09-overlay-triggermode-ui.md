# Overlay Flow, Trigger Mode & UI Modernization — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Improve the Koe voice input experience with (1) an overlay that shows ASR and LLM results through the full session lifecycle, (2) a configurable hold/toggle trigger mode, and (3) a modernized Arc Browser-style Controls panel.

**Architecture:** Changes span three layers — Rust core (new FFI callback + config field), ObjC bridge/app delegate (overlay lifecycle + trigger mode), and UI (card-based Controls panel). Each task is independent enough to build and test separately.

**Tech Stack:** Rust (koe-core), Objective-C (KoeApp), cbindgen (C header generation)

**Spec:** `docs/superpowers/specs/2026-04-09-overlay-triggermode-ui-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `koe-core/src/ffi.rs` | Modify | Add `on_asr_final_text` callback to `SPCallbacks`, add `invoke_asr_final_text()`, add `trigger_mode` to `SPHotkeyConfig` |
| `koe-core/src/lib.rs` | Modify | Call `invoke_asr_final_text()` after ASR finalization, expose `trigger_mode` in `sp_core_get_hotkey_config()` |
| `koe-core/src/config.rs` | Modify | Add `trigger_mode` field to `HotkeySection` |
| `koe-core/target/koe_core.h` | Regenerate | cbindgen auto-generates from Rust changes |
| `KoeApp/Koe/Bridge/SPRustBridge.h` | Modify | Add `rustBridgeDidReceiveAsrFinalText:` delegate method |
| `KoeApp/Koe/Bridge/SPRustBridge.m` | Modify | Add `bridge_on_asr_final_text` callback, register it |
| `KoeApp/Koe/Overlay/SPOverlayPanel.h` | Modify | Add `updateDisplayText:`, `lingerAndDismiss:` methods |
| `KoeApp/Koe/Overlay/SPOverlayPanel.m` | Modify | Allow interim text in non-recording states, add linger dismiss logic |
| `KoeApp/Koe/Hotkey/SPHotkeyMonitor.h` | Modify | Add `triggerMode` property enum |
| `KoeApp/Koe/Hotkey/SPHotkeyMonitor.m` | Modify | Gate tap behavior on `triggerMode` |
| `KoeApp/Koe/AppDelegate/SPAppDelegate.m` | Modify | Handle new ASR final text callback, linger timer, read trigger mode from config |
| `KoeApp/Koe/SetupWizard/SPSetupWizardWindowController.m` | Modify | Redesign Controls panel with card layout, add trigger mode popup |

---

## Task 1: Add `trigger_mode` to Rust Config

**Files:**
- Modify: `koe-core/src/config.rs:314-335` (HotkeySection)

- [ ] **Step 1: Add `trigger_mode` field to `HotkeySection`**

In `koe-core/src/config.rs`, add the field after `cancel_key`:

```rust
#[derive(Debug, Deserialize, Clone)]
pub struct HotkeySection {
    #[serde(
        default = "default_trigger_key",
        deserialize_with = "deserialize_string_or_int"
    )]
    pub trigger_key: String,

    #[serde(
        default = "default_cancel_key",
        deserialize_with = "deserialize_string_or_int"
    )]
    pub cancel_key: String,

    /// Trigger mode: "hold" (press-and-hold, default) or "toggle" (tap to start/stop).
    #[serde(default = "default_trigger_mode")]
    pub trigger_mode: String,
}
```

- [ ] **Step 2: Add the default function**

Add near the other default functions (search for `fn default_trigger_key`):

```rust
fn default_trigger_mode() -> String {
    "hold".into()
}
```

- [ ] **Step 3: Build and verify**

Run: `cargo build --manifest-path koe-core/Cargo.toml 2>&1 | tail -5`
Expected: Compiles successfully. Existing configs without `trigger_mode` will deserialize with `"hold"` default.

- [ ] **Step 4: Commit**

```bash
git add koe-core/src/config.rs
git commit -m "feat(config): add trigger_mode field to hotkey section"
```

---

## Task 2: Expose `trigger_mode` and `on_asr_final_text` in FFI

**Files:**
- Modify: `koe-core/src/ffi.rs:28-50` (SPCallbacks struct), `koe-core/src/ffi.rs:138-154` (SPHotkeyConfig struct)

- [ ] **Step 1: Add `on_asr_final_text` to `SPCallbacks`**

In `koe-core/src/ffi.rs`, add after the `on_interim_text` field (line 49):

```rust
pub struct SPCallbacks {
    pub on_session_ready: Option<extern "C" fn(token: u64)>,
    pub on_session_error: Option<extern "C" fn(token: u64, message: *const c_char)>,
    pub on_session_warning: Option<extern "C" fn(token: u64, message: *const c_char)>,
    pub on_final_text_ready: Option<extern "C" fn(token: u64, text: *const c_char)>,
    pub on_log_event: Option<extern "C" fn(level: c_int, message: *const c_char)>,
    pub on_state_changed: Option<extern "C" fn(token: u64, state: *const c_char)>,
    pub on_interim_text: Option<extern "C" fn(token: u64, text: *const c_char)>,
    /// Called when ASR finalization completes with the final recognized text,
    /// before LLM correction begins. Used to display ASR result in the overlay.
    pub on_asr_final_text: Option<extern "C" fn(token: u64, text: *const c_char)>,
}
```

- [ ] **Step 2: Add `invoke_asr_final_text` function**

Add after the existing `invoke_interim_text` function (around line 126):

```rust
pub fn invoke_asr_final_text(token: u64, text: &str) {
    let cb = CALLBACKS.lock().unwrap();
    if let Some(ref cbs) = *cb {
        if let Some(f) = cbs.on_asr_final_text {
            let c_text = CString::new(text).unwrap_or_default();
            f(token, c_text.as_ptr());
        }
    }
}
```

- [ ] **Step 3: Add `trigger_mode` to `SPHotkeyConfig`**

In `koe-core/src/ffi.rs`, add to the `SPHotkeyConfig` struct after `cancel_modifier_flag`:

```rust
pub struct SPHotkeyConfig {
    pub trigger_key_code: u16,
    pub trigger_alt_key_code: u16,
    pub trigger_modifier_flag: u64,
    pub cancel_key_code: u16,
    pub cancel_alt_key_code: u16,
    pub cancel_modifier_flag: u64,
    /// Trigger mode: 0 = hold (press-and-hold), 1 = toggle (tap to start/stop)
    pub trigger_mode: u8,
}
```

- [ ] **Step 4: Build and verify**

Run: `cargo build --manifest-path koe-core/Cargo.toml 2>&1 | tail -5`
Expected: Compiles successfully.

- [ ] **Step 5: Commit**

```bash
git add koe-core/src/ffi.rs
git commit -m "feat(ffi): add on_asr_final_text callback and trigger_mode to SPHotkeyConfig"
```

---

## Task 3: Wire FFI Changes in Rust Core (`lib.rs`)

**Files:**
- Modify: `koe-core/src/lib.rs:16` (import), `koe-core/src/lib.rs:565-587` (sp_core_get_hotkey_config), `koe-core/src/lib.rs:770-772` (after ASR finalization)

- [ ] **Step 1: Add `invoke_asr_final_text` to imports**

In `koe-core/src/lib.rs` line 16, add to the existing import:

```rust
    SPFeedbackConfig, SPHotkeyConfig, SPSessionContext, SPSessionMode,
```

No change needed here — `invoke_asr_final_text` is already accessible from the `ffi` module. Just make sure the function is `pub`.

- [ ] **Step 2: Call `invoke_asr_final_text` after ASR finalization**

In `koe-core/src/lib.rs`, after the ASR text is finalized (around line 770, after `session.asr_text = Some(asr_text.clone());`), add:

```rust
    // Store ASR text in session
    {
        let mut s = session_arc.lock().unwrap();
        if let Some(ref mut session) = *s {
            session.asr_text = Some(asr_text.clone());
        }
    }

    // Notify ObjC of the final ASR text so the overlay can display it
    // during the LLM correction phase.
    invoke_asr_final_text(session_token, &asr_text);

    // --- LLM Correction ---
```

- [ ] **Step 3: Expose `trigger_mode` in `sp_core_get_hotkey_config`**

In `koe-core/src/lib.rs`, modify `sp_core_get_hotkey_config()` (line 565) to include `trigger_mode`:

```rust
pub extern "C" fn sp_core_get_hotkey_config() -> SPHotkeyConfig {
    let global = CORE.lock().unwrap();
    if let Some(ref core) = *global {
        let params = core.config.hotkey.resolve();
        let mode = match core.config.hotkey.trigger_mode.as_str() {
            "toggle" => 1u8,
            _ => 0u8,
        };
        SPHotkeyConfig {
            trigger_key_code: params.trigger.key_code,
            trigger_alt_key_code: params.trigger.alt_key_code,
            trigger_modifier_flag: params.trigger.modifier_flag,
            cancel_key_code: params.cancel.key_code,
            cancel_alt_key_code: params.cancel.alt_key_code,
            cancel_modifier_flag: params.cancel.modifier_flag,
            trigger_mode: mode,
        }
    } else {
        SPHotkeyConfig {
            trigger_key_code: 63,
            trigger_alt_key_code: 179,
            trigger_modifier_flag: 0x00800000,
            cancel_key_code: 58,
            cancel_alt_key_code: 0,
            cancel_modifier_flag: 0x00000020,
            trigger_mode: 0,
        }
    }
}
```

- [ ] **Step 4: Build and verify**

Run: `cargo build --manifest-path koe-core/Cargo.toml 2>&1 | tail -5`
Expected: Compiles successfully.

- [ ] **Step 5: Regenerate C header**

Run: `cd koe-core && cbindgen --config cbindgen.toml --crate koe-core --output target/koe_core.h`
Verify the new header contains `on_asr_final_text` in `SPCallbacks` and `trigger_mode` in `SPHotkeyConfig`.

- [ ] **Step 6: Commit**

```bash
git add koe-core/src/lib.rs koe-core/target/koe_core.h
git commit -m "feat(core): emit asr_final_text callback and expose trigger_mode in hotkey config"
```

---

## Task 4: ObjC Bridge — Add `on_asr_final_text` Callback

**Files:**
- Modify: `KoeApp/Koe/Bridge/SPRustBridge.h:9-16` (delegate protocol)
- Modify: `KoeApp/Koe/Bridge/SPRustBridge.m:0-100` (callback functions and registration)

- [ ] **Step 1: Add delegate method to `SPRustBridge.h`**

Add after `rustBridgeDidReceiveInterimText:` (line 15):

```objc
@protocol SPRustBridgeDelegate <NSObject>
- (void)rustBridgeDidBecomeReady;
- (void)rustBridgeDidReceiveFinalText:(NSString *)text;
- (void)rustBridgeDidEncounterError:(NSString *)message;
- (void)rustBridgeDidReceiveWarning:(NSString *)message;
- (void)rustBridgeDidChangeState:(NSString *)state;
- (void)rustBridgeDidReceiveInterimText:(NSString *)text;
- (void)rustBridgeDidReceiveAsrFinalText:(NSString *)text;
@end
```

- [ ] **Step 2: Add C callback function in `SPRustBridge.m`**

Add after `bridge_on_interim_text` (around line 87):

```objc
static void bridge_on_asr_final_text(uint64_t token, const char *text) {
    NSString *txt = text ? [NSString stringWithUTF8String:text] : @"";
    id<SPRustBridgeDelegate> delegate = _bridgeDelegate;
    if (delegate) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (token != _currentSessionToken) return;
            [delegate rustBridgeDidReceiveAsrFinalText:txt];
        });
    }
}
```

- [ ] **Step 3: Register the callback**

Find where `SPCallbacks` is populated (search for `sp_core_register_callbacks` in SPRustBridge.m) and add the new field:

```objc
struct SPCallbacks callbacks = {
    .on_session_ready = bridge_on_session_ready,
    .on_session_error = bridge_on_session_error,
    .on_session_warning = bridge_on_session_warning,
    .on_final_text_ready = bridge_on_final_text_ready,
    .on_log_event = bridge_on_log_event,
    .on_state_changed = bridge_on_state_changed,
    .on_interim_text = bridge_on_interim_text,
    .on_asr_final_text = bridge_on_asr_final_text,
};
```

- [ ] **Step 4: Commit**

```bash
git add KoeApp/Koe/Bridge/SPRustBridge.h KoeApp/Koe/Bridge/SPRustBridge.m
git commit -m "feat(bridge): add on_asr_final_text callback and delegate method"
```

---

## Task 5: Overlay — Support Text Display in All Phases + Linger Dismiss

**Files:**
- Modify: `KoeApp/Koe/Overlay/SPOverlayPanel.h`
- Modify: `KoeApp/Koe/Overlay/SPOverlayPanel.m:302-367` (state handling), `KoeApp/Koe/Overlay/SPOverlayPanel.m:444-454` (hide)

- [ ] **Step 1: Add new methods to `SPOverlayPanel.h`**

```objc
@interface SPOverlayPanel : NSObject

- (instancetype)init;

/// Update displayed state. Same state strings as SPStatusBarManager.
- (void)updateState:(NSString *)state;

/// Update interim ASR text shown during recording.
- (void)updateInterimText:(NSString *)text;

/// Update display text shown during non-recording phases (ASR result, LLM result).
- (void)updateDisplayText:(NSString *)text;

/// Dismiss the overlay after a dynamic linger period based on text length.
- (void)lingerAndDismiss;

@end
```

- [ ] **Step 2: Remove recording-only gate on `updateInterimText`**

In `SPOverlayPanel.m`, the `updateInterimText:` method (line 362) currently returns early if not recording. We need a separate method for non-recording text. Rename the guard:

```objc
- (void)updateInterimText:(NSString *)text {
    if (![self.currentState hasPrefix:@"recording"]) return;
    self.contentView.interimText = text;
    [self resizeAndCenterAnimated:YES];
    [self.contentView setNeedsDisplay:YES];
}

- (void)updateDisplayText:(NSString *)text {
    self.contentView.interimText = text;
    [self resizeAndCenterAnimated:YES];
    [self.contentView setNeedsDisplay:YES];
}
```

- [ ] **Step 3: Add `lingerAndDismiss` method**

Add a property to track the linger timer in the `@interface` extension, then implement:

Add to the private interface (search for `@property` block in the `@interface SPOverlayPanel ()` extension):

```objc
@property (nonatomic, strong) NSTimer *lingerTimer;
```

Then add the method implementation:

```objc
- (void)lingerAndDismiss {
    [self.lingerTimer invalidate];
    self.lingerTimer = nil;

    // Dynamic linger: clamp(charCount * 0.03, 0.8, 2.5)
    NSString *displayText = self.contentView.interimText ?: self.contentView.statusText ?: @"";
    NSUInteger charCount = displayText.length;
    NSTimeInterval linger = fmin(fmax(charCount * 0.03, 0.8), 2.5);

    self.lingerTimer = [NSTimer scheduledTimerWithTimeInterval:linger
                                                      repeats:NO
                                                        block:^(NSTimer *timer) {
        self.lingerTimer = nil;
        self.sessionMaxWidth = 0;
        self.sessionMaxHeight = 0;
        [self hide];
        self.currentState = @"idle";
    }];
}
```

- [ ] **Step 4: Modify `updateState:` to not auto-hide on "completed"**

In `updateState:` (line 309), change the idle/completed handling so "completed" triggers linger instead of immediate hide. Actually, we won't use the "completed" state for this — the AppDelegate will call `lingerAndDismiss` directly. No change needed here.

- [ ] **Step 5: Cancel linger timer when a new session starts**

In `updateState:`, at the top of the method, add:

```objc
- (void)updateState:(NSString *)state {
    // Cancel any pending linger dismiss from a previous session
    [self.lingerTimer invalidate];
    self.lingerTimer = nil;

    self.currentState = state;
    [self stopAnimation];
    // ... rest of method unchanged
```

- [ ] **Step 6: Build and verify**

Run: `make build-lite 2>&1 | tail -5`
Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Commit**

```bash
git add KoeApp/Koe/Overlay/SPOverlayPanel.h KoeApp/Koe/Overlay/SPOverlayPanel.m
git commit -m "feat(overlay): add displayText and lingerAndDismiss for full-lifecycle display"
```

---

## Task 6: AppDelegate — Wire Overlay Full-Lifecycle + Trigger Mode

**Files:**
- Modify: `KoeApp/Koe/AppDelegate/SPAppDelegate.m:28-45` (applyHotkeyConfig), `334-369` (rustBridgeDidReceiveFinalText), `443-447` (rustBridgeDidChangeState)

- [ ] **Step 1: Implement `rustBridgeDidReceiveAsrFinalText:`**

Add this new delegate method in the `SPRustBridgeDelegate` section:

```objc
- (void)rustBridgeDidReceiveAsrFinalText:(NSString *)text {
    NSLog(@"[Koe] ASR final text: %lu chars", (unsigned long)text.length);
    [self.overlayPanel updateDisplayText:text];
}
```

- [ ] **Step 2: Modify `rustBridgeDidReceiveFinalText:` for linger behavior**

Replace the overlay-to-idle transition at the end of `rustBridgeDidReceiveFinalText:` with linger:

```objc
- (void)rustBridgeDidReceiveFinalText:(NSString *)text {
    if (self.quitting) return;
    NSLog(@"[Koe] Final text received (%lu chars)", (unsigned long)text.length);

    // Record history
    NSInteger durationMs = 0;
    if (self.recordingStartTime) {
        durationMs = (NSInteger)(-[self.recordingStartTime timeIntervalSinceNow] * 1000);
        self.recordingStartTime = nil;
    }
    [[SPHistoryManager sharedManager] recordSessionWithDurationMs:durationMs text:text];

    // Show corrected text in overlay before pasting
    [self.overlayPanel updateDisplayText:text];

    [self.statusBarManager updateState:@"pasting"];
    [self.overlayPanel updateState:@"pasting"];

    // Backup clipboard, write text, paste, restore
    [self.clipboardManager backup];
    [self.clipboardManager writeText:text];

    uint64_t token = self.rustBridge.currentSessionToken;

    if ([self.permissionManager isAccessibilityGranted]) {
        [self.pasteManager simulatePasteWithCompletion:^{
            [self.clipboardManager scheduleRestoreAfterDelay:1500];
            if (token != self.rustBridge.currentSessionToken) return;
            [self.statusBarManager updateState:@"idle"];
            // Don't immediately hide overlay — linger to show the result
            [self.overlayPanel lingerAndDismiss];
        }];
    } else {
        NSLog(@"[Koe] Accessibility not granted — text copied to clipboard only");
        [self.statusBarManager updateState:@"idle"];
        [self.overlayPanel lingerAndDismiss];
    }
}
```

- [ ] **Step 3: Update `rustBridgeDidChangeState:` to show ASR text during correcting phase**

The existing handler simply forwards state to overlay and status bar. The "correcting" state change from Rust will automatically update the overlay's status text and color (already handled in SPOverlayPanel.updateState). The ASR final text is set via `rustBridgeDidReceiveAsrFinalText:` which calls `updateDisplayText:`. No change needed here — the overlay will show the ASR text set by `updateDisplayText:` while the status label changes to "Thinking..." via `updateState:`.

However, we need to make sure `updateState:` does NOT clear the interimText when transitioning to "correcting" or "preparing_paste" phases. Currently line 307 clears it on every state change. Fix:

In `SPOverlayPanel.m`, modify `updateState:` to only clear interim text when starting a new recording:

```objc
- (void)updateState:(NSString *)state {
    [self.lingerTimer invalidate];
    self.lingerTimer = nil;

    self.currentState = state;
    [self stopAnimation];

    // Only clear display text when starting a new recording session
    if ([state hasPrefix:@"recording"]) {
        self.contentView.interimText = nil;
    }

    if ([state isEqualToString:@"idle"] || [state isEqualToString:@"completed"]) {
        // ... rest unchanged
```

- [ ] **Step 4: Apply trigger mode from config**

In `applyHotkeyConfig:restartMonitorIfNeeded:` (line 28), add trigger mode handling:

```objc
- (void)applyHotkeyConfig:(struct SPHotkeyConfig)hotkeyConfig restartMonitorIfNeeded:(BOOL)restartIfNeeded {
    BOOL changed = self.hotkeyMonitor.targetKeyCode != hotkeyConfig.trigger_key_code ||
                   self.hotkeyMonitor.altKeyCode != hotkeyConfig.trigger_alt_key_code ||
                   self.hotkeyMonitor.targetModifierFlag != hotkeyConfig.trigger_modifier_flag ||
                   self.hotkeyMonitor.cancelKeyCode != hotkeyConfig.cancel_key_code ||
                   self.hotkeyMonitor.cancelAltKeyCode != hotkeyConfig.cancel_alt_key_code ||
                   self.hotkeyMonitor.cancelModifierFlag != hotkeyConfig.cancel_modifier_flag ||
                   self.hotkeyMonitor.triggerMode != hotkeyConfig.trigger_mode;

    if (!changed) return;

    if (restartIfNeeded) {
        [self.hotkeyMonitor stop];
    }

    self.hotkeyMonitor.targetKeyCode = hotkeyConfig.trigger_key_code;
    self.hotkeyMonitor.altKeyCode = hotkeyConfig.trigger_alt_key_code;
    self.hotkeyMonitor.targetModifierFlag = hotkeyConfig.trigger_modifier_flag;
    self.hotkeyMonitor.cancelKeyCode = hotkeyConfig.cancel_key_code;
    self.hotkeyMonitor.cancelAltKeyCode = hotkeyConfig.cancel_alt_key_code;
    self.hotkeyMonitor.cancelModifierFlag = hotkeyConfig.cancel_modifier_flag;
    self.hotkeyMonitor.triggerMode = hotkeyConfig.trigger_mode;

    if (restartIfNeeded) {
        [self.hotkeyMonitor start];
    }
}
```

- [ ] **Step 5: Build and verify**

Run: `make build-lite 2>&1 | tail -5`
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add KoeApp/Koe/AppDelegate/SPAppDelegate.m KoeApp/Koe/Overlay/SPOverlayPanel.m
git commit -m "feat(app): wire overlay full-lifecycle display and trigger mode config"
```

---

## Task 7: Hotkey Monitor — Gate Tap on Trigger Mode

**Files:**
- Modify: `KoeApp/Koe/Hotkey/SPHotkeyMonitor.h:12-46`
- Modify: `KoeApp/Koe/Hotkey/SPHotkeyMonitor.m:313-335` (handleTriggerUp)

- [ ] **Step 1: Add `triggerMode` property to header**

In `SPHotkeyMonitor.h`, add after `holdThresholdMs`:

```objc
/// Trigger mode: 0 = hold (short press ignored), 1 = toggle (tap to start/stop).
@property (nonatomic, assign) uint8_t triggerMode;
```

- [ ] **Step 2: Gate tap in `handleTriggerUp`**

In `SPHotkeyMonitor.m`, modify `handleTriggerUp` (line 313):

```objc
- (void)handleTriggerUp {
    if (!self.running) return;
    NSLog(@"[Koe] Trigger UP (state=%ld)", (long)self.state);
    switch (self.state) {
        case SPHotkeyStatePending:
            [self cancelHoldTimer];
            if (self.triggerMode == 1) {
                // Toggle mode: short press starts recording
                self.state = SPHotkeyStateRecordingToggle;
                [self.delegate hotkeyMonitorDidDetectTapStart];
            } else {
                // Hold mode: short press is ignored
                self.state = SPHotkeyStateIdle;
            }
            break;

        case SPHotkeyStateRecordingHold:
            self.state = SPHotkeyStateIdle;
            [self.delegate hotkeyMonitorDidDetectHoldEnd];
            break;

        case SPHotkeyStateConsumeKeyUp:
            self.state = SPHotkeyStateIdle;
            break;

        default:
            break;
    }
}
```

- [ ] **Step 3: Build and verify**

Run: `make build-lite 2>&1 | tail -5`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add KoeApp/Koe/Hotkey/SPHotkeyMonitor.h KoeApp/Koe/Hotkey/SPHotkeyMonitor.m
git commit -m "feat(hotkey): gate tap-to-toggle on trigger_mode config"
```

---

## Task 8: UI — Modernized Controls Panel with Card Layout

**Files:**
- Modify: `KoeApp/Koe/SetupWizard/SPSetupWizardWindowController.m:723-822` (buildHotkeyPane)

- [ ] **Step 1: Add card layout helper methods**

Add these helper methods in the `// ─── UI Helpers` section (after `descriptionLabel:`):

```objc
// ─── Card Layout Helpers ───────────────────────────────────────────

/// Create a card view (white rounded rect) with a title and row views.
- (NSView *)cardWithTitle:(NSString *)title rows:(NSArray<NSView *> *)rows width:(CGFloat)width {
    CGFloat cardPad = 16.0;
    CGFloat rowHeight = 44.0;
    CGFloat separatorInset = 16.0;

    // Card content height
    CGFloat cardHeight = rows.count * rowHeight;
    // Title height
    CGFloat titleHeight = title.length > 0 ? 28.0 : 0.0;
    CGFloat totalHeight = titleHeight + cardHeight;

    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, totalHeight)];

    // Title label
    if (title.length > 0) {
        NSTextField *titleLabel = [NSTextField labelWithString:title.uppercaseString];
        titleLabel.font = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
        titleLabel.textColor = [NSColor colorWithRed:0.525 green:0.525 blue:0.557 alpha:1.0];
        titleLabel.frame = NSMakeRect(cardPad, cardHeight, width - 2 * cardPad, 20);
        [container addSubview:titleLabel];
    }

    // Card background
    NSView *card = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, cardHeight)];
    card.wantsLayer = YES;
    card.layer.backgroundColor = [NSColor whiteColor].CGColor;
    card.layer.cornerRadius = 12.0;
    [container addSubview:card];

    // Layout rows from top to bottom
    for (NSUInteger i = 0; i < rows.count; i++) {
        NSView *row = rows[i];
        CGFloat rowY = cardHeight - (i + 1) * rowHeight;
        row.frame = NSMakeRect(0, rowY, width, rowHeight);
        [card addSubview:row];

        // Add separator between rows (not after last)
        if (i < rows.count - 1) {
            NSView *sep = [[NSView alloc] initWithFrame:NSMakeRect(separatorInset, rowY, width - separatorInset, 1)];
            sep.wantsLayer = YES;
            sep.layer.backgroundColor = [NSColor colorWithRed:0.898 green:0.898 blue:0.918 alpha:1.0].CGColor;
            [card addSubview:sep];
        }
    }

    return container;
}

/// Create a single card row with a label on the left and a control on the right.
- (NSView *)cardRowWithLabel:(NSString *)label control:(NSView *)control {
    CGFloat rowHeight = 44.0;
    CGFloat pad = 16.0;
    NSView *row = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 100, rowHeight)];

    NSTextField *lbl = [NSTextField labelWithString:label];
    lbl.font = [NSFont systemFontOfSize:13 weight:NSFontWeightRegular];
    lbl.textColor = [NSColor colorWithRed:0.114 green:0.114 blue:0.122 alpha:1.0];
    lbl.frame = NSMakeRect(pad, (rowHeight - 20) / 2.0, 200, 20);
    [row addSubview:lbl];

    // Position control on the right side
    CGFloat controlW = control.frame.size.width;
    CGFloat controlH = control.frame.size.height;
    control.autoresizingMask = NSViewMinXMargin;
    // Will be repositioned when row frame is set; use a tag for width reference
    control.frame = NSMakeRect(row.frame.size.width - pad - controlW, (rowHeight - controlH) / 2.0, controlW, controlH);
    [row addSubview:control];

    return row;
}

/// Reposition right-aligned controls after the row frame is finalized.
- (void)finalizeCardRowLayout:(NSView *)card {
    CGFloat pad = 16.0;
    for (NSView *row in card.subviews) {
        if (![row isKindOfClass:[NSView class]] || row.subviews.count < 2) continue;
        for (NSView *sub in row.subviews) {
            if ([sub isKindOfClass:[NSPopUpButton class]] || [sub isKindOfClass:[NSSwitch class]]) {
                CGFloat controlW = sub.frame.size.width;
                CGFloat controlH = sub.frame.size.height;
                sub.frame = NSMakeRect(row.frame.size.width - pad - controlW,
                                       (row.frame.size.height - controlH) / 2.0,
                                       controlW, controlH);
            }
        }
    }
}
```

- [ ] **Step 2: Rebuild `buildHotkeyPane` with card layout**

Replace the entire `buildHotkeyPane` method:

```objc
- (NSView *)buildHotkeyPane {
    CGFloat paneWidth = 600;
    CGFloat cardWidth = paneWidth - 48; // 24pt margin each side
    CGFloat cardSpacing = 16.0;
    CGFloat topPad = 24.0;

    // ── Build controls ──
    // Trigger Key popup
    self.hotkeyPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 220, 26) pullsDown:NO];
    [self.hotkeyPopup addItemsWithTitles:@[
        @"Fn (Globe)",
        @"Left Option (\u2325)",
        @"Right Option (\u2325)",
        @"Left Command (\u2318)",
        @"Right Command (\u2318)",
        @"Left Control (\u2303)",
        @"Right Control (\u2303)",
    ]];
    [self.hotkeyPopup itemAtIndex:0].representedObject = @"fn";
    [self.hotkeyPopup itemAtIndex:1].representedObject = @"left_option";
    [self.hotkeyPopup itemAtIndex:2].representedObject = @"right_option";
    [self.hotkeyPopup itemAtIndex:3].representedObject = @"left_command";
    [self.hotkeyPopup itemAtIndex:4].representedObject = @"right_command";
    [self.hotkeyPopup itemAtIndex:5].representedObject = @"left_control";
    [self.hotkeyPopup itemAtIndex:6].representedObject = @"right_control";

    // Trigger Mode popup
    self.triggerModePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 220, 26) pullsDown:NO];
    [self.triggerModePopup addItemsWithTitles:@[
        @"Hold (Press & Hold)",
        @"Toggle (Tap to Start/Stop)",
    ]];
    [self.triggerModePopup itemAtIndex:0].representedObject = @"hold";
    [self.triggerModePopup itemAtIndex:1].representedObject = @"toggle";

    // Cancel Key popup
    self.cancelHotkeyPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 220, 26) pullsDown:NO];
    [self.cancelHotkeyPopup addItemsWithTitles:@[
        @"Fn (Globe)",
        @"Left Option (\u2325)",
        @"Right Option (\u2325)",
        @"Left Command (\u2318)",
        @"Right Command (\u2318)",
        @"Left Control (\u2303)",
        @"Right Control (\u2303)",
    ]];
    [self.cancelHotkeyPopup itemAtIndex:0].representedObject = @"fn";
    [self.cancelHotkeyPopup itemAtIndex:1].representedObject = @"left_option";
    [self.cancelHotkeyPopup itemAtIndex:2].representedObject = @"right_option";
    [self.cancelHotkeyPopup itemAtIndex:3].representedObject = @"left_command";
    [self.cancelHotkeyPopup itemAtIndex:4].representedObject = @"right_command";
    [self.cancelHotkeyPopup itemAtIndex:5].representedObject = @"left_control";
    [self.cancelHotkeyPopup itemAtIndex:6].representedObject = @"right_control";

    // ── Trigger card ──
    NSView *triggerCard = [self cardWithTitle:@"Trigger" rows:@[
        [self cardRowWithLabel:@"Trigger Key" control:self.hotkeyPopup],
        [self cardRowWithLabel:@"Trigger Mode" control:self.triggerModePopup],
        [self cardRowWithLabel:@"Cancel Key" control:self.cancelHotkeyPopup],
    ] width:cardWidth];

    // ── Feedback Sounds card ──
    self.startSoundCheckbox = [[NSSwitch alloc] initWithFrame:NSMakeRect(0, 0, 38, 22)];
    self.stopSoundCheckbox = [[NSSwitch alloc] initWithFrame:NSMakeRect(0, 0, 38, 22)];
    self.errorSoundCheckbox = [[NSSwitch alloc] initWithFrame:NSMakeRect(0, 0, 38, 22)];

    NSView *feedbackCard = [self cardWithTitle:@"Feedback Sounds" rows:@[
        [self cardRowWithLabel:@"Recording starts" control:self.startSoundCheckbox],
        [self cardRowWithLabel:@"Recording stops" control:self.stopSoundCheckbox],
        [self cardRowWithLabel:@"Error occurs" control:self.errorSoundCheckbox],
    ] width:cardWidth];

    // ── Layout ──
    CGFloat triggerH = triggerCard.frame.size.height;
    CGFloat feedbackH = feedbackCard.frame.size.height;
    CGFloat contentHeight = topPad + triggerH + cardSpacing + feedbackH + 56; // 56 for buttons

    NSView *pane = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, paneWidth, contentHeight)];
    pane.wantsLayer = YES;
    pane.layer.backgroundColor = [NSColor colorWithRed:0.961 green:0.961 blue:0.969 alpha:1.0].CGColor;

    CGFloat y = contentHeight - topPad;

    // Place trigger card
    y -= triggerH;
    triggerCard.frame = NSMakeRect(24, y, cardWidth, triggerH);
    [pane addSubview:triggerCard];
    [self finalizeCardRowLayout:[triggerCard.subviews objectAtIndex:1]]; // the card NSView

    // Place feedback card
    y -= cardSpacing + feedbackH;
    feedbackCard.frame = NSMakeRect(24, y, cardWidth, feedbackH);
    [pane addSubview:feedbackCard];
    [self finalizeCardRowLayout:[feedbackCard.subviews objectAtIndex:1]];

    // Save / Cancel buttons
    [self addButtonsToPane:pane atY:16 width:paneWidth];

    return pane;
}
```

- [ ] **Step 3: Add `triggerModePopup` property**

In the private `@interface SPSetupWizardWindowController ()` section, add:

```objc
@property (nonatomic, strong) NSPopUpButton *triggerModePopup;
```

- [ ] **Step 4: Update `loadValuesForPane:` for trigger mode**

Find the hotkey loading section in `loadValuesForPane:` (search for `kToolbarHotkey`) and add trigger mode loading:

```objc
    // Load trigger mode
    NSString *triggerMode = configGet(@"hotkey.trigger_mode");
    if ([triggerMode isEqualToString:@"toggle"]) {
        [self.triggerModePopup selectItemAtIndex:1];
    } else {
        [self.triggerModePopup selectItemAtIndex:0];
    }
```

- [ ] **Step 5: Update `saveConfig:` to save trigger mode**

Find where hotkey values are saved (search for `hotkey.trigger_key` in the save method) and add:

```objc
    // Save trigger mode
    NSString *triggerModeValue = [self.triggerModePopup selectedItem].representedObject ?: @"hold";
    configSet(@"hotkey.trigger_mode", triggerModeValue);
```

- [ ] **Step 6: Handle NSSwitch state for feedback sounds**

The old code used `NSButton` checkboxes (`state == NSControlStateValueOn`). `NSSwitch` uses the same `.state` property, so `loadValuesForPane:` and `saveConfig:` should work without changes, but verify:
- Load: `self.startSoundCheckbox.state = [configGet(@"feedback.start_sound") isEqualToString:@"true"] ? NSControlStateValueOn : NSControlStateValueOff;`
- Save: `configSet(@"feedback.start_sound", self.startSoundCheckbox.state == NSControlStateValueOn ? @"true" : @"false");`

Check that the existing load/save code is compatible with `NSSwitch`. `NSSwitch` inherits from `NSControl` and uses the same `state` property as `NSButton` checkbox, so it should be compatible.

- [ ] **Step 7: Build and verify**

Run: `make build-lite 2>&1 | tail -5`
Expected: BUILD SUCCEEDED.

- [ ] **Step 8: Test manually**

Launch the app: `open ~/Library/Developer/Xcode/DerivedData/Koe-*/Build/Products/Release/Koe.app`
Open Settings → Controls tab. Verify:
- Light gray background with white rounded cards
- "TRIGGER" card with 3 rows: Trigger Key, Trigger Mode, Cancel Key
- "FEEDBACK SOUNDS" card with 3 toggle switches
- Save/Cancel buttons at bottom

- [ ] **Step 9: Commit**

```bash
git add KoeApp/Koe/SetupWizard/SPSetupWizardWindowController.m
git commit -m "feat(ui): modernize Controls panel with Arc-style card layout and trigger mode"
```

---

## Task 9: Integration Test — Full Flow Verification

- [ ] **Step 1: Full rebuild**

```bash
make build-lite 2>&1 | tail -10
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 2: Launch and test overlay lifecycle**

Launch the app. Configure an ASR provider with valid credentials (or use DoubaoIME free mode). Press and hold the trigger key, speak a sentence, release.

Verify:
1. Overlay shows "Listening..." with red waveform during recording
2. After release, overlay shows "Recognizing..." with orange/blue dots
3. If LLM enabled: overlay shows "Thinking..." with purple dots, ASR text visible
4. After LLM: overlay shows "Pasting..." with green checkmark, corrected text visible
5. Overlay lingers for ~0.8-2.5s showing the final text, then fades out

- [ ] **Step 3: Test trigger mode**

Open Settings → Controls. Change Trigger Mode to "Toggle (Tap to Start/Stop)". Save.
- Tap the trigger key once → recording starts
- Tap again → recording stops, pipeline continues
- Switch back to "Hold" → short taps are ignored, only hold works

- [ ] **Step 4: Test card UI**

Verify Controls panel:
- Cards have 12pt corner radius, white background on light gray
- Row separators visible between items
- Controls right-aligned within rows
- NSSwitch toggles work for feedback sounds

- [ ] **Step 5: Final commit**

```bash
git add -A
git commit -m "chore: integration verification for overlay flow, trigger mode, and UI updates"
```
