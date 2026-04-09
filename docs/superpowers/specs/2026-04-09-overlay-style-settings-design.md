# Overlay Style Settings and Long-Text Behavior

**Date:** 2026-04-10
**Status:** Implemented

## Overview

This change turns the bottom live transcript overlay into a configurable surface instead of a fixed hard-coded HUD.

Users can now control:

1. The font family used by the live transcript overlay.
2. The transcript text size.
3. The distance from the bottom of the screen.
4. Whether long live text is capped to a visible line count.
5. The visible line cap when limiting is enabled (`3`, `4`, or `5` lines).

All Overlay style changes are previewed through the real desktop overlay itself. The previous in-window mock preview was removed so Settings no longer maintains a second rendering path that can drift from runtime behavior.

## Problem

The original overlay implementation used a fixed visual style:

- `13pt` medium system font.
- `10pt` bottom margin.
- No user control over font family or visible line policy.
- No stable strategy for very long interim transcripts.

That caused two classes of issues:

- Accessibility and preference issues: some users needed larger text or a different font.
- Layout polish issues: long live text could grow awkwardly, feel cramped, or produce rough-looking clipping behavior.

## Goals

- Let users tune overlay typography without editing config files.
- Keep the runtime overlay horizontally centered at all times.
- Let users move the overlay vertically with a bottom-offset control.
- Support both compact and fully expanded long-text behavior.
- Keep the long-text experience visually polished, with stable scrolling when line limiting is enabled.
- Apply saved settings immediately without restarting the app.

## Non-Goals

- No freeform drag placement for the overlay.
- No horizontal position control.
- No per-state styling differences between recording, processing, and final result states.
- No custom overlay colors, blur themes, or border themes in this change.

## Final UX

### Settings Entry

The Settings window includes a dedicated `Overlay` pane with the `captions.bubble` symbol.

### Controls

The pane exposes these controls:

- `Font`
- `Text Size`
- `Distance from Bottom`
- `Limit Visible Lines`
- `Max Visible Lines`
- `Reset to Default`

### Preview Model

Overlay changes are previewed by showing the real desktop overlay with temporary unsaved values.

This keeps preview behavior aligned with runtime behavior for:

- font metrics
- bubble height
- bottom offset
- centered positioning
- long-text wrapping and scrolling

When the user closes Settings, cancels, or switches away from the Overlay pane, the temporary preview is dismissed and the configured appearance is restored.

## Long-Text Behavior

### Limited Mode

When `Limit Visible Lines` is enabled:

- The overlay keeps the full transcript text in memory.
- The visible viewport is capped to `3-5` lines.
- New content scrolls upward inside the bubble instead of overflowing the frame.
- The bubble height remains stable within the configured visible-line window.

This keeps the UI compact while preserving the full transcript for later model processing.

### Unlimited Mode

When `Limit Visible Lines` is disabled:

- The overlay expands to fit the full current live transcript.
- Text still wraps inside the bubble width and does not spill outside the bubble frame.

### Visual Polish

To avoid rough edges during long dictation:

- internal paddings scale with the active font line height
- bubble height is measured from actual text layout rather than fixed constants
- previous dark edge artifacts and fade masks were removed

## Runtime Layout Rules

The overlay frame remains horizontally centered:

- `x = midX(visibleFrame) - overlayWidth / 2`
- `y = minY(visibleFrame) + configuredBottomMargin`

The overlay width continues to grow based on text content up to the runtime maximum width.

When line limiting is enabled, the visible text viewport height is derived from the configured number of measured text lines. When line limiting is disabled, the bubble grows to the measured full text height.

## Configuration

Overlay settings are stored in `~/.koe/config.yaml`:

```yaml
overlay:
  font_family: "system"
  font_size: 13
  bottom_margin: 10
  limit_visible_lines: true
  max_visible_lines: 3
```

Rules:

- `font_family`
  - string
  - `"system"` uses the platform system font
- `font_size`
  - numeric
  - clamped to `12...28`
- `bottom_margin`
  - numeric
  - clamped to `0...180`
- `limit_visible_lines`
  - boolean
  - default `true`
- `max_visible_lines`
  - numeric
  - clamped to `3...5`

## Architecture Summary

### Rust

`koe-core/src/config.rs`

- adds `OverlaySection`
- adds defaults for font family, text size, bottom margin, and long-text settings
- includes overlay defaults in generated config text and tests

### Objective-C Runtime Overlay

`KoeApp/Koe/Overlay/SPOverlayPanel.{h,m}`

- loads overlay appearance from config
- exposes temporary preview APIs for Settings
- measures text height with TextKit-backed layout
- supports capped visible-line scrolling for long live transcripts
- recalculates padding and bubble geometry from the selected font

### Objective-C Settings UI

`KoeApp/Koe/SetupWizard/SPSetupWizardWindowController.m`

- adds the Overlay pane and controls
- lists available system font families
- pushes unsaved control values into the real overlay preview
- saves overlay config back to `config.yaml`

### App Delegate

`KoeApp/Koe/AppDelegate/SPAppDelegate.m`

- reloads overlay appearance after config saves
- reloads overlay appearance when config file changes are detected

## Result

The overlay now behaves like a configurable product surface instead of a fixed hard-coded component, while staying visually consistent with the live runtime experience.
