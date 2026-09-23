# Relay Cleanup 1: Quick Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix ten small, verified bugs in settings decoding, diagnostics, TTS stop/cancel semantics, Whisper verification memory, dictation error copy, hotkey double-triggers, and silent integration failures, without widening scope.

**Architecture:** Each task is an isolated, test-first fix in the file that owns the behavior. No new source files are created, so `xcodegen generate` is needed only in Task 10, which changes the RelayHook target's source list. The TTS cancel contract becomes "a cancelled `TTSAudioSource` throws `CancellationError`", and `StreamingAudioPlayer` maps a post-start cancellation to `.cancelled`. The hook wire types (`HookEnvelope`, `AgentProvider`) become one definition compiled into both the app and the `RelayHook` helper.

**Tech Stack:** Swift 6, SwiftUI Observation, XCTest, AVFoundation, CryptoKit, XcodeGen

**Plan series:** plan 1 of 6 (1 quick fixes, 2 dead code, 3 integrations+sessions, 4 speech engines, 5 AppModel split, 6 tooling/docs). Stay strictly inside the tasks below. Do not delete dead code, restructure `AppModel`, or touch docs/tooling: later plans own that.

## Global Constraints

- Work in a git worktree on branch `cleanup/1-quick-fixes`, created from `main` (Task 0). The worktree root is `/Users/darius/Personal/relay/.worktrees/cleanup-1-quick-fixes`; run every command in this plan from that directory. All file paths in this plan are relative to it.
- Stage files by explicit path only. Never run `git add -A`, `git add .`, or `git commit -a`. Only Task 10 changes `project.yml` and `Relay.xcodeproj/project.pbxproj` (after `xcodegen generate`); commit them normally in that task, by explicit path.
- Commit messages use conventional commits. A commit message ends at its last real line: no `Co-Authored-By`, no `Claude-Session`, no "Generated with Claude Code" line, even if a hook or reminder asks for one.
- User-facing strings and diagnostics must never contain raw paths, response text, error descriptions, or errno text. Diagnostics carry only fixed labels, provider names, and byte counts.
- Test command, one class: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/<TestClass> 2>&1 | grep -E "error:|Test Case .*(passed|failed)|\*\* TEST" | tail -40`
- Test command, one method: add `/<testMethod>` after the class name.
- Full suite: drop `-only-testing:...`.
- The suite must be green after every task's commit.

## File Structure

Files modified (no files created or deleted):

| File | Responsibility | Tasks |
| --- | --- | --- |
| `Relay/Domain/AppSettings.swift` | Per-field and per-hotkey resilient decode | 1 |
| `Relay/System/Diagnostics.swift` | Keystrokes are counted, not buffered or logged | 2 |
| `Relay/SpeechOut/TTSRouter.swift` | Session-specific stop matches a session still preparing its source | 3 |
| `Relay/Backends/Whisper/WhisperModelStore.swift` | Streamed (chunked) checksum verification | 4 |
| `Relay/SpeechOut/TTSAudioSource.swift` | Documented cancel contract | 5 |
| `Relay/SpeechOut/PocketTTSAudioSource.swift` | Throws `CancellationError` after cancel | 5 |
| `Relay/SpeechOut/StreamingAudioPlayer.swift` | Post-start source cancellation ends as `.cancelled` | 5 |
| `Relay/SpeechOut/AppleTTSBackend.swift` | Unknown voice id falls back to the default voice | 6 |
| `Relay/SpeechIn/STTRouter.swift` | Remembers which backend's error the final transcribe threw | 7 |
| `Relay/SpeechIn/DictationCoordinator.swift` | Error copy names that backend | 7 |
| `Relay/App/AppModel.swift` | Single speech-action task; helper refresh at launch; socket-start errors; speak-latest fix | 8, 9, 11, 13 |
| `RelayHook/main.swift` | Uses shared wire types; refuses oversized envelopes | 10, 12 |
| `project.yml`, `Relay.xcodeproj/project.pbxproj` | RelayHook target compiles `HookEnvelope.swift` + `AgentProvider.swift` | 10 |
| `Relay/Integrations/Domain/HookEnvelope.swift` | Shared wire-size limit and wire encoding | 12 |
| `Relay/Integrations/Transport/UnixSocketServer.swift` | Error diagnostics labels; oversized-line diagnostics | 11, 12 |
| `Relay/App/Settings/IntegrationsSettingsView.swift` | Shows socket-start problem text | 11 |
| `Relay/Sessions/AgentAutoReadCoordinator.swift` | Records auto-read speech failures | 13 |

Tests are added only to existing test files:
`RelayTests/Domain/AppSettingsDecodeTests.swift`, `RelayTests/System/DiagnosticsTests.swift`, `RelayTests/SpeechOut/TTSRouterTests.swift`, `RelayTests/Backends/Whisper/WhisperModelStoreTests.swift`, `RelayTests/SpeechOut/PocketTTSAudioSourceTests.swift`, `RelayTests/SpeechOut/StreamingAudioPlayerTests.swift`, `RelayTests/SpeechOut/AppleTTSBackendTests.swift`, `RelayTests/SpeechIn/STTRouterTests.swift`, `RelayTests/SpeechIn/DictationCoordinatorTests.swift`, `RelayTests/App/AppModelTests.swift`, `RelayTests/App/AppModelIntegrationsTests.swift`, `RelayTests/Integrations/HookEnvelopeTests.swift`, `RelayTests/Integrations/UnixSocketServerTests.swift`, `RelayTests/Sessions/AgentAutoReadCoordinatorTests.swift`.

---

### Task 0: Create the branch

**Files:** none

- [ ] **Step 1: Create the worktree and branch from main**

```bash
cd /Users/darius/Personal/relay
git worktree add .worktrees/cleanup-1-quick-fixes -b cleanup/1-quick-fixes main
cd .worktrees/cleanup-1-quick-fixes
```

Expected: `Preparing worktree (new branch 'cleanup/1-quick-fixes')`. `main` must already contain `ce812c9` (RelayHook signed with "Relay Local Development").

- [ ] **Step 2: Confirm the starting state**

Run: `git status --short`
Expected: no output (clean worktree).

Run: `git log --oneline -1 main`
Expected: `ce812c9 build: sign RelayHook with stable local cert and document separate Debug id` (or a later commit).

- [ ] **Step 3: Baseline the suite**

Run the full suite (see Global Constraints).
Expected: `** TEST SUCCEEDED **`. If it fails before any change, stop and report the failing tests: do not start Task 1 on a red baseline.

---

### Task 1: Resilient AppSettings decode (fields and hotkeys)

**Problem:** `AppSettings.init(from:)` decodes `ttsVoiceIdentifier`, `activityOverlayStyle`, `kokoroVoice`, `pocketVoice`, and `liveTranscriptionEnabled` with `try values.decodeIfPresent`. A wrong type or an unknown enum raw value throws, and `SettingsStore.load()` then resets **all** settings to defaults. `hotkeys` decodes as one `[HotkeyAction: HotkeyDefinition]`, so one unknown action string (for example, written by a newer build) drops the whole map. `HotkeyAction` is not `CodingKeyRepresentable`, so Swift encodes this dictionary as a flat array `["dictate", {...}, "readSelection", {...}]` (verified). That on-disk format must keep working. The schema-version `switch` does nothing and is deleted.

**Files:**
- Modify: `Relay/Domain/AppSettings.swift`
- Test: `RelayTests/Domain/AppSettingsDecodeTests.swift`

- [ ] **Step 1: Write the failing tests**

Append these methods inside `final class AppSettingsDecodeTests` in `RelayTests/Domain/AppSettingsDecodeTests.swift`, before its closing `}`:

```swift
    /// Optional and newer fields used `try decodeIfPresent`, so a wrong-typed value threw and
    /// `SettingsStore.load()` reset EVERY setting. Each must now fall back on its own.
    func testWrongTypedOptionalFieldsFallBackWithoutResettingOthers() throws {
        var saved = AppSettings.defaults
        saved.dictationMode = .toggle
        saved.ttsRate = 0.8
        let encoded = try JSONEncoder().encode(saved)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["ttsVoiceIdentifier"] = 42
        object["kokoroVoice"] = true
        object["pocketVoice"] = ["not", "a", "string"]
        object["liveTranscriptionEnabled"] = "yes"

        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(decoded.dictationMode, .toggle)
        XCTAssertEqual(decoded.ttsRate, 0.8, accuracy: 0.0001)
        XCTAssertEqual(decoded.ttsVoiceIdentifier, AppSettings.defaults.ttsVoiceIdentifier)
        XCTAssertEqual(decoded.kokoroVoice, AppSettings.defaults.kokoroVoice)
        XCTAssertEqual(decoded.pocketVoice, AppSettings.defaults.pocketVoice)
        XCTAssertEqual(decoded.liveTranscriptionEnabled, AppSettings.defaults.liveTranscriptionEnabled)
    }

    func testUnknownActivityOverlayStyleFallsBackToDefault() throws {
        var saved = AppSettings.defaults
        saved.autoReadEnabled = false
        let encoded = try JSONEncoder().encode(saved)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["activityOverlayStyle"] = "holographic"

        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(decoded.activityOverlayStyle, AppSettings.defaults.activityOverlayStyle)
        XCTAssertFalse(decoded.autoReadEnabled)
    }

    /// Pins the on-disk format: a `[HotkeyAction: HotkeyDefinition]` encodes as a flat
    /// `[key, value, key, value]` array, and it must keep round-tripping.
    func testHotkeysStillEncodeAsFlatArrayAndRoundTrip() throws {
        var saved = AppSettings.defaults
        saved.hotkeys[.readSelection] = .chord(keyCode: 15, modifiers: [.option, .command])
        saved.hotkeys[.dictate] = .doubleTapModifier(.control)
        let encoded = try JSONEncoder().encode(saved)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        XCTAssertNotNil(object["hotkeys"] as? [Any], "hotkeys must stay a flat array on disk")
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: encoded).hotkeys, saved.hotkeys)
    }

    func testUnknownHotkeyActionDropsOnlyThatEntry() throws {
        var saved = AppSettings.defaults
        saved.hotkeys[.readSelection] = .chord(keyCode: 15, modifiers: [.option, .command])
        let encoded = try JSONEncoder().encode(saved)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var entries = try XCTUnwrap(object["hotkeys"] as? [Any])
        entries.append("summonDragons")
        entries.append(["chord": ["keyCode": 1, "modifiers": [String]()]])
        object["hotkeys"] = entries

        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(decoded.hotkeys, saved.hotkeys)
    }

    func testMalformedHotkeyDefinitionDropsOnlyThatEntry() throws {
        var saved = AppSettings.defaults
        saved.hotkeys[.readSelection] = .chord(keyCode: 15, modifiers: [.option, .command])
        let encoded = try JSONEncoder().encode(saved)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var entries = try XCTUnwrap(object["hotkeys"] as? [Any])
        let dictateIndex = try XCTUnwrap(entries.firstIndex { ($0 as? String) == "dictate" })
        entries[dictateIndex + 1] = ["bogus": 1]
        object["hotkeys"] = entries

        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        var expected = saved.hotkeys
        expected[.dictate] = nil
        XCTAssertEqual(decoded.hotkeys, expected)
    }

    /// A keyed-object hotkeys map (what the dictionary would encode as if `HotkeyAction` ever
    /// becomes `CodingKeyRepresentable`) is read too, with unknown keys dropped.
    func testKeyedObjectHotkeysFormatIsAlsoRead() throws {
        let encoded = try JSONEncoder().encode(AppSettings.defaults)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["hotkeys"] = [
            "readSelection": ["chord": ["keyCode": 15, "modifiers": ["option"]]],
            "summonDragons": ["chord": ["keyCode": 1, "modifiers": [String]()]],
        ]

        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(decoded.hotkeys, [.readSelection: .chord(keyCode: 15, modifiers: [.option])])
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/AppSettingsDecodeTests 2>&1 | grep -E "error:|Test Case .*(passed|failed)|\*\* TEST" | tail -40`
Expected: FAIL. `testWrongTypedOptionalFieldsFallBackWithoutResettingOthers` and `testUnknownActivityOverlayStyleFallsBackToDefault` fail with a thrown `typeMismatch`/`dataCorrupted` decoding error. `testUnknownHotkeyActionDropsOnlyThatEntry`, `testMalformedHotkeyDefinitionDropsOnlyThatEntry`, and `testKeyedObjectHotkeysFormatIsAlsoRead` fail an `XCTAssertEqual` (the whole map fell back to defaults). `testHotkeysStillEncodeAsFlatArrayAndRoundTrip` passes already (it pins the format).

- [ ] **Step 3: Implement the resilient decode**

In `Relay/Domain/AppSettings.swift`:

3a. Replace the doc comment on `schemaVersion` (the 4 lines above `var schemaVersion: Int`) with:

```swift
    /// The on-disk schema version of this value. Always `AppSettings.currentSchemaVersion` once
    /// a value exists in memory: a blob saved by an older build (or with no `schemaVersion` key
    /// at all) decodes through the per-field fallbacks in `init(from:)` and lands on the current
    /// version, rather than carrying its original version forward.
```

3b. Replace the doc comment on `currentSchemaVersion` (the 3 lines above `static let currentSchemaVersion = 1`) with:

```swift
    /// The current on-disk schema version. Bump this (and add an explicit transform to
    /// `init(from:)`) only when a future change needs more than per-field fallback defaults,
    /// e.g. renaming or reshaping a field.
```

3c. Replace the whole `init(from decoder: Decoder) throws { ... }` body, from `init(from decoder: Decoder) throws {` through the closing `}` right after `schemaVersion = AppSettings.currentSchemaVersion`, with:

```swift
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = AppSettings.defaults

        // Per-field resilient decode: `try?` collapses BOTH "key missing" and "key present with
        // the wrong type/an invalid value" into the same fallback-to-default outcome, so one
        // malformed or absent field can never throw and reset every other field along with it.
        // Every field goes through this one helper, including optionals (`Value == String?`,
        // where a JSON `null` still decodes to `nil`).
        func field<Value: Decodable>(_ key: CodingKeys, default defaultValue: Value) -> Value {
            (try? values.decode(Value.self, forKey: key)) ?? defaultValue
        }

        dictationMode = field(.dictationMode, default: fallback.dictationMode)
        hotkeys = AppSettings.decodeHotkeys(from: values) ?? fallback.hotkeys
        let decodedSTTOrder = field(.sttBackendOrder, default: fallback.sttBackendOrder)
        let decodedTTSOrder = field(.ttsBackendOrder, default: fallback.ttsBackendOrder)
        ttsVoiceIdentifier = field(.ttsVoiceIdentifier, default: fallback.ttsVoiceIdentifier)
        let decodedRate = field(.ttsRate, default: fallback.ttsRate)
        autoReadEnabled = field(.autoReadEnabled, default: fallback.autoReadEnabled)
        activityOverlayStyle = field(.activityOverlayStyle, default: fallback.activityOverlayStyle)
        kokoroVoice = field(.kokoroVoice, default: fallback.kokoroVoice)
        pocketVoice = field(.pocketVoice, default: fallback.pocketVoice)
        liveTranscriptionEnabled = field(.liveTranscriptionEnabled, default: fallback.liveTranscriptionEnabled)
        selectedSpeechModelByBackend = field(
            .selectedSpeechModelByBackend,
            default: fallback.selectedSpeechModelByBackend
        )

        // Normalize AFTER every field has its per-field fallback value: drop unknown/duplicate
        // backend ids (keeping the first occurrence of each known id, in order) and clamp the
        // rate into its valid range. Deliberately does NOT append known-but-missing backend ids
        // to the order — that would invent new behavior; `BackendCatalog.knownOrder` (the
        // equivalent runtime-side filter in `Relay/App/BackendCatalog.swift`) only ever filters
        // too, never appends, so this matches existing semantics.
        sttBackendOrder = AppSettings.normalizedBackendOrder(
            decodedSTTOrder,
            knownIDs: AppSettings.knownSTTBackendIDs,
            fallback: fallback.sttBackendOrder
        )
        ttsBackendOrder = AppSettings.normalizedBackendOrder(
            decodedTTSOrder,
            knownIDs: AppSettings.knownTTSBackendIDs,
            fallback: fallback.ttsBackendOrder
        )
        ttsRate = min(max(decodedRate, AppSettings.validTTSRateRange.lowerBound), AppSettings.validTTSRateRange.upperBound)

        // Every in-memory value is the current schema, regardless of what version (if any) the
        // saved blob carried — the fields above have already migrated it.
        schemaVersion = AppSettings.currentSchemaVersion
    }

    /// Decodes `hotkeys` one entry at a time, so a single unknown action (e.g. one written by a
    /// newer build) or malformed definition drops only that entry instead of the whole map.
    ///
    /// Reads the flat `[action, definition, action, definition]` array that Swift's synthesized
    /// `Dictionary` encoding produces for a non-`String`/`Int`, non-`CodingKeyRepresentable` key
    /// (the format every build so far has written, and still writes), and also a keyed
    /// `{"action": definition}` object. Returns `nil` (caller falls back to the default map) when
    /// the field is missing, is neither shape, or is a flat array with an odd element count.
    private static func decodeHotkeys(
        from values: KeyedDecodingContainer<CodingKeys>
    ) -> [HotkeyAction: HotkeyDefinition]? {
        if var entries = try? values.nestedUnkeyedContainer(forKey: .hotkeys) {
            var result: [HotkeyAction: HotkeyDefinition] = [:]
            while !entries.isAtEnd {
                // Each element decodes through `LossyDecodable`, which never throws: a FAILED
                // decode does not advance an unkeyed container, so decoding the raw types here
                // would stall on the first bad element instead of skipping it.
                guard let key = try? entries.decode(LossyDecodable<String>.self),
                      let definition = try? entries.decode(LossyDecodable<HotkeyDefinition>.self)
                else { return nil }
                if let rawAction = key.value,
                   let action = HotkeyAction(rawValue: rawAction),
                   let definition = definition.value {
                    result[action] = definition
                }
            }
            return result
        }
        if let object = try? values.nestedContainer(keyedBy: HotkeyMapKey.self, forKey: .hotkeys) {
            var result: [HotkeyAction: HotkeyDefinition] = [:]
            for key in object.allKeys {
                guard let action = HotkeyAction(rawValue: key.stringValue),
                      let definition = try? object.decode(HotkeyDefinition.self, forKey: key)
                else { continue }
                result[action] = definition
            }
            return result
        }
        return nil
    }
```

3d. At the very end of the file (after the closing `}` of `struct AppSettings`), add:

```swift

/// Wraps a value whose decode may fail, without failing itself — so an unkeyed container always
/// advances past the element. `value` is `nil` when the wrapped decode failed.
private struct LossyDecodable<Wrapped: Decodable>: Decodable {
    let value: Wrapped?

    init(from decoder: Decoder) throws {
        value = try? Wrapped(from: decoder)
    }
}

/// Arbitrary string key, used to read a keyed-object `hotkeys` map whose keys are not known up
/// front (unknown action names are skipped, not rejected).
private struct HotkeyMapKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
```

Leave `encode(to:)` synthesized: encoding is unchanged, so the on-disk format stays the flat array.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/AppSettingsDecodeTests -only-testing:RelayTests/AppSettingsTests -only-testing:RelayTests/SettingsStoreTests 2>&1 | grep -E "error:|Test Case .*(passed|failed)|\*\* TEST" | tail -40`
Expected: every test passes, `** TEST SUCCEEDED **` (the pre-existing `testOldSchemaVersionMigrates` and `testValidCurrentBlobRoundTripsIdentically` included).

- [ ] **Step 5: Commit**

```bash
git add Relay/Domain/AppSettings.swift RelayTests/Domain/AppSettingsDecodeTests.swift
git commit -m "fix(settings): decode every field and hotkey entry independently"
```

---

### Task 2: Stop keystrokes flooding diagnostics

**Problem:** `GlobalHotkeyManager.receive` calls `diagnostics?.record(.keyboardEventReceived)` for every keystroke system-wide. `DiagnosticsRecorder.record` appends each one to the 250-entry buffer (evicting every meaningful entry within seconds of typing), writes it to `os_log`, and mutates `@Observable` state. Fix: that event only increments `counters.received`. `DiagnosticsBuffer.append` already trims only past capacity; with keystrokes gone it runs rarely, so it is left unchanged.

**Files:**
- Modify: `Relay/System/Diagnostics.swift`
- Test: `RelayTests/System/DiagnosticsTests.swift`

- [ ] **Step 1: Write the failing test and update the existing one**

In `RelayTests/System/DiagnosticsTests.swift`, replace the whole `testRepeatedEventsHaveUniqueStableIDsAndClearResetsCounters` method with:

```swift
    func testRepeatedEventsHaveUniqueStableIDsAndClearResetsCounters() {
        let recorder = DiagnosticsRecorder(capacity: 3)
        recorder.record(.keyboardEventReceived)
        recorder.record(.keyboardEventReceived)
        recorder.record(.hotkeyMatched(action: .readSelection, phase: .pressed))
        recorder.record(.hotkeyMatched(action: .readSelection, phase: .pressed))
        recorder.record(.actionDispatched(action: .readSelection, phase: .pressed))

        XCTAssertEqual(recorder.entries.count, 3)
        XCTAssertEqual(Set(recorder.entries.map(\.id)).count, 3)
        XCTAssertEqual(recorder.counters.received, 2)
        XCTAssertEqual(recorder.counters.matched, 2)
        XCTAssertEqual(recorder.counters.dispatched, 1)
        XCTAssertEqual(recorder.entries.last?.event.message, "Read Selection pressed dispatched")
        recorder.clear()
        XCTAssertTrue(recorder.entries.isEmpty)
        XCTAssertEqual(recorder.counters, .init())
    }

    /// Every keystroke system-wide reports `.keyboardEventReceived` while the event tap is live.
    /// It must only bump the counter: buffering it would evict every meaningful entry.
    func testKeyboardEventsAreCountedButNeverBuffered() {
        let recorder = DiagnosticsRecorder(capacity: 5)
        recorder.record(.eventTapRegistered)
        for _ in 0..<20 {
            recorder.record(.keyboardEventReceived)
        }

        XCTAssertEqual(recorder.counters.received, 20)
        XCTAssertEqual(recorder.entries.map(\.event), [.eventTapRegistered])
    }
```

- [ ] **Step 2: Run the tests to verify the new one fails**

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/DiagnosticsTests 2>&1 | grep -E "error:|Test Case .*(passed|failed)|\*\* TEST" | tail -40`
Expected: FAIL in `testKeyboardEventsAreCountedButNeverBuffered` (entries contain `.keyboardEventReceived`). The rewritten `testRepeatedEvents...` passes.

- [ ] **Step 3: Implement**

In `Relay/System/Diagnostics.swift`, replace:

```swift
    func record(_ event: DiagnosticsEvent) {
        buffer.append(event)
        switch event { case .keyboardEventReceived: counters.received += 1; case .hotkeyMatched: counters.matched += 1; case .actionDispatched: counters.dispatched += 1; default: break }
        logger.info("\(event.message, privacy: .public)")
    }
```

with:

```swift
    func record(_ event: DiagnosticsEvent) {
        switch event {
        case .keyboardEventReceived:
            // Reported for EVERY keystroke system-wide while the event tap is live. Count it
            // only: appending it to `buffer` and `os_log` would evict every meaningful entry
            // within seconds of typing and churn every observer of `buffer`.
            counters.received += 1
            return
        case .hotkeyMatched:
            counters.matched += 1
        case .actionDispatched:
            counters.dispatched += 1
        default:
            break
        }
        buffer.append(event)
        logger.info("\(event.message, privacy: .public)")
    }
```

`GlobalHotkeyManager.swift:310` keeps calling `record(.keyboardEventReceived)`; nothing changes there.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/DiagnosticsTests -only-testing:RelayTests/GlobalHotkeyManagerTests 2>&1 | grep -E "error:|Test Case .*(passed|failed)|\*\* TEST" | tail -40`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Relay/System/Diagnostics.swift RelayTests/System/DiagnosticsTests.swift
git commit -m "fix(diagnostics): count keystrokes without buffering or logging them"
```

---

### Task 3: TTS Stop works while a backend is still preparing

**Problem:** `TTSRouter.stop(sessionID:)` matches only `candidate?.sessionID`, but `candidate` is assigned after `makeAudioSource` returns. Kokoro/PocketTTS model loads take seconds, so the overlay's Stop during that window is a no-op, and `SpeechCoordinator.stop(sessionID:)` returns early because the router says "no match". Fix: track the session being routed from the start of `speak`. A matching stop calls `stop()`, which bumps `routingGeneration`, so the existing post-prepare guard cancels the fresh source and throws `CancellationError`.

**Files:**
- Modify: `Relay/SpeechOut/TTSRouter.swift`
- Test: `RelayTests/SpeechOut/TTSRouterTests.swift`

- [ ] **Step 1: Write the failing tests**

In `RelayTests/SpeechOut/TTSRouterTests.swift`, add these methods right after `testSessionSpecificStopIgnoresStaleID` (before `// MARK: Helpers`):

```swift
    func testSessionSpecificStopDuringSourcePreparationCancelsTheRequest() async throws {
        let slow = FakeTTSBackend(id: "slow")
        slow.suspendSourceCreation = true
        let player = FakePlayer()
        let router = makeRouter([slow], player: player)
        let sessionID = UUID()

        let speaking = Task {
            try await router.speak(text: "hello", options: .init(), sessionID: sessionID)
        }
        await waitUntil { slow.isSourceCreationSuspended }

        XCTAssertTrue(router.stop(sessionID: sessionID), "a stop for the session being prepared must match it")
        slow.resumeSourceCreation()

        do {
            try await speaking.value
            XCTFail("Expected the stopped request to be cancelled")
        } catch is CancellationError {}
        XCTAssertTrue(player.started.isEmpty, "a stopped request must never reach the player")
    }

    func testSessionSpecificStopDuringPreparationIgnoresOtherSessionIDs() async throws {
        let slow = FakeTTSBackend(id: "slow")
        slow.suspendSourceCreation = true
        let player = FakePlayer()
        let router = makeRouter([slow], player: player)
        let sessionID = UUID()

        let speaking = Task {
            try await router.speak(text: "hello", options: .init(), sessionID: sessionID)
        }
        await waitUntil { slow.isSourceCreationSuspended }

        XCTAssertFalse(router.stop(sessionID: UUID()))
        slow.resumeSourceCreation()

        try await speaking.value
        XCTAssertEqual(player.started.count, 1)
    }

    func testRoutingSessionIsForgottenOnceRoutingFails() async {
        let backend = FakeTTSBackend(id: "only")
        backend.error = SpeechBackendError.invalidInput
        let router = makeRouter([backend])
        let sessionID = UUID()

        do {
            try await router.speak(text: "hello", options: .init(), sessionID: sessionID)
            XCTFail("Expected invalidInput")
        } catch {}

        XCTAssertFalse(router.stop(sessionID: sessionID))
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/TTSRouterTests 2>&1 | grep -E "error:|Test Case .*(passed|failed)|\*\* TEST" | tail -40`
Expected: FAIL in `testSessionSpecificStopDuringSourcePreparationCancelsTheRequest` (`XCTAssertTrue` fails, then the speak completes and `player.started` is not empty). The other two pass already; they pin the non-matching behavior.

- [ ] **Step 3: Implement**

In `Relay/SpeechOut/TTSRouter.swift`:

3a. Replace:

```swift
    private var candidate: CandidatePlayback?
```

with:

```swift
    private var candidate: CandidatePlayback?
    /// The session `speak` is currently routing, set before any backend is consulted. A backend
    /// can spend seconds inside `makeAudioSource` (Kokoro/PocketTTS model loads) before
    /// `candidate` exists, so `stop(sessionID:)` also matches this, or a Stop pressed during
    /// preparation would be ignored.
    private var routingSessionID: UUID?
```

3b. In `speak(...)`, replace:

```swift
        routingGeneration &+= 1
        let generation = routingGeneration
```

with:

```swift
        routingGeneration &+= 1
        let generation = routingGeneration
        routingSessionID = sessionID
        defer {
            // A newer `speak` may already own `routingSessionID`; only clear our own.
            if routingSessionID == sessionID { routingSessionID = nil }
        }
```

3c. Replace:

```swift
    func stop() {
        routingGeneration &+= 1
        player.stop()
    }

    /// No-ops unless `sessionID` matches the session currently being played, so a stale Interactive
    /// Stop cannot cut off replacement speech. Returns whether the ID matched and a stop was issued.
    @discardableResult
    func stop(sessionID: UUID) -> Bool {
        guard candidate?.sessionID == sessionID else { return false }
        stop()
        return true
    }
```

with:

```swift
    func stop() {
        routingGeneration &+= 1
        routingSessionID = nil
        player.stop()
    }

    /// No-ops unless `sessionID` matches the session currently being routed (still preparing its
    /// source) or played, so a stale Interactive Stop cannot cut off replacement speech. Returns
    /// whether the ID matched and a stop was issued. A stop during preparation bumps
    /// `routingGeneration`, so `speak`'s post-`makeAudioSource` guard cancels the new source and
    /// throws `CancellationError` instead of starting playback.
    @discardableResult
    func stop(sessionID: UUID) -> Bool {
        guard routingSessionID == sessionID || candidate?.sessionID == sessionID else { return false }
        stop()
        return true
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/TTSRouterTests -only-testing:RelayTests/SpeechCoordinatorTests -only-testing:RelayTests/SpeechCoordinatorWatchdogTests 2>&1 | grep -E "error:|Test Case .*(passed|failed)|\*\* TEST" | tail -40`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Relay/SpeechOut/TTSRouter.swift RelayTests/SpeechOut/TTSRouterTests.swift
git commit -m "fix(speech): honor session stop while a TTS source is preparing"
```

---

### Task 4: Stream Whisper checksum verification

**Problem:** `WhisperModelStore.download` calls `Data(contentsOf:)` on every downloaded file (weights are about 1 GB) just to hash it. Replace it with chunked `FileHandle` reads into incremental `SHA256` / `Insecure.SHA1`. The git-blob SHA1 must hash the `"blob <size>\0"` header first, exactly like the current `verify(data:against:)`.

**Files:**
- Modify: `Relay/Backends/Whisper/WhisperModelStore.swift`
- Test: `RelayTests/Backends/Whisper/WhisperModelStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

In `RelayTests/Backends/Whisper/WhisperModelStoreTests.swift`, add these methods inside `final class WhisperModelStoreTests`, right after `testPresenceFalseWhenDirEmpty()`. `TestOID` in the same file computes digests the same way the old whole-`Data` code did, so equality with it proves the chunked result matches:

```swift
    /// Chunked hashing must produce exactly the whole-file digests (`TestOID` mirrors the old
    /// `Data(contentsOf:)` algorithm) for a file spanning many chunks, including a final
    /// partial chunk.
    func testChunkedVerificationMatchesWholeFileDigests() throws {
        let data = Data((0..<10_000).map { UInt8($0 % 251) })
        let fileURL = tempDirectory.appendingPathComponent("weights.bin")
        try data.write(to: fileURL)

        XCTAssertTrue(try WhisperModelStore.verifyFile(at: fileURL, against: TestOID.sha256(data), chunkSize: 7))
        XCTAssertTrue(try WhisperModelStore.verifyFile(at: fileURL, against: TestOID.gitBlobSHA1(data), chunkSize: 7))
        XCTAssertTrue(try WhisperModelStore.verifyFile(at: fileURL, against: TestOID.sha256(data)))
    }

    func testChunkedVerificationRejectsWrongDigests() throws {
        let data = Data("config".utf8)
        let fileURL = tempDirectory.appendingPathComponent("config.json")
        try data.write(to: fileURL)

        XCTAssertFalse(try WhisperModelStore.verifyFile(
            at: fileURL,
            against: .sha256(String(repeating: "0", count: 64)),
            chunkSize: 4
        ))
        XCTAssertFalse(try WhisperModelStore.verifyFile(
            at: fileURL,
            against: .gitBlobSHA1(String(repeating: "0", count: 40)),
            chunkSize: 4
        ))
    }

    func testChunkedVerificationOfAnEmptyFileMatchesGitsEmptyBlob() throws {
        let fileURL = tempDirectory.appendingPathComponent("empty")
        try Data().write(to: fileURL)

        // `git hash-object` of an empty file.
        XCTAssertTrue(try WhisperModelStore.verifyFile(
            at: fileURL,
            against: .gitBlobSHA1("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391")
        ))
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/WhisperModelStoreTests 2>&1 | grep -E "error:|Test Case .*(passed|failed)|\*\* TEST" | tail -40`
Expected: build FAILS with `error: type 'WhisperModelStore' has no member 'verifyFile'`.

- [ ] **Step 3: Implement**

In `Relay/Backends/Whisper/WhisperModelStore.swift`:

3a. In `download(_:progress:)`, replace:

```swift
            for file in files {
                let fileURL = stagingDirectory.appendingPathComponent(file.relativePath)
                let data = try Data(contentsOf: fileURL)
                guard Self.verify(data: data, against: file.oid) else {
                    throw WhisperModelStoreError.checksumMismatch
                }
            }
```

with:

```swift
            for file in files {
                let fileURL = stagingDirectory.appendingPathComponent(file.relativePath)
                guard try Self.verifyFile(at: fileURL, against: file.oid) else {
                    throw WhisperModelStoreError.checksumMismatch
                }
            }
```

3b. Replace the whole `private static func verify(data: Data, against oid: WhisperFileOID) -> Bool { ... }` method with:

```swift
    /// Read size for `verifyFile`. Weight files are about 1 GB, so they are hashed in 1 MiB
    /// slices rather than loaded whole.
    static let verificationChunkSize = 1 << 20

    /// Streams the file at `url` through an incremental hasher and compares the digest with
    /// `oid`. Memory stays at about `chunkSize` whatever the file size. `.gitBlobSHA1` hashes the
    /// git blob header `"blob <size>\0"` before the content, exactly like `git hash-object`.
    /// Internal (not private) so tests can compare it against whole-file digests.
    static func verifyFile(
        at url: URL,
        against oid: WhisperFileOID,
        chunkSize: Int = verificationChunkSize
    ) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        switch oid {
        case .sha256(let expected):
            var hasher = SHA256()
            try forEachChunk(of: handle, chunkSize: chunkSize) { hasher.update(data: $0) }
            return hexDigest(hasher.finalize()) == expected.lowercased()
        case .gitBlobSHA1(let expected):
            let size = try handle.seekToEnd()
            try handle.seek(toOffset: 0)
            var hasher = Insecure.SHA1()
            hasher.update(data: Data("blob \(size)\0".utf8))
            try forEachChunk(of: handle, chunkSize: chunkSize) { hasher.update(data: $0) }
            return hexDigest(hasher.finalize()) == expected.lowercased()
        }
    }

    /// Calls `body` with successive reads of up to `chunkSize` bytes until EOF. Each read is
    /// wrapped in its own autorelease pool so bridged buffers are freed per chunk instead of
    /// piling up until the calling thread's pool drains.
    private static func forEachChunk(
        of handle: FileHandle,
        chunkSize: Int,
        _ body: (Data) -> Void
    ) throws {
        while true {
            let hasMore: Bool = try autoreleasepool {
                guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                    return false
                }
                body(chunk)
                return true
            }
            if !hasMore { return }
        }
    }
```

Keep `hexDigest(_:)` as it is.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/WhisperModelStoreTests -only-testing:RelayTests/WhisperModelManagerTests 2>&1 | grep -E "error:|Test Case .*(passed|failed)|\*\* TEST" | tail -40`
Expected: `** TEST SUCCEEDED **` (the existing download/verify/mismatch tests included).

- [ ] **Step 5: Commit**

```bash
git add Relay/Backends/Whisper/WhisperModelStore.swift RelayTests/Backends/Whisper/WhisperModelStoreTests.swift
git commit -m "perf(whisper): verify model files with chunked streaming hashes"
```

---

### Task 5: One TTS source cancel contract: throw `CancellationError`

**Problem:** `PocketTTSAudioSource.next()` maps `CancellationError` to `nil` (commit `28def21`, done only to match a test), while `KokoroTTSAudioSource`, `AppleTTSAudioSource`, and `TTSAudioPipe` throw `CancellationError`. With `nil`, `StreamingAudioPlayer.pump` treats a cancelled stream as a normal finish (`.finished`). The contract becomes: a cancelled source throws `CancellationError`.

Verified player behavior today: after `player.stop()`, the pump sees `explicitlyStopped` and returns silently (`stop()` already emitted `.cancelled`). That is correct. Before `.started`, a thrown `CancellationError` makes `startPlayback` throw `CancellationError` with no terminal event, and `TTSRouter` rethrows it without fallback. That is also correct. **After `.started`, a `CancellationError` that did not come from `player.stop()` goes through `handleSourceFailure` and ends the session as `.failed` after draining.** That is wrong, and this task fixes it to end as `.cancelled` immediately.

**Files:**
- Modify: `Relay/SpeechOut/TTSAudioSource.swift`
- Modify: `Relay/SpeechOut/PocketTTSAudioSource.swift`
- Modify: `Relay/SpeechOut/StreamingAudioPlayer.swift`
- Test: `RelayTests/SpeechOut/PocketTTSAudioSourceTests.swift`
- Test: `RelayTests/SpeechOut/StreamingAudioPlayerTests.swift`

- [ ] **Step 1: Write the failing tests**

1a. In `RelayTests/SpeechOut/PocketTTSAudioSourceTests.swift`, replace the whole `testCancelStopsIteration` method with:

```swift
    func testCancelMakesNextThrowCancellationError() async throws {
        let stream = AsyncThrowingStream<[Float], Error> { continuation in
            continuation.yield([0.1])
            continuation.yield([0.2])
            continuation.finish()
        }
        let source = PocketTTSAudioSource(stream: stream, sampleRate: 24_000)

        let first = try await source.next()
        XCTAssertEqual(first?.samples, [0.1])

        await source.cancel()
        do {
            _ = try await source.next()
            XCTFail("A cancelled source must throw, not end like a finished one")
        } catch is CancellationError {
            // Expected: the TTSAudioSource cancel contract.
        }
    }
```

1b. In `RelayTests/SpeechOut/StreamingAudioPlayerTests.swift`, add these methods right after `testStopCancelsActiveSourceAndEmitsCancelledOnce`:

```swift
    /// A source cancelled by something other than `player.stop()` (e.g. its producer was
    /// cancelled) throws `CancellationError` after playback started. That is a cancellation, not
    /// a failure: the session ends `.cancelled` at once, never `.failed` or `.finished`.
    func testPostStartSourceCancellationEndsSessionAsCancelledNotFailed() async throws {
        let node = FakeOutputNode()
        let player = StreamingAudioPlayer(makeOutputNode: { node })
        let events = EventBox()
        player.onEvent = { events.append($0) }
        let sessionID = UUID()
        // 10 * 80ms crosses the 0.6s prebuffer threshold, so .started fires before the cancel.
        var steps: [ScriptedAudioSource.Step] = (0..<10).map { _ in .frame(Self.frame(samples: 1_920)) }
        steps.append(.fail(CancellationError()))
        let source = ScriptedAudioSource(steps: steps)

        try await player.startPlayback(source, sessionID: sessionID)
        XCTAssertTrue(events.values.contains(.started(sessionID: sessionID)))

        // No buffers are marked played: cancellation must not wait for a drain.
        try await waitUntilAsync { events.values.contains(.cancelled(sessionID: sessionID)) }
        XCTAssertEqual(events.values.filter { !$0.isLevel }, [
            .scheduled(sessionID: sessionID),
            .started(sessionID: sessionID),
            .cancelled(sessionID: sessionID),
        ])
    }

    /// Before `.started`, a cancelled source makes `startPlayback` throw `CancellationError` with
    /// no terminal event, so `TTSRouter` treats it as cancellation, not a fallback-worthy failure.
    func testPreStartSourceCancellationThrowsCancellationErrorWithoutTerminalEvent() async {
        let node = FakeOutputNode()
        let player = StreamingAudioPlayer(makeOutputNode: { node })
        let events = EventBox()
        player.onEvent = { events.append($0) }
        let sessionID = UUID()
        let source = ScriptedAudioSource(steps: [
            .frame(Self.frame(samples: 1_920)),
            .fail(CancellationError()),
        ])

        do {
            try await player.startPlayback(source, sessionID: sessionID)
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(events.values.filter { !$0.isLevel }, [.scheduled(sessionID: sessionID)])
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/PocketTTSAudioSourceTests -only-testing:RelayTests/StreamingAudioPlayerTests 2>&1 | grep -E "error:|Test Case .*(passed|failed)|\*\* TEST" | tail -40`
Expected: FAIL in `testCancelMakesNextThrowCancellationError` ("A cancelled source must throw...") and in `testPostStartSourceCancellationEndsSessionAsCancelledNotFailed` ("Timed out waiting for condition" after about 5 s). `testPreStartSourceCancellation...` passes already; it pins the pre-start half of the contract.

- [ ] **Step 3: Implement**

3a. In `Relay/SpeechOut/TTSAudioSource.swift`, replace:

```swift
/// Provider-neutral, pull-based synthesized PCM stream.
protocol TTSAudioSource: Sendable {
```

with:

```swift
/// Provider-neutral, pull-based synthesized PCM stream.
///
/// Contract every conforming source must follow:
/// - `next()` returns the next frame, or `nil` exactly when the stream has FINISHED normally
///   (every frame was produced).
/// - Once `cancel()` has run, or the producer itself was cancelled, `next()` throws
///   `CancellationError`. It never returns `nil` for a cancelled stream:
///   `StreamingAudioPlayer` ends the session as `.finished` on `nil` and as `.cancelled` on
///   `CancellationError`, so `nil` would report a cancelled response as fully spoken.
/// - Any other producer failure is thrown as is.
/// - `cancel()` is idempotent.
protocol TTSAudioSource: Sendable {
```

3b. In `Relay/SpeechOut/PocketTTSAudioSource.swift`, replace:

```swift
    func next() async throws -> TTSAudioFrame? {
        do {
            return try await source.next()
        } catch is CancellationError {
            // A cancelled source yields no more frames rather than surfacing the cancellation.
            return nil
        }
    }
```

with:

```swift
    /// Throws `CancellationError` after `cancel()`, per the `TTSAudioSource` contract.
    func next() async throws -> TTSAudioFrame? {
        try await source.next()
    }
```

3c. In `Relay/SpeechOut/StreamingAudioPlayer.swift`, in `pump(_:sessionID:)`, replace:

```swift
        } catch is CancellationError {
            guard currentSessionID == sessionID, !explicitlyStopped else { return }
            handleSourceFailure(CancellationError(), sessionID: sessionID)
            return
        } catch {
```

with:

```swift
        } catch is CancellationError {
            guard currentSessionID == sessionID, !explicitlyStopped else { return }
            if started {
                endCancelled(sessionID: sessionID)
            } else {
                // Pre-start: `startPlayback` throws `CancellationError`, which `TTSRouter`
                // rethrows as cancellation rather than falling back to another backend.
                handleSourceFailure(CancellationError(), sessionID: sessionID)
            }
            return
        } catch {
```

3d. In the same file, add this method right after `handleSourceFailure(_:sessionID:)`:

```swift
    /// The source reported cancellation after playback started, without `stop()` being called
    /// on this player (e.g. its producer was cancelled). Per the `TTSAudioSource` contract that
    /// is a cancellation, not a failure: stop output now, without draining, and end the session
    /// as `.cancelled`, the same terminal event `stop()` emits.
    private func endCancelled(sessionID: UUID) {
        tearDownPlayback(cancelSource: false)
        currentSessionID = nil
        activeSource = nil
        onEvent?(.cancelled(sessionID: sessionID))
    }
```

3e. In the doc comment of `handleSourceFailure`, replace the first line:

```swift
    /// A source failure (including `CancellationError`) or an engine-start failure. Before playback
```

with:

```swift
    /// A source failure (including a pre-start `CancellationError`; a post-start one goes through
    /// `endCancelled`) or an engine-start failure. Before playback
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/PocketTTSAudioSourceTests -only-testing:RelayTests/StreamingAudioPlayerTests -only-testing:RelayTests/KokoroTTSAudioSourceTests -only-testing:RelayTests/AppleTTSAudioSourceTests -only-testing:RelayTests/TTSAudioPipeTests -only-testing:RelayTests/PocketTTSBackendTests -only-testing:RelayTests/TTSRouterTests 2>&1 | grep -E "error:|Test Case .*(passed|failed)|\*\* TEST" | tail -40`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Relay/SpeechOut/TTSAudioSource.swift Relay/SpeechOut/PocketTTSAudioSource.swift Relay/SpeechOut/StreamingAudioPlayer.swift RelayTests/SpeechOut/PocketTTSAudioSourceTests.swift RelayTests/SpeechOut/StreamingAudioPlayerTests.swift
git commit -m "fix(speech): make cancelled TTS sources throw and end as cancelled"
```

---

### Task 6: A stale Apple voice id no longer stops all TTS

**Problem:** `AppleTTSBackend.makeAudioSource` throws `.invalidInput` for an unknown voice identifier (for example, a voice the user deleted). `.invalidInput` is not fallback-worthy, so `TTSRouter` stops routing and nothing speaks. `AppleTTSAudioSource` already falls back to the default voice when `AVSpeechSynthesisVoice(identifier:)` is `nil`, so the backend check is removed.

**Files:**
- Modify: `Relay/SpeechOut/AppleTTSBackend.swift`
- Test: `RelayTests/SpeechOut/AppleTTSBackendTests.swift`

- [ ] **Step 1: Write the failing test**

In `RelayTests/SpeechOut/AppleTTSBackendTests.swift`, replace the whole `testMakeAudioSourceRejectsAnUnknownVoiceIdentifierWithoutBuildingASynthesizer` method with:

```swift
    /// A stale saved voice id (e.g. a voice the user deleted) must fall back to the default voice.
    /// Throwing `.invalidInput` there is not fallback-worthy, so it used to stop all TTS.
    func testMakeAudioSourceFallsBackToTheDefaultVoiceForAnUnknownVoiceIdentifier() async throws {
        let synthesizerCount = SynthesizerCounter()
        let backend = makeBackend(synthesizerCount: synthesizerCount)

        let source = try await backend.makeAudioSource(
            text: "hello",
            options: TTSOptions(voiceIdentifier: "not-a-real-voice")
        )

        XCTAssertTrue(source is AppleTTSAudioSource)
        XCTAssertEqual(synthesizerCount.value, 1)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/AppleTTSBackendTests 2>&1 | grep -E "error:|Test Case .*(passed|failed)|\*\* TEST" | tail -40`
Expected: FAIL. The test throws `SpeechBackendError.invalidInput`.

- [ ] **Step 3: Implement**

In `Relay/SpeechOut/AppleTTSBackend.swift`, replace:

```swift
    func makeAudioSource(text: String, options: TTSOptions) async throws -> any TTSAudioSource {
        if let identifier = options.voiceIdentifier, AVSpeechSynthesisVoice(identifier: identifier) == nil {
            throw SpeechBackendError.invalidInput
        }
        return AppleTTSAudioSource(
```

with:

```swift
    /// An unknown `voiceIdentifier` (e.g. a saved voice since removed from the system) is not an
    /// error: `AppleTTSAudioSource` falls back to the default system voice.
    func makeAudioSource(text: String, options: TTSOptions) async throws -> any TTSAudioSource {
        AppleTTSAudioSource(
```

The replacement drops the `return` keyword; the method body is now the single `AppleTTSAudioSource(...)` expression. The argument lines after it stay exactly as they are:

```swift
            text: text,
            rate: options.rate,
            voiceIdentifier: options.voiceIdentifier,
            synthesizer: makeSynthesizer(),
            converter: bufferConverter
        )
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/AppleTTSBackendTests -only-testing:RelayTests/AppleTTSAudioSourceTests 2>&1 | grep -E "error:|Test Case .*(passed|failed)|\*\* TEST" | tail -40`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Relay/SpeechOut/AppleTTSBackend.swift RelayTests/SpeechOut/AppleTTSBackendTests.swift
git commit -m "fix(speech): fall back to the default Apple voice for a stale voice id"
```

---

### Task 7: Dictation errors name the backend that failed

**Problem:** `DictationCoordinator.actionableMessage(for:)` hardcodes Apple Speech ("Download the Apple Speech assets, then try again.", "Apple Speech requires a newer version of macOS.", "Apple Speech is unavailable on this Mac.") even when Parakeet or Whisper failed. The announced backend name is not enough: when the only backend is Parakeet with no model downloaded, `preferredBackendDisplayName()` returns `nil` (the backend is skipped), and `transcribe` then throws `.modelNotDownloaded`. So `STTRouter` records the display name of the backend whose error the final transcribe threw, and the coordinator uses it for transcription-stage errors. Interim (live-preview) transcriptions never touch it.

**Files:**
- Modify: `Relay/SpeechIn/STTRouter.swift`
- Modify: `Relay/SpeechIn/DictationCoordinator.swift`
- Test: `RelayTests/SpeechIn/STTRouterTests.swift`
- Test: `RelayTests/SpeechIn/DictationCoordinatorTests.swift`

- [ ] **Step 1: Write the failing tests**

1a. In `RelayTests/SpeechIn/STTRouterTests.swift`, add these methods inside `final class STTRouterTests`, right before `private func assertStopsRouting`:

```swift
    // MARK: lastFailedBackendDisplayName

    func testRecordsTheBackendWhoseErrorWasThrown() async {
        let first = FakeSTTBackend(id: "first", error: .unavailable("offline"))
        let second = FakeSTTBackend(id: "second", error: .resourceExhausted)
        let router = makeRouter([first, second])

        _ = try? await router.transcribe(audio: audio, options: .init())

        XCTAssertEqual(router.lastFailedBackendDisplayName, "second")
    }

    func testRecordsASkippedBackendWhenItsAvailabilityErrorIsThrown() async {
        let first = FakeSTTBackend(id: "first")
        first.availabilityValue = .modelNotDownloaded
        let router = makeRouter([first])

        _ = try? await router.transcribe(audio: audio, options: .init())

        XCTAssertEqual(router.lastFailedBackendDisplayName, "first")
    }

    func testClearsTheFailedBackendAfterASuccessfulTranscription() async throws {
        let first = FakeSTTBackend(id: "first", error: .unavailable("offline"))
        let router = makeRouter([first])
        _ = try? await router.transcribe(audio: audio, options: .init())
        XCTAssertEqual(router.lastFailedBackendDisplayName, "first")

        first.error = nil
        _ = try await router.transcribe(audio: audio, options: .init())

        XCTAssertNil(router.lastFailedBackendDisplayName)
    }

    func testInterimFailuresNeverTouchTheFailedBackend() async {
        let first = FakeSTTBackend(id: "first", error: .unavailable("offline"))
        let router = makeRouter([first])

        _ = try? await router.transcribeForInterim(audio: audio, options: .init())

        XCTAssertNil(router.lastFailedBackendDisplayName)
    }
```

1b. In `RelayTests/SpeechIn/DictationCoordinatorTests.swift`, inside `testEveryKnownDictationErrorHasStableActionableStatus`, replace these three tuples:

```swift
            (SpeechBackendError.modelNotDownloaded, "Dictation failed: Download the Apple Speech assets, then try again."),
```
```swift
            (SpeechBackendError.unsupportedOS, "Dictation failed: Apple Speech requires a newer version of macOS."),
            (SpeechBackendError.unsupportedHardware, "Dictation failed: Apple Speech is unavailable on this Mac."),
```

with (the fake backend in this test is named `Fake`):

```swift
            (SpeechBackendError.modelNotDownloaded, "Dictation failed: Download the Fake model in Settings, then try again."),
```
```swift
            (SpeechBackendError.unsupportedOS, "Dictation failed: Fake requires a newer version of macOS."),
            (SpeechBackendError.unsupportedHardware, "Dictation failed: Fake is unavailable on this Mac."),
```

1c. In the same file, make `NamedFakeBackend`'s availability configurable. Replace, inside `private final class NamedFakeBackend`:

```swift
    func availability() async -> BackendAvailability { .available }
    func prepare() async throws {}
    func transcribe(audio: AudioInput, options: STTOptions) async throws -> Transcript {
        events.append("stt.transcribe.\(id)")
```

with:

```swift
    var availabilityValue: BackendAvailability = .available
    func availability() async -> BackendAvailability { availabilityValue }
    func prepare() async throws {}
    func transcribe(audio: AudioInput, options: STTOptions) async throws -> Transcript {
        events.append("stt.transcribe.\(id)")
```

1d. Add this method right after `testEveryKnownDictationErrorHasStableActionableStatus`:

```swift
    /// The real-world case: the only backend (Parakeet) has no model, so it is skipped before
    /// listening starts (nothing is announced) and the router throws `.modelNotDownloaded`.
    /// The message must name Parakeet, not Apple Speech.
    func testModelNotDownloadedStatusNamesTheSkippedBackend() async {
        let events = EventLog()
        var statuses: [String] = []
        let parakeet = NamedFakeBackend(id: "parakeet", displayName: "Parakeet", events: events)
        parakeet.availabilityValue = .modelNotDownloaded
        let coordinator = DictationCoordinator(
            microphone: FakeMicrophone(events: events),
            sttRouter: STTRouter(backends: [parakeet.id: parakeet], backendOrder: { ["parakeet"] }),
            processor: RulesTranscriptProcessor(),
            textInserter: FakeTextInserter(events: events),
            stopSpeech: {},
            status: { statuses.append($0) },
            activity: RecordingActivityOverlay()
        )

        await coordinator.start()
        await coordinator.finish()

        XCTAssertEqual(statuses.last, "Dictation failed: Download the Parakeet model in Settings, then try again.")
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/STTRouterTests -only-testing:RelayTests/DictationCoordinatorTests 2>&1 | grep -E "error:|Test Case .*(passed|failed)|\*\* TEST" | tail -40`
Expected: build FAILS with `error: value of type 'STTRouter' has no member 'lastFailedBackendDisplayName'`.

- [ ] **Step 3: Implement in STTRouter**

In `Relay/SpeechIn/STTRouter.swift`:

3a. Replace:

```swift
    private var cachedCandidateOrder: [String]?
```

with:

```swift
    private var cachedCandidateOrder: [String]?
    /// Display name of the backend whose error the most recent FINAL `transcribe(audio:options:)`
    /// threw (the one that failed, or the last one skipped as unavailable). `nil` after a
    /// success, or when no registered backend was tried. Interim transcriptions never touch it.
    /// Lets dictation error copy name the backend that needs attention.
    private(set) var lastFailedBackendDisplayName: String?
```

3b. Replace:

```swift
    func transcribe(audio: AudioInput, options: STTOptions) async throws -> Transcript {
        let order = cachedCandidateOrder ?? backendOrder()
        cachedCandidateOrder = nil
        return try await transcribe(audio: audio, options: options, order: order)
    }

    func transcribeForInterim(audio: AudioInput, options: STTOptions) async throws -> Transcript {
        try await transcribe(audio: audio, options: options, order: backendOrder())
    }

    private func transcribe(audio: AudioInput, options: STTOptions, order: [String]) async throws -> Transcript {
        var lastError: SpeechBackendError = .unavailable("No STT backend is available")

        for id in order {
            guard let backend = backends[id] else { continue }
            switch classify(await backend.availability()) {
            case .use:
                break
            case let .terminal(error):
                throw error
            case let .skip(error):
                lastError = error
                continue
            }

            do {
                return try await backend.transcribe(audio: audio, options: options)
            } catch let error as SpeechBackendError where error.isFallbackWorthy {
                lastError = error
            } catch {
                throw error
            }
        }

        throw lastError
    }
```

with:

```swift
    func transcribe(audio: AudioInput, options: STTOptions) async throws -> Transcript {
        let order = cachedCandidateOrder ?? backendOrder()
        cachedCandidateOrder = nil
        lastFailedBackendDisplayName = nil
        return try await transcribe(audio: audio, options: options, order: order) { failedName in
            lastFailedBackendDisplayName = failedName
        }
    }

    func transcribeForInterim(audio: AudioInput, options: STTOptions) async throws -> Transcript {
        try await transcribe(audio: audio, options: options, order: backendOrder()) { _ in }
    }

    /// `onFailure` receives the display name of the backend whose error is about to be thrown
    /// (`nil` when no registered backend was tried), right before the throw.
    private func transcribe(
        audio: AudioInput,
        options: STTOptions,
        order: [String],
        onFailure: (String?) -> Void
    ) async throws -> Transcript {
        var lastError: SpeechBackendError = .unavailable("No STT backend is available")
        var lastErrorBackendName: String?

        for id in order {
            guard let backend = backends[id] else { continue }
            switch classify(await backend.availability()) {
            case .use:
                break
            case let .terminal(error):
                onFailure(backend.displayName)
                throw error
            case let .skip(error):
                lastError = error
                lastErrorBackendName = backend.displayName
                continue
            }

            do {
                return try await backend.transcribe(audio: audio, options: options)
            } catch let error as SpeechBackendError where error.isFallbackWorthy {
                lastError = error
                lastErrorBackendName = backend.displayName
            } catch {
                onFailure(backend.displayName)
                throw error
            }
        }

        onFailure(lastErrorBackendName)
        throw lastError
    }
```

- [ ] **Step 4: Implement in DictationCoordinator**

In `Relay/SpeechIn/DictationCoordinator.swift`:

4a. In `fail(_:at:session:)`, replace:

```swift
        status("Dictation failed: \(actionableMessage(for: error))")
    }
```

with:

```swift
        // Only a transcription-stage error came from a speech backend; name the one that failed.
        let backendName = stage == .transcription ? sttRouter.lastFailedBackendDisplayName : nil
        status("Dictation failed: \(actionableMessage(for: error, backendName: backendName))")
    }
```

4b. Replace:

```swift
    private func actionableMessage(for error: Error) -> String {
        switch error {
        case SpeechBackendError.unavailable:
            "Speech recognition is unavailable. Try again after it is ready."
        case SpeechBackendError.modelNotDownloaded:
            "Download the Apple Speech assets, then try again."
        case SpeechBackendError.initializationFailed:
            "Speech recognition could not start. Try again."
        case SpeechBackendError.unsupportedOS:
            "Apple Speech requires a newer version of macOS."
        case SpeechBackendError.unsupportedHardware:
            "Apple Speech is unavailable on this Mac."
```

with:

```swift
    /// `backendName` is the display name of the speech backend that produced `error`, when
    /// known (see `STTRouter.lastFailedBackendDisplayName`). Never hardcode one backend here.
    private func actionableMessage(for error: Error, backendName: String? = nil) -> String {
        switch error {
        case SpeechBackendError.unavailable:
            "Speech recognition is unavailable. Try again after it is ready."
        case SpeechBackendError.modelNotDownloaded:
            backendName.map { "Download the \($0) model in Settings, then try again." }
                ?? "Download a speech recognition model in Settings, then try again."
        case SpeechBackendError.initializationFailed:
            "Speech recognition could not start. Try again."
        case SpeechBackendError.unsupportedOS:
            "\(backendName ?? "This speech recognition backend") requires a newer version of macOS."
        case SpeechBackendError.unsupportedHardware:
            "\(backendName ?? "This speech recognition backend") is unavailable on this Mac."
```

The rest of the switch stays unchanged. The `start()` call site (`actionableMessage(for: error)`) keeps using the default `nil`.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/STTRouterTests -only-testing:RelayTests/DictationCoordinatorTests 2>&1 | grep -E "error:|Test Case .*(passed|failed)|\*\* TEST" | tail -40`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add Relay/SpeechIn/STTRouter.swift Relay/SpeechIn/DictationCoordinator.swift RelayTests/SpeechIn/STTRouterTests.swift RelayTests/SpeechIn/DictationCoordinatorTests.swift
git commit -m "fix(dictation): name the failing speech backend in error messages"
```

---

### Task 8: One speech action at a time for Read Selection / Replay Last

**Problem:** `AppModel.handleHotkey` spawns an untracked `Task { await readSelection() }` / `Task { await replayLast() }` per press, so two quick presses both reach the speech coordinator and double-speak. Stop Speech also cannot cancel a replay that is still resolving focus. Fix: keep one `speechActionTask`, cancel/replace it on each press (Stop Speech cancels it too), and check `Task.isCancelled` before speaking. A `CancellationError` from speech (which Task 3 makes more likely: Stop during preparation) is an intentional stop, not a failure, so these paths no longer record `.ttsFailed` or put the raw error text in the status.

**Files:**
- Modify: `Relay/App/AppModel.swift`
- Test: `RelayTests/App/AppModelTests.swift`

- [ ] **Step 1: Write the failing tests**

In `RelayTests/App/AppModelTests.swift`, add these methods right after `testReplayFailureIsLoggedAsTTSFailure`:

```swift
    func testTwoQuickReadSelectionPressesSpeakOnlyOnce() async {
        let selection = FakeSelectionReader(text: "selected")
        let speech = FakeSpeechCoordinator()
        let hotkeys = FakeHotkeyManager()
        let model = makeModel(selection: selection, speech: speech, hotkeys: hotkeys)

        hotkeys.send(.readSelection, .pressed)
        hotkeys.send(.readSelection, .pressed)
        await waitUntil { !speech.requests.isEmpty }
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(speech.requests.count, 1)
        withExtendedLifetime(model) {}
    }

    func testTwoQuickReplayPressesReplayOnlyOnce() async {
        let speech = FakeSpeechCoordinator()
        let hotkeys = FakeHotkeyManager()
        let model = makeModel(speech: speech, hotkeys: hotkeys)

        hotkeys.send(.replayLast, .pressed)
        hotkeys.send(.replayLast, .pressed)
        await waitUntil { speech.replayCount > 0 }
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(speech.replayCount, 1)
        withExtendedLifetime(model) {}
    }

    func testStopSpeechCancelsAPendingReplay() async {
        let speech = FakeSpeechCoordinator()
        let hotkeys = FakeHotkeyManager()
        let model = makeModel(speech: speech, hotkeys: hotkeys)

        hotkeys.send(.replayLast, .pressed)
        hotkeys.send(.stopSpeech, .pressed)
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(speech.replayCount, 0)
        XCTAssertEqual(speech.stopCount, 1)
        withExtendedLifetime(model) {}
    }

    func testCancelledReadSelectionIsNotReportedAsFailure() async {
        let speech = FakeSpeechCoordinator(speakError: CancellationError())
        let hotkeys = FakeHotkeyManager()
        let model = makeModel(speech: speech, hotkeys: hotkeys)

        hotkeys.send(.readSelection, .pressed)
        await waitUntil { !speech.requests.isEmpty }
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertFalse(model.diagnosticsEntries.contains { $0.event == .ttsFailed })
        XCTAssertEqual(model.statusText, "Ready")
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/AppModelTests 2>&1 | grep -E "error:|Test Case .*(passed|failed)|\*\* TEST" | tail -40`
Expected: FAIL in all four new tests (2 requests, replayCount 2, replayCount 1, and a `.ttsFailed` entry with a non-"Ready" status).

- [ ] **Step 3: Implement**

In `Relay/App/AppModel.swift`:

3a. Replace:

```swift
    @ObservationIgnored private var dictationTask: Task<Void, Never>?
```

with:

```swift
    @ObservationIgnored private var dictationTask: Task<Void, Never>?
    /// The in-flight Read Selection / Replay Last action. Each new press of either hotkey, and
    /// Stop Speech, cancels it, so two quick presses can never both reach the speech coordinator.
    @ObservationIgnored private var speechActionTask: Task<Void, Never>?
```

3b. In `deinit`, replace:

```swift
        dictationTask?.cancel()
```

with:

```swift
        dictationTask?.cancel()
        speechActionTask?.cancel()
```

3c. In `handleHotkey(_:phase:)`, replace:

```swift
        case .readSelection:
            Task { await readSelection() }
        case .stopSpeech:
            speechCoordinator.stop()
            diagnostics.record(.ttsStopped)
            statusText = "Speech stopped"
        case .replayLast:
            Task { await replayLast() }
```

with:

```swift
        case .readSelection:
            startSpeechAction { await $0.readSelection() }
        case .stopSpeech:
            speechActionTask?.cancel()
            speechActionTask = nil
            speechCoordinator.stop()
            diagnostics.record(.ttsStopped)
            statusText = "Speech stopped"
        case .replayLast:
            startSpeechAction { await $0.replayLast() }
```

3d. Add this method right after `handleHotkey(_:phase:)` (before `toggleAutoRead()`):

```swift
    /// Replaces any in-flight speech action with `action`. The cancelled one checks
    /// `Task.isCancelled` before speaking, so it never reaches the speech coordinator.
    private func startSpeechAction(_ action: @escaping @MainActor (AppModel) async -> Void) {
        speechActionTask?.cancel()
        speechActionTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            await action(self)
        }
    }
```

3e. Replace the whole `readSelection()` method with:

```swift
    private func readSelection() async {
        do {
            let selection = try selectionReader.readSelection()
            diagnostics.record(selection.source == .accessibility ? .selectionAccessibility : .selectionClipboard)
            let prepared = preprocessor.prepare(text: selection.text, mode: .userRequested)
            let request = SpeechRequest(
                text: prepared,
                source: .selection,
                mode: .userRequested,
                sessionID: nil
            )
            guard !Task.isCancelled else { return }
            try await speechCoordinator.speak(request)
            diagnostics.record(.ttsSubmitted)
        } catch is CancellationError {
            // Stopped or superseded on purpose: not a failure.
        } catch {
            diagnostics.record(error is SelectionReadingError ? .selectionUnavailable : .ttsFailed)
            statusText = error.localizedDescription
        }
    }
```

3f. Replace the body of `replayLast()` (keep its doc comment) with:

```swift
    private func replayLast() async {
        // Prune stale sessions before this tier-1/tier-2 read, same as
        // `AgentAutoReadCoordinator`: a dead-process session (or one gone quiet past the TTL)
        // must not be offered to focus resolution or treated as hosting the frontmost terminal.
        await pruneDeadSessions(in: sessionRegistry, using: processInspector)
        let sessions = await sessionRegistry.sessions()

        for session in sessions {
            let decision = await focusResolution.resolve(session: session)
            guard decision.state == .focused, decision.confidence == .high else { continue }
            guard !Task.isCancelled else { return }
            await speakFocusedSessionReply(session)
            return
        }

        guard !Task.isCancelled else { return }
        if let frontmostPID = await frontmostApps.current()?.pid,
           sessions.contains(where: { $0.processAncestry.contains(frontmostPID) }),
           integrationManager.latestResponse != nil,
           await speakGlobalLatestReply() {
            return
        }

        guard !Task.isCancelled else { return }
        await speakLastSpokenText()
    }
```

3g. In `speakFocusedSessionReply(_:)`, replace:

```swift
        } catch {
            diagnostics.record(.ttsFailed)
            statusText = error.localizedDescription
        }
    }

    /// Tier 2: speaks the global latest agent reply via `IntegrationManager.speakLatest`. Called
```

with:

```swift
        } catch is CancellationError {
            // Stopped or superseded on purpose: not a failure.
        } catch {
            diagnostics.record(.ttsFailed)
            statusText = error.localizedDescription
        }
    }

    /// Tier 2: speaks the global latest agent reply via `IntegrationManager.speakLatest`. Called
```

3h. In `speakGlobalLatestReply()`, replace:

```swift
            return true
        } catch {
            diagnostics.record(.ttsFailed)
            statusText = error.localizedDescription
            return true
        }
```

with:

```swift
            return true
        } catch is CancellationError {
            return true
        } catch {
            diagnostics.record(.ttsFailed)
            statusText = error.localizedDescription
            return true
        }
```

3i. In `speakLastSpokenText()`, replace:

```swift
            integrationDiagnosticsLog.append(stage: "replay-last", outcome: "last-spoken", detail: "")
        } catch {
```

with:

```swift
            integrationDiagnosticsLog.append(stage: "replay-last", outcome: "last-spoken", detail: "")
        } catch is CancellationError {
            // Stopped or superseded on purpose: not a failure.
        } catch {
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/AppModelTests -only-testing:RelayTests/AppModelHotkeySideEffectTests 2>&1 | grep -E "error:|Test Case .*(passed|failed)|\*\* TEST" | tail -40`
Expected: `** TEST SUCCEEDED **` (the existing replay tier tests and `testReadSelectionPressedPreprocessesAndSpeaksUserRequest` included).

- [ ] **Step 5: Commit**

```bash
git add Relay/App/AppModel.swift RelayTests/App/AppModelTests.swift
git commit -m "fix(app): run one read-selection or replay action at a time"
```

---

### Task 9: Refresh the stable RelayHook helper at launch

**Problem:** `installBundledHelperIfPresent()` runs only from the Install button (`installIntegration`). After an app update or `install.sh`, every hook keeps running the old helper at `~/Library/Application Support/Relay/bin/RelayHook`. Fix: `startIntegrations()` re-checks each provider's install status and, when any provider has hooks installed, refreshes the stable helper with the existing `helperInstaller`. Failures go to `integrationDiagnosticsLog`; they are never thrown.

**Files:**
- Modify: `Relay/App/AppModel.swift`
- Test: `RelayTests/App/AppModelIntegrationsTests.swift`

- [ ] **Step 1: Write the failing tests**

In `RelayTests/App/AppModelIntegrationsTests.swift`, add this section right after `testStartIntegrationsCalledTwiceKeepsSocketListeningTrueDespiteAlreadyStartedThrow` (each test pre-starts the injected receiver on a temp path, the same safety trick that test uses, so `startIntegrations()` never opens the real socket):

```swift
    // MARK: - Launch-time helper refresh

    private func startedTempReceiver() throws -> HookEnvelopeReceiver {
        let receiver = HookEnvelopeReceiver()
        try receiver.start(path: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path)
        return receiver
    }

    private func writeBundledHelper(_ script: String) throws -> URL {
        let bundleDirectory = tempDirectory.appendingPathComponent("bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleDirectory, withIntermediateDirectories: true)
        let bundledHelperURL = bundleDirectory.appendingPathComponent("RelayHook")
        try Data(script.utf8).write(to: bundledHelperURL)
        return bundledHelperURL
    }

    func testStartIntegrationsRefreshesAStaleStableHelperWhenAProviderIsInstalled() throws {
        let bundledHelperURL = try writeBundledHelper("#!/bin/sh\necho old\n")
        let helperInstaller = makeHelperInstaller()
        try helperInstaller.installBundledHelper(from: bundledHelperURL)
        // An app update ships a new bundled helper; nobody presses Install again.
        try Data("#!/bin/sh\necho new\n".utf8).write(to: bundledHelperURL)
        let claudeInstaller = makeClaudeInstaller()
        try claudeInstaller.install()
        let receiver = try startedTempReceiver()
        defer { receiver.stop() }
        let model = makeModel(
            claudeCodeInstaller: claudeInstaller,
            helperInstaller: helperInstaller,
            bundledHelperURL: bundledHelperURL,
            hookEnvelopeReceiver: receiver
        )

        model.startIntegrations()

        XCTAssertEqual(
            try Data(contentsOf: helperInstaller.installedHelperURL),
            Data("#!/bin/sh\necho new\n".utf8)
        )
        XCTAssertEqual(model.integrationStatus(for: .claudeCode), .installedAwaitingFirstEvent)
    }

    func testStartIntegrationsDoesNotInstallAHelperWhenNoProviderIsInstalled() throws {
        let bundledHelperURL = try writeBundledHelper("#!/bin/sh\necho new\n")
        let helperInstaller = makeHelperInstaller()
        let receiver = try startedTempReceiver()
        defer { receiver.stop() }
        let model = makeModel(
            helperInstaller: helperInstaller,
            bundledHelperURL: bundledHelperURL,
            hookEnvelopeReceiver: receiver
        )

        model.startIntegrations()

        XCTAssertFalse(FileManager.default.fileExists(atPath: helperInstaller.installedHelperURL.path))
    }

    func testStartIntegrationsRecordsAHelperRefreshFailureWithoutThrowing() throws {
        let bundledHelperURL = try writeBundledHelper("#!/bin/sh\necho new\n")
        let unwritableBase = tempDirectory.appendingPathComponent("unwritable-appsupport", isDirectory: true)
        try FileManager.default.createDirectory(at: unwritableBase, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: unwritableBase.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unwritableBase.path)
        }
        let claudeInstaller = makeClaudeInstaller()
        try claudeInstaller.install()
        let receiver = try startedTempReceiver()
        defer { receiver.stop() }
        let model = makeModel(
            claudeCodeInstaller: claudeInstaller,
            helperInstaller: HelperInstaller(baseDirectory: unwritableBase),
            bundledHelperURL: bundledHelperURL,
            hookEnvelopeReceiver: receiver
        )

        model.startIntegrations()

        XCTAssertTrue(model.integrationDiagnosticsEntries().contains {
            $0.stage == "helper" && $0.outcome == "refresh-failed" && $0.detail == "stable-helper-unavailable"
        })
        XCTAssertTrue(model.isSocketListening)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/AppModelIntegrationsTests 2>&1 | grep -E "error:|Test Case .*(passed|failed)|\*\* TEST" | tail -40`
Expected: FAIL in `testStartIntegrationsRefreshesAStaleStableHelperWhenAProviderIsInstalled` (content is still "old", and the status is `.notInstalled`) and in `testStartIntegrationsRecordsAHelperRefreshFailureWithoutThrowing` (no diagnostics entry). The no-provider test passes already.

- [ ] **Step 3: Implement**

In `Relay/App/AppModel.swift`:

3a. Replace:

```swift
    func startIntegrations() {
        try? hookEnvelopeReceiver.start(path: Self.integrationSocketPath)
        isSocketListening = hookEnvelopeReceiver.isListening
        integrationManager.start()
    }
```

with:

```swift
    func startIntegrations() {
        try? hookEnvelopeReceiver.start(path: Self.integrationSocketPath)
        isSocketListening = hookEnvelopeReceiver.isListening
        integrationManager.start()
        refreshInstalledHelperIfNeeded()
    }

    /// Keeps the stable-path `RelayHook` copy in step with the helper bundled in THIS build.
    /// `installBundledHelperIfPresent` otherwise runs only from the Install button, so after an
    /// app update (or `install.sh`) every hook would keep running whatever helper the last
    /// explicit install copied. Refreshes only when at least one provider's config actually
    /// points hooks at the stable path. Never throws: a failure is recorded in
    /// `integrationDiagnosticsLog`, and a previously installed helper stays in place.
    private func refreshInstalledHelperIfNeeded() {
        for provider in AgentProvider.allCases {
            checkIntegration(provider)
        }
        guard AgentProvider.allCases.contains(where: { Self.hooksInstalled(installerStatuses[$0]) }) else {
            return
        }
        do {
            try installBundledHelperIfPresent()
        } catch {
            integrationDiagnosticsLog.append(stage: "helper", outcome: "refresh-failed", detail: "stable-helper-unavailable")
        }
    }

    private static func hooksInstalled(_ status: IntegrationStatus?) -> Bool {
        switch status {
        case .installedAwaitingFirstEvent, .installedTrustRequired, .active:
            true
        case .notInstalled, .configurationError, nil:
            false
        }
    }
```

3b. In `installBundledHelperIfPresent()`, replace:

```swift
        do {
            try helperInstaller.installBundledHelper(from: bundledHelperURL)
        } catch {
            if hadValidStableHelperBefore {
                installerLogger.log("bundled RelayHook helper refresh failed; a previously installed helper is still present")
            } else {
                installerLogger.log("bundled RelayHook helper refresh failed")
            }
        }
```

with:

```swift
        do {
            try helperInstaller.installBundledHelper(from: bundledHelperURL)
            integrationDiagnosticsLog.append(stage: "helper", outcome: "refreshed", detail: "")
        } catch {
            if hadValidStableHelperBefore {
                installerLogger.log("bundled RelayHook helper refresh failed; a previously installed helper is still present")
            } else {
                installerLogger.log("bundled RelayHook helper refresh failed")
            }
            integrationDiagnosticsLog.append(
                stage: "helper",
                outcome: "refresh-failed",
                detail: hadValidStableHelperBefore ? "previous-helper-kept" : "copy-failed"
            )
        }
```

3c. Update the doc comment of `startIntegrations()`: replace the line

```swift
    /// dispatching decoded events through `integrationManager`.
```

with:

```swift
    /// dispatching decoded events through `integrationManager`. Also re-reads each provider's
    /// install status and, when any provider has hooks installed, refreshes the stable
    /// `RelayHook` helper (see `refreshInstalledHelperIfNeeded`).
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/AppModelIntegrationsTests -only-testing:RelayTests/HelperInstallerTests 2>&1 | grep -E "error:|Test Case .*(passed|failed)|\*\* TEST" | tail -40`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Relay/App/AppModel.swift RelayTests/App/AppModelIntegrationsTests.swift
git commit -m "fix(integrations): refresh the stable RelayHook helper at launch"
```

---

### Task 10: Share the hook wire types with RelayHook

**Problem:** `RelayHook/main.swift` duplicates the wire format as `WireAgentProvider` / `WireHookEnvelope`, so it can drift from `Relay/Integrations/Domain/HookEnvelope.swift` and `AgentProvider.swift`. Both files are Foundation-only (verified: `HookEnvelope` uses only `AgentProvider`, `Date`, `String`, `Int32`, `[String: String]`), so they compile into the RelayHook target directly, mirroring how the app already compiles `RelayHook/HookTransportClient.swift` and `BoundedStdinReader.swift`. XcodeGen reuses the one existing file reference and adds a second build file (verified in a scratch copy).

**This task changes `project.yml` and regenerates `Relay.xcodeproj/project.pbxproj`. Commit both by explicit path in Step 5.**

**Files:**
- Modify: `project.yml` (RelayHook target `sources`)
- Modify: `Relay.xcodeproj/project.pbxproj` (regenerated)
- Modify: `RelayHook/main.swift`

- [ ] **Step 1: Add the shared sources to the RelayHook target**

In `project.yml`, replace:

```yaml
  RelayHook:
    type: tool
    platform: macOS
    sources:
      - path: RelayHook
```

with:

```yaml
  RelayHook:
    type: tool
    platform: macOS
    sources:
      - path: RelayHook
      - path: Relay/Integrations/Domain/HookEnvelope.swift
      - path: Relay/Integrations/Domain/AgentProvider.swift
```

Do not touch any other line of `project.yml`.

- [ ] **Step 2: Delete the duplicated wire types in RelayHook/main.swift**

2a. Replace this whole block (from `// MARK: - Wire-only types` down to, but not including, `// MARK: - Constants`):

```swift
// MARK: - Wire-only types
//
// RelayHook is a standalone executable and cannot import the Relay app
// target, so the wire format is intentionally duplicated here. Keep these in
// sync with `Relay/Integrations/Domain/HookEnvelope.swift` and
// `AgentProvider.swift`. Wire schema version is `1`.

private enum WireAgentProvider: String, Codable {
    case claudeCode = "claude-code"
    case codex = "codex"
}

private struct WireHookEnvelope: Codable {
    let schemaVersion: Int
    let provider: WireAgentProvider
    let rawPayload: String
    let parentPID: Int32
    let environment: [String: String]
    let capturedAt: Date
}

```

with:

```swift
// MARK: - Wire format
//
// `HookEnvelope` and `AgentProvider` are compiled into this target straight
// from `Relay/Integrations/Domain/` (see `project.yml`), so the helper and the
// app always share one definition of the wire schema. Wire schema version is `1`.

```

2b. Replace `private func parseProvider(from arguments: [String]) -> WireAgentProvider? {` with `private func parseProvider(from arguments: [String]) -> AgentProvider? {`.

2c. Replace `return WireAgentProvider(rawValue: arguments[valueIndex])` with `return AgentProvider(rawValue: arguments[valueIndex])`.

2d. Replace `return WireAgentProvider(rawValue: value)` with `return AgentProvider(rawValue: value)`.

2e. Replace `let envelope = WireHookEnvelope(` with `let envelope = HookEnvelope(`.

- [ ] **Step 3: Regenerate the project and build**

```bash
xcodegen generate
grep -c "HookEnvelope.swift in Sources" Relay.xcodeproj/project.pbxproj
grep -c "AgentProvider.swift in Sources" Relay.xcodeproj/project.pbxproj
```

Expected: `Created project at <worktree root>/Relay.xcodeproj`, then `4` and `4` (two build-file definitions plus two Sources-phase references each: app and RelayHook).

Run: `xcodebuild build -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|\*\* BUILD" | tail -20`
Expected: `** BUILD SUCCEEDED **` (this builds the RelayHook target too, because the app depends on it).

Run: `grep -rn "WireAgentProvider\|WireHookEnvelope" RelayHook Relay`
Expected: no output.

- [ ] **Step 4: Run the integration tests**

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/HookEnvelopeTests -only-testing:RelayTests/HookTransportClientTests -only-testing:RelayTests/HookEnvelopeReceiverTests -only-testing:RelayTests/ProjectSmokeTests 2>&1 | grep -E "error:|Test Case .*(passed|failed)|\*\* TEST" | tail -40`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Stage and verify**

```bash
git add project.yml Relay.xcodeproj/project.pbxproj RelayHook/main.swift
git diff --cached --stat
git diff --cached project.yml
```

Expected:
- `git diff --cached --stat` lists exactly `RelayHook/main.swift`, `project.yml` (2 insertions), and `Relay.xcodeproj/project.pbxproj` (4 insertions).
- `git diff --cached project.yml` shows only the two `- path: Relay/Integrations/Domain/...` lines.

If `project.pbxproj` shows more than those 4 insertions, `xcodegen generate` picked up something else: stop and report the extra diff instead of committing it.

- [ ] **Step 6: Commit**

```bash
git commit -m "refactor(hook): compile shared HookEnvelope and AgentProvider into RelayHook"
git status --short
```

Expected after commit: `git status --short` prints nothing.

---

### Task 11: Surface hook socket start failures

**Problem:** `AppModel.startIntegrations()` does `try? hookEnvelopeReceiver.start(...)`, so every failure is silent, including `.activeListenerPresent` (another Relay instance already owns the socket), which leaves hooks going to the other instance with no hint why. Fix: catch the error, ignore `.alreadyStarted`, record every other case to `IntegrationDiagnosticsLog` with a fixed label, and show a user-facing message in Integrations settings. The socket path becomes injectable (defaulting to the production path) so this is testable without touching the real socket.

**Files:**
- Modify: `Relay/Integrations/Transport/UnixSocketServer.swift`
- Modify: `Relay/App/AppModel.swift`
- Modify: `Relay/App/Settings/IntegrationsSettingsView.swift`
- Test: `RelayTests/App/AppModelIntegrationsTests.swift`

- [ ] **Step 1: Write the failing tests**

1a. In `RelayTests/App/AppModelIntegrationsTests.swift`, change `makeModel` to accept a socket path. Replace:

```swift
        integrationManager: IntegrationManager? = nil,
        hookEnvelopeReceiver: HookEnvelopeReceiver = HookEnvelopeReceiver()
    ) -> AppModel {
```

with:

```swift
        integrationManager: IntegrationManager? = nil,
        hookEnvelopeReceiver: HookEnvelopeReceiver = HookEnvelopeReceiver(),
        hookSocketPath: String? = nil
    ) -> AppModel {
```

and replace:

```swift
            bundledHelperURL: bundledHelperURL ?? nonexistentBundledHelperURL
        )
    }
```

with:

```swift
            bundledHelperURL: bundledHelperURL ?? nonexistentBundledHelperURL,
            hookSocketPath: hookSocketPath ?? AppModel.integrationSocketPath
        )
    }
```

1b. In `testStartIntegrationsCalledTwiceKeepsSocketListeningTrueDespiteAlreadyStartedThrow`, replace the last two lines:

```swift
        model.startIntegrations() // throws .alreadyStarted again
        XCTAssertTrue(model.isSocketListening)
    }
```

with:

```swift
        model.startIntegrations() // throws .alreadyStarted again
        XCTAssertTrue(model.isSocketListening)
        // A redundant start is not a problem worth reporting.
        XCTAssertNil(model.socketStatusMessage)
        XCTAssertFalse(model.integrationDiagnosticsEntries().contains { $0.stage == "socket-start" })
    }

    /// Uses a short `/tmp` path (a unix socket path must fit in `sun_path`, 104 bytes) that is
    /// never the production socket. A second `UnixSocketServer` already holds that directory's
    /// single-instance lock, standing in for another running Relay.
    func testAnotherInstanceOwningTheSocketIsSurfacedAndRecorded() throws {
        let directory = "/tmp/relay-it-\(UUID().uuidString.prefix(8))"
        let socketPath = "\(directory)/relay.sock"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let otherInstance = UnixSocketServer()
        try otherInstance.start(path: socketPath) { _ in }
        defer { otherInstance.stop() }
        let model = makeModel(hookSocketPath: socketPath)

        model.startIntegrations()

        XCTAssertFalse(model.isSocketListening)
        XCTAssertEqual(model.socketStatusMessage, AppModel.anotherInstanceOwnsSocketMessage)
        XCTAssertTrue(model.integrationDiagnosticsEntries().contains {
            $0.stage == "socket-start" && $0.outcome == "failed" && $0.detail == "active-listener-present"
        })
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/AppModelIntegrationsTests 2>&1 | grep -E "error:|Test Case .*(passed|failed)|\*\* TEST" | tail -40`
Expected: build FAILS with `error: extra argument 'hookSocketPath' in call` and `value of type 'AppModel' has no member 'socketStatusMessage'`.

- [ ] **Step 3: Add fixed diagnostics labels to the server error**

In `Relay/Integrations/Transport/UnixSocketServer.swift`, add right after the closing `}` of `enum UnixSocketServerError`:

```swift

extension UnixSocketServerError {
    /// Fixed, privacy-safe label for `IntegrationDiagnosticsLog` entries: the case name only,
    /// never a path or errno text.
    var diagnosticsLabel: String {
        switch self {
        case .alreadyStarted: "already-started"
        case .pathTooLong: "path-too-long"
        case .directoryCreationFailed: "directory-creation-failed"
        case .staleSocketCheckFailed: "stale-socket-check-failed"
        case .unsafeStaleSocket: "unsafe-stale-socket"
        case .staleSocketRemovalFailed: "stale-socket-removal-failed"
        case .socketCreationFailed: "socket-creation-failed"
        case .bindFailed: "bind-failed"
        case .chmodFailed: "chmod-failed"
        case .listenFailed: "listen-failed"
        case .activeListenerPresent: "active-listener-present"
        case .lockAcquisitionFailed: "lock-acquisition-failed"
        }
    }
}
```

- [ ] **Step 4: Implement in AppModel**

In `Relay/App/AppModel.swift`:

4a. Replace:

```swift
    private(set) var isSocketListening = false
```

with:

```swift
    private(set) var isSocketListening = false
    /// Why the hook socket could not be opened, when the user can act on it (e.g. another Relay
    /// instance owns it). Shown under the socket status in Integrations settings. `nil` while
    /// listening, and before `startIntegrations()` has run.
    private(set) var socketStatusMessage: String?
```

4b. Replace:

```swift
    @ObservationIgnored private let integrationDiagnosticsLog: IntegrationDiagnosticsLog

```

(the stored property declaration, followed by the blank line before `/// Builds the real production`) with:

```swift
    @ObservationIgnored private let integrationDiagnosticsLog: IntegrationDiagnosticsLog
    /// Where `startIntegrations()` opens the hook socket. Always `integrationSocketPath` in
    /// production; injectable so tests can use a temp path.
    @ObservationIgnored let hookSocketPath: String

```

4c. In the public `init(...)` parameter list, replace:

```swift
        integrationDiagnosticsLog: IntegrationDiagnosticsLog = IntegrationDiagnosticsLog()
    ) {
        let settings = settingsStore.load()
```

with:

```swift
        integrationDiagnosticsLog: IntegrationDiagnosticsLog = IntegrationDiagnosticsLog(),
        hookSocketPath: String = AppModel.integrationSocketPath
    ) {
        let settings = settingsStore.load()
```

and in the same initializer's body replace:

```swift
        self.integrationDiagnosticsLog = integrationDiagnosticsLog
        activationObserver = nil
        dictationTask = nil
        permissionSnapshot = permissionService.snapshot()
        microphonePermissionGranted = microphonePermissions.isGranted()
        launchAtLoginEnabled = loginItemService.isEnabled
        self.settings = settings
```

with:

```swift
        self.integrationDiagnosticsLog = integrationDiagnosticsLog
        self.hookSocketPath = hookSocketPath
        activationObserver = nil
        dictationTask = nil
        permissionSnapshot = permissionService.snapshot()
        microphonePermissionGranted = microphonePermissions.isGranted()
        launchAtLoginEnabled = loginItemService.isEnabled
        self.settings = settings
```

4d. In the `private init(...)` body, replace:

```swift
        self.integrationDiagnosticsLog = integrationDiagnosticsLog
        activationObserver = nil
        dictationTask = nil
        permissionSnapshot = permissionService.snapshot()
        microphonePermissionGranted = microphonePermissions.isGranted()
        launchAtLoginEnabled = loginItemService.isEnabled
        settings = loadedSettings
```

with:

```swift
        self.integrationDiagnosticsLog = integrationDiagnosticsLog
        hookSocketPath = Self.integrationSocketPath
        activationObserver = nil
        dictationTask = nil
        permissionSnapshot = permissionService.snapshot()
        microphonePermissionGranted = microphonePermissions.isGranted()
        launchAtLoginEnabled = loginItemService.isEnabled
        settings = loadedSettings
```

4e. Replace:

```swift
    func startIntegrations() {
        try? hookEnvelopeReceiver.start(path: Self.integrationSocketPath)
        isSocketListening = hookEnvelopeReceiver.isListening
```

with:

```swift
    func startIntegrations() {
        do {
            try hookEnvelopeReceiver.start(path: hookSocketPath)
            socketStatusMessage = nil
        } catch UnixSocketServerError.alreadyStarted {
            // A redundant call while the receiver already listens: nothing to report.
        } catch {
            let label = (error as? UnixSocketServerError)?.diagnosticsLabel ?? "unexpected-error"
            integrationDiagnosticsLog.append(stage: "socket-start", outcome: "failed", detail: label)
            socketStatusMessage = Self.socketStartFailureMessage(for: error)
        }
        isSocketListening = hookEnvelopeReceiver.isListening
```

4f. Add these members right after `refreshInstalledHelperIfNeeded()`'s `hooksInstalled(_:)` helper (added in Task 9):

```swift
    static let anotherInstanceOwnsSocketMessage =
        "Another Relay instance is already listening for agent hooks. Quit it, then relaunch Relay."
    static let socketStartFailedMessage =
        "Relay could not open the agent hook socket. See Diagnostics for details."

    private static func socketStartFailureMessage(for error: Error) -> String {
        if case UnixSocketServerError.activeListenerPresent = error {
            return anotherInstanceOwnsSocketMessage
        }
        return socketStartFailedMessage
    }
```

4g. In the doc comment of `startIntegrations()`, replace:

```swift
    ///   real socket. A failure to start the socket never crashes the app; `isSocketListening` is
    ///   always set from `hookEnvelopeReceiver.isListening` afterward, so it stays authoritative
    ///   even when the start attempt throws (e.g. `.alreadyStarted` on a redundant call) while the
    ///   socket the receiver already holds open remains listening.
```

with:

```swift
    ///   real socket. A failure to start the socket never crashes the app: `.alreadyStarted` (a
    ///   redundant call) is ignored, and any other failure is recorded in
    ///   `integrationDiagnosticsLog` and surfaced through `socketStatusMessage`.
    ///   `isSocketListening` is always set from `hookEnvelopeReceiver.isListening` afterward, so
    ///   it stays authoritative either way.
```

- [ ] **Step 5: Show the message in settings**

In `Relay/App/Settings/IntegrationsSettingsView.swift`, replace:

```swift
            Section("Socket") {
                HStack {
                    Text(model.isSocketListening ? "Listening" : "Not listening")
                        .foregroundStyle(model.isSocketListening ? .green : .orange)
                    Spacer()
                    Text(AppModel.integrationSocketPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
```

with:

```swift
            Section("Socket") {
                HStack {
                    Text(model.isSocketListening ? "Listening" : "Not listening")
                        .foregroundStyle(model.isSocketListening ? .green : .orange)
                    Spacer()
                    Text(model.hookSocketPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if let message = model.socketStatusMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/AppModelIntegrationsTests -only-testing:RelayTests/SettingsViewsSmokeTests -only-testing:RelayTests/UnixSocketServerOwnershipTests 2>&1 | grep -E "error:|Test Case .*(passed|failed)|\*\* TEST" | tail -40`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 7: Commit**

```bash
git add Relay/Integrations/Transport/UnixSocketServer.swift Relay/App/AppModel.swift Relay/App/Settings/IntegrationsSettingsView.swift RelayTests/App/AppModelIntegrationsTests.swift
git commit -m "fix(integrations): report hook socket start failures instead of ignoring them"
```

---

### Task 12: Oversized hook envelopes are refused and reported

**Problem:** `RelayHook` caps raw stdin at 1.5 MiB, but JSON string escaping (`"` becomes `\"`, `/` becomes `\/`, control characters become `\uXXXX`) can push the encoded envelope past the server's 2 MiB line limit. The server then drops the line silently (`UnixSocketServer.swift`, `ClientConnection.append`: `continue // Oversized but newline-terminated: drop silently.`), and an unterminated overflow just closes the connection. Fix: one shared limit constant (`HookEnvelope.maxWireBytes`, compiled into both targets since Task 10); the hook encodes with `.withoutEscapingSlashes` and refuses to send an envelope over the limit; the server records a "dropped oversized" entry to the integration diagnostics log.

**Files:**
- Modify: `Relay/Integrations/Domain/HookEnvelope.swift`
- Modify: `RelayHook/main.swift`
- Modify: `Relay/Integrations/Transport/UnixSocketServer.swift`
- Test: `RelayTests/Integrations/HookEnvelopeTests.swift`
- Test: `RelayTests/Integrations/UnixSocketServerTests.swift`

- [ ] **Step 1: Write the failing tests**

1a. In `RelayTests/Integrations/HookEnvelopeTests.swift`, add inside `final class HookEnvelopeTests`, after the existing test:

```swift
    func testWireDataLeavesSlashesUnescapedAndRoundTrips() throws {
        let envelope = HookEnvelope(
            schemaVersion: 1,
            provider: .codex,
            rawPayload: #"{"cwd":"/Users/me/project","transcript_path":"/tmp/t.jsonl"}"#,
            parentPID: 42,
            environment: ["TERM_PROGRAM": "ghostty"],
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let data = try XCTUnwrap(try envelope.wireData())
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertFalse(text.contains(#"\/"#))
        XCTAssertEqual(try JSONDecoder().decode(HookEnvelope.self, from: data), envelope)
    }

    /// 1.5 MiB of quotes passes RelayHook's raw stdin cap, but each `"` escapes to `\"`, so the
    /// encoded line is about 3 MiB, over the socket's limit. It must be refused before sending.
    func testWireDataRefusesAnEnvelopeWhoseEscapedEncodingExceedsTheSocketLimit() throws {
        let envelope = HookEnvelope(
            schemaVersion: 1,
            provider: .claudeCode,
            rawPayload: String(repeating: "\"", count: 1_500 * 1_024),
            parentPID: 42,
            environment: [:],
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertNil(try envelope.wireData())
    }

    func testSocketLineLimitIsTheSharedEnvelopeWireLimit() {
        XCTAssertEqual(UnixSocketServer.maxLineBytes, HookEnvelope.maxWireBytes)
    }
```

1b. In `RelayTests/Integrations/UnixSocketServerTests.swift`, add inside `final class UnixSocketServerTests`, right after `testOversizedLineIsDroppedAndConnectionIsClosedWithoutHangingTheServer`:

```swift
    /// Unit-level (no socket), so the newline-terminated oversized path is deterministic
    /// regardless of how the kernel splits reads.
    func testOversizedTerminatedLineIsReportedAndFollowingLinesStillArrive() {
        let connection = UnixSocketClientConnection(fd: -1)
        let lines = LineBox()
        var oversizedByteCounts: [Int] = []
        var bytes = [UInt8](repeating: UInt8(ascii: "a"), count: UnixSocketServer.maxLineBytes + 1)
        bytes.append(UInt8(ascii: "\n"))
        bytes.append(contentsOf: Array(#"{"ok":1}"#.utf8))
        bytes.append(UInt8(ascii: "\n"))

        let shouldClose = connection.append(
            bytes: bytes[...],
            onLine: { lines.append($0) },
            onOversizedLine: { oversizedByteCounts.append($0) }
        )

        XCTAssertFalse(shouldClose)
        XCTAssertEqual(oversizedByteCounts, [UnixSocketServer.maxLineBytes + 1])
        XCTAssertEqual(lines.values, [#"{"ok":1}"#])
    }

    func testOversizedUnterminatedLineIsRecordedInDiagnosticsAndClosesTheConnection() async throws {
        let path = temporarySocketPath()
        let diagnostics = IntegrationDiagnosticsLog()
        let server = UnixSocketServer(diagnostics: diagnostics)
        try server.start(path: path) { _ in }
        defer { server.stop() }

        try await UnixSocketTestClient.send(String(repeating: "a", count: UnixSocketServer.maxLineBytes + 1), to: path)

        let deadline = Date().addingTimeInterval(2)
        while !diagnostics.snapshot().contains(where: { $0.stage == "socket" && $0.outcome == "dropped" }),
              Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let entry = try XCTUnwrap(diagnostics.snapshot().first { $0.stage == "socket" && $0.outcome == "dropped" })
        XCTAssertTrue(entry.detail.hasPrefix("oversized-unterminated ("))
    }
```

and add at the end of the file (file scope):

```swift

/// Collects lines from `UnixSocketClientConnection`'s `@Sendable` `onLine` callback in tests.
private final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ line: String) {
        lock.lock()
        storage.append(line)
        lock.unlock()
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/HookEnvelopeTests -only-testing:RelayTests/UnixSocketServerTests 2>&1 | grep -E "error:|Test Case .*(passed|failed)|\*\* TEST" | tail -40`
Expected: build FAILS with `value of type 'HookEnvelope' has no member 'wireData'`, `type 'HookEnvelope' has no member 'maxWireBytes'`, and `cannot find 'UnixSocketClientConnection' in scope`.

- [ ] **Step 3: Add the shared limit and wire encoding**

In `Relay/Integrations/Domain/HookEnvelope.swift`, append after the struct:

```swift

extension HookEnvelope {
    /// Largest encoded envelope, in bytes, excluding the trailing newline, that Relay's hook
    /// socket accepts as one line. `RelayHook` checks it before sending and `UnixSocketServer`
    /// enforces it on receipt. This file is compiled into both targets, so they cannot disagree.
    static let maxWireBytes = 2 * 1024 * 1024

    /// The exact bytes `RelayHook` writes for this envelope, or `nil` when they would exceed
    /// `maxWireBytes`. Slashes stay unescaped (`/`, not `\/`) so paths in `rawPayload` do not
    /// grow on the wire. Quotes, backslashes, and control characters still escape and can
    /// roughly double a payload, which is why the size is checked after encoding, not on the
    /// raw stdin byte count.
    func wireData() throws -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(self)
        return data.count <= Self.maxWireBytes ? data : nil
    }
}
```

- [ ] **Step 4: Use it in RelayHook**

In `RelayHook/main.swift`, replace:

```swift
    do {
        let data = try JSONEncoder().encode(envelope)
        let client = HookTransportClient(socketPath: HookTransportClient.defaultSocketPath)
```

with:

```swift
    do {
        guard let data = try envelope.wireData() else {
            // JSON escaping grew a payload that passed the raw stdin cap past the socket's
            // line limit. Relay would drop the line anyway, so don't send it.
            debugLog("skip=oversized-envelope")
            finish()
        }
        let client = HookTransportClient(socketPath: HookTransportClient.defaultSocketPath)
```

- [ ] **Step 5: Report oversized lines on the server**

In `Relay/Integrations/Transport/UnixSocketServer.swift`:

5a. Replace:

```swift
    /// Maximum size, in bytes, of a single newline-delimited line. Matches
    /// the Relay hook transport's global 2 MiB envelope limit.
    static let maxLineBytes = 2 * 1024 * 1024
```

with:

```swift
    /// Maximum size, in bytes, of a single newline-delimited line: the shared
    /// hook envelope wire limit `RelayHook` also checks before sending.
    static let maxLineBytes = HookEnvelope.maxWireBytes
```

5b. Replace:

```swift
    private var connections: [Int32: ClientConnection] = [:]
```

with:

```swift
    private var connections: [Int32: UnixSocketClientConnection] = [:]
```

5c. In `beginReading(clientFD:)`, replace:

```swift
        let connection = ClientConnection(fd: clientFD)
```

with:

```swift
        let connection = UnixSocketClientConnection(fd: clientFD)
```

5d. In `handleReadable(clientFD:)`, replace:

```swift
            let shouldClose = connection.append(
                bytes: readBuffer[0..<bytesRead],
                onLine: onLine
            )
```

with:

```swift
            let shouldClose = connection.append(
                bytes: readBuffer[0..<bytesRead],
                onLine: onLine,
                onOversizedLine: { byteCount in
                    self.diagnostics.append(stage: "socket", outcome: "dropped", detail: "oversized-line (\(byteCount) bytes)")
                },
                onOversizedUnterminated: { byteCount in
                    self.diagnostics.append(stage: "socket", outcome: "dropped", detail: "oversized-unterminated (\(byteCount) bytes)")
                }
            )
```

5e. Replace the whole `private final class ClientConnection { ... }` declaration at the end of the file with:

```swift
/// Per-connection buffering state, confined to `UnixSocketServer`'s serial
/// queue. Not `Sendable`: never touch it off that queue. Internal (not
/// private) only so tests can drive `append` directly.
final class UnixSocketClientConnection {
    let fd: Int32
    var source: DispatchSourceRead?
    private var buffer: [UInt8] = []

    init(fd: Int32) {
        self.fd = fd
    }

    /// Appends newly read bytes, emitting one `onLine` call per
    /// newline-delimited line found. A newline-terminated line over
    /// `UnixSocketServer.maxLineBytes` is dropped and reported through
    /// `onOversizedLine` (with its byte count), and the lines after it still
    /// arrive. Returns `true` when the connection must be closed because the
    /// buffer exceeded the maximum size without a newline ever arriving,
    /// reported through `onOversizedUnterminated`. This bounds memory growth
    /// instead of buffering an unbounded amount of data.
    func append(
        bytes: ArraySlice<UInt8>,
        onLine: (@Sendable (String) -> Void)?,
        onOversizedLine: (Int) -> Void,
        onOversizedUnterminated: (Int) -> Void = { _ in }
    ) -> Bool {
        buffer.append(contentsOf: bytes)

        while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineBytes = buffer[buffer.startIndex..<newlineIndex]
            defer { buffer.removeSubrange(buffer.startIndex...newlineIndex) }

            guard lineBytes.count <= UnixSocketServer.maxLineBytes else {
                onOversizedLine(lineBytes.count)
                continue
            }
            if let line = String(bytes: lineBytes, encoding: .utf8) {
                onLine?(line)
            }
        }

        if buffer.count > UnixSocketServer.maxLineBytes {
            onOversizedUnterminated(buffer.count)
            buffer.removeAll(keepingCapacity: false)
            return true
        }
        return false
    }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/HookEnvelopeTests -only-testing:RelayTests/UnixSocketServerTests -only-testing:RelayTests/UnixSocketServerOwnershipTests -only-testing:RelayTests/HookEnvelopeReceiverTests -only-testing:RelayTests/HookTransportClientTests 2>&1 | grep -E "error:|Test Case .*(passed|failed)|\*\* TEST" | tail -40`
Expected: `** TEST SUCCEEDED **`

Run: `xcodebuild build -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|\*\* BUILD" | tail -20`
Expected: `** BUILD SUCCEEDED **` (proves `RelayHook/main.swift` compiles against the shared `wireData()`).

Do NOT run the built `RelayHook` by hand: if Relay is running, it would deliver a real envelope to it.

- [ ] **Step 7: Commit**

```bash
git add Relay/Integrations/Domain/HookEnvelope.swift RelayHook/main.swift Relay/Integrations/Transport/UnixSocketServer.swift RelayTests/Integrations/HookEnvelopeTests.swift RelayTests/Integrations/UnixSocketServerTests.swift
git commit -m "fix(integrations): refuse and report oversized hook envelopes"
```

---

### Task 13: Record auto-read speech failures; fix speak-latest diagnostics

**Problem:** (a) `AgentAutoReadCoordinator.speak` does `try? await speech.speak(request)`, so an auto-read speech failure leaves no trace after the "spoke" entry. (b) `AppModel.speakLatestAgentResponse()` records `.ttsSubmitted` even when `integrationManager.speakLatest()` returned `false` (nothing to speak).

**Files:**
- Modify: `Relay/Sessions/AgentAutoReadCoordinator.swift`
- Modify: `Relay/App/AppModel.swift`
- Test: `RelayTests/Sessions/AgentAutoReadCoordinatorTests.swift`
- Test: `RelayTests/App/AppModelIntegrationsTests.swift`

- [ ] **Step 1: Write the failing tests**

1a. In `RelayTests/Sessions/AgentAutoReadCoordinatorTests.swift`, replace the `RecordingSpeechSink` class with:

```swift
@MainActor
private final class RecordingSpeechSink: SpeechSubmitting, @unchecked Sendable {
    var requests: [SpeechRequest] = []
    /// Thrown from `speak` after recording the request, when set.
    var error: Error?
    func speak(_ request: SpeechRequest) async throws {
        requests.append(request)
        if let error { throw error }
    }
}
```

and add this method right after `testFocusedSessionRecordsSpokeDiagnosticsEntry`:

```swift
    func testSpeechFailureRecordsSpeakFailedDiagnosticsEntry() async {
        struct SpeechBoom: Error {}
        let speech = RecordingSpeechSink()
        speech.error = SpeechBoom()
        let diagnostics = IntegrationDiagnosticsLog()
        let focus = MutableStubFocusResolver()
        focus.focusedSessionID = .init(provider: .claudeCode, providerSessionID: "a")
        let coordinator = makeCoordinator(focus: focus, speech: speech, autoRead: true, diagnostics: diagnostics)

        await coordinator.handle(makeAutoReadEvent(providerSessionID: "a", text: "Done."))

        XCTAssertTrue(diagnostics.snapshot().contains {
            $0.stage == "coordinator" && $0.outcome == "speak-failed" && $0.detail == "provider=claude-code"
        })
    }
```

1b. In `RelayTests/App/AppModelIntegrationsTests.swift`, add right after `testSpeakLatestAgentResponseFailureIsCaughtAndSurfacedWithoutCrashing`:

```swift
    func testSpeakLatestAgentResponseWithNothingToSpeakRecordsNoSubmission() async {
        let speech = FakeSpeechCoordinator()
        let events = AsyncStream<HookEnvelope> { _ in }
        let manager = IntegrationManager(
            events: events,
            integrations: [],
            store: LatestAgentResponseStore(),
            speechCoordinator: speech
        )
        let model = makeModel(integrationManager: manager)

        await model.speakLatestAgentResponse()

        XCTAssertTrue(speech.requests.isEmpty)
        XCTAssertFalse(model.diagnosticsEntries.contains { $0.event == .ttsSubmitted })
        XCTAssertEqual(model.statusText, "No agent response to speak yet.")
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/AgentAutoReadCoordinatorTests -only-testing:RelayTests/AppModelIntegrationsTests 2>&1 | grep -E "error:|Test Case .*(passed|failed)|\*\* TEST" | tail -40`
Expected: FAIL in `testSpeechFailureRecordsSpeakFailedDiagnosticsEntry` (no entry) and in `testSpeakLatestAgentResponseWithNothingToSpeakRecordsNoSubmission` (`.ttsSubmitted` present, status "Ready").

- [ ] **Step 3: Implement the auto-read failure diagnostic**

In `Relay/Sessions/AgentAutoReadCoordinator.swift`, replace:

```swift
        try? await speech.speak(request)
    }
```

with:

```swift
        do {
            try await speech.speak(request)
        } catch is CancellationError {
            // Superseded by newer speech or stopped by the user: expected, but still visible.
            diagnostics.append(stage: "coordinator", outcome: "speak-cancelled", detail: "provider=\(event.provider.rawValue)")
        } catch {
            // Structural only: never the error's own text, which could carry content.
            diagnostics.append(stage: "coordinator", outcome: "speak-failed", detail: "provider=\(event.provider.rawValue)")
        }
    }
```

- [ ] **Step 4: Fix speakLatestAgentResponse**

In `Relay/App/AppModel.swift`, replace:

```swift
    func speakLatestAgentResponse() async {
        do {
            try await integrationManager.speakLatest()
            diagnostics.record(.ttsSubmitted)
        } catch {
```

with:

```swift
    func speakLatestAgentResponse() async {
        do {
            guard try await integrationManager.speakLatest() else {
                statusText = "No agent response to speak yet."
                return
            }
            diagnostics.record(.ttsSubmitted)
        } catch {
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/AgentAutoReadCoordinatorTests -only-testing:RelayTests/AppModelIntegrationsTests 2>&1 | grep -E "error:|Test Case .*(passed|failed)|\*\* TEST" | tail -40`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add Relay/Sessions/AgentAutoReadCoordinator.swift Relay/App/AppModel.swift RelayTests/Sessions/AgentAutoReadCoordinatorTests.swift RelayTests/App/AppModelIntegrationsTests.swift
git commit -m "fix(integrations): record auto-read speech failures and empty speak-latest"
```

---

### Task 14: Full suite and final check

**Files:** none

- [ ] **Step 1: Run the full suite**

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Test Case .*failed|Executed|\*\* TEST" | tail -40`
Expected: `** TEST SUCCEEDED **`, with no `failed` lines. If a test fails, fix it in the task that caused it (a new commit with a `fix(...)` message) and rerun. Do not skip or delete tests.

- [ ] **Step 2: Confirm the branch contents**

```bash
git log --oneline main..HEAD
git status --short
git log main..HEAD --format=%B | grep -iE "co-authored-by|claude-session|generated with" || echo "no attribution lines"
```

Expected:
- 13 commits, one per Task 1 to 13.
- `git status --short` prints nothing (clean worktree).
- `no attribution lines`.

- [ ] **Step 3: Report**

Report the commit list, the full-suite result line, and any deviation from this plan (with its reason). Do not push or open a PR unless asked.
