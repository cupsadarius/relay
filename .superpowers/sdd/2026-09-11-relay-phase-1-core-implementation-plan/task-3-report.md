# Task 3 Report: Persisted Settings and Configurable Hotkeys

## Status

Implemented the settings model, configurable hotkey definitions, and `UserDefaults`-backed persistence. The approved Phase 1 production backend ruling is reflected by `AppSettings.defaults.sttBackendOrder == ["apple-speech"]`; TTS defaults to `["apple-tts"]`.

The bare Escape stop shortcut remains representable as `.chord(keyCode: 53, modifiers: [])`. This task only persists the definition and does not install or enforce the shortcut; conflict policy remains deferred to Task 7.

## Changes

- Added `HotkeyModifier`, `HotkeyDefinition`, `HotkeyAction`, and `DictationMode`.
- Added Codable, Equatable, Sendable `AppSettings` with the requested defaults.
- Added main-actor `SettingsStore` using the versioned `relay.settings.v1` key.
- Added tests for Codable round-tripping, exact defaults, missing/invalid-data fallback, and save/load persistence.
- Regenerated `Relay.xcodeproj` with XcodeGen so the new sources and tests are part of their targets.

## TDD Evidence

### RED

Command:

```bash
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -derivedDataPath .derived-data -only-testing:RelayTests/AppSettingsTests test
```

Result: expected compile failure after adding tests and before production code. Representative diagnostics:

```text
error: cannot find 'AppSettings' in scope
error: cannot find 'SettingsStore' in scope
** TEST FAILED **
```

An initial sandboxed invocation failed earlier in the build because Xcode's Observation macro service was unavailable there. Re-running outside the sandbox produced the intended missing-type RED failure above.

### Focused GREEN

Command:

```bash
xcodegen generate && xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -derivedDataPath .derived-data -only-testing:RelayTests/AppSettingsTests test
```

Result:

```text
Executed 5 tests, with 0 failures (0 unexpected)
** TEST SUCCEEDED **
```

### Full Suite

Command:

```bash
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -derivedDataPath .derived-data test
```

Result:

```text
RelayTests.xctest: Executed 10 tests, with 0 failures (0 unexpected)
Swift Testing: Test run with 1 test in 1 suite passed
** TEST SUCCEEDED **
```

## Self-review

- Requirements: all requested interfaces and persistence behavior are present; no UI was added.
- Backend ruling: only Apple Speech appears in the default STT order.
- Hotkey policy: Escape is stored as data only; no global registration or conflict policy was introduced.
- Scope: changes are limited to settings/hotkey sources, tests, the generated project, and this report.
- Mutation check: changing a default, breaking Codable conformance, changing the persistence key behavior, ignoring saved values, or removing invalid-data fallback causes at least one test to fail.

## Concerns

- Xcode test execution requires running outside the filesystem sandbox because the sandbox blocks Xcode macro/test services.
- The test process logs benign `com.apple.linkd.autoShortcut` connection warnings; tests still complete successfully.
