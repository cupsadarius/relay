# Relay Phase 1.6 — Settings Remodel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restructure the single-`Form` settings pane into four native macOS toolbar tabs (Keybinds, Dictation, TTS, Security & Permissions), splitting the large `SettingsView.swift` into focused per-tab files, with zero behavior change.

**Architecture:** Replace the one `Form` in `Relay/App/SettingsView.swift` with a `TabView` whose four tabs each carry `.tabItem { Label(...) }` (the standard Preferences toolbar-tab look). Each tab is its own `View` struct in `Relay/App/Settings/`, taking `@Bindable var model: AppModel`. Controls, bindings, and helper views move verbatim next to the tab that uses them. No change to `AppModel`, `AppSettings`, persistence, or any backend.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI + AppKit, XcodeGen, XCTest, macOS 14+.

**Spec:** `docs/superpowers/specs/2026-09-15-relay-settings-remodel-and-kokoro-tts-design.md`

---

## Ground rules for the implementer

- Work on `main` directly. No worktrees.
- Generate the Xcode project only via `project.yml` + `xcodegen generate`. Never edit `Relay.xcodeproj` by hand. XcodeGen's `sources: path: Relay` glob is recursive, so new files under `Relay/App/Settings/` are picked up automatically after `xcodegen generate`.
- Do not commit `HANDOVER.md` (intentionally untracked).
- Commit trailers on every commit:
  ```
  Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01ACV8BiPqWH9ioEVQF8fouE
  ```
- Build/test command (run from repo root):
  ```
  xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -derivedDataPath .derived-data test
  ```
- This phase is a pure refactor. The correctness bar is: **the build succeeds, the full existing suite stays green, and every control keeps its exact current binding, label, and action.** After each extraction, diff the moved code against the original to confirm it is byte-for-byte the same logic (only the enclosing `struct`/`Section` wrapper changes).

## File structure (end state)

- Create `Relay/App/Settings/SettingsView.swift` — the `TabView` container only. (Replaces the current `Relay/App/SettingsView.swift`.)
- Create `Relay/App/Settings/KeybindsSettingsView.swift` — Global Hotkeys section, plus the `HotkeyRecorder` `NSViewRepresentable`, the `HotkeyRecorderButton` `NSButton`, and the `HotkeyDefinition`/`HotkeyModifier` private extensions.
- Create `Relay/App/Settings/DictationSettingsView.swift` — Mode picker, Speech Recognition section (`speechBackendRow`, `speechBackendActionView`, `speechBackendStatusLabel`), Activity Overlay section, and the `DictationMode.title` private extension.
- Create `Relay/App/Settings/TTSSettingsView.swift` — Speech section (Voice picker + rate slider), the `voices` list, `voiceBinding`, `rateBinding`.
- Create `Relay/App/Settings/PermissionsSettingsView.swift` — Permissions section and `permissionRow`.
- Delete `Relay/App/SettingsView.swift` (its contents are distributed to the files above).
- Create `RelayTests/App/SettingsViewsSmokeTests.swift` — a light test that each tab view initializes against a test `AppModel`.

Each tab view owns the bindings and helpers only it uses, so no shared helper file is needed. If, while extracting, you find a helper used by two tabs, put it in a new `Relay/App/Settings/SettingsControls.swift` rather than duplicating it — but the current code has no such overlap.

---

## Task 1: Create the `Settings/` folder with the TTS tab (smallest, self-contained)

Start with the TTS tab because it is the smallest and has no AppKit dependency, proving the extraction pattern before the larger tabs.

**Files:**
- Create: `Relay/App/Settings/TTSSettingsView.swift`

- [ ] **Step 1: Create `TTSSettingsView.swift`** with the Speech section moved verbatim into its own `Form`:

```swift
import AVFoundation
import SwiftUI

struct TTSSettingsView: View {
    @Bindable var model: AppModel
    private let voices = AVSpeechSynthesisVoice.speechVoices().sorted {
        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }

    var body: some View {
        Form {
            Section("Speech") {
                Picker("Voice", selection: voiceBinding) {
                    Text("System Default").tag(nil as String?)
                    ForEach(voices, id: \.identifier) { voice in
                        Text("\(voice.name) — \(voice.language)")
                            .tag(voice.identifier as String?)
                    }
                }

                HStack {
                    Slider(value: rateBinding, in: 0.1...1.0, step: 0.05)
                    Text(model.settings.ttsRate, format: .number.precision(.fractionLength(2)))
                        .monospacedDigit()
                        .frame(width: 38, alignment: .trailing)
                }
                .accessibilityLabel("Speech rate")
            }
        }
        .formStyle(.grouped)
    }

    private var voiceBinding: Binding<String?> {
        Binding(
            get: { model.settings.ttsVoiceIdentifier },
            set: { model.setVoiceIdentifier($0) }
        )
    }

    private var rateBinding: Binding<Double> {
        Binding(
            get: { Double(model.settings.ttsRate) },
            set: { model.setSpeechRate(Float($0)) }
        )
    }
}
```

Note: `.formStyle(.grouped)` gives each per-tab `Form` the standard grouped appearance inside a tab. Keep it consistent across all four tab views.

- [ ] **Step 2: Do not wire it yet.** It is unreferenced until Task 5. Leave `Relay/App/SettingsView.swift` untouched so the app still builds. (Swift allows an unused `struct`.)

- [ ] **Step 3: Regenerate and build**

Run: `xcodegen generate && xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -derivedDataPath .derived-data build`
Expected: `** BUILD SUCCEEDED **` (the new file compiles alongside the old view).

- [ ] **Step 4: Commit**

```bash
git add Relay/App/Settings/TTSSettingsView.swift Relay.xcodeproj/project.pbxproj
git commit -m "refactor(settings): extract TTS tab view"
```

---

## Task 2: Extract the Permissions tab

**Files:**
- Create: `Relay/App/Settings/PermissionsSettingsView.swift`

- [ ] **Step 1: Create `PermissionsSettingsView.swift`** with the Permissions section and `permissionRow` moved verbatim:

```swift
import SwiftUI

struct PermissionsSettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("Permissions") {
                permissionRow(
                    title: "Microphone",
                    granted: model.microphonePermissionGranted,
                    request: { Task { await model.requestMicrophonePermission() } },
                    settings: { model.openPrivacySettings(.microphone) }
                )
                permissionRow(
                    title: "Accessibility",
                    granted: model.permissionSnapshot.accessibilityGranted,
                    settings: { model.openPrivacySettings(.accessibility) }
                )
                Button("Request Accessibility") { model.requestPermissions() }
                    .controlSize(.small)
            }
        }
        .formStyle(.grouped)
    }

    private func permissionRow(
        title: String,
        granted: Bool,
        request: (() -> Void)? = nil,
        settings: @escaping () -> Void
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(granted ? "Allowed" : "Required")
                .foregroundStyle(granted ? .green : .orange)
            if !granted {
                if let request { Button("Allow", action: request) }
                Button("Open Settings", action: settings)
            }
        }
    }
}
```

- [ ] **Step 2: Regenerate and build**

Run: `xcodegen generate && xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -derivedDataPath .derived-data build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Relay/App/Settings/PermissionsSettingsView.swift Relay.xcodeproj/project.pbxproj
git commit -m "refactor(settings): extract Permissions tab view"
```

---

## Task 3: Extract the Dictation tab

This tab holds the Mode picker, the Speech Recognition backend list (with its three helpers), and the Activity Overlay style.

**Files:**
- Create: `Relay/App/Settings/DictationSettingsView.swift`

- [ ] **Step 1: Create `DictationSettingsView.swift`.** Move, verbatim, from `SettingsView`: the `Dictation`, `Speech Recognition`, and `Activity Overlay` sections; the helpers `speechBackendRow`, `speechBackendActionView(_:)`, `speechBackendStatusLabel(_:)`; the `dictationModeBinding` and `activityOverlayStyleBinding`; and the private `DictationMode.title` extension. Structure:

```swift
import SwiftUI

struct DictationSettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("Dictation") {
                Picker("Mode", selection: dictationModeBinding) {
                    ForEach(DictationMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
            }

            Section("Speech Recognition") {
                ForEach(model.sttBackends) { backend in
                    speechBackendRow(backend)
                }
                if let message = model.speechBackendMessage {
                    Text(message)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("speech-backend-message")
                }
                Text("Relay tries enabled backends in order and falls back to the next one. Parakeet runs fully on-device after a one-time model download (about 1 GB).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Activity Overlay") {
                Picker("Style", selection: activityOverlayStyleBinding) {
                    Text("Off").tag(ActivityOverlayStyle.off)
                    Text("Minimal").tag(ActivityOverlayStyle.minimal)
                    Text("Interactive").tag(ActivityOverlayStyle.interactive)
                }
                .pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped)
    }

    // Move speechBackendRow, speechBackendActionView, speechBackendStatusLabel,
    // dictationModeBinding, activityOverlayStyleBinding here VERBATIM from the old SettingsView.
}

// Move the private `extension DictationMode { var title... }` here verbatim.
```

Copy the three `speechBackend*` helpers and the two bindings exactly as they are in the current `SettingsView.swift` (lines 117–184, 218–223, 225–230). Do not change their logic.

- [ ] **Step 2: Regenerate and build**

Run: `xcodegen generate && xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -derivedDataPath .derived-data build`
Expected: `** BUILD SUCCEEDED **`. If you get a "redeclaration" error for `DictationMode.title`, it is still declared in the old `SettingsView.swift`; that is expected until Task 5 removes it. To keep the build green in the interim, temporarily leave the old `SettingsView.swift` as the sole owner of shared private extensions and only move section BODIES in Tasks 1–4, then move the extensions in Task 5. (Simpler: perform Tasks 3, 4, and 5 as one commit if interim redeclaration is unavoidable — see Task 5 note.)

- [ ] **Step 3: Commit**

```bash
git add Relay/App/Settings/DictationSettingsView.swift Relay.xcodeproj/project.pbxproj
git commit -m "refactor(settings): extract Dictation tab view"
```

---

## Task 4: Extract the Keybinds tab

This tab holds the Global Hotkeys section and all its AppKit machinery.

**Files:**
- Create: `Relay/App/Settings/KeybindsSettingsView.swift`

- [ ] **Step 1: Create `KeybindsSettingsView.swift`.** Move verbatim: the `Global Hotkeys` section body; the private `HotkeyRecorder` `NSViewRepresentable` (lines 233–248); the private `HotkeyRecorderButton` `NSButton` (lines 250–314); the private `HotkeyDefinition` extension (`displayName` + `keyName(for:)`, lines 325–365); and the private `HotkeyModifier` extension (`allCases`, `displayOrder`, `symbol`, lines 367–382). Structure:

```swift
import AppKit
import SwiftUI

struct KeybindsSettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("Global Hotkeys") {
                ForEach(HotkeyAction.allCases, id: \.self) { action in
                    LabeledContent(action.title) {
                        HotkeyRecorder(
                            definition: model.settings.hotkeys[action] ?? .chord(keyCode: 0, modifiers: [])
                        ) { definition in
                            model.setHotkey(definition, for: action)
                        }
                        Menu("Double Tap") {
                            ForEach(HotkeyModifier.allCases, id: \.self) { modifier in
                                Button("\(modifier.symbol) \(modifier.symbol)") {
                                    model.setHotkey(.doubleTapModifier(modifier), for: action)
                                }
                            }
                        }
                    }
                }
                if let conflict = model.hotkeyConflictMessage {
                    Text(conflict)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("hotkey-conflict-message")
                }
                Text("Click a shortcut to record a key combination, or choose Double Tap. The Fn key can be recorded by itself. Hotkeys are listen-only, so keys such as Escape still reach the active app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// Move HotkeyRecorder, HotkeyRecorderButton, and the HotkeyDefinition / HotkeyModifier
// private extensions here VERBATIM from the old SettingsView.swift.
```

- [ ] **Step 2: Commit together with Task 5** if the shared private extensions cause redeclaration errors while both the old and new files exist. Otherwise regenerate + build now:

Run: `xcodegen generate && xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -derivedDataPath .derived-data build`
Expected: `** BUILD SUCCEEDED **`

---

## Task 5: Replace `SettingsView` with the tab container and delete the old file

This is the switch-over. The old `Relay/App/SettingsView.swift` is deleted and replaced by the container at `Relay/App/Settings/SettingsView.swift`. Because the private extensions (`DictationMode.title`, `HotkeyDefinition`/`HotkeyModifier`, etc.) are `private` to a file, moving them out of the old file and into their new homes and deleting the old file in the same commit avoids any redeclaration window.

**Files:**
- Create: `Relay/App/Settings/SettingsView.swift`
- Delete: `Relay/App/SettingsView.swift`

- [ ] **Step 1: Create the container** `Relay/App/Settings/SettingsView.swift`:

```swift
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            KeybindsSettingsView(model: model)
                .tabItem { Label("Keybinds", systemImage: "keyboard") }
            DictationSettingsView(model: model)
                .tabItem { Label("Dictation", systemImage: "mic") }
            TTSSettingsView(model: model)
                .tabItem { Label("TTS", systemImage: "speaker.wave.2") }
            PermissionsSettingsView(model: model)
                .tabItem { Label("Security", systemImage: "lock.shield") }
        }
        .frame(width: 620, height: 610)
        .task { await model.refreshSpeechBackendStatuses() }
    }
}
```

Rationale: the `.frame` and `.task { refreshSpeechBackendStatuses() }` move from the old `SettingsView.body` to the container so the size and the on-open backend refresh behavior are preserved exactly. The tab labels use SF Symbols matching each tab's purpose.

- [ ] **Step 2: Delete the old file**

```bash
git rm Relay/App/SettingsView.swift
```

Confirm every piece of the old file now lives in a `Settings/` file: Speech → TTS (Task 1); Permissions → Permissions (Task 2); Dictation/Speech Recognition/Activity Overlay + `DictationMode.title` → Dictation (Task 3); Global Hotkeys + `HotkeyRecorder`/`HotkeyRecorderButton`/`HotkeyDefinition`/`HotkeyModifier` extensions → Keybinds (Task 4). Nothing from the old file is left unmoved.

- [ ] **Step 3: Regenerate and build**

Run: `xcodegen generate && xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -derivedDataPath .derived-data build`
Expected: `** BUILD SUCCEEDED **` with zero warnings. If a "redeclaration" or "cannot find in scope" error appears, a private helper was left in the deleted file or duplicated; move it to the single correct tab file.

- [ ] **Step 4: Run the full suite**

Run: `xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -derivedDataPath .derived-data test`
Expected: `** TEST SUCCEEDED **`, same test count as before this phase.

- [ ] **Step 5: Commit** (this commit includes Task 4's file if it was deferred here)

```bash
git add -A Relay/App Relay.xcodeproj/project.pbxproj
git commit -m "refactor(settings): switch to four-tab container, remove old SettingsView"
```

---

## Task 6: Add smoke tests for the tab views

Give each extracted view a minimal test that it constructs against a test `AppModel`, so a future accidental initializer change is caught.

**Files:**
- Create: `RelayTests/App/SettingsViewsSmokeTests.swift`

- [ ] **Step 1: Check how existing tests build an `AppModel`.** Read `RelayTests/App/AppModelTests.swift` and reuse its exact `AppModel` construction (initializer, fakes, `@MainActor` setup). Do not invent a new construction path.

- [ ] **Step 2: Write the smoke test** using the same `AppModel` setup:

```swift
import XCTest
import SwiftUI
@testable import Relay

@MainActor
final class SettingsViewsSmokeTests: XCTestCase {
    func testAllSettingsTabViewsConstruct() {
        let model = /* build the same way AppModelTests builds it */
        _ = SettingsView(model: model)
        _ = KeybindsSettingsView(model: model)
        _ = DictationSettingsView(model: model)
        _ = TTSSettingsView(model: model)
        _ = PermissionsSettingsView(model: model)
    }
}
```

The value here is compile-time: if any tab view's initializer or dependency changes incompatibly, this test file fails to build. Keep it minimal; do not attempt to render bodies (no ViewInspector dependency exists in this project).

- [ ] **Step 3: Run it**

Run: `xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -derivedDataPath .derived-data test`
Expected: `** TEST SUCCEEDED **`, one new test passing.

- [ ] **Step 4: Commit**

```bash
git add RelayTests/App/SettingsViewsSmokeTests.swift Relay.xcodeproj/project.pbxproj
git commit -m "test(settings): smoke-construct the four tab views"
```

---

## Acceptance (final check, done by the orchestrator/main session)

- [ ] `xcodegen generate` then a clean build succeeds with zero warnings.
- [ ] Full test suite passes, count equal to pre-phase plus the one new smoke test.
- [ ] `codesign --verify --deep --strict .derived-data/Build/Products/Debug/Relay.app` passes.
- [ ] Manual: open Settings from the menu bar. Confirm four toolbar tabs (Keybinds, Dictation, TTS, Security). Confirm each control works exactly as before: voice + rate, dictation mode, Parakeet/Apple enable/order/download, overlay style, permission rows, hotkey recorders + Double Tap. No behavior changed.
- [ ] `git diff --check` clean; `HANDOVER.md` not committed.

## Notes for the implementer

- The interim redeclaration risk (Tasks 3–5) comes only from `private` extensions being defined in both the old and new files at once. The safe path: do Tasks 1 and 2 as standalone commits (their helpers are instance methods, not shared file-private extensions, so no conflict), then do Tasks 3, 4, and 5 together in one commit that creates the two remaining tab files, moves the shared private extensions, adds the container, and deletes the old file atomically. Choose whichever keeps every commit building.
- Do not change `RelayApp.swift`. It already references `SettingsView(model:)`, and the new container keeps that exact name and initializer, so the `Settings { SettingsView(model: model) ... }` scene is unaffected.
- Keep `.formStyle(.grouped)` identical on all four tabs for a consistent look.
