# Relay — Keybinds Smart Recorder Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Replace the two-control keybind row (a recorder button plus a separate "Double Tap" menu) with a single smart recorder field per action that detects a chord, Fn alone, or a double-tapped modifier, plus a ✕ to clear. An unset action shows "Not set" instead of the misleading "A".

**Architecture:** The runtime `GlobalHotkeyManager` already handles all three `HotkeyDefinition` forms and its own double-tap window, and already ignores an action with no binding. So this is a Settings-UI + `AppModel` change only: add `removeHotkey(for:)`, make the recorder field optional-aware, fold double-tap detection into the recorder's own AppKit event handling, and drop the Double Tap menu.

**Tech Stack:** Swift 6 strict concurrency, SwiftUI + AppKit (`NSViewRepresentable` over an `NSButton`), Observation, XCTest, XcodeGen.

---

## Ground rules
- Work on `main`. No worktrees. One implementer at a time.
- Generate the project only via `xcodegen generate` if a file is added. Never hand-edit `Relay.xcodeproj`.
- Build zero warnings; suite `** TEST SUCCEEDED **`.
- No commit trailers. Plain messages.
- Do not change `GlobalHotkeyManager` — it already supports nil/removed actions and every definition form.

## Current state (read first)
- `Relay/App/Settings/KeybindsSettingsView.swift`: per action, a `HotkeyRecorder` (non-optional definition, defaults to `.chord(keyCode:0, modifiers:[])`) AND a `Menu("Double Tap")`. The recorder's `keyDown` records a chord; `flagsChanged == [.function]` records `modifierOnly(.function)`. The private `displayName` renders `.chord(keyCode:0, modifiers:[])` as "A".
- `Relay/App/AppModel.swift`: `setHotkey(_:for:)` with conflict detection. No remove path. `hotkeys` is `[HotkeyAction: HotkeyDefinition]`.
- `Relay/Domain/HotkeyDefinition.swift`: `.modifierOnly`, `.doubleTapModifier`, `.chord`; `HotkeyModifier` = command/option/control/shift/function.

## Task 1: AppModel.removeHotkey
**Files:** `Relay/App/AppModel.swift`; Test `RelayTests/App/AppModelTests.swift`.
- [ ] Add `func removeHotkey(for action: HotkeyAction)`: set `hotkeyConflictMessage = nil`, then `updateSettings { $0.hotkeys[action] = nil }`.
- [ ] Tests: after `removeHotkey`, `settings.hotkeys[action] == nil`; a previously set `hotkeyConflictMessage` is cleared. Green. Commit `feat(keybinds): add removeHotkey for clearing a shortcut`.

## Task 2: Single smart recorder field + clear + "Not set"
**Files:** `Relay/App/Settings/KeybindsSettingsView.swift`.
- [ ] Make `HotkeyRecorder` take an OPTIONAL `HotkeyDefinition?`. Drop the `?? .chord(keyCode:0, modifiers:[])` at the call site — pass `model.settings.hotkeys[action]`.
- [ ] The recorder button shows `definition?.displayName ?? "Not set"` when not recording.
- [ ] Add a ✕ button beside the recorder, enabled only when `model.settings.hotkeys[action] != nil`, calling `model.removeHotkey(for: action)`.
- [ ] Remove the `Menu("Double Tap")` block entirely.
- [ ] Update the footer copy to: "Click a shortcut to record. Double-tap a modifier (⌘ ⌥ ⌃ ⇧) to bind it. Fn can be recorded alone. ✕ clears. Hotkeys are listen-only, so keys such as Escape still reach the active app."
- [ ] Keep the conflict message row. Keep the per-tab smoke test green. Commit `feat(keybinds): single smart recorder field with clear`.

## Task 3: Double-tap detection in the recorder
**Files:** `Relay/App/Settings/KeybindsSettingsView.swift` (the private `HotkeyRecorderButton`).
- [ ] While `isRecording`, keep the existing paths: `keyDown` → `.chord(keyCode, modifiers)`; `flagsChanged == [.function]` → `.modifierOnly(.function)`.
- [ ] Add double-tap detection for the non-Fn modifiers ⌘ ⌥ ⌃ ⇧ via a small state machine over `flagsChanged`:
  - Transition empty → exactly one non-Fn modifier `M` (no key): if a release of the SAME `M` was seen within ~0.4s, `finish(with: .doubleTapModifier(M))`; else record `firstPressAt = now` for `M`.
  - Transition `{M}` → empty: record `releasedAt = now` for `M`.
  - Reset the state on any `keyDown` (that is a chord) and when a different modifier set appears.
  - Do NOT finish on a single modifier press — the user may be starting a chord. Only finish on `keyDown` (chord), Fn (modifierOnly), or a confirmed second press (double-tap).
- [ ] Fn stays single-press only (no Fn double-tap).
- [ ] Manual test — the NSEvent flow is not unit-testable. Build zero warnings. Commit `feat(keybinds): detect double-tap modifier in the recorder`.

## Acceptance (final check — orchestrator)
- [ ] Build zero warnings; full suite passes; `codesign --verify` passes.
- [ ] Manual: record a chord; record Fn alone; double-tap ⌘; clear with ✕ → field shows "Not set"; each binding persists across a settings reopen; duplicate bindings still show the conflict message.
- [ ] No transcript/text/audio/path/error strings added to any log/Diagnostics/overlay.
