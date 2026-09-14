# Task 4 Report: TTS Routing, Apple TTS, and Speech Coordination

## Status

Implemented and verified.

## Implementation

- Added `TTSRouter`, isolated to the main actor, with an existential backend registry keyed by backend ID and a closure that supplies the current ordered IDs for every request.
- Routing skips missing or unavailable registry entries, continues after fallback-worthy `SpeechBackendError` values, and immediately propagates non-fallback errors.
- Successful submission selects the active backend. Stop, pause, and resume are sent only to that backend; stop also clears it.
- Added `AppleTTSBackend` using `AVSpeechSynthesizer`. It reports voice selection, pause/resume, and fully-offline capabilities. An explicitly requested unknown voice is rejected as invalid input rather than silently speaking with a different voice.
- Added `SpeechCoordinator` with user-requested replacement semantics. It records a request only after successful submission and replay evaluates the current options closure at replay time.
- Regenerated `Relay.xcodeproj` with XcodeGen so the new production and test sources are included.

## TDD Evidence

### RED

After adding the focused tests first, ran:

```sh
xcodegen generate
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -derivedDataPath .derived-data -only-testing:RelayTests/TTSRouterTests -only-testing:RelayTests/SpeechCoordinatorTests test
```

The build failed for the expected reason: `TTSRouter` and `SpeechCoordinator` were not in scope. The result reported three missing-type/symbol failures.

### GREEN

After implementing the three production types, the same focused test selection was rerun outside the restricted sandbox because Swift macro plugin services require system access. Result:

- `TTSRouterTests`: 6 tests, 0 failures
- `SpeechCoordinatorTests`: 4 tests, 0 failures
- Selected total: 10 tests, 0 failures
- `** TEST SUCCEEDED **`

Covered behaviors:

- Backend ordering is read again between calls.
- Fallback-worthy errors continue to the next backend.
- Non-fallback errors stop routing.
- Missing and unavailable entries are skipped.
- Stop, pause, and resume target only the active backend.
- Apple TTS advertises all three implemented capabilities.
- User-requested speech replaces active speech; automatic speech does not.
- Replay is a no-op before success, preserves the last successful request, and uses options current at replay time.

## Full Verification

Ran once after the focused suite:

```sh
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -derivedDataPath .derived-data test
```

Result:

- XCTest suites: 20 tests, 0 failures
- Swift Testing suite: 1 test, 0 failures
- `** TEST SUCCEEDED **`

## Self-review

- Compared the implementation against every requirement in the task brief and the approved dynamic-registry ruling.
- Confirmed main-actor isolation is consistent across the backend contract, router, coordinator, fake, and tests.
- Confirmed a failed submission cannot replace the coordinator's replay target or router's active backend.
- Confirmed `git diff --check` reports no whitespace errors.
- No local neural TTS or UI work was added.

## Concerns

- `AVSpeechSynthesizer.speak` confirms that an utterance was submitted, not that playback completed. This matches the backend contract and the task's “successfully submitted” replay semantics.
- The test run emits benign macOS intents-service connection messages from the app test host; tests and build still complete successfully.

## Fix Round 1: Cross-backend stream replacement

### Finding addressed

A live backend-order change could route a later automatic request to a different backend while leaving the previous backend speaking and no longer reachable through router transport controls.

### Regression test and RED evidence

Added `testSwitchingBackendsStopsThePreviouslyActiveBackend`. It submits to backend A, changes the live order to prefer backend B, submits again, calls router stop, and verifies both A and B received exactly one stop at the appropriate point.

Command:

```sh
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -derivedDataPath .derived-data -only-testing:RelayTests/TTSRouterTests/testSwitchingBackendsStopsThePreviouslyActiveBackend test
```

Expected RED result:

```text
XCTAssertEqual failed: ("0") is not equal to ("1")
Executed 1 test, with 1 failure (0 unexpected)
** TEST FAILED **
```

Backend A's zero stop count demonstrated that it had been orphaned when B became active.

### Minimal fix

Before submitting to an available candidate, `TTSRouter` now checks backend object identity. If the candidate differs from the active backend, it stops and clears the prior backend before submission. Submissions to the same backend are unchanged, preserving automatic same-backend queuing and the coordinator's explicit user-requested stop behavior.

### Focused GREEN evidence

Command:

```sh
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -derivedDataPath .derived-data -only-testing:RelayTests/TTSRouterTests -only-testing:RelayTests/SpeechCoordinatorTests test
```

Result:

```text
TTSRouterTests: Executed 7 tests, with 0 failures
SpeechCoordinatorTests: Executed 4 tests, with 0 failures
Selected tests: Executed 11 tests, with 0 failures
** TEST SUCCEEDED **
```

### Full-suite verification

Final fresh command after strengthening the regression test to assert stop-before-speak event ordering:

```sh
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -derivedDataPath .derived-data test
```

Result:

```text
XCTest: Executed 21 tests, with 0 failures
Swift Testing: 1 test passed
** TEST SUCCEEDED **
```

The app test host continues to emit benign intents-service connection messages; they do not affect the successful result.
