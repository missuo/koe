# Prompt Templates Selection Feature

**Date:** 2026-04-09
**Status:** Approved

## Overview

After the default LLM correction and auto-paste, the overlay stays visible and shows optional prompt template buttons. Users can press a number key (1-9) or click a button to rewrite the ASR text with a different prompt (e.g., translate, tweet style, Xiaohongshu style). The rewritten text is copied to clipboard (not auto-pasted).

## Flow

1. Default flow completes: ASR → LLM correction → auto-paste → Overlay shows corrected text
2. If `prompt_templates` are configured, Overlay expands to show a button row: `[1] 翻译  [2] 推文  [3] 小红书`
3. User can:
   - **Do nothing** → Overlay disappears after linger time (extended to 4s when templates are configured)
   - **Press number key 1-9** → Triggers rewrite with that template
   - **Click a button** → Same as pressing the number key
4. On rewrite trigger:
   - Overlay switches to "Rewriting..." (processing mode, blue)
   - Rust calls LLM with the template's system_prompt + ASR original text
   - Result is copied to clipboard
   - Overlay shows rewritten text + "Copied" indicator (green)
   - Overlay lingers then disappears

## Configuration

```yaml
prompt_templates:
  - name: "翻译为英文"
    shortcut: 1
    system_prompt: "将用户的语音输入翻译为流畅的英文。保持原意，不要添加额外内容。只输出翻译结果。"

  - name: "推文风格"
    shortcut: 2
    system_prompt: "将用户的语音输入改写为适合发 Twitter/X 的简短推文。280字符以内，可适当加emoji。只输出推文内容。"

  - name: "小红书风格"
    shortcut: 3
    system_prompt: "将用户的语音输入改写为适合小红书的帖子风格。加上合适的emoji和标题，语气活泼亲切。只输出帖子内容。"
```

Fields:
- `name`: Display name shown on button
- `shortcut`: Number key 1-9
- `system_prompt`: Inline system prompt text (mutually exclusive with `system_prompt_path`)
- `system_prompt_path`: Path to prompt file, relative to `~/.koe/` (optional, alternative to inline)

Max 9 templates. User prompt reuses the default `user_prompt.txt` template with `{{asr_text}}` placeholder. Dictionary entries and interim history are also passed.

## Architecture

### Rust Side

**Config** (`config.rs`):
- New `prompt_templates: Vec<PromptTemplate>` in top-level config
- `PromptTemplate { name, shortcut, system_prompt, system_prompt_path }`

**FFI** (`ffi.rs`):
- New callback: `on_rewrite_text_ready: Option<extern "C" fn(token: u64, text: *const c_char)>`
- New invoke: `invoke_rewrite_text_ready(token, text)`

**Core** (`lib.rs`):
- New FFI function: `sp_core_rewrite_with_template(template_index: i32, asr_text: *const c_char) -> i32`
  - Loads the template's system_prompt
  - Constructs LLM request with template's system_prompt + rendered user_prompt (using asr_text)
  - Uses the same LLM provider config (base_url, api_key, model, etc.)
  - Calls `invoke_rewrite_text_ready` with result
  - Returns 0 on success, -1 on error
- New FFI function: `sp_core_get_prompt_templates_json() -> *mut c_char`
  - Returns JSON array: `[{"name":"翻译","shortcut":1}, ...]`
  - ObjC calls this to know which templates to display

### ObjC Side

**SPOverlayPanel** — Major changes:
- New mode: `SPOverlayModeTemplateSelection` — shows corrected text + button row
- `ignoresMouseEvents` set to NO during template selection phase
- Button row: horizontal strip of rounded-rect buttons with `[N] Name` labels
- Hover highlight on buttons
- Click handler calls delegate method
- New delegate protocol for overlay interaction events

**SPHotkeyMonitor / AppDelegate**:
- During template selection phase, monitor NSEvent for number keys 1-9
- Route key press to trigger rewrite

**SPRustBridge**:
- Register `on_rewrite_text_ready` callback
- Add `rewriteWithTemplate:asrText:` method
- Add `promptTemplatesJSON` method
- New delegate method: `rustBridgeDidReceiveRewriteText:`

**SPAppDelegate**:
- Store `lastAsrText` from `rustBridgeDidReceiveAsrFinalText:` for rewrite use
- On template selection (from overlay click or number key):
  - Call `rustBridge.rewriteWithTemplate:asrText:`
  - Update overlay to "Rewriting..." state
- On rewrite text received:
  - Copy to clipboard (no auto-paste)
  - Update overlay with rewritten text + "Copied" indicator
  - Linger then dismiss

### Overlay Visual Design

**Template selection state:**
```
╭─────────────────────────────────────────────╮
│ ✓  校正后的文本显示在这里...                    │
│─────────────────────────────────────────────│
│  ❶ 翻译为英文    ❷ 推文风格    ❸ 小红书      │
╰─────────────────────────────────────────────╯
```

- Top: green checkmark + corrected text (existing success mode)
- Separator: 1px line
- Bottom: button row, 32pt height, buttons with 8pt corner radius
- Button style: semi-transparent white background (20%), white text, number prefix
- Hover: background brightens to 40%
- Active/pressed: background 50%

**Rewriting state:**
```
╭─────────────────────────────────────────────╮
│ ⟳  Rewriting... (翻译为英文)                  │
╰─────────────────────────────────────────────╯
```

**Rewrite complete:**
```
╭─────────────────────────────────────────────╮
│ ✓  Rewritten text here... (Copied)          │
╰─────────────────────────────────────────────╯
```

### Linger Timing

- When prompt_templates are configured: linger extended to `max(4.0, existing_linger)` seconds
- During rewrite processing: no auto-dismiss
- After rewrite complete: standard linger formula applies

## Files to Modify

| File | Changes |
|------|---------|
| `koe-core/src/config.rs` | Add `PromptTemplate` struct, `prompt_templates` field |
| `koe-core/src/ffi.rs` | Add `on_rewrite_text_ready` callback, `invoke_rewrite_text_ready` |
| `koe-core/src/lib.rs` | Add `sp_core_rewrite_with_template`, `sp_core_get_prompt_templates_json` |
| `koe-core/src/prompt.rs` | Add helper to load template system_prompt from inline or file |
| `KoeApp/Koe/Bridge/SPRustBridge.h/.m` | Add rewrite callback, delegate method, bridge methods |
| `KoeApp/Koe/Overlay/SPOverlayPanel.h/.m` | Add template selection mode, button drawing, click/hover handling, delegate protocol |
| `KoeApp/Koe/Hotkey/SPHotkeyMonitor.h/.m` | No changes (number key monitoring done via NSEvent in AppDelegate) |
| `KoeApp/Koe/AppDelegate/SPAppDelegate.m` | Store ASR text, handle template selection, number key monitoring, rewrite flow |
