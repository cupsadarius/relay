# Relay Cleanup 4: Speech Engines Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the duplicated model-loading, audio-source, and audio-buffer code in Relay's speech engines, and fix the concurrency, audio-route, and selection bugs found in the speech-engine review.

**Architecture:** One generic `ModelSessionLoader<Session>` actor replaces the three copies of the single-flight load state machine in the FluidAudio engines. `WhisperRuntime` gets its own keyed single-flight transition, plus an in-use counter so an unload waits for running transcriptions. One `PipedTTSAudioSource` holds the producer-task and `TTSAudioPipe` glue for Kokoro, PocketTTS and Apple TTS. For Apple TTS, the blocking `NSCondition` bridge goes away and a callback that never blocks takes its place. One `AudioBufferUtilities` file holds the converter feeder, RMS meter and (de)interleave loops. Audio-engine route changes now fail through the existing terminal paths. `STTRouter` returns an explicit selection token instead of keeping a hidden per-session candidate cache. Plan 1's read-only `lastFailedBackendDisplayName` diagnostic stays.

**Tech Stack:** Swift 6 strict concurrency, AVFoundation, Speech, Synchronization (`Mutex`), FluidAudio 0.15.7, WhisperKit 1.1.0, XcodeGen, XCTest, macOS 26.0+, arm64.

**Branch:** `cleanup/4-speech-engines`, cut from current `main`. Cleanup plans 1 and 2 are already merged into `main`. Plan 3 (`cleanup/3-integrations-sessions`) is NOT merged; this plan runs in parallel with it and must not wait for it.

---

## Assumptions from plans 1–2 (merged) and plan 3 (parallel) (re-read every file before you edit it)

This plan's snippets are written on top of the end state of `docs/superpowers/plans/2026-09-23-relay-cleanup-1-quick-fixes.md` and `docs/superpowers/plans/2026-09-23-relay-cleanup-2-dead-code.md`. When a snippet here and the file disagree on something those plans changed, keep what the plans did and apply only the change this task describes.

- **Plan 1 already landed:**
  - The `TTSRouter` stop-during-preparation fix (Task 3).
  - Whisper chunked hashing (Task 4).
  - Plan 1 Task 5, the TTS cancel contract:
    - After `cancel()`, `TTSAudioSource.next()` **throws `CancellationError`**. `PocketTTSAudioSource.next()` forwards it.
    - In `StreamingAudioPlayer.pump`, the `catch is CancellationError` branch calls the new `endCancelled(sessionID:)` once playback has started. This plan keeps that branch.
  - An unknown Apple voice falls back to the default voice instead of throwing `invalidInput` (Task 6).
  - Plan 1 Task 7:
    - `STTRouter.lastFailedBackendDisplayName` (`private(set)`) is set by the final `transcribe` only. `DictationCoordinator.fail` reads it for transcription-stage errors.
    - `actionableMessage(for:backendName:)` uses it.
    - `NamedFakeBackend` has a settable `availabilityValue`.
    - Four `STTRouterTests` (`testRecordsTheBackendWhoseErrorWasThrown`, `testRecordsASkippedBackendWhenItsAvailabilityErrorIsThrown`, `testClearsTheFailedBackendAfterASuccessfulTranscription`, `testInterimFailuresNeverTouchTheFailedBackend`) and `DictationCoordinatorTests.testModelNotDownloadedStatusNamesTheSkippedBackend` pin this. Task 14 keeps all of them passing.
- **Plan 2 already deleted:**
  - Whole-WAV `synthesize(text:…)` on the Kokoro and Pocket engines and their sessions.
  - (Correction, verified on `main`: `KokoroEngineError.textTooLong` was NOT deleted. It still maps `KokoroAneError.phonemeSequenceTooLong` in `FluidAudioKokoroEngine.synthesize(phonemes:voice:speed:)` and is pinned by `testSynthesizeMapsPhonemeSequenceTooLongToTextTooLong`. Leave it alone.)
  - The throwing protocol-extension defaults.
  - The pause/resume chain (`pause()`/`resume()` on the player and output node, `pauseSpeaking`/`continueSpeaking` where they were only used for that).
  - `STTCapabilities`/`TTSCapabilities` and every `capabilities` property.
  - Plan 2 Task 4:
    - `SpeechToTextBackend.prepare()` is gone from the protocol, from every STT backend (including `AppleSpeechBackend.prepare()`) and from every fake.
    - `BackendAvailability.initializing` is gone, together with its `case .initializing:` arm in `STTRouter.classify(_:)`.
  - Plan 2 Task 7:
    - The `delegate`, `speak(_:)`, `pauseSpeaking` and `continueSpeaking` members of `AppleSpeechSynthesizing` are gone.
    - The pause/resume chain is gone.
    - The `.scheduled` event is gone entirely.
  - `CandidatePlayback.committed`, the `.scheduled` playback event, `ParakeetBackend.downloadModels`, stale comments and `SPIKE` labels.

  Test fakes in this plan therefore declare **no** `capabilities` property, **no** `prepare()` and **no** `pause`/`resume` members. If one of those members is still a protocol requirement when you run a task, add it back to the fake as a trivial stub.
- **Plan 3 (not merged, runs in parallel):** this plan does not depend on anything plan 3 changes, and must not edit what plan 3 owns: `Relay/Integrations/`, `Relay/Sessions/` (including `AgentAutoReadCoordinator`), `Shared/RelayPaths.swift`/`Shared/BuildFlavor.swift`, `project.yml`, and the Whisper cache-directory wiring in `Relay/App/RelayRuntime.swift`. No step in this plan edits `RelayRuntime.swift`; if one ever needs to, keep the edit minimal and note "may conflict with plan 3 Task 4 (Whisper cache path) — resolve by keeping both changes". The expected merge conflict with plan 3 is `Relay.xcodeproj/project.pbxproj` (both plans add files): resolve it by taking either side and re-running `xcodegen generate`, never by hand-merging.
- The snippets below were re-checked against `main` after plans 1 and 2 merged (line numbers and quoted "replace X" code are current). Still re-read every file before editing it; if a file changed underneath this plan, apply the intent of the step.

## Global Constraints

- **Work in a dedicated worktree**, `.worktrees/cleanup-4-speech-engines` on branch `cleanup/4-speech-engines` (see Task 0). After `xcodegen generate`, commit the plan's `project.yml`/`Relay.xcodeproj/project.pbxproj` changes normally, with the task that caused them.
- Stage files by explicit path only. Never use `git add -A` or `git add .`.
- Commit messages are Conventional Commits. They **must not** contain `Co-Authored-By:`, `Claude-Session:` or any "Generated with Claude Code" line. A message ends at its last real line.
- Run `xcodegen generate` after you add or delete any Swift file. Never hand-edit `project.pbxproj`.
- **Never add `group:` entries to `project.yml`** (xcodegen 2.46 hangs on them). This plan needs no `project.yml` change at all: new files under `Relay/` and `RelayTests/` (including the new `Relay/Audio/` and `RelayTests/Audio/` folders) are picked up by the existing `path: Relay` / `path: RelayTests` sources.
- **Every `xcodebuild` command uses `-derivedDataPath /tmp/relay-dd-cleanup4`** (already in every command below), so this worktree never shares DerivedData with plan 3 or the main checkout. Add it to any ad-hoc `xcodebuild` you run.
- The full test suite must be green at the end of every task.
- Privacy rule:
  - Never log or put in an error: speech text, transcripts, phonemes, PCM, or raw `error.localizedDescription` from speech frameworks.
  - Error labels are fixed strings.
- Keep every behavior the existing tests pin unless a task says to change it.
- Out of scope:
  - An idle model-unload timer.
  - Splitting `SpeechCoordinator` or `DictationCoordinator` into several files.

Test command template (the user's form):

```bash
xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/relay-dd-cleanup4 -only-testing:RelayTests/<Class>/<method>
```

Full suite:

```bash
xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/relay-dd-cleanup4
```

Output to expect:
- A passing run ends with `** TEST SUCCEEDED **`.
- A failing assertion ends with `** TEST FAILED **`.
- A compile error prints `error:` lines and `** TEST FAILED **` (xcodebuild reports build failures under the test action this way).

## Execution Notes (fill in while executing)

- **Task 8 spike: which thread runs Apple TTS `write` callbacks:** not skipped (system voices were installed). `SPIKE apple-tts-write-callback: main=62 background=0 nonEmptyBuffers=61`, macOS 27.0 (arm64). All callbacks arrived on the main thread; `main > 0` means the old `NSCondition`-based bridge risked blocking the main actor `next()` also needs (a deadlock risk), confirming Task 9's never-blocking, explicitly-`@Sendable` callback is the correct fix regardless of which thread Apple uses.
- **Task 13 Step 7 manual check (real hardware, route change while dictating):** PENDING — not performed by this automated session; needs a human with real hardware to switch input devices mid-recording and confirm the pill surfaces the microphone error immediately and that dictation recovers on the next attempt.
- Deviations from this plan and why: Task 13's `testCloseWaitsForAnInFlightCallbackToLeave` (`CaptureCallbackGateTests`) as given waits on the same `XCTestExpectation` twice (`XCTWaiter.wait` then `wait(for:)`), which XCTest raises `API violation` for on this toolchain. Rewrote it with a lock-protected boolean flag polled with `Thread.sleep`, preserving the same assertion intent (close blocks while a callback is in flight, returns once it leaves) without reusing the expectation object.
- **Task 21 Step 1 (clean full-suite run):** `rm -rf` of the derived data dir, then `xcodegen generate` reproduced `project.pbxproj` byte-identical (`git status --short` empty). Clean rebuild: `** TEST SUCCEEDED **`, 948 tests (942 passed, 6 skipped, 0 failures).
- **Task 21 Step 2 (leftover greps):** all five greps (`inFlightLoad`/`enum LoadKind` outside `ModelSessionLoader.swift`; `AppleSpeechBufferBridge`/`NSCondition` outside `CaptureCallbackGate.swift`; `preferredBackendDisplayName`/`cachedCandidateOrder`/`MicrophoneLevelMeter`/`level(forFrame`; `engine: any …Engine = FluidAudio…`; `inferenceFailed(error.localizedDescription`) printed nothing, as expected.
- **Task 21 Step 3 (manual smoke test in the Debug app):** PENDING — not performed by this automated session. All four checks (dictation with live transcription and a single Whisper memory ramp on first load; Kokoro/PocketTTS/Apple playback waveform and immediate stop; output-device switch ending the session immediately with no 300s hang; input-device switch, already tracked as Task 13 Step 7) need a human at the physical machine with real audio hardware and Activity Monitor. Automated coverage for the underlying logic (route-change failure, no-double-buffering, level timing, single-load-per-locale) is in the corresponding unit tests added in this plan.
- Per the controller's explicit instruction, this branch was NOT rebased onto or merged with `main` even though `main` has moved (plan 3 merged first); the controller owns that rebase, and Step 5 (finishing-a-development-branch) was skipped for the same reason.

## File Structure

### Create

| File | Responsibility |
|---|---|
| `Relay/Backends/ModelSessionLoader.swift` | Generic single-flight, download-aware session loader actor (validation cache, join/fail-fast rules, `reset`, `unload`). |
| `Relay/SpeechOut/PipedTTSAudioSource.swift` | A `TTSAudioSource` fed by a producer closure through a bounded `TTSAudioPipe`. Maps finish, fail and cancel. |
| `Relay/Audio/AudioBufferUtilities.swift` | One-buffer `AVAudioConverter` pass, RMS×4 level meter, interleave and deinterleave. |
| `Relay/Audio/AudioEngineConfigurationObserver.swift` | Observes `AVAudioEngineConfigurationChange` for one engine on an injectable `NotificationCenter`. |
| `Relay/SpeechIn/CaptureCallbackGate.swift` | Lock-free-callout gate between the microphone tap thread and `stop()`. |
| `RelayTests/Backends/ModelSessionLoaderTests.swift` | Loader semantics (ported from the three engine test files). |
| `RelayTests/SpeechOut/PipedTTSAudioSourceTests.swift` | Producer/pipe mapping. |
| `RelayTests/SpeechOut/AppleTTSWriteCallbackSpikeTests.swift` | Real `AVSpeechSynthesizer.write` smoke/spike test (skips when no voices are installed). |
| `RelayTests/Audio/AudioBufferUtilitiesTests.swift` | Converter, RMS, (de)interleave. |
| `RelayTests/Audio/AudioEngineConfigurationObserverTests.swift` | Notification filtering and lifetime. |
| `RelayTests/SpeechIn/CaptureCallbackGateTests.swift` | Gate open, enter, fail and close semantics. |

### Modify

| File | Change |
|---|---|
| `Relay/Backends/FluidAudioParakeetEngine.swift`, `FluidAudioKokoroEngine.swift`, `FluidAudioPocketTTSEngine.swift` | Use `ModelSessionLoader`. Pocket also gets a lazy frame-stream adapter. |
| `Relay/Backends/Whisper/WhisperRuntime.swift` | Keyed single-flight transitions, and unload deferred while a transcription is in use. |
| `Relay/SpeechOut/KokoroTTSAudioSource.swift`, `PocketTTSAudioSource.swift`, `AppleTTSAudioSource.swift` | Built on `PipedTTSAudioSource`. The Apple bridge is deleted. |
| `Relay/SpeechOut/StreamingAudioPlayer.swift` | Levels emitted when a buffer has played; route-change failure; shared utilities. |
| `Relay/SpeechIn/MicrophoneCapture.swift` | `AVAudioEngineSource` rebuilt on the gate, an engine queue, the observer and the utilities. |
| `Relay/SpeechIn/STTRouter.swift`, `Relay/SpeechIn/DictationCoordinator.swift` | `STTSelection` token; interim uses the first backend only; cancellation checks. |
| `Relay/Backends/AppleSpeechBackend.swift` | Per-locale asset cache, a fixed privacy label, shared converter. |
| `Relay/SpeechOut/RulesSpeechPreprocessor.swift` | Precompiled static regexes. |
| `Relay/Backends/KokoroTTSBackend.swift` | Clamped speed. No default engine argument. |
| `Relay/SpeechOut/SpeechCoordinator.swift`, `Relay/SpeechOut/TTSRouter.swift` | Remove the redundant `@unchecked Sendable` and a duplicate catch. |
| `Relay/Backends/ParakeetBackend.swift`, `ParakeetModelManager.swift`, `KokoroModelManager.swift`, `PocketTTSModelManager.swift`, `PocketTTSBackend.swift` | Remove the `= FluidAudioXEngine()` default arguments. |
| Matching test files | As described in each task. |

---

## Task 0: Worktree and baseline

**Files:** none

- [ ] **Step 1: Create the worktree from up-to-date `main`**

```bash
cd /Users/darius/Personal/relay
git status --short          # expect clean
git worktree add .worktrees/cleanup-4-speech-engines -b cleanup/4-speech-engines main
cd .worktrees/cleanup-4-speech-engines
git log --oneline -5
```

Expected: the log shows the merge commits for cleanup plans 1 and 2. If it doesn't, stop: this plan must run after they merge. Plan 3 is not expected in the log; do not wait for it and do not rebase onto `cleanup/3-integrations-sessions`.

- [ ] **Step 2: Generate the project and run the full suite**

```bash
xcodegen generate
git status --short
xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/relay-dd-cleanup4
```

Expected: `git status --short` prints nothing (the pbxproj regenerates identically), and the run ends with `** TEST SUCCEEDED **`. If the pbxproj shows a diff, commit it on its own first with `git add Relay.xcodeproj/project.pbxproj && git commit -m "chore: regenerate Xcode project"`.

All later commands run from `/Users/darius/Personal/relay/.worktrees/cleanup-4-speech-engines`.

---

## Task 1: Close the `TTSAudioPipe` test gaps (review item 10)

These are characterization tests of existing code, so they should pass on the first run. If one fails, you have found a real pipe bug: stop and report it instead of changing the test.

**Files:**
- Modify: `RelayTests/SpeechOut/TTSAudioPipeTests.swift`

- [ ] **Step 1: Add the tests**

Append these members inside `final class TTSAudioPipeTests` (after `testCancellationDiscardsBufferedAudio`). Each frame below is `sampleRate: 10`, so 10 samples equal 1 second of audio.

```swift
    private func second() -> TTSAudioFrame {
        TTSAudioFrame(samples: [Float](repeating: 0, count: 10), format: format)
    }

    private func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }

    func testProducerBlocksAtHighWatermarkAndResumesOnlyBelowLowWatermark() async throws {
        let pipe = TTSAudioPipe.make(highWatermark: 2, lowWatermark: 1)
        let progress = PipeProgress()
        let frame = second()
        let producer = Task {
            for _ in 0..<3 {
                try await pipe.sink.yield(frame)
                await progress.increment()
            }
        }

        await settle()
        let beforeDrain = await progress.value
        XCTAssertEqual(beforeDrain, 2, "the third 1s frame must wait: 2s buffered reached the 2s high watermark")

        _ = try await pipe.source.next()   // 1s buffered: not below the 1s low watermark yet
        await settle()
        let afterFirstDrain = await progress.value
        XCTAssertEqual(afterFirstDrain, 2, "hysteresis: the producer stays blocked until buffered < low watermark")

        _ = try await pipe.source.next()   // 0s buffered: below low watermark
        try await producer.value
        let afterSecondDrain = await progress.value
        XCTAssertEqual(afterSecondDrain, 3)
    }

    func testBlockedProducerIsWokenByCancelAndThrowsCancellation() async throws {
        let pipe = TTSAudioPipe.make(highWatermark: 1, lowWatermark: 0.5)
        let frame = second()
        try await pipe.sink.yield(frame)
        let blocked = Task { try await pipe.sink.yield(frame) }
        await settle()

        await pipe.source.cancel()

        do {
            try await blocked.value
            XCTFail("A producer woken by cancel must throw")
        } catch is CancellationError {
            // expected
        }
    }

    func testBlockedProducerIsWokenByFinishAndThrowsCancellation() async throws {
        let pipe = TTSAudioPipe.make(highWatermark: 1, lowWatermark: 0.5)
        let frame = second()
        try await pipe.sink.yield(frame)
        let blocked = Task { try await pipe.sink.yield(frame) }
        await settle()

        await pipe.sink.finish()

        do {
            try await blocked.value
            XCTFail("A producer woken by finish must not enqueue after the terminal state")
        } catch is CancellationError {
            // expected
        }
        let first = try await pipe.source.next()
        let end = try await pipe.source.next()
        XCTAssertEqual(first?.samples.count, 10, "audio accepted before finish is kept")
        XCTAssertNil(end)
    }

    func testBlockedConsumerIsWokenByYield() async throws {
        let pipe = TTSAudioPipe.make(highWatermark: 10, lowWatermark: 5)
        let consumer = Task { try await pipe.source.next() }
        await settle()

        try await pipe.sink.yield(.init(samples: [7], format: format))

        let frame = try await consumer.value
        XCTAssertEqual(frame?.samples, [7])
    }

    func testBlockedConsumerIsWokenByFinishWithNil() async throws {
        let pipe = TTSAudioPipe.make(highWatermark: 10, lowWatermark: 5)
        let consumer = Task { try await pipe.source.next() }
        await settle()

        await pipe.sink.finish()

        let frame = try await consumer.value
        XCTAssertNil(frame)
    }

    func testBlockedConsumerIsWokenByFailureWithTheError() async {
        enum Boom: Error { case boom }
        let pipe = TTSAudioPipe.make(highWatermark: 10, lowWatermark: 5)
        let consumer = Task { try await pipe.source.next() }
        await settle()

        await pipe.sink.fail(Boom.boom)

        do {
            _ = try await consumer.value
            XCTFail("Expected the failure")
        } catch is Boom {
            // expected
        } catch {
            XCTFail("Unexpected \(error)")
        }
    }

    func testBlockedConsumerIsWokenByCancelWithCancellation() async {
        let pipe = TTSAudioPipe.make(highWatermark: 10, lowWatermark: 5)
        let consumer = Task { try await pipe.source.next() }
        await settle()

        await pipe.source.cancel()

        do {
            _ = try await consumer.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("Unexpected \(error)")
        }
    }

    func testYieldAfterAnyTerminalStateThrowsCancellation() async {
        enum Boom: Error { case boom }
        let finished = TTSAudioPipe.make(highWatermark: 10, lowWatermark: 5)
        await finished.sink.finish()
        let failed = TTSAudioPipe.make(highWatermark: 10, lowWatermark: 5)
        await failed.sink.fail(Boom.boom)
        let cancelled = TTSAudioPipe.make(highWatermark: 10, lowWatermark: 5)
        await cancelled.sink.cancel()

        for sink in [finished.sink, failed.sink, cancelled.sink] {
            do {
                try await sink.yield(.init(samples: [1], format: format))
                XCTFail("yield after a terminal state must throw")
            } catch is CancellationError {
                // expected
            } catch {
                XCTFail("Unexpected \(error)")
            }
        }
    }
```

Append this helper at file scope, after the class:

```swift
private actor PipeProgress {
    private(set) var value = 0
    func increment() { value += 1 }
}
```

- [ ] **Step 2: Run the pipe tests**

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/relay-dd-cleanup4 -only-testing:RelayTests/TTSAudioPipeTests`
Expected: `** TEST SUCCEEDED **` with 11 tests.

- [ ] **Step 3: Commit**

```bash
git add RelayTests/SpeechOut/TTSAudioPipeTests.swift
git commit -m "test(speech): pin TTSAudioPipe watermark and wake-up semantics"
```

---

## Task 2: Add `ModelSessionLoader` (review item 1, part 1)

The loader keeps the exact rules the three engines implement today. Error mapping is injected as closures, so the loader never needs to know the engine error types.

**Files:**
- Create: `Relay/Backends/ModelSessionLoader.swift`
- Create: `RelayTests/Backends/ModelSessionLoaderTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `RelayTests/Backends/ModelSessionLoaderTests.swift`:

```swift
import XCTest
@testable import Relay

/// Pins the single-flight load rules every FluidAudio engine shares. These are the same semantics
/// `FluidAudioParakeetEngineTests`/`FluidAudioKokoroEngineTests`/`FluidAudioPocketTTSEngineTests`
/// used to pin once per engine.
final class ModelSessionLoaderTests: XCTestCase {
    func testLocalLoadThatFailsValidationThrowsModelsNotDownloadedWithoutLoading() async {
        let probe = LoaderProbe()
        await probe.setPresent(false)
        let loader = makeLoader(probe)

        await assertLoad(loader, allowDownload: false, throws: .notDownloaded)

        let localCalls = await probe.localCalls
        let downloadCalls = await probe.downloadCalls
        XCTAssertEqual(localCalls, 0)
        XCTAssertEqual(downloadCalls, 0)
        let session = await loader.session
        XCTAssertNil(session)
    }

    func testLocalLoadValidatesThenLoadsAndExposesTheSession() async throws {
        let probe = LoaderProbe()
        let loader = makeLoader(probe)

        try await loader.load(allowDownload: false, progress: { _ in })

        let session = await loader.session
        XCTAssertEqual(session, "local-1")
        let validateCalls = await probe.validateCalls
        XCTAssertEqual(validateCalls, 1)
    }

    func testLoadIsANoOpOnceASessionIsLoaded() async throws {
        let probe = LoaderProbe()
        let loader = makeLoader(probe)

        try await loader.load(allowDownload: false, progress: { _ in })
        try await loader.load(allowDownload: false, progress: { _ in })
        try await loader.load(allowDownload: true, progress: { _ in })

        let validateCalls = await probe.validateCalls
        let localCalls = await probe.localCalls
        let downloadCalls = await probe.downloadCalls
        XCTAssertEqual(validateCalls, 1)
        XCTAssertEqual(localCalls, 1)
        XCTAssertEqual(downloadCalls, 0)
    }

    func testConcurrentLocalLoadsShareOneUnderlyingLoad() async throws {
        let probe = LoaderProbe()
        await probe.gateLocalLoads()
        let loader = makeLoader(probe)

        let first = Task { try await loader.load(allowDownload: false, progress: { _ in }) }
        let second = Task { try await loader.load(allowDownload: false, progress: { _ in }) }
        await waitUntil { await probe.localCalls == 1 }
        await settle()
        let callsWhileGated = await probe.localCalls

        await probe.openLocalGate()
        try await first.value
        try await second.value

        XCTAssertEqual(callsWhileGated, 1)
        let finalCalls = await probe.localCalls
        XCTAssertEqual(finalCalls, 1)
    }

    func testConcurrentDownloadsShareOneUnderlyingDownload() async throws {
        let probe = LoaderProbe()
        await probe.gateDownloads()
        let loader = makeLoader(probe)

        let first = Task { try await loader.load(allowDownload: true, progress: { _ in }) }
        let second = Task { try await loader.load(allowDownload: true, progress: { _ in }) }
        await waitUntil { await probe.downloadCalls == 1 }
        await settle()

        await probe.openDownloadGate()
        try await first.value
        try await second.value

        let downloadCalls = await probe.downloadCalls
        XCTAssertEqual(downloadCalls, 1)
    }

    func testDownloadSkipsValidationAndForwardsProgress() async throws {
        let probe = LoaderProbe()
        let loader = makeLoader(probe)
        let recorder = ProgressRecorder()

        try await loader.load(allowDownload: true, progress: { recorder.record($0) })

        XCTAssertEqual(recorder.values, [0.5, 1.0])
        let validateCalls = await probe.validateCalls
        XCTAssertEqual(validateCalls, 0)
        let session = await loader.session
        XCTAssertEqual(session, "download-1")
    }

    func testLoadFailureIsMappedAndClearsTheValidationCacheSoARetryRevalidates() async throws {
        let probe = LoaderProbe()
        await probe.setLocalError(LoaderTestError.boom)
        let loader = makeLoader(probe)

        await assertLoad(loader, allowDownload: false, throws: .mapped)

        await probe.setLocalError(nil)
        try await loader.load(allowDownload: false, progress: { _ in })

        let validateCalls = await probe.validateCalls
        let localCalls = await probe.localCalls
        XCTAssertEqual(validateCalls, 2, "a failed load must not leave a trusted positive validation behind")
        XCTAssertEqual(localCalls, 2)
    }

    func testValidationErrorsPropagateUnmapped() async {
        let probe = LoaderProbe()
        await probe.setValidateError(LoaderTestError.boom)
        let loader = makeLoader(probe)

        await assertLoad(loader, allowDownload: false, throws: .boom)
        let localCalls = await probe.localCalls
        XCTAssertEqual(localCalls, 0)
    }

    func testCancellationIsNotMappedAndKeepsTheValidationCache() async throws {
        let probe = LoaderProbe()
        await probe.setLocalError(CancellationError())
        let loader = makeLoader(probe)

        do {
            try await loader.load(allowDownload: false, progress: { _ in })
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // expected
        }

        await probe.setLocalError(nil)
        try await loader.load(allowDownload: false, progress: { _ in })
        let validateCalls = await probe.validateCalls
        XCTAssertEqual(validateCalls, 1, "cancellation says nothing about on-disk state")
    }

    func testLocalCallerFailsFastWhileAnUnvalidatedDownloadIsRunning() async throws {
        let probe = LoaderProbe()
        await probe.gateDownloads()
        let loader = makeLoader(probe)

        let download = Task { try await loader.load(allowDownload: true, progress: { _ in }) }
        await waitUntil { await probe.downloadCalls == 1 }

        await assertLoad(loader, allowDownload: false, throws: .notDownloaded)
        let validateCalls = await probe.validateCalls
        XCTAssertEqual(validateCalls, 0)

        await probe.openDownloadGate()
        try await download.value
    }

    func testLocalCallerJoinsARunningDownloadWhenPresenceIsAlreadyValidated() async throws {
        let probe = LoaderProbe()
        await probe.gateDownloads()
        let loader = makeLoader(probe, validatedModelsPresent: true)

        let download = Task { try await loader.load(allowDownload: true, progress: { _ in }) }
        await waitUntil { await probe.downloadCalls == 1 }
        let local = Task { try await loader.load(allowDownload: false, progress: { _ in }) }
        await settle()

        await probe.openDownloadGate()
        try await download.value
        try await local.value

        let localCalls = await probe.localCalls
        XCTAssertEqual(localCalls, 0)
        let session = await loader.session
        XCTAssertEqual(session, "download-1")
    }

    func testDownloadCallerWaitsForARunningLocalLoadThenDownloadsIfItFailed() async throws {
        let probe = LoaderProbe()
        await probe.gateLocalLoads()
        await probe.setLocalError(LoaderTestError.boom)
        let loader = makeLoader(probe)

        let local = Task { try await loader.load(allowDownload: false, progress: { _ in }) }
        await waitUntil { await probe.localCalls == 1 }
        let download = Task { try await loader.load(allowDownload: true, progress: { _ in }) }
        await settle()
        let downloadsWhileLocalRuns = await probe.downloadCalls

        await probe.openLocalGate()
        try await download.value
        do {
            try await local.value
            XCTFail("The local load itself still fails")
        } catch {
            XCTAssertEqual(error as? LoaderTestError, .mapped)
        }

        XCTAssertEqual(downloadsWhileLocalRuns, 0)
        let session = await loader.session
        XCTAssertEqual(session, "download-1")
    }

    func testTwoDownloadCallersWaitingOnAFailedLocalLoadStartOnlyOneDownload() async throws {
        let probe = LoaderProbe()
        await probe.gateLocalLoads()
        await probe.setLocalError(LoaderTestError.boom)
        let loader = makeLoader(probe)

        let local = Task { try? await loader.load(allowDownload: false, progress: { _ in }) }
        await waitUntil { await probe.localCalls == 1 }
        let firstDownload = Task { try await loader.load(allowDownload: true, progress: { _ in }) }
        let secondDownload = Task { try await loader.load(allowDownload: true, progress: { _ in }) }
        await settle()

        await probe.openLocalGate()
        _ = await local.value
        try await firstDownload.value
        try await secondDownload.value

        let downloadCalls = await probe.downloadCalls
        XCTAssertEqual(downloadCalls, 1, "the second waiter must join the first waiter's download")
    }

    func testDownloadCallerReusesTheSessionARunningLocalLoadProduced() async throws {
        let probe = LoaderProbe()
        await probe.gateLocalLoads()
        let loader = makeLoader(probe)

        let local = Task { try await loader.load(allowDownload: false, progress: { _ in }) }
        await waitUntil { await probe.localCalls == 1 }
        let download = Task { try await loader.load(allowDownload: true, progress: { _ in }) }
        await settle()

        await probe.openLocalGate()
        try await local.value
        try await download.value

        let downloadCalls = await probe.downloadCalls
        XCTAssertEqual(downloadCalls, 0)
        let session = await loader.session
        XCTAssertEqual(session, "local-1")
    }

    func testResetDropsTheSessionAndForgetsValidation() async throws {
        let probe = LoaderProbe()
        let loader = makeLoader(probe)
        try await loader.load(allowDownload: false, progress: { _ in })

        await loader.reset()

        let sessionAfterReset = await loader.session
        XCTAssertNil(sessionAfterReset)
        try await loader.load(allowDownload: false, progress: { _ in })
        let validateCalls = await probe.validateCalls
        XCTAssertEqual(validateCalls, 2)
    }

    func testResetWaitsForAnInFlightLoadAndLeavesNoSession() async throws {
        let probe = LoaderProbe()
        await probe.gateLocalLoads()
        let loader = makeLoader(probe)
        let local = Task { try? await loader.load(allowDownload: false, progress: { _ in }) }
        await waitUntil { await probe.localCalls == 1 }

        let reset = Task { await loader.reset() }
        await settle()
        await probe.openLocalGate()
        await reset.value
        _ = await local.value

        let session = await loader.session
        XCTAssertNil(session, "a load that finishes during reset must not resurrect the session")
    }

    func testUnloadDropsTheSessionButKeepsValidation() async throws {
        let probe = LoaderProbe()
        let loader = makeLoader(probe)
        try await loader.load(allowDownload: false, progress: { _ in })

        await loader.unload()

        let sessionAfterUnload = await loader.session
        XCTAssertNil(sessionAfterUnload)
        try await loader.load(allowDownload: false, progress: { _ in })
        let validateCalls = await probe.validateCalls
        let localCalls = await probe.localCalls
        XCTAssertEqual(validateCalls, 1)
        XCTAssertEqual(localCalls, 2)
    }

    func testInitialValidationSkipsTheFirstCheck() async throws {
        let probe = LoaderProbe()
        let loader = makeLoader(probe, validatedModelsPresent: true)

        try await loader.load(allowDownload: false, progress: { _ in })

        let validateCalls = await probe.validateCalls
        XCTAssertEqual(validateCalls, 0)
    }

    // MARK: - Helpers

    private func makeLoader(_ probe: LoaderProbe, validatedModelsPresent: Bool = false) -> ModelSessionLoader<String> {
        ModelSessionLoader(
            validatedModelsPresent: validatedModelsPresent,
            modelsNotDownloaded: { LoaderTestError.notDownloaded },
            mapLoadFailure: { _ in LoaderTestError.mapped },
            validateLocal: { try await probe.validate() },
            loadLocal: { try await probe.loadLocal() },
            downloadAndLoad: { progress in try await probe.download(progress: progress) }
        )
    }

    private func assertLoad(
        _ loader: ModelSessionLoader<String>,
        allowDownload: Bool,
        throws expected: LoaderTestError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await loader.load(allowDownload: allowDownload, progress: { _ in })
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? LoaderTestError, expected, file: file, line: line)
        }
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    private func waitUntil(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () async -> Bool
    ) async {
        for _ in 0..<10_000 {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("Condition never became true", file: file, line: line)
    }
}

private enum LoaderTestError: Error, Equatable {
    case notDownloaded
    case mapped
    case boom
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []
    func record(_ value: Double) { lock.withLock { storage.append(value) } }
    var values: [Double] { lock.withLock { storage } }
}

private actor LoaderProbe {
    private(set) var validateCalls = 0
    private(set) var localCalls = 0
    private(set) var downloadCalls = 0
    private var present = true
    private var validateError: (any Error)?
    private var localError: (any Error)?
    private var gateLocal = false
    private var gateDownload = false
    private var localGate: CheckedContinuation<Void, Never>?
    private var downloadGate: CheckedContinuation<Void, Never>?

    func setPresent(_ value: Bool) { present = value }
    func setValidateError(_ error: (any Error)?) { validateError = error }
    func setLocalError(_ error: (any Error)?) { localError = error }
    func gateLocalLoads() { gateLocal = true }
    func gateDownloads() { gateDownload = true }

    func openLocalGate() {
        gateLocal = false
        localGate?.resume()
        localGate = nil
    }

    func openDownloadGate() {
        gateDownload = false
        downloadGate?.resume()
        downloadGate = nil
    }

    func validate() throws -> Bool {
        validateCalls += 1
        if let validateError { throw validateError }
        return present
    }

    func loadLocal() async throws -> String {
        localCalls += 1
        if gateLocal {
            await withCheckedContinuation { localGate = $0 }
        }
        if let localError { throw localError }
        return "local-\(localCalls)"
    }

    func download(progress: @Sendable (Double) -> Void) async throws -> String {
        downloadCalls += 1
        progress(0.5)
        if gateDownload {
            await withCheckedContinuation { downloadGate = $0 }
        }
        progress(1.0)
        return "download-\(downloadCalls)"
    }
}
```

- [ ] **Step 2: Generate the project and run to confirm the failure**

```bash
xcodegen generate
xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/relay-dd-cleanup4 -only-testing:RelayTests/ModelSessionLoaderTests
```

Expected: build failure, `error: cannot find 'ModelSessionLoader' in scope`.

- [ ] **Step 3: Implement the loader**

Create `Relay/Backends/ModelSessionLoader.swift`:

```swift
import Foundation

/// Single-flight, download-aware loader for one heavyweight on-device model session. Shared by
/// the FluidAudio engines (Parakeet, Kokoro, PocketTTS), which each used to carry an identical
/// copy of this state machine. Error types stay engine-specific through the injected closures.
///
/// Rules (pinned by `ModelSessionLoaderTests`):
/// - Once a session is loaded, `load` is a no-op.
/// - Concurrent loads of the same kind share one underlying load.
/// - A download caller that finds a local-only load running waits for it (ignoring its outcome),
///   then starts its own download unless that local load produced a session.
/// - A local-only caller that finds a download running joins it only when local presence is
///   already validated; otherwise it fails fast with `modelsNotDownloaded()` rather than block on
///   a transfer it never asked for.
/// - `allowDownload: false` never calls `downloadAndLoad`, and calls `loadLocal` only after
///   `validateLocal` returned `true`. A positive validation is cached; a negative one never is.
///   Any non-cancellation failure clears the cache, because a failed FluidAudio load may have
///   deleted or replaced files on disk.
/// - `validateLocal` errors propagate as thrown (the engine maps them); `loadLocal` and
///   `downloadAndLoad` errors go through `mapLoadFailure`, except `CancellationError`.
actor ModelSessionLoader<Session: Sendable> {
    typealias Progress = @Sendable (Double) -> Void

    private enum LoadKind: Equatable {
        case localOnly
        case download
    }

    private let modelsNotDownloaded: @Sendable () -> any Error
    private let mapLoadFailure: @Sendable (any Error) -> any Error
    private let validateLocal: @Sendable () async throws -> Bool
    private let loadLocal: @Sendable () async throws -> Session
    private let downloadAndLoad: @Sendable (@escaping Progress) async throws -> Session

    /// The loaded session, or `nil` before a successful load and after `reset()`/`unload()`.
    private(set) var session: Session?
    private var inFlightLoad: (task: Task<Void, Error>, kind: LoadKind)?
    private var validatedModelsPresent: Bool

    init(
        validatedModelsPresent: Bool = false,
        modelsNotDownloaded: @escaping @Sendable () -> any Error,
        mapLoadFailure: @escaping @Sendable (any Error) -> any Error,
        validateLocal: @escaping @Sendable () async throws -> Bool,
        loadLocal: @escaping @Sendable () async throws -> Session,
        downloadAndLoad: @escaping @Sendable (@escaping Progress) async throws -> Session
    ) {
        self.validatedModelsPresent = validatedModelsPresent
        self.modelsNotDownloaded = modelsNotDownloaded
        self.mapLoadFailure = mapLoadFailure
        self.validateLocal = validateLocal
        self.loadLocal = loadLocal
        self.downloadAndLoad = downloadAndLoad
    }

    func load(allowDownload: Bool, progress: @escaping Progress) async throws {
        while true {
            if session != nil {
                return
            }
            guard let inFlightLoad else { break }

            switch (inFlightLoad.kind, allowDownload) {
            case (.localOnly, false), (.download, true):
                try await awaitAndClear(inFlightLoad.task)
                return

            case (.localOnly, true):
                // Let the local load get out of the way (ignoring its outcome), then re-evaluate
                // from the top. It may have produced a session, or another download caller that
                // waited on the same local load may already have started the download. Joining
                // that download avoids fetching the model twice.
                _ = try? await inFlightLoad.task.value
                clearIfCurrent(inFlightLoad.task)

            case (.download, false):
                guard validatedModelsPresent else {
                    throw modelsNotDownloaded()
                }
                try await awaitAndClear(inFlightLoad.task)
                return
            }
        }

        try await startLoad(allowDownload: allowDownload, progress: progress)
    }

    /// Cancels and awaits any in-flight load, then drops the session and forgets the cached
    /// validation. Call before deleting model files.
    func reset() async {
        if let inFlightLoad {
            inFlightLoad.task.cancel()
            _ = try? await inFlightLoad.task.value
            clearIfCurrent(inFlightLoad.task)
        }
        session = nil
        validatedModelsPresent = false
    }

    /// Awaits any in-flight load, then drops the session to free its memory. Keeps the cached
    /// validation: the files are still on disk, so the next local load can skip the check.
    func unload() async {
        if let inFlightLoad {
            _ = try? await inFlightLoad.task.value
            clearIfCurrent(inFlightLoad.task)
        }
        session = nil
    }

    private func startLoad(allowDownload: Bool, progress: @escaping Progress) async throws {
        let kind: LoadKind = allowDownload ? .download : .localOnly
        let task = Task { try await self.performLoad(allowDownload: allowDownload, progress: progress) }
        inFlightLoad = (task, kind)
        try await awaitAndClear(task)
    }

    /// Clears `inFlightLoad` only if it still refers to `task`, so a newer load started while
    /// this caller was suspended is never clobbered.
    private func awaitAndClear(_ task: Task<Void, Error>) async throws {
        do {
            try await task.value
            clearIfCurrent(task)
        } catch is CancellationError {
            clearIfCurrent(task)
            throw CancellationError()
        } catch {
            clearIfCurrent(task)
            validatedModelsPresent = false
            throw error
        }
    }

    private func clearIfCurrent(_ task: Task<Void, Error>) {
        if inFlightLoad?.task == task {
            inFlightLoad = nil
        }
    }

    private func performLoad(allowDownload: Bool, progress: @escaping Progress) async throws {
        if !allowDownload {
            guard try await modelsAreValidatedLocally() else {
                throw modelsNotDownloaded()
            }
        }

        let loaded: Session
        do {
            loaded = allowDownload ? try await downloadAndLoad(progress) : try await loadLocal()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw mapLoadFailure(error)
        }
        session = loaded
    }

    private func modelsAreValidatedLocally() async throws -> Bool {
        if validatedModelsPresent {
            return true
        }
        let valid = try await validateLocal()
        if valid {
            validatedModelsPresent = true
        }
        return valid
    }
}
```

- [ ] **Step 4: Run the loader tests**

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/relay-dd-cleanup4 -only-testing:RelayTests/ModelSessionLoaderTests`
Expected: `** TEST SUCCEEDED **` with 18 tests.

- [ ] **Step 5: Commit**

```bash
git add Relay/Backends/ModelSessionLoader.swift RelayTests/Backends/ModelSessionLoaderTests.swift Relay.xcodeproj/project.pbxproj
git commit -m "feat(speech): add generic single-flight ModelSessionLoader"
```

---

## Task 3: Migrate `FluidAudioParakeetEngine` onto the loader (review item 1, part 2)

**Files:**
- Modify: `Relay/Backends/FluidAudioParakeetEngine.swift` (the `actor FluidAudioParakeetEngine` body, currently about lines 38–226)
- Modify: `RelayTests/Backends/FluidAudioParakeetEngineTests.swift`

- [ ] **Step 1: Add the Parakeet-specific validation-mapping test**

In `RelayTests/Backends/FluidAudioParakeetEngineTests.swift`, add this test inside the class:

```swift
    func testValidationErrorMapsToLoadFailedWithTheValidationLabel() async {
        let loader = FakeModelLoader()
        await loader.setValidationError(FakeLoaderError.boom)
        let engine = makeEngine(loader: loader)

        do {
            try await engine.load(allowDownload: false)
            XCTFail("Expected loadFailed")
        } catch {
            XCTAssertEqual(error as? ParakeetEngineError, .loadFailed("Parakeet model validation failed"))
        }
    }
```

In `private actor FakeModelLoader`, add a stored property and setter, and make `isModelValid()` honor it:

```swift
    private var validationError: Error?

    func setValidationError(_ error: Error?) {
        validationError = error
    }

    func isModelValid() async throws -> Bool {
        isModelValidCallCount += 1
        if let validationError { throw validationError }
        return isValid
    }
```

(Replace the existing `isModelValid()` with the version above.)

- [ ] **Step 2: Delete the engine tests the loader tests now cover**

Delete these two methods from `FluidAudioParakeetEngineTests`:
- `testConcurrentLoadsShareASingleUnderlyingLoad`
- `testIsModelValidIsOnlyConsultedOnceAcrossRepeatedLoadAttempts`

Keep the rest (they cover the model directory, padding, error mapping, and the wiring of `modelsArePresent` and download progress). Also remove `setShouldGateLoad`, `openGate`, `shouldGateLoad` and `gateContinuation` from `FakeModelLoader`, plus the gate block in `load()`, now that nothing uses them.

- [ ] **Step 3: Run the new test (it passes against the old engine too: the mapping already exists)**

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/relay-dd-cleanup4 -only-testing:RelayTests/FluidAudioParakeetEngineTests`
Expected: `** TEST SUCCEEDED **`. This is the safety net for the refactor that follows.

- [ ] **Step 4: Replace the engine's load machinery**

In `Relay/Backends/FluidAudioParakeetEngine.swift`, replace everything from the line `actor FluidAudioParakeetEngine: ParakeetEngine {` through the closing `}` of that actor (just before `/// Live \`ParakeetModelLoading\` backed by ...`) with the code below. Keep the type-level doc comment above it. `FluidAudioModelLoader` and `AsrManagerSession` stay unchanged.

```swift
actor FluidAudioParakeetEngine: ParakeetEngine {
    private static let version: AsrModelVersion = .v2
    /// FluidAudio requires at least one second of 16 kHz audio (`ASRError.invalidAudioData`);
    /// shorter clips are zero-padded up to this length before transcription.
    private static let minimumSampleCount = 16_000
    private static let logger = Logger(subsystem: "dev.relaymac.Relay", category: "parakeet")

    /// The directory FluidAudio stores the Parakeet model files in. Always
    /// `AsrModels.defaultCacheDirectory(for: .v2)`: FluidAudio's own `AsrModels.isModelValid`
    /// takes no directory parameter and only ever checks that location.
    let modelDirectory: URL

    private let sessionLoader: ModelSessionLoader<any ParakeetModelSession>

    init(
        modelLoader: (any ParakeetModelLoading)? = nil,
        validatedModelsPresent: Bool = false
    ) {
        let modelDirectory = AsrModels.defaultCacheDirectory(for: Self.version)
        self.modelDirectory = modelDirectory
        let modelLoader = modelLoader ?? FluidAudioModelLoader(modelDirectory: modelDirectory, version: Self.version)
        let logger = Self.logger
        sessionLoader = ModelSessionLoader(
            validatedModelsPresent: validatedModelsPresent,
            modelsNotDownloaded: { ParakeetEngineError.modelsNotDownloaded },
            mapLoadFailure: { error in
                logger.debug("Parakeet model load failed: \(error.localizedDescription, privacy: .private)")
                return ParakeetEngineError.loadFailed("Parakeet model load failed")
            },
            validateLocal: {
                do {
                    return try await modelLoader.isModelValid()
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    logger.debug("Parakeet model validation failed: \(error.localizedDescription, privacy: .private)")
                    throw ParakeetEngineError.loadFailed("Parakeet model validation failed")
                }
            },
            loadLocal: { try await modelLoader.load() },
            downloadAndLoad: { progress in try await modelLoader.downloadAndLoad(progress: progress) }
        )
    }

    func modelsArePresent() async -> Bool {
        AsrModels.modelsExist(at: modelDirectory, version: Self.version)
    }

    func load(allowDownload: Bool, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await sessionLoader.load(allowDownload: allowDownload, progress: progress)
    }

    func transcribe(samples: [Float]) async throws -> String {
        guard let session = await sessionLoader.session else {
            throw ParakeetEngineError.notLoaded
        }

        var paddedSamples = samples
        if paddedSamples.count < Self.minimumSampleCount {
            paddedSamples.append(
                contentsOf: repeatElement(Float(0), count: Self.minimumSampleCount - paddedSamples.count)
            )
        }

        do {
            return try await session.transcribe(samples: paddedSamples)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Self.logger.debug("Parakeet transcription failed: \(error.localizedDescription, privacy: .private)")
            throw ParakeetEngineError.transcriptionFailed("Parakeet transcription failed")
        }
    }
}
```

The type-level doc comment (lines 28–37 today) describes no `LoadKind`/`inFlightLoad`/`validatedModelsPresent` internals, so keep it and append one line: "Single-flight loading and the local-validation gate live in `ModelSessionLoader`." The per-property doc comments on `LoadKind` and `validatedModelsPresent` go away with the properties. The instance `private let logger` becomes the `private static let logger` shown above.

- [ ] **Step 5: Run the Parakeet tests and the backend tests**

```bash
xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/relay-dd-cleanup4 -only-testing:RelayTests/FluidAudioParakeetEngineTests -only-testing:RelayTests/ParakeetBackendTests -only-testing:RelayTests/ModelSessionLoaderTests
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Full suite, then commit**

Run the full suite and expect `** TEST SUCCEEDED **`. Then:

```bash
git add Relay/Backends/FluidAudioParakeetEngine.swift RelayTests/Backends/FluidAudioParakeetEngineTests.swift
git commit -m "refactor(speech): load Parakeet through ModelSessionLoader"
```

---

## Task 4: Migrate `FluidAudioKokoroEngine` onto the loader (review item 1, part 3)

**Files:**
- Modify: `Relay/Backends/FluidAudioKokoroEngine.swift` (the actor body, currently lines 104–305)
- Modify: `RelayTests/Backends/FluidAudioKokoroEngineTests.swift`

- [ ] **Step 1: Swap duplicated loader tests for one mapping test**

Delete these methods from `FluidAudioKokoroEngineTests`:
- `testConcurrentLocalLoadsShareASingleUnderlyingLoad`
- `testFailedLocalLoadDoesNotCacheAFalsePresentSoARetryReconsultsTheLoader`
- `testPresenceCheckIsCachedAcrossRepeatedSuccessfulLocalLoads`

Add:

```swift
    func testLoaderFailureMapsToLoadFailed() async {
        let loader = FakeKokoroModelLoader()
        await loader.setPresent(true)
        await loader.setLoadError(FakeLoaderError.boom)
        let engine = FluidAudioKokoroEngine(modelLoader: loader)

        do {
            try await engine.load(allowDownload: false)
            XCTFail("Expected loadFailed")
        } catch {
            XCTAssertEqual(error as? KokoroEngineError, .loadFailed)
        }
    }
```

Remove the unused gate members (`shouldGateLoad`, `gateContinuation`, `setShouldGateLoad`, `openGate`, and the gate block in `loadLocal()`) from `FakeKokoroModelLoader`. Keep:
- `testEngineRemovalReleasesSessionAndInvalidatesPresenceCache`: it pins that `removeModels` wires to `reset`.
- The not-downloaded tests.
- The download-progress wiring test.
- Every `FluidAudioKokoroModelLoader` filesystem test.

- [ ] **Step 2: Run the Kokoro engine tests on the old code**

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/relay-dd-cleanup4 -only-testing:RelayTests/FluidAudioKokoroEngineTests`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 3: Replace the engine's load machinery**

In `actor FluidAudioKokoroEngine`, make these edits:

1. Delete the `LoadKind` enum, `private let logger`, `private var session`, `private var inFlightLoad`, `private var validatedModelsPresent`, and the methods `startLoad`, `awaitAndClear`, `clearIfCurrent`, `performLoad` and `modelsAreValidatedLocally`.
2. Replace the stored properties and `init` with:

```swift
    private static let logger = Logger(subsystem: "dev.relaymac.Relay", category: "kokoro")

    private let modelLoader: any KokoroModelLoading
    private let sessionLoader: ModelSessionLoader<any KokoroModelSession>

    init(
        modelLoader: (any KokoroModelLoading)? = nil,
        validatedModelsPresent: Bool = false
    ) {
        let modelLoader = modelLoader ?? FluidAudioKokoroModelLoader(cacheDirectory: Self.defaultCacheDirectory())
        self.modelLoader = modelLoader
        let logger = Self.logger
        sessionLoader = ModelSessionLoader(
            validatedModelsPresent: validatedModelsPresent,
            modelsNotDownloaded: { KokoroEngineError.modelsNotDownloaded },
            mapLoadFailure: { _ in
                logger.debug("Kokoro model load failed")
                return KokoroEngineError.loadFailed
            },
            validateLocal: { await modelLoader.modelsArePresent() },
            loadLocal: { try await modelLoader.loadLocal() },
            downloadAndLoad: { progress in try await modelLoader.downloadAndLoad(progress: progress) }
        )
    }
```

3. Replace `removeModels()` and `load(allowDownload:progress:)` with:

```swift
    func removeModels() async throws {
        await sessionLoader.reset()
        try await modelLoader.removeModels()
        guard await !modelLoader.modelsArePresent() else {
            throw KokoroEngineError.loadFailed
        }
    }

    func load(allowDownload: Bool, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await sessionLoader.load(allowDownload: allowDownload, progress: progress)
    }
```

4. In every remaining method that starts with `guard let session else { throw KokoroEngineError.synthesisFailed }` (after plan 2 these are `phonemes(for:)` and `synthesize(phonemes:voice:speed:)`), change the guard to:

```swift
        guard let session = await sessionLoader.session else {
            throw KokoroEngineError.synthesisFailed
        }
```

Leave the rest of each method body unchanged. `modelsArePresent()` and `defaultCacheDirectory()` stay as they are. Update the type doc comment the same way as in Task 3.

- [ ] **Step 4: Run Kokoro engine, backend and model-manager tests**

```bash
xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/relay-dd-cleanup4 -only-testing:RelayTests/FluidAudioKokoroEngineTests -only-testing:RelayTests/KokoroTTSBackendTests -only-testing:RelayTests/KokoroModelManagerTests
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Full suite, then commit**

```bash
git add Relay/Backends/FluidAudioKokoroEngine.swift RelayTests/Backends/FluidAudioKokoroEngineTests.swift
git commit -m "refactor(speech): load Kokoro through ModelSessionLoader"
```

---

## Task 5: Migrate `FluidAudioPocketTTSEngine` onto the loader (review item 1, part 4)

**Files:**
- Modify: `Relay/Backends/FluidAudioPocketTTSEngine.swift` (the actor body, currently lines 85–261)
- Modify: `RelayTests/Backends/FluidAudioPocketTTSEngineTests.swift`

- [ ] **Step 1: Swap duplicated loader tests for one mapping test**

Delete these from `FluidAudioPocketTTSEngineTests`:
- `testConcurrentLocalLoadsShareASingleUnderlyingLoad`
- `testFailedLocalLoadDoesNotCacheAFalsePresentSoARetryReconsultsTheLoader`
- `testPresenceCheckIsCachedAcrossRepeatedSuccessfulLocalLoads`

Add:

```swift
    func testLoaderFailureMapsToLoadFailed() async {
        let loader = FakePocketTTSModelLoader()
        await loader.setPresent(true)
        await loader.setLoadError(FakeLoaderError.boom)
        let engine = FluidAudioPocketTTSEngine(modelLoader: loader)

        do {
            try await engine.load(allowDownload: false)
            XCTFail("Expected loadFailed")
        } catch {
            XCTAssertEqual(error as? PocketTTSEngineError, .loadFailed)
        }
    }
```

Remove the unused gate members from `FakePocketTTSModelLoader`, the same way as in Task 4.

- [ ] **Step 2: Run the Pocket engine tests on the old code**

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/relay-dd-cleanup4 -only-testing:RelayTests/FluidAudioPocketTTSEngineTests`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 3: Replace the engine's load machinery**

In `actor FluidAudioPocketTTSEngine`:

1. Delete `LoadKind`, `logger`, `session`, `inFlightLoad` and `validatedModelsPresent`, plus `startLoad`, `awaitAndClear`, `clearIfCurrent`, `performLoad` and `modelsAreValidatedLocally`.
2. Replace the stored properties and `init` with:

```swift
    private static let logger = Logger(subsystem: "dev.relaymac.Relay", category: "pocket-tts")

    private let modelLoader: any PocketTTSModelLoading
    private let sessionLoader: ModelSessionLoader<any PocketTTSModelSession>

    init(
        modelLoader: (any PocketTTSModelLoading)? = nil,
        validatedModelsPresent: Bool = false
    ) {
        let modelLoader = modelLoader ?? FluidAudioPocketTTSModelLoader(cacheDirectory: Self.defaultCacheDirectory())
        self.modelLoader = modelLoader
        let logger = Self.logger
        sessionLoader = ModelSessionLoader(
            validatedModelsPresent: validatedModelsPresent,
            modelsNotDownloaded: { PocketTTSEngineError.modelsNotDownloaded },
            mapLoadFailure: { _ in
                logger.debug("PocketTTS model load failed")
                return PocketTTSEngineError.loadFailed
            },
            validateLocal: { await modelLoader.modelsArePresent() },
            loadLocal: { try await modelLoader.loadLocal() },
            downloadAndLoad: { progress in try await modelLoader.downloadAndLoad(progress: progress) }
        )
    }
```

3. Replace `removeModels()` and `load(allowDownload:progress:)`:

```swift
    func removeModels() async throws {
        await sessionLoader.reset()
        try await modelLoader.removeModels()
        guard await !modelLoader.modelsArePresent() else {
            throw PocketTTSEngineError.loadFailed
        }
    }

    func load(allowDownload: Bool, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await sessionLoader.load(allowDownload: allowDownload, progress: progress)
    }
```

4. In `synthesizeStream(text:voice:)`, and in any other remaining session-using method, change `guard let session else` to `guard let session = await sessionLoader.session else`.

- [ ] **Step 4: Run Pocket engine, backend and model-manager tests**

```bash
xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/relay-dd-cleanup4 -only-testing:RelayTests/FluidAudioPocketTTSEngineTests -only-testing:RelayTests/PocketTTSBackendTests -only-testing:RelayTests/PocketTTSModelManagerTests
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Confirm no copies are left, run the full suite, commit**

```bash
grep -rn "inFlightLoad\|enum LoadKind" Relay
```

Expected: only matches in `Relay/Backends/ModelSessionLoader.swift`.

```bash
git add Relay/Backends/FluidAudioPocketTTSEngine.swift RelayTests/Backends/FluidAudioPocketTTSEngineTests.swift
git commit -m "refactor(speech): load PocketTTS through ModelSessionLoader"
```

---

## Task 6: `WhisperRuntime` single-flight and safe unload (review item 2)

`ModelSessionLoader` is not a fit here. Whisper transitions are keyed by model id, must unload the old context before loading the new one, have no download kinds, and must wait out running transcriptions. So the runtime gets one keyed in-flight *transition* (activate to an id, or unload to `nil`), plus an in-use counter.

**Files:**
- Modify: `Relay/Backends/Whisper/WhisperRuntime.swift` (the `actor WhisperRuntime` block and its doc comment, currently lines 31–100). This is `WhisperRuntime.swift`, not `Relay/App/RelayRuntime.swift`; plan 3 does not touch this file.
- Modify: `RelayTests/Backends/Whisper/WhisperRuntimeTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `RelayTests/Backends/Whisper/WhisperRuntimeTests.swift`, at file scope:

```swift
/// Gate the concurrency tests below open by hand.
private actor WhisperTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
}

private actor GatedWhisperContext: LoadedWhisperContext {
    let id: WhisperModelID
    let log: FakeWhisperEventLog
    let transcribeGate: WhisperTestGate?
    private(set) var transcribeStarted = false

    init(id: WhisperModelID, log: FakeWhisperEventLog, transcribeGate: WhisperTestGate?) {
        self.id = id
        self.log = log
        self.transcribeGate = transcribeGate
    }

    func transcribe(_ samples: [Float], options: STTOptions) async throws -> String {
        transcribeStarted = true
        await transcribeGate?.wait()
        log.append(.transcribed(id))
        return "gated transcript"
    }

    func unload() async {
        log.append(.unloaded(id))
    }
}

private actor GatedWhisperEngine: WhisperEngine {
    let log: FakeWhisperEventLog
    private let loadGate: WhisperTestGate?
    private let transcribeGateByID: [WhisperModelID: WhisperTestGate]
    private let error: (any Error)?
    private(set) var loadCount = 0
    private(set) var lastContext: GatedWhisperContext?

    init(
        log: FakeWhisperEventLog,
        loadGate: WhisperTestGate? = nil,
        transcribeGateByID: [WhisperModelID: WhisperTestGate] = [:],
        error: (any Error)? = nil
    ) {
        self.log = log
        self.loadGate = loadGate
        self.transcribeGateByID = transcribeGateByID
        self.error = error
    }

    func load(modelFolder: URL) async throws -> any LoadedWhisperContext {
        loadCount += 1
        await loadGate?.wait()
        if let error { throw error }
        let id = WhisperModelID(rawValue: modelFolder.lastPathComponent)!
        log.append(.loaded(id))
        let context = GatedWhisperContext(id: id, log: log, transcribeGate: transcribeGateByID[id])
        lastContext = context
        return context
    }
}
```

Add these methods inside `final class WhisperRuntimeTests`:

```swift
    private func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }

    func testConcurrentActivateOfTheSameModelLoadsOnce() async throws {
        let gate = WhisperTestGate()
        let gatedEngine = GatedWhisperEngine(log: log, loadGate: gate)
        let runtime = WhisperRuntime(engine: gatedEngine, modelFolder: Self.folder(for:))

        let interimTick = Task { try await runtime.activate(.baseEn) }
        let finalTranscribe = Task { try await runtime.activate(.baseEn) }
        await settle()
        let loadsWhileGated = await gatedEngine.loadCount

        await gate.open()
        try await interimTick.value
        try await finalTranscribe.value

        XCTAssertEqual(loadsWhileGated, 1, "the second caller must join the in-flight load")
        let totalLoads = await gatedEngine.loadCount
        XCTAssertEqual(totalLoads, 1)
        let current = await runtime.currentModelID
        XCTAssertEqual(current, .baseEn)
    }

    func testActivatingAnotherModelWaitsForAnInUseTranscriptionBeforeUnloading() async throws {
        let transcribeGate = WhisperTestGate()
        let gatedEngine = GatedWhisperEngine(log: log, transcribeGateByID: [.baseEn: transcribeGate])
        let runtime = WhisperRuntime(engine: gatedEngine, modelFolder: Self.folder(for:))
        try await runtime.activate(.baseEn)
        let context = try XCTUnwrap(await gatedEngine.lastContext)

        let transcription = Task { try await runtime.transcribe([0.1], options: STTOptions()) }
        while await !context.transcribeStarted { await Task.yield() }
        let switchTask = Task { try await runtime.activate(.smallEn) }
        await settle()

        XCTAssertEqual(log.all, [.loaded(.baseEn)], "the in-use context must not be unloaded mid-transcription")

        await transcribeGate.open()
        let text = try await transcription.value
        try await switchTask.value

        XCTAssertEqual(text, "gated transcript")
        XCTAssertEqual(log.all, [.loaded(.baseEn), .transcribed(.baseEn), .unloaded(.baseEn), .loaded(.smallEn)])
    }

    func testUnloadWaitsForAnInUseTranscription() async throws {
        let transcribeGate = WhisperTestGate()
        let gatedEngine = GatedWhisperEngine(log: log, transcribeGateByID: [.baseEn: transcribeGate])
        let runtime = WhisperRuntime(engine: gatedEngine, modelFolder: Self.folder(for:))
        try await runtime.activate(.baseEn)
        let context = try XCTUnwrap(await gatedEngine.lastContext)

        let transcription = Task { try await runtime.transcribe([0.1], options: STTOptions()) }
        while await !context.transcribeStarted { await Task.yield() }
        let unload = Task { await runtime.unload() }
        await settle()
        XCTAssertFalse(log.all.contains(.unloaded(.baseEn)))

        await transcribeGate.open()
        _ = try await transcription.value
        await unload.value
        XCTAssertEqual(log.all.last, .unloaded(.baseEn))
        let current = await runtime.currentModelID
        XCTAssertNil(current)
    }

    func testConcurrentActivateThatFailsLeavesNothingLoadedForEitherCaller() async {
        let gate = WhisperTestGate()
        let gatedEngine = GatedWhisperEngine(log: log, loadGate: gate, error: FakeWhisperEngineError.simulatedLoadFailure)
        let runtime = WhisperRuntime(engine: gatedEngine, modelFolder: Self.folder(for:))

        let first = Task { try await runtime.activate(.baseEn) }
        let second = Task { try await runtime.activate(.baseEn) }
        await settle()
        await gate.open()

        for task in [first, second] {
            do {
                try await task.value
                XCTFail("both callers must see the load failure")
            } catch {
                XCTAssertEqual(error as? FakeWhisperEngineError, .simulatedLoadFailure)
            }
        }
        let loadCount = await gatedEngine.loadCount
        XCTAssertEqual(loadCount, 1)
        let current = await runtime.currentModelID
        XCTAssertNil(current)
    }

    func testUnloadDuringAnInFlightActivationWaitsAndLeavesNothingLoaded() async throws {
        let gate = WhisperTestGate()
        let gatedEngine = GatedWhisperEngine(log: log, loadGate: gate)
        let runtime = WhisperRuntime(engine: gatedEngine, modelFolder: Self.folder(for:))

        let activation = Task { try await runtime.activate(.baseEn) }
        await settle()
        let unload = Task { await runtime.unload() }
        await settle()
        await gate.open()

        try await activation.value
        await unload.value
        XCTAssertEqual(log.all, [.loaded(.baseEn), .unloaded(.baseEn)])
        let current = await runtime.currentModelID
        XCTAssertNil(current)
    }
```

- [ ] **Step 2: Run to confirm failure**

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/relay-dd-cleanup4 -only-testing:RelayTests/WhisperRuntimeTests`

Expected: `** TEST FAILED **`, with these tests failing:
- `testConcurrentActivateOfTheSameModelLoadsOnce` (2 loads).
- `testActivatingAnotherModelWaitsForAnInUseTranscriptionBeforeUnloading` (unloaded mid-transcription).
- `testUnloadWaitsForAnInUseTranscription`.
- `testConcurrentActivateThatFailsLeavesNothingLoadedForEitherCaller` (loadCount 2).
- `testUnloadDuringAnInFlightActivationWaitsAndLeavesNothingLoaded` (the unload runs before the load lands, so `.baseEn` stays loaded).

- [ ] **Step 3: Implement**

Replace the `actor WhisperRuntime { ... }` block and its doc comment (lines 31–100, from `/// Owns the single heavyweight Whisper inference context…` through the actor's closing `}` just before `/// Live \`WhisperEngine\` backed by WhisperKit.`) with:

```swift
/// Owns the single heavyweight Whisper inference context Relay ever keeps resident.
///
/// Every change of the resident model is one *transition* (activate to an id, or unload to `nil`).
/// At most one transition runs at a time:
/// - A caller that asks for the transition already in flight joins it, so a concurrent interim
///   tick and final transcription load a model once instead of leaking a second multi-GB context.
/// - A caller that asks for a different target waits for the running transition, then re-checks.
///
/// A transition unloads the current context strictly before loading the replacement, and first
/// waits until no `transcribe` is still using that context. `loaded` is assigned only after a
/// load succeeds, so a failed load leaves nothing resident.
actor WhisperRuntime {
    private struct Transition {
        let target: WhisperModelID?
        let token: UUID
        let task: Task<Void, Error>
    }

    private let engine: any WhisperEngine
    private let modelFolder: @Sendable (WhisperModelID) -> URL
    private let logger = Logger(subsystem: "dev.relaymac.Relay", category: "whisper")

    private var loaded: (id: WhisperModelID, context: any LoadedWhisperContext)?
    private var inFlightTransition: Transition?
    private var activeTranscriptions = 0
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    /// The currently-loaded model, if any. `nil` before any activation, after a failed one, after
    /// `unload()`, and while a transition is between unloading the old model and loading the new.
    var currentModelID: WhisperModelID? {
        loaded?.id
    }

    init(engine: any WhisperEngine, modelFolder: @escaping @Sendable (WhisperModelID) -> URL) {
        self.engine = engine
        self.modelFolder = modelFolder
    }

    /// Makes `id` the active model. A no-op if `id` is already active; joins an in-flight
    /// activation of `id`. Throws the load error if loading fails, leaving nothing loaded.
    func activate(_ id: WhisperModelID) async throws {
        try await transition(to: id)
    }

    /// Transcribes with the active model. Throws `WhisperRuntimeError.notLoaded` if none is
    /// active. The context counts as in use until this returns, so no transition unloads it
    /// underneath the call.
    func transcribe(_ samples: [Float], options: STTOptions) async throws -> String {
        guard let loaded else {
            throw WhisperRuntimeError.notLoaded
        }
        activeTranscriptions += 1
        defer {
            activeTranscriptions -= 1
            if activeTranscriptions == 0 {
                let waiters = drainWaiters
                drainWaiters = []
                for waiter in waiters { waiter.resume() }
            }
        }
        return try await loaded.context.transcribe(samples, options: options)
    }

    /// Unloads the active model once in-flight transcriptions finish. Waits for (and then
    /// undoes) an in-flight activation. A no-op if nothing is loaded.
    func unload() async {
        try? await transition(to: nil)
    }

    private func transition(to target: WhisperModelID?) async throws {
        while true {
            if inFlightTransition == nil, loaded?.id == target {
                return
            }
            guard let inFlight = inFlightTransition else { break }
            if inFlight.target == target {
                try await inFlight.task.value
            } else {
                _ = try? await inFlight.task.value
            }
            // Re-evaluate: another transition may have started while this caller waited.
        }

        let token = UUID()
        let task = Task { try await self.performTransition(to: target, token: token) }
        inFlightTransition = Transition(target: target, token: token, task: task)
        try await task.value
    }

    private func performTransition(to target: WhisperModelID?, token: UUID) async throws {
        // Cleared here, on the actor, before the task completes - so every waiter that resumes
        // from `task.value` already sees no transition in flight and cannot spin on a stale one.
        defer {
            if inFlightTransition?.token == token {
                inFlightTransition = nil
            }
        }

        if let current = loaded {
            loaded = nil
            await waitForActiveTranscriptions()
            await current.context.unload()
            logger.debug("Whisper model unloaded")
        }

        guard let target else { return }
        let context = try await engine.load(modelFolder: modelFolder(target))
        loaded = (id: target, context: context)
        logger.debug("Whisper model activated")
    }

    private func waitForActiveTranscriptions() async {
        while activeTranscriptions > 0 {
            await withCheckedContinuation { drainWaiters.append($0) }
        }
    }
}
```

`transition(to:)` returns only when no transition is in flight *and* `loaded?.id == target`. A joiner whose joined transition succeeded loops once more and sees that state. When the target is `nil` and nothing is loaded, the call returns immediately. If a joined transition failed, `try await inFlight.task.value` throws the load error to the joiner. `unload()` swallows errors, because a failure only happens on the load half and an unload never loads.

- [ ] **Step 4: Run the Whisper tests**

```bash
xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/relay-dd-cleanup4 -only-testing:RelayTests/WhisperRuntimeTests -only-testing:RelayTests/WhisperBackendTests -only-testing:RelayTests/WhisperModelManagerTests
```

Expected: `** TEST SUCCEEDED **`. The old tests still pass, including `testSwitchUnloadsPreviousBeforeLoadingNext` and `testFailedActivateLeavesNoLoadedContext`.

- [ ] **Step 5: Full suite, then commit**

```bash
git add Relay/Backends/Whisper/WhisperRuntime.swift RelayTests/Backends/Whisper/WhisperRuntimeTests.swift
git commit -m "fix(whisper): single-flight model activation and defer unload while in use"
```

---

## Task 7: Extract `PipedTTSAudioSource` and migrate Kokoro and Pocket (review item 3)

**Files:**
- Create: `Relay/SpeechOut/PipedTTSAudioSource.swift`
- Create: `RelayTests/SpeechOut/PipedTTSAudioSourceTests.swift`
- Modify: `Relay/SpeechOut/KokoroTTSAudioSource.swift` (lines 5–52)
- Modify: `Relay/SpeechOut/PocketTTSAudioSource.swift` (whole type)
- Modify: `RelayTests/SpeechOut/StreamingAudioPlayerTests.swift` (`FloatStreamTestSource`)

- [ ] **Step 1: Write the failing tests**

Create `RelayTests/SpeechOut/PipedTTSAudioSourceTests.swift`:

```swift
import XCTest
@testable import Relay

final class PipedTTSAudioSourceTests: XCTestCase {
    private let format = TTSAudioFormat(sampleRate: 10, channelCount: 1)

    func testReturningProducerFinishesAfterItsFrames() async throws {
        let format = self.format
        let source = PipedTTSAudioSource { sink in
            try await sink.yield(TTSAudioFrame(samples: [1], format: format))
            try await sink.yield(TTSAudioFrame(samples: [2], format: format))
        }

        let first = try await source.next()
        let second = try await source.next()
        let end = try await source.next()
        XCTAssertEqual(first?.samples, [1])
        XCTAssertEqual(second?.samples, [2])
        XCTAssertNil(end)
    }

    func testThrowingProducerDeliversBufferedFramesThenTheError() async throws {
        struct Boom: Error {}
        let format = self.format
        let source = PipedTTSAudioSource { sink in
            try await sink.yield(TTSAudioFrame(samples: [1], format: format))
            throw Boom()
        }

        let first = try await source.next()
        XCTAssertEqual(first?.samples, [1])
        do {
            _ = try await source.next()
            XCTFail("Expected the producer error")
        } catch is Boom {
            // expected
        }
    }

    func testProducerCancellationSurfacesAsCancellation() async {
        let source = PipedTTSAudioSource { _ in throw CancellationError() }

        do {
            _ = try await source.next()
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("Unexpected \(error)")
        }
    }

    func testCancelStopsABlockedProducerAndTheConsumerSeesCancellation() async throws {
        let format = self.format
        let producerEnded = ProducerEnded()
        let source = PipedTTSAudioSource(highWatermark: 1, lowWatermark: 0.5) { sink in
            defer { Task { await producerEnded.mark() } }
            while true {
                try await sink.yield(TTSAudioFrame(samples: [Float](repeating: 0, count: 10), format: format))
            }
        }
        for _ in 0..<50 { await Task.yield() }

        await source.cancel()

        do {
            _ = try await source.next()
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // expected
        }
        var spins = 0
        while await !producerEnded.value, spins < 1_000 {
            spins += 1
            await Task.yield()
        }
        let ended = await producerEnded.value
        XCTAssertTrue(ended, "cancel() must end the producer, not just the consumer side")
    }
}

private actor ProducerEnded {
    private(set) var value = false
    func mark() { value = true }
}
```

- [ ] **Step 2: Run to confirm failure**

```bash
xcodegen generate
xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/relay-dd-cleanup4 -only-testing:RelayTests/PipedTTSAudioSourceTests
```

Expected: build failure, `cannot find 'PipedTTSAudioSource' in scope`.

- [ ] **Step 3: Implement `PipedTTSAudioSource`**

Create `Relay/SpeechOut/PipedTTSAudioSource.swift`:

```swift
import Foundation

/// A `TTSAudioSource` fed by a producer task through a bounded `TTSAudioPipe`. The producer runs
/// `produce` against the pipe's sink; the player pulls from the pipe independently, so synthesis
/// suspends at the pipe's high watermark instead of filling memory.
///
/// Terminal mapping:
/// - `produce` returns → finish (buffered audio then `nil`).
/// - `produce` throws `CancellationError`, or returns after its task was cancelled → cancel.
/// - `produce` throws anything else → fail (buffered audio then that error).
///
/// `cancel()` cancels the producer task and the pipe, which wakes a producer blocked in `yield`.
struct PipedTTSAudioSource: TTSAudioSource {
    private let source: TTSAudioPipe.Source
    private let producer: Task<Void, Never>

    init(
        highWatermark: TimeInterval = 30,
        lowWatermark: TimeInterval = 15,
        produce: @escaping @Sendable (TTSAudioPipe.Sink) async throws -> Void
    ) {
        let pipe = TTSAudioPipe.make(highWatermark: highWatermark, lowWatermark: lowWatermark)
        source = pipe.source
        producer = Task {
            do {
                try await produce(pipe.sink)
                if Task.isCancelled {
                    await pipe.sink.cancel()
                } else {
                    await pipe.sink.finish()
                }
            } catch is CancellationError {
                await pipe.sink.cancel()
            } catch {
                await pipe.sink.fail(error)
            }
        }
    }

    func next() async throws -> TTSAudioFrame? {
        try await source.next()
    }

    func cancel() async {
        producer.cancel()
        await source.cancel()
    }
}
```

These are the actual `TTSAudioPipe` API names on `main`: `make(highWatermark:lowWatermark:)` (defaults 30/15), `Sink.yield/finish/fail/cancel`, `Source.next/cancel`.

- [ ] **Step 4: Run the new tests**

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/relay-dd-cleanup4 -only-testing:RelayTests/PipedTTSAudioSourceTests`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Migrate `KokoroTTSAudioSource`**

In `Relay/SpeechOut/KokoroTTSAudioSource.swift`, replace the stored properties, `init`, `next()` and `cancel()` (lines 8–52) with the code below. Leave `maxAdaptiveSplitDepth` and `produce(chunk:depth:…)` unchanged.

```swift
    private let piped: PipedTTSAudioSource

    init(
        engine: any KokoroEngine,
        chunks: [String],
        voice: String,
        speed: Float,
        framer: PCMFramer = PCMFramer(),
        highWatermark: TimeInterval = 30,
        lowWatermark: TimeInterval = 15
    ) {
        piped = PipedTTSAudioSource(highWatermark: highWatermark, lowWatermark: lowWatermark) { sink in
            for chunk in chunks {
                try Task.checkCancellation()
                try await Self.produce(
                    chunk: chunk,
                    depth: 0,
                    engine: engine,
                    voice: voice,
                    speed: speed,
                    framer: framer,
                    sink: sink
                )
            }
        }
    }

    func next() async throws -> TTSAudioFrame? {
        try await piped.next()
    }

    func cancel() async {
        await piped.cancel()
    }
```

- [ ] **Step 6: Migrate `PocketTTSAudioSource`**

Replace the body of `struct PocketTTSAudioSource` with:

```swift
    private let piped: PipedTTSAudioSource

    init(
        stream: AsyncThrowingStream<[Float], Error>,
        sampleRate: Double,
        highWatermark: TimeInterval = 30,
        lowWatermark: TimeInterval = 15
    ) {
        let format = TTSAudioFormat(sampleRate: sampleRate, channelCount: 1)
        piped = PipedTTSAudioSource(highWatermark: highWatermark, lowWatermark: lowWatermark) { sink in
            for try await samples in stream {
                try Task.checkCancellation()
                try await sink.yield(TTSAudioFrame(samples: samples, format: format))
            }
        }
    }

    func next() async throws -> TTSAudioFrame? {
        try await piped.next()
    }

    func cancel() async {
        await piped.cancel()
    }
```

This follows plan 1's cancel contract (merged): after `cancel()`, `next()` throws `CancellationError`, pinned by `PocketTTSAudioSourceTests.testCancelMakesNextThrowCancellationError`. Keep the existing `/// Throws \`CancellationError\` after \`cancel()\`, per the \`TTSAudioSource\` contract.` doc comment on `next()`.

- [ ] **Step 7: Replace the test-only `FloatStreamTestSource` glue**

In `RelayTests/SpeechOut/StreamingAudioPlayerTests.swift`, replace the whole `private final class FloatStreamTestSource` with:

```swift
/// Feeds a raw `[Float]` frame stream into a pipe, keeping the stream iterator inside the
/// producer task.
private struct FloatStreamTestSource: TTSAudioSource {
    private let piped: PipedTTSAudioSource

    init(frames: AsyncThrowingStream<[Float], Error>, sampleRate: Double) {
        let format = TTSAudioFormat(sampleRate: sampleRate, channelCount: 1)
        piped = PipedTTSAudioSource { sink in
            for try await samples in frames {
                try await sink.yield(TTSAudioFrame(samples: samples, format: format))
            }
        }
    }

    func next() async throws -> TTSAudioFrame? { try await piped.next() }
    func cancel() async { await piped.cancel() }
}
```

- [ ] **Step 8: Run the source and player tests**

```bash
xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/relay-dd-cleanup4 -only-testing:RelayTests/KokoroTTSAudioSourceTests -only-testing:RelayTests/PocketTTSAudioSourceTests -only-testing:RelayTests/StreamingAudioPlayerTests -only-testing:RelayTests/PipedTTSAudioSourceTests
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 9: Full suite, then commit**

```bash
git add Relay/SpeechOut/PipedTTSAudioSource.swift RelayTests/SpeechOut/PipedTTSAudioSourceTests.swift Relay/SpeechOut/KokoroTTSAudioSource.swift Relay/SpeechOut/PocketTTSAudioSource.swift RelayTests/SpeechOut/StreamingAudioPlayerTests.swift Relay.xcodeproj/project.pbxproj
git commit -m "refactor(speech): share producer/pipe glue in PipedTTSAudioSource"
```

---

## Task 8: Spike — which thread runs Apple TTS `write` callbacks (review item 4, part 1)

The design in Task 9 is safe on any thread. The spike matters because of Swift 6 inference. A closure formed inside `MainActor.run {}` and passed to a non-`@Sendable` ObjC callback parameter is inferred as `@MainActor`-isolated. If Apple then calls it off the main thread, the runtime isolation check traps. Task 9 marks the callback `@Sendable` explicitly for that reason. Record what you observe here.

**Files:**
- Create: `RelayTests/SpeechOut/AppleTTSWriteCallbackSpikeTests.swift`

- [ ] **Step 1: Write the spike test**

```swift
import AVFoundation
import XCTest

/// Real-`AVSpeechSynthesizer` smoke test. Also prints which thread delivers `write` buffers
/// (recorded in the cleanup-4 plan's execution notes). Skips when no system voice is installed.
@MainActor
final class AppleTTSWriteCallbackSpikeTests: XCTestCase {
    func testRealWriteDeliversBuffersThenAnEmptyTerminator() async throws {
        guard !AVSpeechSynthesisVoice.speechVoices().isEmpty else {
            throw XCTSkip("No system speech voices installed")
        }
        let synthesizer = AVSpeechSynthesizer()
        let probe = WriteCallbackProbe()
        let ended = expectation(description: "a zero-length buffer ends the write")
        // Apple may deliver more than one zero-length buffer; only the first matters.
        ended.assertForOverFulfill = false

        // `@Sendable` so Swift 6 does not infer this closure as main-actor isolated: if Apple
        // calls it off the main thread, an inferred-isolated closure would trap.
        synthesizer.write(AVSpeechUtterance(string: "Relay.")) { @Sendable buffer in
            let isMainThread = Thread.isMainThread
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            probe.record(isMainThread: isMainThread, frameLength: Int(pcm.frameLength))
            if pcm.frameLength == 0 { ended.fulfill() }
        }

        await fulfillment(of: [ended], timeout: 20)
        let summary = probe.summary
        print("SPIKE apple-tts-write-callback: \(summary)")
        XCTAssertGreaterThan(summary.nonEmptyBuffers, 0)
    }
}

private final class WriteCallbackProbe: @unchecked Sendable {
    struct Summary: CustomStringConvertible {
        var mainThreadCallbacks = 0
        var backgroundCallbacks = 0
        var nonEmptyBuffers = 0

        var description: String {
            "main=\(mainThreadCallbacks) background=\(backgroundCallbacks) nonEmptyBuffers=\(nonEmptyBuffers)"
        }
    }

    private let lock = NSLock()
    private var storage = Summary()

    func record(isMainThread: Bool, frameLength: Int) {
        lock.withLock {
            if isMainThread { storage.mainThreadCallbacks += 1 } else { storage.backgroundCallbacks += 1 }
            if frameLength > 0 { storage.nonEmptyBuffers += 1 }
        }
    }

    var summary: Summary { lock.withLock { storage } }
}
```

- [ ] **Step 2: Run it and record the result**

```bash
xcodegen generate
xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/relay-dd-cleanup4 -only-testing:RelayTests/AppleTTSWriteCallbackSpikeTests 2>&1 | grep -E "SPIKE apple-tts-write-callback|skipped|TEST (SUCCEEDED|FAILED)"
```

Expected: either a `SPIKE apple-tts-write-callback: main=… background=… nonEmptyBuffers=…` line followed by `** TEST SUCCEEDED **`, or a skip. Write the exact line into **Execution Notes** at the top of this plan.

Interpretation: `background > 0` confirms the old `NSCondition.wait()` blocked a speech-synthesis worker thread, and that the explicit `@Sendable` in Task 9 is required. `main > 0` would mean the old bridge blocked the main actor that `next()` also needs, which is a deadlock risk. Either way, Task 9's never-blocking callback is correct.

- [ ] **Step 3: Commit the spike test and the plan note**

```bash
git add RelayTests/SpeechOut/AppleTTSWriteCallbackSpikeTests.swift Relay.xcodeproj/project.pbxproj docs/superpowers/plans/2026-09-23-relay-cleanup-4-speech-engines.md
git commit -m "test(speech): characterize the AVSpeechSynthesizer write callback thread"
```

---

## Task 9: Move Apple TTS onto the pipe and delete the `NSCondition` bridge (review item 4, part 2)

**Files:**
- Modify: `Relay/SpeechOut/AppleTTSAudioSource.swift`: delete `AppleSpeechBufferBridge` (lines 101–211) and rewrite `AppleTTSAudioSource` (lines 213–289)
- Modify: `RelayTests/SpeechOut/AppleTTSAudioSourceTests.swift`

- [ ] **Step 1: Write the failing tests**

In `AppleTTSAudioSourceTests`, add:

```swift
    func testCallbackNeverBlocksEvenWithFarMoreAudioThanTheHighWatermark() async throws {
        let synth = FakeWriteSynthesizer()
        let source = AppleTTSAudioSource(
            text: "hi",
            rate: 0.5,
            voiceIdentifier: nil,
            synthesizer: synth,
            converter: ScriptedConverter(),
            highWatermark: 0.1,
            lowWatermark: 0.05
        )

        let pull = Task { try await source.next() }
        try await waitUntil { synth.hasCallback }
        let callback = UncheckedBufferCallback(try XCTUnwrap(synth.callbackForTesting))
        let allReturned = expectation(description: "every Apple callback returned without blocking")

        // 64 x 100 ms = 6.4 s of audio against a 0.1 s high watermark, fired from a background
        // thread the way Apple does. The old count-based bridge blocked here after 8 buffers.
        DispatchQueue.global().async {
            for _ in 0..<64 {
                callback.call(Self.backgroundBuffer(frames: 2_400))
            }
            callback.call(Self.backgroundBuffer(frames: 0))
            allReturned.fulfill()
        }
        await fulfillment(of: [allReturned], timeout: 2)

        _ = try await pull.value
        var frames = 1
        while try await source.next() != nil { frames += 1 }
        XCTAssertEqual(frames, 64)
    }

    func testCancelBeforeTheFirstNextNeverStartsSynthesis() async {
        let synth = FakeWriteSynthesizer()
        let source = AppleTTSAudioSource(
            text: "hi",
            rate: 0.5,
            voiceIdentifier: nil,
            synthesizer: synth,
            converter: ScriptedConverter()
        )

        await source.cancel()

        do {
            _ = try await source.next()
            XCTFail("A source cancelled before its first pull must not produce audio")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("Unexpected \(error)")
        }
        XCTAssertTrue(synth.writtenUtterances.isEmpty, "cancel before next() must not start synthesis")
    }

    nonisolated private static func backgroundBuffer(frames: Int) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 24_000,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(frames, 1)))!
        buffer.frameLength = AVAudioFrameCount(frames)
        return buffer
    }
```

In `FakeWriteSynthesizer`, add:

```swift
    var callbackForTesting: AVSpeechSynthesizer.BufferCallback? { callback }
```

At file scope, add:

```swift
/// Lets a test invoke Apple's buffer callback from a background thread, as Apple does.
private final class UncheckedBufferCallback: @unchecked Sendable {
    private let callback: AVSpeechSynthesizer.BufferCallback
    init(_ callback: @escaping AVSpeechSynthesizer.BufferCallback) { self.callback = callback }
    func call(_ buffer: AVAudioBuffer) { callback(buffer) }
}
```

`testCancelStopsGenerationAndEndsTheSource` stays as it is. It covers cancel during synthesis, `stopSpeaking`, and late callbacks after cancel.

- [ ] **Step 2: Run to confirm failure**

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/relay-dd-cleanup4 -only-testing:RelayTests/AppleTTSAudioSourceTests`
Expected: build failure, `extra arguments at positions #6, #7 in call` (no `highWatermark` parameter yet).

- [ ] **Step 3: Implement**

Delete the whole `AppleSpeechBufferBridge` class and its doc comment. Replace `final class AppleTTSAudioSource` and its doc comment with:

```swift
/// Produces PCM from `AVSpeechSynthesizer.write(_:toBufferCallback:)`. Each source owns a
/// dedicated synthesizer, so a cancelled attempt's late callbacks cannot leak into a later
/// session.
///
/// Apple's write callback is synchronous and push-driven, and it must never block (see the
/// cleanup-4 spike). Each buffer is converted in the callback (a deep copy: Apple may reuse the
/// buffer once the callback returns) and yielded into an unbounded `AsyncStream`. A producer
/// inside `PipedTTSAudioSource` is that stream's single consumer (`AsyncStream` supports exactly
/// one) and moves frames into the bounded, duration-based `TTSAudioPipe` the player pulls from.
/// Apple cannot pause `write`, so generation runs ahead at its own pace; Relay's memory for it is
/// bounded by the utterance (~96 KB per second of 24 kHz mono), not by playback.
///
/// Synthesis starts on the first `next()`. `cancel()` before that never starts it.
final class AppleTTSAudioSource: TTSAudioSource, @unchecked Sendable {
    private enum GenerationEvent: Sendable {
        case frame(TTSAudioFrame)
        case finished
        case failed
    }

    private enum StartState {
        case idle
        case started
        case cancelled
    }

    private let synthesizer: any AppleSpeechSynthesizing
    private let converter: any AppleSpeechBufferConverting
    private let text: String
    private let rate: Float
    private let voiceIdentifier: String?
    private let events: AsyncStream<GenerationEvent>.Continuation
    private let piped: PipedTTSAudioSource

    private let stateLock = NSLock()
    private var startState: StartState = .idle

    init(
        text: String,
        rate: Float,
        voiceIdentifier: String?,
        synthesizer: any AppleSpeechSynthesizing,
        converter: any AppleSpeechBufferConverting,
        highWatermark: TimeInterval = 30,
        lowWatermark: TimeInterval = 15
    ) {
        self.text = text
        self.rate = rate
        self.voiceIdentifier = voiceIdentifier
        self.synthesizer = synthesizer
        self.converter = converter

        let (stream, continuation) = AsyncStream.makeStream(of: GenerationEvent.self)
        events = continuation
        piped = PipedTTSAudioSource(highWatermark: highWatermark, lowWatermark: lowWatermark) { sink in
            for await event in stream {
                switch event {
                case let .frame(frame):
                    try await sink.yield(frame)
                case .finished:
                    return
                case .failed:
                    throw SpeechBackendError.inferenceFailed("Apple speech generation failed")
                }
            }
            // The event stream ended with no terminal event: the source was cancelled.
            throw CancellationError()
        }
    }

    func next() async throws -> TTSAudioFrame? {
        if claimStart() {
            await startGeneration()
        }
        return try await piped.next()
    }

    func cancel() async {
        stateLock.withLock { startState = .cancelled }
        events.finish()
        await piped.cancel()
        await MainActor.run { [synthesizer] in
            _ = synthesizer.stopSpeaking(at: .immediate)
        }
    }

    private func claimStart() -> Bool {
        stateLock.withLock {
            guard startState == .idle else { return false }
            startState = .started
            return true
        }
    }

    private func isCancelled() -> Bool {
        stateLock.withLock { startState == .cancelled }
    }

    private func startGeneration() async {
        let text = self.text
        let rate = self.rate
        let voiceIdentifier = self.voiceIdentifier
        let converter = self.converter
        let events = self.events
        await MainActor.run { [synthesizer] in
            // `cancel()` may have run between `claimStart()` and this hop. It stops the
            // synthesizer on the main actor too, so this check orders `write` strictly before
            // or after that stop.
            guard !self.isCancelled() else { return }
            let utterance = AVSpeechUtterance(string: text)
            utterance.rate = rate
            if let voiceIdentifier, let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
                utterance.voice = voice
            }
            // Explicitly `@Sendable`: Apple may call this off the main thread (Task 8 spike), and
            // a closure inferred as main-actor isolated would trap there.
            synthesizer.write(utterance) { @Sendable buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    events.yield(.finished)
                    events.finish()
                    return
                }
                do {
                    events.yield(.frame(try converter.frame(from: pcm)))
                } catch {
                    events.yield(.failed)
                    events.finish()
                }
            }
        }
    }
}
```

The `if let voiceIdentifier…` block matches `main` exactly and IS plan 1's unknown-voice fallback: an identifier `AVSpeechSynthesisVoice(identifier:)` cannot resolve leaves `utterance.voice` at the system default (documented on `AppleTTSBackend.makeAudioSource`, pinned by `testMakeAudioSourceFallsBackToTheDefaultVoiceForAnUnknownVoiceIdentifier`). Keep it verbatim.

- [ ] **Step 4: Run the Apple TTS tests**

```bash
xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/relay-dd-cleanup4 -only-testing:RelayTests/AppleTTSAudioSourceTests -only-testing:RelayTests/AppleTTSBackendTests
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Confirm the bridge is gone, run the full suite, commit**

```bash
grep -rn "AppleSpeechBufferBridge\|NSCondition\|bridgeCapacity" Relay RelayTests
```

Expected: no output.

```bash
git add Relay/SpeechOut/AppleTTSAudioSource.swift RelayTests/SpeechOut/AppleTTSAudioSourceTests.swift
git commit -m "fix(speech): never block Apple TTS write callbacks; feed the shared pipe"
```

---

## Task 10: Shared audio buffer utilities (review item 9)

**Files:**
- Create: `Relay/Audio/AudioBufferUtilities.swift`
- Create: `RelayTests/Audio/AudioBufferUtilitiesTests.swift`
- Modify:
  - `Relay/SpeechOut/StreamingAudioPlayer.swift`: `ConversionInputState` and its doc comment (lines 66–77), deinterleave (391–405), converter call (414–427), `levelGain` and `level(forFrame:)` (97–99, 465–477), and the use at line 190.
  - `Relay/SpeechOut/AppleTTSAudioSource.swift`: `AVAudioPCMBufferConverter` (lines 12–99; fast path 25–40, `try convert(...)` at 57, private `convert` 71–90, `SingleBufferInput` 92–98).
  - `Relay/SpeechIn/MicrophoneCapture.swift`: `MicrophoneLevelMeter` (lines 27–36), its use at line 151, the converter call (412–416), and `AVAudioInputBufferSupplier` (448–467).
  - `Relay/Backends/AppleSpeechBackend.swift`: the converter call inside `AppleSpeechRuntime.convert(_:to:)` (242–254) and `AudioBufferInputSupplier` (259–273).
  - `RelayTests/SpeechOut/StreamingAudioPlayerTests.swift` and `RelayTests/SpeechIn/MicrophoneCaptureStateTests.swift`: move the level tests.

- [ ] **Step 1: Write the failing tests**

Create `RelayTests/Audio/AudioBufferUtilitiesTests.swift`:

```swift
import AVFoundation
import XCTest
@testable import Relay

final class AudioBufferUtilitiesTests: XCTestCase {
    // MARK: - Level

    func testLevelOfSilenceAndOfNothingIsZero() {
        XCTAssertEqual(AudioBufferUtilities.level(of: [Float](repeating: 0, count: 1_920)), 0)
        XCTAssertEqual(AudioBufferUtilities.level(of: []), 0)
    }

    func testLevelClampsToOne() {
        XCTAssertEqual(AudioBufferUtilities.level(of: [Float](repeating: 1, count: 1_920)), 1)
        XCTAssertEqual(AudioBufferUtilities.level(of: [1, -1]), 1)
    }

    func testLevelIsRMSTimesFour() {
        // The RMS of a constant signal is its amplitude.
        XCTAssertEqual(AudioBufferUtilities.level(of: [Float](repeating: 0.2, count: 1_920)), 0.8, accuracy: 0.0001)
    }

    // MARK: - Converter

    func testConvertResamples48kTo16kAndFlushesAtEndOfStream() throws {
        let input = try Self.monoBuffer(sampleRate: 48_000, frames: 4_800) { Float(sin(Double($0) * 0.05)) }
        let outputFormat = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let converter = try XCTUnwrap(AVAudioConverter(from: input.format, to: outputFormat))
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 1_700))

        let result = AudioBufferUtilities.convert(input, into: output, using: converter, exhaustedStatus: .endOfStream)

        XCTAssertNotEqual(result.status, .error)
        XCTAssertNil(result.error)
        XCTAssertEqual(Double(output.frameLength), 1_600, accuracy: 16)
    }

    func testConvertHandsTheInputOverExactlyOnce() throws {
        let input = try Self.monoBuffer(sampleRate: 24_000, frames: 100) { _ in 0.25 }
        let outputFormat = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: true))
        let converter = try XCTUnwrap(AVAudioConverter(from: input.format, to: outputFormat))
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 400))

        let result = AudioBufferUtilities.convert(input, into: output, using: converter)

        XCTAssertNotEqual(result.status, .error)
        XCTAssertEqual(output.frameLength, 100, "feeding the buffer twice would double the output")
    }

    // MARK: - Interleave

    func testInterleaveAndDeinterleaveRoundTripStereo() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 2, interleaved: false))
        let planar = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3))
        planar.frameLength = 3
        let channels = try XCTUnwrap(planar.floatChannelData)
        for index in 0..<3 {
            channels[0][index] = Float(index)        // left: 0 1 2
            channels[1][index] = Float(index) + 10   // right: 10 11 12
        }

        let interleaved = AudioBufferUtilities.interleave(channels, channelCount: 2, frameLength: 3)
        XCTAssertEqual(interleaved, [0, 10, 1, 11, 2, 12])

        let back = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3))
        back.frameLength = 3
        let backChannels = try XCTUnwrap(back.floatChannelData)
        AudioBufferUtilities.deinterleave(interleaved, channelCount: 2, into: backChannels)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: backChannels[0], count: 3)), [0, 1, 2])
        XCTAssertEqual(Array(UnsafeBufferPointer(start: backChannels[1], count: 3)), [10, 11, 12])
    }

    func testMonoInterleaveIsACopy() throws {
        let buffer = try Self.monoBuffer(sampleRate: 24_000, frames: 4) { Float($0) }
        let channels = try XCTUnwrap(buffer.floatChannelData)
        XCTAssertEqual(AudioBufferUtilities.interleave(channels, channelCount: 1, frameLength: 4), [0, 1, 2, 3])
    }

    private static func monoBuffer(sampleRate: Double, frames: Int, sample: (Int) -> Float) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let channel = try XCTUnwrap(buffer.floatChannelData)[0]
        for index in 0..<frames { channel[index] = sample(index) }
        return buffer
    }
}
```

- [ ] **Step 2: Run to confirm failure**

```bash
xcodegen generate
xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/relay-dd-cleanup4 -only-testing:RelayTests/AudioBufferUtilitiesTests
```

Expected: build failure, `cannot find 'AudioBufferUtilities' in scope`.

- [ ] **Step 3: Implement the utilities**

Create `Relay/Audio/AudioBufferUtilities.swift`:

```swift
import AVFoundation

/// Small pure helpers shared by every place Relay pushes PCM through `AVAudioConverter`,
/// meters it, or switches between planar and interleaved layouts.
enum AudioBufferUtilities {
    /// Empirical gain applied to RMS so speech reads well on the activity overlay's meter. Shared by
    /// the microphone level and the speaking level so both waveforms scale the same way.
    static let levelGain: Float = 4

    /// RMS of `samples` times `levelGain`, clamped to `0...1`. Returns only the level, never the
    /// samples.
    static func level(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sumOfSquares: Float = 0
        for sample in samples {
            sumOfSquares += sample * sample
        }
        return min(max(sqrt(sumOfSquares / Float(samples.count)) * levelGain, 0), 1)
    }

    /// Runs one `AVAudioConverter` pass that hands `input` over exactly once. Once the buffer has
    /// been provided, the converter is told `exhaustedStatus`:
    /// - `.noDataNow` for a live stream, where a later call brings more input and the converter
    ///   keeps its resampler state.
    /// - `.endOfStream` for a one-shot conversion of a complete clip, which flushes the tail.
    static func convert(
        _ input: AVAudioPCMBuffer,
        into output: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        exhaustedStatus: AVAudioConverterInputStatus = .noDataNow
    ) -> (status: AVAudioConverterOutputStatus, error: NSError?) {
        let feeder = SingleBufferFeeder(buffer: input)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            feeder.next(inputStatus: inputStatus, exhaustedStatus: exhaustedStatus)
        }
        return (status, error)
    }

    /// Interleaves `channelCount` planar channels of `frameLength` frames into one array.
    static func interleave(
        _ channels: UnsafePointer<UnsafeMutablePointer<Float>>,
        channelCount: Int,
        frameLength: Int
    ) -> [Float] {
        if channelCount == 1 {
            return Array(UnsafeBufferPointer(start: channels[0], count: frameLength))
        }
        var interleaved = [Float](repeating: 0, count: frameLength * channelCount)
        for channel in 0..<channelCount {
            let source = channels[channel]
            for index in 0..<frameLength {
                interleaved[index * channelCount + channel] = source[index]
            }
        }
        return interleaved
    }

    /// Writes interleaved `samples` into `channelCount` planar channels. `samples.count` must be a
    /// multiple of `channelCount`, and every channel must hold `samples.count / channelCount` frames.
    static func deinterleave(
        _ samples: [Float],
        channelCount: Int,
        into channels: UnsafePointer<UnsafeMutablePointer<Float>>
    ) {
        let framesPerChannel = samples.count / channelCount
        samples.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            if channelCount == 1 {
                channels[0].update(from: base, count: framesPerChannel)
                return
            }
            for channel in 0..<channelCount {
                let destination = channels[channel]
                for index in 0..<framesPerChannel {
                    destination[index] = base[index * channelCount + channel]
                }
            }
        }
    }
}

/// Carries the "already provided" flag and the buffer into `AVAudioConverter`'s input block,
/// which is imported as `@Sendable` but is only ever called synchronously on the calling thread.
/// That synchronous contract is what makes `@unchecked` safe.
private final class SingleBufferFeeder: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private var provided = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(
        inputStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>,
        exhaustedStatus: AVAudioConverterInputStatus
    ) -> AVAudioBuffer? {
        guard !provided else {
            inputStatus.pointee = exhaustedStatus
            return nil
        }
        provided = true
        inputStatus.pointee = .haveData
        return buffer
    }
}
```

- [ ] **Step 4: Run the utility tests**

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/relay-dd-cleanup4 -only-testing:RelayTests/AudioBufferUtilitiesTests`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Migrate `StreamingAudioPlayer`**

1. Delete `private final class ConversionInputState` and its doc comment.
2. Delete `private static nonisolated let levelGain` and the whole `// MARK: - Levels` section (`level(forFrame:)`).
3. In `pump`, change `level: Self.level(forFrame: frame.samples)` to `level: AudioBufferUtilities.level(of: frame.samples)`.
4. In `convert(_:)`, replace the deinterleave block (`// Deinterleave the shared interleaved…` through its closing `}`) with:

```swift
        if let channels = sourceBuffer.floatChannelData {
            AudioBufferUtilities.deinterleave(frame.samples, channelCount: channelCount, into: channels)
        }
```

5. Replace the `let inputState = …` through `guard status != .error else { … }` block with:

```swift
        let result = AudioBufferUtilities.convert(sourceBuffer, into: outputBuffer, using: converter)
        guard result.status != .error else {
            throw result.error ?? StreamingAudioPlayerError.conversionFailed
        }
```

- [ ] **Step 6: Migrate `AVAudioPCMBufferConverter` (Apple TTS)**

Replace its fast-path block (from `// Already non-interleaved Float32: interleave directly.` through its closing `}`) with:

```swift
        if inputFormat.commonFormat == .pcmFormatFloat32, !inputFormat.isInterleaved,
           let channels = buffer.floatChannelData {
            return TTSAudioFrame(
                samples: AudioBufferUtilities.interleave(
                    channels,
                    channelCount: channelCount,
                    frameLength: Int(buffer.frameLength)
                ),
                format: TTSAudioFormat(sampleRate: sampleRate, channelCount: channelCount)
            )
        }
```

Replace `try convert(buffer, to: outputBuffer, using: converter)` with:

```swift
        let result = AudioBufferUtilities.convert(buffer, into: outputBuffer, using: converter)
        if result.status == .error {
            throw result.error ?? ConversionError.conversionFailed
        }
```

Delete the private `convert(_:to:using:)` method and `SingleBufferInput`.

- [ ] **Step 7: Migrate `MicrophoneCapture` (minimal; Task 13 rewrites the source)**

1. Delete `enum MicrophoneLevelMeter`. In `start(onLevel:)`, change `onLevel(MicrophoneLevelMeter.normalized(samples: samples))` to `onLevel(AudioBufferUtilities.level(of: samples))`.
2. In `AVAudioEngineSource.convert(...)`, replace:

```swift
            let supplier = AVAudioInputBufferSupplier(buffer: buffer)
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                supplier.next(inputStatus: inputStatus)
            }
```

with:

```swift
            let result = AudioBufferUtilities.convert(buffer, into: output, using: converter)
            let status = result.status
            let conversionError = result.error
```

3. Delete `AVAudioInputBufferSupplier`.

- [ ] **Step 8: Migrate `AppleSpeechBackend`**

In `AppleSpeechRuntime.convert(_:to:)`, replace the `let inputSupplier = …` through `guard status != .error, conversionError == nil, … else` lines with:

```swift
        let result = AudioBufferUtilities.convert(inputBuffer, into: outputBuffer, using: converter, exhaustedStatus: .endOfStream)
        guard result.status != .error, result.error == nil, outputBuffer.frameLength > 0 else {
            throw SpeechBackendError.inferenceFailed("Unable to convert Apple Speech input")
        }
```

Delete `AudioBufferInputSupplier`.

- [ ] **Step 9: Move the old level tests**

- In `StreamingAudioPlayerTests`, delete the four `testLevel…` tests, the `// MARK: - Unconditional: level(forFrame:)` line, and the `level(forFrame:)` sentence in the class doc comment.
- In `MicrophoneCaptureStateTests`, delete `testLevelMeterNormalizesRMSWithoutExposingSamples`.

`AudioBufferUtilitiesTests` covers the same cases.

- [ ] **Step 10: Confirm no duplicates are left, run the full suite, commit**

```bash
grep -rn "ConversionInputState\|SingleBufferInput\|AVAudioInputBufferSupplier\|AudioBufferInputSupplier\|MicrophoneLevelMeter\|level(forFrame" Relay RelayTests
```

Expected: no output. Full suite: `** TEST SUCCEEDED **`.

```bash
git add Relay/Audio/AudioBufferUtilities.swift RelayTests/Audio/AudioBufferUtilitiesTests.swift Relay/SpeechOut/StreamingAudioPlayer.swift Relay/SpeechOut/AppleTTSAudioSource.swift Relay/SpeechIn/MicrophoneCapture.swift Relay/Backends/AppleSpeechBackend.swift RelayTests/SpeechOut/StreamingAudioPlayerTests.swift RelayTests/SpeechIn/MicrophoneCaptureStateTests.swift Relay.xcodeproj/project.pbxproj
git commit -m "refactor(audio): share converter feeder, RMS meter, and interleave helpers"
```

---

## Task 11: Emit speaking levels when audio has played, not when it is scheduled (review item 5)

**Files:**
- Modify: `Relay/SpeechOut/StreamingAudioPlayer.swift` (`schedule` at line 307, `handlePlayed` at line 318 before Task 10; a few lines earlier after it)
- Modify: `RelayTests/SpeechOut/StreamingAudioPlayerTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `StreamingAudioPlayerTests`:

```swift
    func testLevelsAreEmittedAsBuffersPlayNotWhenTheyAreScheduled() async throws {
        let node = FakeOutputNode()
        let player = StreamingAudioPlayer(makeOutputNode: { node })
        let events = EventBox()
        player.onEvent = { events.append($0) }
        let sessionID = UUID()
        // 10 x 80 ms crosses the 0.6 s prebuffer, so every frame is flushed to the node at once.
        let source = ScriptedAudioSource(steps: (0..<10).map { _ in .frame(Self.frame(samples: 1_920)) })

        try await player.startPlayback(source, sessionID: sessionID)
        try await waitUntilAsync { node.scheduledCount == 10 }

        XCTAssertEqual(events.values.filter(\.isLevel).count, 0, "no level may run ahead of audible audio")

        node.firePlayed(3)
        XCTAssertEqual(events.values.filter(\.isLevel).count, 3, "one level per buffer that actually played")
    }
```

- [ ] **Step 2: Run to confirm failure**

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/relay-dd-cleanup4 -only-testing:RelayTests/StreamingAudioPlayerTests/testLevelsAreEmittedAsBuffersPlayNotWhenTheyAreScheduled`
Expected: `** TEST FAILED **`, `XCTAssertEqual failed: ("10") is not equal to ("0")`.

- [ ] **Step 3: Implement**

Replace `schedule(_:sessionID:)` and `handlePlayed(duration:sessionID:)` with:

```swift
    private func schedule(_ item: PendingBuffer, sessionID: UUID) {
        guard let outputNode else { return }
        scheduledCount += 1
        scheduledDuration += item.duration
        let duration = item.duration
        let level = item.level
        outputNode.schedule(item.buffer) { [weak self] in
            self?.handlePlayed(duration: duration, level: level, sessionID: sessionID)
        }
    }

    /// Runs when a buffer has actually played back. The level goes out here, not at schedule
    /// time. Otherwise the meter would run up to `maxScheduledAheadSeconds` ahead of the audio,
    /// the prebuffer flush would burst ~8 levels at once, and those levels would re-arm the
    /// speech watchdog for audio nobody has heard yet.
    private func handlePlayed(duration: TimeInterval, level: Float, sessionID: UUID) {
        guard currentSessionID == sessionID, !explicitlyStopped else { return }
        playedCount += 1
        playedDuration += duration
        onEvent?(.level(sessionID: sessionID, level: level))
        if scheduledDuration - playedDuration < Self.maxScheduledAheadSeconds {
            resumeCapacityWaiters()
        }
        checkForCompletion(sessionID: sessionID)
    }
```

Leave the `pump` catch branches as they are. Plan 1 Task 5 made the `catch is CancellationError` branch different on purpose: once playback has started it calls `endCancelled(sessionID:)`. They are no longer duplicates.

- [ ] **Step 4: Run the player and speech-coordinator tests**

```bash
xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/relay-dd-cleanup4 -only-testing:RelayTests/StreamingAudioPlayerTests -only-testing:RelayTests/SpeechCoordinatorTests -only-testing:RelayTests/SpeechCoordinatorWatchdogTests -only-testing:RelayTests/TTSRouterTests
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Full suite, then commit**

```bash
git add Relay/SpeechOut/StreamingAudioPlayer.swift RelayTests/SpeechOut/StreamingAudioPlayerTests.swift
git commit -m "fix(speech): emit speaking levels on playback, not at schedule time"
```

---

## Task 12: Fail playback on audio route changes (review item 6, output)

**Files:**
- Create: `Relay/Audio/AudioEngineConfigurationObserver.swift`
- Create: `RelayTests/Audio/AudioEngineConfigurationObserverTests.swift`
- Modify: `Relay/SpeechOut/StreamingAudioPlayer.swift` (the `AudioOutputNode` protocol, `AVEngineOutputNode`, `StreamingAudioPlayerError`, output-node creation in `convert`)
- Modify: `RelayTests/SpeechOut/StreamingAudioPlayerTests.swift` (`FakeOutputNode` and new tests)

- [ ] **Step 1: Write the failing observer tests**

Create `RelayTests/Audio/AudioEngineConfigurationObserverTests.swift`:

```swift
import AVFoundation
import XCTest
@testable import Relay

final class AudioEngineConfigurationObserverTests: XCTestCase {
    func testFiresOnlyForTheObservedEngine() {
        let center = NotificationCenter()
        let engine = NSObject()
        let other = NSObject()
        let counter = ChangeCounter()
        let observer = AudioEngineConfigurationObserver(engine: engine, center: center) { counter.increment() }

        center.post(name: .AVAudioEngineConfigurationChange, object: other)
        XCTAssertEqual(counter.value, 0)
        center.post(name: .AVAudioEngineConfigurationChange, object: engine)
        XCTAssertEqual(counter.value, 1)

        withExtendedLifetime(observer) {}
    }

    func testStopsObservingOnceReleased() {
        let center = NotificationCenter()
        let engine = NSObject()
        let counter = ChangeCounter()
        var observer: AudioEngineConfigurationObserver? = AudioEngineConfigurationObserver(engine: engine, center: center) {
            counter.increment()
        }
        XCTAssertNotNil(observer)
        observer = nil

        center.post(name: .AVAudioEngineConfigurationChange, object: engine)
        XCTAssertEqual(counter.value, 0)
    }
}

private final class ChangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
```

- [ ] **Step 2: Run to confirm failure**

```bash
xcodegen generate
xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/relay-dd-cleanup4 -only-testing:RelayTests/AudioEngineConfigurationObserverTests
```

Expected: build failure, `cannot find 'AudioEngineConfigurationObserver' in scope`.

- [ ] **Step 3: Implement the observer**

Create `Relay/Audio/AudioEngineConfigurationObserver.swift`:

```swift
import AVFoundation

/// Watches one `AVAudioEngine` for `AVAudioEngineConfigurationChange` (output or input device
/// switched, sample rate changed, headphones unplugged). AVFoundation stops the engine when this
/// fires, and every graph built against the old format is dead. Owners must fail the session
/// instead of waiting on callbacks that will never come.
///
/// Observation ends when the observer is released. `center` is injectable so tests can post the
/// notification without a real audio device.
final class AudioEngineConfigurationObserver: @unchecked Sendable {
    private let center: NotificationCenter
    private let token: NSObjectProtocol

    /// - Parameter engine: the engine whose notifications are delivered, matched by identity.
    ///   `onChange` runs on the posting thread.
    init(engine: AnyObject, center: NotificationCenter = .default, onChange: @escaping @Sendable () -> Void) {
        self.center = center
        token = center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { _ in
            onChange()
        }
    }

    deinit {
        center.removeObserver(token)
    }
}
```

- [ ] **Step 4: Run the observer tests**

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/relay-dd-cleanup4 -only-testing:RelayTests/AudioEngineConfigurationObserverTests`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Write the failing player tests**

In `StreamingAudioPlayerTests.swift`, add these members to `FakeOutputNode`:

```swift
    var onConfigurationChange: (@MainActor () -> Void)?

    func simulateConfigurationChange() {
        onConfigurationChange?()
    }
```

Add this file-scope source that hangs after its first frame:

```swift
/// Yields one frame, then suspends until cancelled, so playback stays in its prebuffer window.
private actor FirstFrameThenHangSource: TTSAudioSource {
    private let frame: TTSAudioFrame
    private var delivered = false
    private var waiter: CheckedContinuation<TTSAudioFrame?, Error>?
    private(set) var cancelled = false

    init(frame: TTSAudioFrame) { self.frame = frame }

    func next() async throws -> TTSAudioFrame? {
        if cancelled { throw CancellationError() }
        if !delivered {
            delivered = true
            return frame
        }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }

    func cancel() {
        cancelled = true
        waiter?.resume(throwing: CancellationError())
        waiter = nil
    }
}
```

Add the tests:

```swift
    func testRouteChangeAfterStartFailsTheSessionOnceAndCancelsTheSource() async throws {
        let node = FakeOutputNode()
        let player = StreamingAudioPlayer(makeOutputNode: { node })
        let events = EventBox()
        player.onEvent = { events.append($0) }
        let sessionID = UUID()
        let source = ScriptedAudioSource(repeating: Self.frame(samples: 1_920))
        try await player.startPlayback(source, sessionID: sessionID)
        XCTAssertTrue(events.values.contains(.started(sessionID: sessionID)))

        node.simulateConfigurationChange()

        let terminal = events.values.filter { !$0.isLevel && $0 != .started(sessionID: sessionID) }
        XCTAssertEqual(terminal, [.failed(sessionID: sessionID)])
        try await waitUntilAsync { await source.wasCancelled() }
        node.firePlayed(node.scheduledCount)
        XCTAssertFalse(events.values.contains(.finished(sessionID: sessionID)))
    }

    func testRouteChangeBeforeStartThrowsFromStartPlaybackWithoutATerminalEvent() async throws {
        let nodes = NodeBox()
        let player = StreamingAudioPlayer(makeOutputNode: {
            let node = FakeOutputNode()
            nodes.append(node)
            return node
        })
        let events = EventBox()
        player.onEvent = { events.append($0) }
        let sessionID = UUID()
        let source = FirstFrameThenHangSource(frame: Self.frame(samples: 1_920))

        let start = Task { try await player.startPlayback(source, sessionID: sessionID) }
        try await waitUntilAsync { !nodes.values.isEmpty }
        nodes.values[0].simulateConfigurationChange()

        do {
            try await start.value
            XCTFail("Expected startPlayback to throw")
        } catch {
            XCTAssertEqual(error as? StreamingAudioPlayerError, .outputConfigurationChanged)
        }
        XCTAssertFalse(events.values.contains(.failed(sessionID: sessionID)))
        try await waitUntilAsync { await source.cancelled }
    }
```

- [ ] **Step 6: Run to confirm failure**

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/relay-dd-cleanup4 -only-testing:RelayTests/StreamingAudioPlayerTests`
Expected: build failure, `type 'StreamingAudioPlayerError' has no member 'outputConfigurationChanged'`.

- [ ] **Step 7: Implement in the player**

1. Add this protocol requirement to `AudioOutputNode`:

```swift
    /// Set by the player. Called on the main actor when the device configuration changes under the
    /// node (a route change); nothing already scheduled will ever play.
    var onConfigurationChange: (@MainActor () -> Void)? { get set }
```

2. In `AVEngineOutputNode`, add the property and observer and replace `init()`:

```swift
    var onConfigurationChange: (@MainActor () -> Void)?
    private var configurationObserver: AudioEngineConfigurationObserver?

    init(notificationCenter: NotificationCenter = .default) {
        engine.attach(playerNode)
        outputFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.connect(playerNode, to: engine.mainMixerNode, format: outputFormat)
        configurationObserver = AudioEngineConfigurationObserver(engine: engine, center: notificationCenter) { [weak self] in
            Task { @MainActor in self?.onConfigurationChange?() }
        }
    }
```

3. Add `case outputConfigurationChanged` to `StreamingAudioPlayerError`.

4. In `convert(_:)`, replace

```swift
        if outputNode == nil {
            outputNode = makeOutputNode()
        }
```

with

```swift
        if outputNode == nil {
            let node = makeOutputNode()
            node.onConfigurationChange = { [weak self, weak node] in
                guard let self, let node, self.outputNode === node else { return }
                self.handleOutputConfigurationChange()
            }
            outputNode = node
        }
```

5. Add this method after `handleSourceFailure`:

```swift
    /// The output device changed under the node. Nothing scheduled will play and no played-back
    /// callback will arrive, so waiting would stall until the speech watchdog fires. End now:
    /// - Before `.started`, `startPlayback` throws, so the router may fall back.
    /// - After it, the session ends `.failed`.
    /// Either way the healthy source is cancelled.
    private func handleOutputConfigurationChange() {
        guard let sessionID = currentSessionID, !explicitlyStopped else { return }
        let wasStarted = started
        tearDownPlayback(cancelSource: true)
        currentSessionID = nil
        activeSource = nil
        if wasStarted {
            onEvent?(.failed(sessionID: sessionID))
        } else {
            resumeStart(throwing: StreamingAudioPlayerError.outputConfigurationChanged)
        }
    }
```

6. If any other `AudioOutputNode` conformer exists (run `grep -rn ": AudioOutputNode" Relay RelayTests`), give it `var onConfigurationChange: (@MainActor () -> Void)?`.

- [ ] **Step 8: Run the player tests**

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/relay-dd-cleanup4 -only-testing:RelayTests/StreamingAudioPlayerTests -only-testing:RelayTests/AudioEngineConfigurationObserverTests`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 9: Full suite, then commit**

```bash
git add Relay/Audio/AudioEngineConfigurationObserver.swift RelayTests/Audio/AudioEngineConfigurationObserverTests.swift Relay/SpeechOut/StreamingAudioPlayer.swift RelayTests/SpeechOut/StreamingAudioPlayerTests.swift Relay.xcodeproj/project.pbxproj
git commit -m "fix(speech): fail playback on audio route change instead of stalling"
```

---

## Task 13: Restructure `MicrophoneCapture` locking and fail capture on route changes (review items 12 and 6, input)

Today `AVAudioEngineSource` has these problems:
- `stop()` calls `removeTap` while holding the same lock the tap callback takes, which is a deadlock if AVFoundation waits for an in-flight callback.
- User callbacks run under that lock.
- `failCapture` removes the tap from inside the tap callback.

The new structure:
- A `CaptureCallbackGate` holds the gate state and the in-flight count. It never holds a lock across a callout.
- A serial `engineQueue` runs every engine mutation. The tap callback never runs on it.
- Failure teardown is *queued* on `engineQueue`, never run on the tap thread.

**Files:**
- Create: `Relay/SpeechIn/CaptureCallbackGate.swift`
- Create: `RelayTests/SpeechIn/CaptureCallbackGateTests.swift`
- Modify: `Relay/SpeechIn/MicrophoneCapture.swift` (`AVAudioEngineSource`, currently lines 325–446)

- [ ] **Step 1: Write the failing gate tests**

Create `RelayTests/SpeechIn/CaptureCallbackGateTests.swift`:

```swift
import XCTest
@testable import Relay

final class CaptureCallbackGateTests: XCTestCase {
    private enum Boom: Error, Equatable { case first, second }

    func testEnterIsRefusedUntilOpened() {
        let gate = CaptureCallbackGate()
        XCTAssertFalse(gate.enter())
        gate.open()
        XCTAssertTrue(gate.enter())
        gate.leave()
    }

    func testCloseWaitsForAnInFlightCallbackToLeave() {
        let gate = CaptureCallbackGate()
        gate.open()
        XCTAssertTrue(gate.enter())

        let closed = expectation(description: "close returned")
        DispatchQueue.global().async {
            _ = gate.close()
            closed.fulfill()
        }
        let stillWaiting = XCTWaiter.wait(for: [closed], timeout: 0.1)
        XCTAssertEqual(stillWaiting, .timedOut, "close must not return while a callback is delivering samples")

        gate.leave()
        wait(for: [closed], timeout: 2)
    }

    func testNoCallbackIsAdmittedAfterClose() {
        let gate = CaptureCallbackGate()
        gate.open()
        _ = gate.close()
        XCTAssertFalse(gate.enter())
    }

    func testOnlyTheFirstFailureIsRecordedAndCloseReturnsItOnce() {
        let gate = CaptureCallbackGate()
        gate.open()
        XCTAssertTrue(gate.enter())

        XCTAssertTrue(gate.fail(Boom.first), "fail must not wait for the callback that is calling it")
        XCTAssertFalse(gate.fail(Boom.second))
        XCTAssertFalse(gate.enter())
        gate.leave()

        XCTAssertEqual(gate.close() as? Boom, .first)
        XCTAssertNil(gate.close())
    }

    func testOpenClearsAPreviousFailure() {
        let gate = CaptureCallbackGate()
        gate.open()
        _ = gate.fail(Boom.first)
        gate.open()
        XCTAssertNil(gate.close())
    }
}
```

- [ ] **Step 2: Run to confirm failure**

```bash
xcodegen generate
xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/relay-dd-cleanup4 -only-testing:RelayTests/CaptureCallbackGateTests
```

Expected: build failure, `cannot find 'CaptureCallbackGate' in scope`.

- [ ] **Step 3: Implement the gate**

Create `Relay/SpeechIn/CaptureCallbackGate.swift`:

```swift
import Foundation

/// Coordinates the audio tap thread with `stop()` without holding any lock across a callout.
/// - The tap brackets each delivery with `enter()`/`leave()`, and delivers samples outside the
///   lock.
/// - `close()` stops admitting callbacks and waits until in-flight ones have left. When it
///   returns, no further samples are delivered until the next `open()`.
/// - `fail(_:)` records the first failure and closes the gate without waiting, so a callback can
///   call it on itself.
///
/// `close()` blocks its thread briefly: at most one tap callback's conversion time.
final class CaptureCallbackGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var isOpen = false
    private var inFlight = 0
    private var failure: (any Error)?

    /// Starts a new capture: admits callbacks and clears any previous failure.
    func open() {
        condition.withLock {
            isOpen = true
            failure = nil
        }
    }

    /// Tap thread. `true` means this callback may deliver samples; balance it with `leave()`.
    func enter() -> Bool {
        condition.withLock {
            guard isOpen else { return false }
            inFlight += 1
            return true
        }
    }

    func leave() {
        condition.withLock {
            inFlight -= 1
            if inFlight == 0 {
                condition.broadcast()
            }
        }
    }

    /// Records `error` and closes the gate. Returns `true` only for the call that closed it, so the
    /// terminal error is reported exactly once. Never waits for in-flight callbacks.
    func fail(_ error: any Error) -> Bool {
        condition.withLock {
            guard isOpen else { return false }
            isOpen = false
            failure = error
            return true
        }
    }

    /// Closes the gate, waits until no callback is delivering samples, and returns (then clears)
    /// the failure recorded since `open()`, if any.
    func close() -> (any Error)? {
        condition.withLock {
            isOpen = false
            while inFlight > 0 {
                condition.wait()
            }
            defer { failure = nil }
            return failure
        }
    }
}
```

- [ ] **Step 4: Run the gate tests**

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/relay-dd-cleanup4 -only-testing:RelayTests/CaptureCallbackGateTests`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Rebuild `AVAudioEngineSource` on the gate**

In `Relay/SpeechIn/MicrophoneCapture.swift`, replace the whole `private final class AVAudioEngineSource` (after Task 10 it already uses `AudioBufferUtilities`) with the code below. `AudioConversionDisposition` stays as it is.

```swift
/// Live microphone source. Threading rules:
/// - The tap callback only takes the gate briefly and delivers samples with no lock held.
/// - Every engine mutation (installTap, start, removeTap, stop) runs on `engineQueue`, which the
///   tap never runs on, so teardown there can wait for an in-flight callback without deadlocking.
/// - A failure seen on the tap thread (or on a route change) closes the gate and *queues* teardown
///   on `engineQueue`, because removing a tap from inside its own callback can deadlock. A later
///   `start()`/`stop()` goes through the same queue, so that teardown always runs before a newer
///   capture installs its tap.
private final class AVAudioEngineSource: AudioCaptureSourcing, AudioInputFormatReporting, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let gate = CaptureCallbackGate()
    private let engineQueue = DispatchQueue(label: "dev.relaymac.Relay.microphone-engine")
    private let notificationCenter: NotificationCenter

    private let stateLock = NSLock()
    /// The real input device rate captured in `start()`, before resampling to 16 kHz. Metadata
    /// for privacy-safe diagnostics only.
    private var inputSampleRate: Double = 0
    private var terminalErrorHandler: (@Sendable (Error) async -> Void)?
    private var configurationObserver: AudioEngineConfigurationObserver?

    /// Only touched on `engineQueue`.
    private var tapInstalled = false

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
    }

    func currentInputSampleRate() -> Double {
        stateLock.withLock { inputSampleRate }
    }

    func start(
        onSamples: @escaping @Sendable ([Float]) -> Void,
        onTerminalError: @escaping @Sendable (Error) async -> Void
    ) async throws {
        try engineQueue.sync {
            guard !tapInstalled else { throw MicrophoneCaptureError.alreadyRecording }
            let input = engine.inputNode
            let inputFormat = input.inputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
                  let outputFormat = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: 16_000,
                    channels: 1,
                    interleaved: false
                  ),
                  let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
            else {
                throw MicrophoneCaptureError.unavailable("The current input format is unsupported.")
            }

            stateLock.withLock {
                inputSampleRate = inputFormat.sampleRate
                terminalErrorHandler = onTerminalError
            }
            gate.open()
            input.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) { [weak self] buffer, _ in
                self?.handleTap(buffer, converter: converter, outputFormat: outputFormat, onSamples: onSamples)
            }
            tapInstalled = true

            do {
                try engine.start()
            } catch {
                _ = gate.close()
                tearDownEngine()
                throw MicrophoneCaptureError.unavailable(error.localizedDescription)
            }
        }

        let observer = AudioEngineConfigurationObserver(engine: engine, center: notificationCenter) { [weak self] in
            self?.fail(MicrophoneCaptureError.unavailable("The audio input device changed."))
        }
        stateLock.withLock { configurationObserver = observer }
    }

    /// Blocks its calling thread briefly, two ways: `gate.close()` waits out at most one
    /// in-flight tap callback (one 4096-frame conversion), and `engineQueue.sync` waits for
    /// `removeTap`/`engine.stop()`. Both are bounded and short. That is acceptable on the
    /// `MicrophoneCapture` actor's executor, and it is what upholds the `AudioCaptureSourcing.stop`
    /// contract that no samples arrive after it returns.
    func stop() async throws {
        let error = gate.close()
        let observer: AudioEngineConfigurationObserver? = stateLock.withLock {
            defer {
                configurationObserver = nil
                terminalErrorHandler = nil
            }
            return configurationObserver
        }
        withExtendedLifetime(observer) {}   // released here, outside the lock
        engineQueue.sync { tearDownEngine() }
        if let error { throw error }
    }

    /// `engineQueue` only.
    private func tearDownEngine() {
        guard tapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        tapInstalled = false
    }

    /// Tap thread.
    private func handleTap(
        _ buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        outputFormat: AVAudioFormat,
        onSamples: @Sendable ([Float]) -> Void
    ) {
        guard gate.enter() else { return }
        defer { gate.leave() }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            fail(MicrophoneCaptureError.unavailable("Unable to allocate an audio conversion buffer."))
            return
        }

        let result = AudioBufferUtilities.convert(buffer, into: output, using: converter)
        switch AudioConversionDisposition.resolve(
            status: result.status,
            hasConversionError: result.error != nil,
            frameLength: output.frameLength
        ) {
        case .appendOutput:
            break
        case .awaitNextCallback:
            return
        case .fail:
            fail(result.error ?? MicrophoneCaptureError.unavailable("Audio conversion failed with status \(result.status.rawValue)."))
            return
        }
        guard let channel = output.floatChannelData?[0] else {
            fail(MicrophoneCaptureError.unavailable("Converted audio has no float samples."))
            return
        }
        onSamples(Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength))))
    }

    /// Tap thread or notification thread. Reports the first failure once and queues teardown.
    private func fail(_ error: Error) {
        guard gate.fail(error) else { return }
        let handler = stateLock.withLock { terminalErrorHandler }
        engineQueue.async { [weak self] in self?.tearDownEngine() }
        if let handler {
            Task { await handler(error) }
        }
    }
}
```

Behavior compared with today:
- `MicrophoneCapture`'s `.failedRecording` path skips `source.stop()`. That is fine: the queued teardown removes the tap, and the next `start()` calls `gate.open()`, which clears the stale failure.
- `stop()` still returns only once no further callbacks can deliver samples (the `AudioCaptureSourcing.stop` contract), because `gate.close()` waits for in-flight callbacks.

- [ ] **Step 6: Run the microphone and dictation tests**

```bash
xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/relay-dd-cleanup4 -only-testing:RelayTests/MicrophoneCaptureStateTests -only-testing:RelayTests/CaptureCallbackGateTests -only-testing:RelayTests/DictationCoordinatorTests
```

Expected: `** TEST SUCCEEDED **`. These tests use fake sources, so they pin the `MicrophoneCapture` state machine. The live source is covered by the gate and observer tests plus the manual check below.

- [ ] **Step 7: Manual check (real hardware; record it in Execution Notes)**

Build and launch the Debug app. Start dictation and speak. While it records, switch the input device in Control Center or unplug a USB or Bluetooth mic.

Expected: the pill shows the microphone error right away instead of recording silence. Dictation still works on the next attempt with the new device. If microphone permission looks stale after the rebuild, re-toggle the grant (see memory note "Microphone permission stale on rebuild").

- [ ] **Step 8: Full suite, then commit**

```bash
git add Relay/SpeechIn/CaptureCallbackGate.swift RelayTests/SpeechIn/CaptureCallbackGateTests.swift Relay/SpeechIn/MicrophoneCapture.swift Relay.xcodeproj/project.pbxproj
git commit -m "fix(dictation): never tear down the mic tap under its own lock; fail on route change"
```

---

## Task 14: `STTRouter` selection token, first-backend-only interim, cancellation checks (review item 7)

**Files:**
- Modify: `Relay/SpeechIn/STTRouter.swift` (whole file)
- Modify: `Relay/SpeechIn/DictationCoordinator.swift` (stored state: `announcedBackendName` at line 60; the backend lookup in `start()` at lines 148–152; `cancel(sessionID:)` at line 194 with `finishRequested = false` at 201; the final `sttRouter.transcribe` in `runProcessingPipeline` at line 343)
- Modify: `RelayTests/SpeechIn/STTRouterTests.swift`
- Modify: `RelayTests/SpeechIn/DictationCoordinatorTests.swift`

- [ ] **Step 1: Rewrite the router tests that pinned the hidden cache**

In `STTRouterTests`:

1. Delete these tests:
   - `testTranscribeReusesTheSelectionCachedByPreferredBackendDisplayNameWithoutReprobingSkippedBackends`
   - `testCachedSelectionIsClearedAfterOneTranscribeCallSoALaterCallReprobesFromScratch`
   - `testInterimTranscribeCallsDoNotConsumeOrDisturbTheCachedSelectionForTheFinalCall`
   - `testTranscribeForInterimAlwaysWalksTheFullCurrentBackendOrder`
2. In the four `testPreferredBackendDisplayName…` tests, replace `let name = await router.preferredBackendDisplayName()` with `let name = await router.selectBackend()?.displayName`. Rename each method's `PreferredBackendDisplayName` segment to `SelectBackend`.
3. Add these tests:

```swift
    func testSelectBackendReturnsTheRemainingCandidateOrder() async {
        let first = FakeSTTBackend(id: "first")
        first.availabilityValue = .unavailable("offline")
        let second = FakeSTTBackend(id: "second")
        let third = FakeSTTBackend(id: "third")
        let router = makeRouter([first, second, third])

        let selection = await router.selectBackend()

        XCTAssertEqual(selection, STTSelection(backendID: "second", displayName: "second", candidateOrder: ["second", "third"]))
    }

    func testTranscribeWithASelectionStartsAtTheSelectedBackend() async throws {
        let first = FakeSTTBackend(id: "first")
        first.availabilityValue = .unavailable("offline")
        let second = FakeSTTBackend(id: "second")
        let router = makeRouter([first, second])
        let selection = await router.selectBackend()
        first.availabilityValue = .available

        let transcript = try await router.transcribe(audio: audio, options: .init(), selection: selection)

        XCTAssertEqual(transcript, Transcript(text: "second", backendID: "second"))
        XCTAssertEqual(first.availabilityCallCount, 1, "the selection already ruled out 'first'")
        XCTAssertEqual(first.transcriptionCount, 0)
    }

    func testSelectBackendLeavesNoHiddenStateForALaterTranscribe() async throws {
        let first = FakeSTTBackend(id: "first")
        first.availabilityValue = .unavailable("offline")
        let second = FakeSTTBackend(id: "second")
        let router = makeRouter([first, second])
        _ = await router.selectBackend()
        first.availabilityValue = .available

        let transcript = try await router.transcribe(audio: audio, options: .init())

        XCTAssertEqual(transcript, Transcript(text: "first", backendID: "first"))
    }

    func testInterimUsesOnlyTheFirstAvailableBackendAndNeverFallsBack() async {
        let first = FakeSTTBackend(id: "first", error: .initializationFailed("cold"))
        let second = FakeSTTBackend(id: "second")
        let router = makeRouter([first, second])

        do {
            _ = try await router.transcribeForInterim(audio: audio, options: .init())
            XCTFail("Interim must surface the first backend's error")
        } catch {
            XCTAssertEqual(error as? SpeechBackendError, .initializationFailed("cold"))
        }
        XCTAssertEqual(second.transcriptionCount, 0, "a fallback would load a second model on every interim tick")
        XCTAssertEqual(second.availabilityCallCount, 0)
    }

    func testInterimSkipsUnavailableBackendsToFindTheFirstAvailableOne() async throws {
        let first = FakeSTTBackend(id: "first")
        first.availabilityValue = .modelNotDownloaded
        let second = FakeSTTBackend(id: "second")
        let router = makeRouter([first, second])

        let transcript = try await router.transcribeForInterim(audio: audio, options: .init())

        XCTAssertEqual(transcript, Transcript(text: "second", backendID: "second"))
    }

    func testTranscribeStopsAtTheNextBackendWhenTheTaskIsCancelled() async {
        let first = FakeSTTBackend(id: "first")
        let router = makeRouter([first])

        let task = Task { @MainActor in try await router.transcribe(audio: audio, options: .init()) }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("Unexpected \(error)")
        }
        XCTAssertEqual(first.availabilityCallCount, 0)
        XCTAssertEqual(first.transcriptionCount, 0)
    }
```

4. Keep plan 1's four `lastFailedBackendDisplayName` tests unchanged. `testInterimFailuresNeverTouchTheFailedBackend` still holds: interim throws the first backend's error and never writes the property. Add this one, so a selection-driven final transcription still records the failing backend:

```swift
    func testTranscribeWithASelectionRecordsTheBackendWhoseErrorWasThrown() async {
        let first = FakeSTTBackend(id: "first", error: .resourceExhausted)
        let router = makeRouter([first])
        let selection = await router.selectBackend()

        _ = try? await router.transcribe(audio: audio, options: .init(), selection: selection)

        XCTAssertEqual(router.lastFailedBackendDisplayName, "first")
    }
```

5. `FakeSTTBackend` has no `capabilities` or `prepare()` after plan 2. Don't add them back.

- [ ] **Step 2: Run to confirm failure**

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/relay-dd-cleanup4 -only-testing:RelayTests/STTRouterTests`
Expected: build failure, `value of type 'STTRouter' has no member 'selectBackend'`.

- [ ] **Step 3: Implement the router (on top of plan 1 Task 7's version)**

Replace the contents of `Relay/SpeechIn/STTRouter.swift` with the file below. It keeps plan 1's `lastFailedBackendDisplayName` exactly as `DictationCoordinator.fail` and plan 1's tests expect it:
- It is reset to `nil` at the start of every final `transcribe`.
- It is set to the backend whose error is thrown (terminal, non-fallback-worthy, or the last skipped/fallback-worthy one).
- It stays `nil` after a success.
- Interim transcription never touches it.

Plan 1's private `transcribe(audio:options:order:onFailure:)` helper is folded into the final `transcribe`, because the interim path no longer shares it. So the `onFailure` closure becomes direct assignments. `classify(_:)` has no `.initializing` arm (plan 2 Task 4 deleted that case).

```swift
import Foundation

/// The STT backend chosen for one dictation session. `STTRouter.selectBackend()` returns it when
/// listening begins, and the caller passes it back to `transcribe(audio:options:selection:)`.
/// `candidateOrder` starts at the chosen backend, so the final transcription skips backends
/// already ruled out, without the router caching a candidate order between calls.
struct STTSelection: Equatable, Sendable {
    let backendID: String
    let displayName: String
    let candidateOrder: [String]
}

@MainActor
final class STTRouter {
    private enum SelectionStep {
        case use
        case terminal(SpeechBackendError)
        case skip(SpeechBackendError)
    }

    private let backends: [String: any SpeechToTextBackend]
    private let backendOrder: () -> [String]

    /// Display name of the backend whose error the most recent FINAL
    /// `transcribe(audio:options:selection:)` threw (the one that failed, or the last one skipped
    /// as unavailable). `nil` after a success, when no registered backend was tried, or when the
    /// call was cancelled. Interim transcriptions never touch it. Lets dictation error copy name
    /// the backend that needs attention.
    private(set) var lastFailedBackendDisplayName: String?

    init(
        backends: [String: any SpeechToTextBackend],
        backendOrder: @escaping () -> [String]
    ) {
        self.backends = backends
        self.backendOrder = backendOrder
    }

    func displayName(forBackendID id: String) -> String? {
        backends[id]?.displayName
    }

    /// The first available backend in the current order, or `nil` if none is available or a
    /// backend reports a terminal state (permission denied).
    func selectBackend() async -> STTSelection? {
        let order = backendOrder()
        for (index, id) in order.enumerated() {
            guard let backend = backends[id] else { continue }
            switch classify(await backend.availability()) {
            case .use:
                return STTSelection(backendID: id, displayName: backend.displayName, candidateOrder: Array(order[index...]))
            case .terminal:
                return nil
            case .skip:
                continue
            }
        }
        return nil
    }

    /// Final transcription with fallback. It walks `selection.candidateOrder` when given, else the
    /// current backend order, and stops at the next backend once the task is cancelled.
    func transcribe(audio: AudioInput, options: STTOptions, selection: STTSelection? = nil) async throws -> Transcript {
        lastFailedBackendDisplayName = nil
        var lastError: SpeechBackendError = .unavailable("No STT backend is available")
        var lastErrorBackendName: String?

        for id in selection?.candidateOrder ?? backendOrder() {
            try Task.checkCancellation()
            guard let backend = backends[id] else { continue }
            switch classify(await backend.availability()) {
            case .use:
                break
            case let .terminal(error):
                lastFailedBackendDisplayName = backend.displayName
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
                lastFailedBackendDisplayName = backend.displayName
                throw error
            }
        }

        lastFailedBackendDisplayName = lastErrorBackendName
        throw lastError
    }

    /// Interim (live preview) transcription runs every ~450 ms. It uses only the first
    /// available backend and never falls back: a fallback here would load a second model on
    /// every tick just to draw a preview. It never touches `lastFailedBackendDisplayName`.
    func transcribeForInterim(audio: AudioInput, options: STTOptions) async throws -> Transcript {
        var lastError: SpeechBackendError = .unavailable("No STT backend is available")

        for id in backendOrder() {
            try Task.checkCancellation()
            guard let backend = backends[id] else { continue }
            switch classify(await backend.availability()) {
            case .use:
                return try await backend.transcribe(audio: audio, options: options)
            case let .terminal(error):
                throw error
            case let .skip(error):
                lastError = error
            }
        }

        throw lastError
    }

    private func classify(_ availability: BackendAvailability) -> SelectionStep {
        switch availability {
        case .available:
            .use
        case .permissionDenied:
            .terminal(.permissionDenied)
        case .unavailable(let reason):
            .skip(.unavailable(reason))
        case .modelNotDownloaded:
            .skip(.modelNotDownloaded)
        case .unsupportedOS:
            .skip(.unsupportedOS)
        case .unsupportedHardware:
            .skip(.unsupportedHardware)
        case .failed(let reason):
            .skip(.initializationFailed(reason))
        }
    }
}
```

If plan 1 landed `lastFailedBackendDisplayName` with a different doc comment or a different helper shape, keep plan 1's public surface (`private(set) var lastFailedBackendDisplayName: String?`) and its semantics. Only the helper is folded in and the selection is added. `DictationCoordinator.fail` and `actionableMessage(for:backendName:)` need no change.

- [ ] **Step 4: Update `DictationCoordinator`**

1. Next to `private var announcedBackendName: String?`, add:

```swift
    /// The backend chosen when listening began. `finish()` passes it to the final transcription,
    /// so backends ruled out at listen time are not probed again.
    private var sttSelection: STTSelection?
```

2. In `start()`, replace

```swift
        announcedBackendName = nil
        if let name = await sttRouter.preferredBackendDisplayName(), isRecording(session) {
            announcedBackendName = name
            activity.setBackendName(name, sessionID: session)
        }
```

with

```swift
        announcedBackendName = nil
        sttSelection = nil
        if let selection = await sttRouter.selectBackend(), isRecording(session) {
            sttSelection = selection
            announcedBackendName = selection.displayName
            activity.setBackendName(selection.displayName, sessionID: session)
        }
```

3. In `cancel(sessionID:)`, add `sttSelection = nil` right after `finishRequested = false`.

4. In `runProcessingPipeline`, replace

```swift
            transcript = try await sttRouter.transcribe(audio: audio, options: .init())
```

with

```swift
            let selection = sttSelection
            sttSelection = nil
            transcript = try await sttRouter.transcribe(audio: audio, options: .init(), selection: selection)
```

5. Update the `BlockingAvailabilityBackend` doc comment in `DictationCoordinatorTests.swift`: change "`preferredBackendDisplayName()` lookup" to "`selectBackend()` lookup".

- [ ] **Step 5: Add a coordinator wiring test**

Add to `DictationCoordinatorTests`:

```swift
    func testFinalTranscriptionUsesTheBackendSelectedWhenListeningBegan() async {
        let events = EventLog()
        let first = ToggleAvailabilityBackend(id: "first", events: events)
        first.availabilityValue = .unavailable("offline")
        let second = ToggleAvailabilityBackend(id: "second", events: events)
        let sttRouter = STTRouter(backends: [first.id: first, second.id: second], backendOrder: { ["first", "second"] })
        let overlay = RecordingActivityOverlay()
        let coordinator = makeCoordinator(sttRouter: sttRouter, overlay: overlay)

        await coordinator.start()
        first.availabilityValue = .available
        await coordinator.finish()

        XCTAssertEqual(events.values, ["stt.transcribe.second"])
        XCTAssertEqual(first.availabilityCallCount, 1, "the listen-time selection already ruled out 'first'")
    }
```

At file scope:

```swift
@MainActor
private final class ToggleAvailabilityBackend: SpeechToTextBackend {
    let id: String
    let displayName: String
    let events: EventLog
    var availabilityValue: BackendAvailability = .available
    private(set) var availabilityCallCount = 0

    init(id: String, events: EventLog) {
        self.id = id
        self.displayName = id
        self.events = events
    }

    func availability() async -> BackendAvailability {
        availabilityCallCount += 1
        return availabilityValue
    }

    func transcribe(audio: AudioInput, options: STTOptions) async throws -> Transcript {
        events.append("stt.transcribe.\(id)")
        return Transcript(text: "text", backendID: id)
    }
}
```

`makeCoordinator` builds its default `FakeMicrophone` with its own private `EventLog`, so the test's `events` only ever sees the backend entries and the exact assertion holds. If it ever picks up `microphone.*` entries, assert `XCTAssertEqual(events.values.filter { $0.hasPrefix("stt.") }, ["stt.transcribe.second"])` instead.

- [ ] **Step 6: Run router and coordinator tests**

```bash
xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/relay-dd-cleanup4 -only-testing:RelayTests/STTRouterTests -only-testing:RelayTests/DictationCoordinatorTests
grep -rn "preferredBackendDisplayName\|cachedCandidateOrder" Relay RelayTests
```

Expected: `** TEST SUCCEEDED **`, including plan 1's four `lastFailedBackendDisplayName` router tests and `DictationCoordinatorTests.testModelNotDownloadedStatusNamesTheSkippedBackend`. The grep prints nothing.

- [ ] **Step 7: Full suite, then commit**

```bash
git add Relay/SpeechIn/STTRouter.swift Relay/SpeechIn/DictationCoordinator.swift RelayTests/SpeechIn/STTRouterTests.swift RelayTests/SpeechIn/DictationCoordinatorTests.swift
git commit -m "fix(dictation): explicit STT selection token; interim never falls back"
```

---

## Task 15: `AppleSpeechBackend` asset cache and privacy label (review items 8 and 11)

The existing `prepareAssets`/`transcribeAudio` closures are already the test seam. The cache sits in front of `prepareAssets`, so from the second call on for a locale, each `transcribe` builds exactly one `SpeechTranscriber` (inside `transcribeAudio`). The first call for a locale still builds one in `prepareAssets` to query `AssetInventory`. The "prepare() uses `.current`" half of review item 8 is moot: plan 2 Task 4 deleted STT `prepare()`, so `transcribe` is the only caller of `prepareAssets`.

**Files:**
- Modify: `Relay/Backends/AppleSpeechBackend.swift` (`transcribe`, and the runtime catch that throws `inferenceFailed(error.localizedDescription)`)
- Modify: `RelayTests/Backends/AppleSpeechBackendTests.swift`

- [ ] **Step 1: Write the failing tests**

Add to `AppleSpeechBackendTests`:

```swift
    func testAssetsArePreparedOncePerLocale() async throws {
        let recorder = SpeechOperationRecorder()
        let backend = AppleSpeechBackend(
            isMacOS26OrLater: { true },
            isSpeechTranscriberAvailable: { true },
            prepareAssets: { locale in await recorder.recordPrepared(locale) },
            transcribeAudio: { _, locale in
                await recorder.recordTranscribed(locale)
                return "Hello"
            }
        )
        let audio = AudioInput(samples: [0.1], sampleRate: 16_000)

        _ = try await backend.transcribe(audio: audio, options: STTOptions(localeIdentifier: "fr-FR"))
        _ = try await backend.transcribe(audio: audio, options: STTOptions(localeIdentifier: "fr-FR"))
        _ = try await backend.transcribe(audio: audio, options: STTOptions(localeIdentifier: "de-DE"))

        let operations = await recorder.operations
        XCTAssertEqual(operations, [
            .prepared("fr-FR"), .transcribed("fr-FR"),
            .transcribed("fr-FR"),
            .prepared("de-DE"), .transcribed("de-DE"),
        ])
    }

    func testFailedAssetPreparationIsRetriedOnTheNextCall() async throws {
        let attempts = PreparationAttempts()
        let backend = AppleSpeechBackend(
            isMacOS26OrLater: { true },
            isSpeechTranscriberAvailable: { true },
            prepareAssets: { _ in
                if await attempts.next() == 1 { throw TestFailure.failed }
            },
            transcribeAudio: { _, _ in "Hello" }
        )
        let audio = AudioInput(samples: [0.1], sampleRate: 16_000)

        _ = try? await backend.transcribe(audio: audio, options: .init())
        _ = try await backend.transcribe(audio: audio, options: .init())

        let count = await attempts.count
        XCTAssertEqual(count, 2)
    }
```

At file scope:

```swift
private actor PreparationAttempts {
    private(set) var count = 0
    func next() -> Int {
        count += 1
        return count
    }
}
```

- [ ] **Step 2: Run to confirm failure**

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/relay-dd-cleanup4 -only-testing:RelayTests/AppleSpeechBackendTests`

Expected: `** TEST FAILED **`:
- `testAssetsArePreparedOncePerLocale` shows extra `.prepared("fr-FR")`.

- [ ] **Step 3: Implement**

1. Add `import Synchronization` at the top of the file.
2. Add this stored property after `transcribeAudio`:

```swift
    /// Locale identifiers whose on-device assets were confirmed installed during this process.
    /// A failed preparation is never cached. Keyed by `Locale.identifier`.
    private let installedAssetLocales = Mutex<Set<String>>([])
```

3. Replace the first `do { try await prepareAssets(locale) … }` block in `transcribe` with:

```swift
        try await ensureAssets(for: locale)
```

4. Add this method before `defaultOSSupport()`:

```swift
    private func ensureAssets(for locale: Locale) async throws {
        if installedAssetLocales.withLock({ $0.contains(locale.identifier) }) {
            return
        }
        do {
            try await prepareAssets(locale)
            try Task.checkCancellation()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SpeechBackendError {
            throw error
        } catch {
            throw SpeechBackendError.initializationFailed("Apple Speech preparation failed")
        }
        installedAssetLocales.withLock { _ = $0.insert(locale.identifier) }
    }
```

5. Privacy (review item 11): in `AppleSpeechRuntime.transcribe`, change the last catch from `throw SpeechBackendError.inferenceFailed(error.localizedDescription)` to:

```swift
            throw SpeechBackendError.inferenceFailed("Apple Speech analysis failed")
```

That path lives inside the private runtime and cannot be reached without the real Speech framework, so it has no unit test. It matches the label the backend wrapper already uses.

- [ ] **Step 4: Run the backend tests and the privacy grep**

```bash
xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/relay-dd-cleanup4 -only-testing:RelayTests/AppleSpeechBackendTests
grep -n "localizedDescription" Relay/Backends/AppleSpeechBackend.swift
```

Expected: `** TEST SUCCEEDED **`, and the grep prints nothing.

- [ ] **Step 5: Full suite, then commit**

```bash
git add Relay/Backends/AppleSpeechBackend.swift RelayTests/Backends/AppleSpeechBackendTests.swift
git commit -m "fix(dictation): cache Apple Speech assets per locale; keep raw errors out of messages"
```

---

## Task 16: Precompile the `RulesSpeechPreprocessor` regexes (review item 11)

This is a pure refactor: `RulesSpeechPreprocessorTests` already pins the output. `NSRegularExpression` is `NS_SWIFT_SENDABLE` in the macOS 27 SDK, so a `static let` is concurrency-safe.

**Files:**
- Modify: `Relay/SpeechOut/RulesSpeechPreprocessor.swift` (lines 6–53, 107–121)

- [ ] **Step 1: Run the existing tests (baseline)**

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/relay-dd-cleanup4 -only-testing:RelayTests/RulesSpeechPreprocessorTests`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 2: Implement**

Replace `prepare(text:mode:)` and `replacingMatches(in:pattern:with:)` with the code below. Keep `codeBlockCue`, the fence helpers and `Fence` unchanged.

```swift
    /// Markdown-to-speech rewrite rules, compiled once. Order matters: each rule runs on the
    /// output of the previous one. The patterns are constants covered by
    /// `RulesSpeechPreprocessorTests`, so a compile failure is a programmer error.
    private static let rules: [(expression: NSRegularExpression, template: String)] = [
        (#"\[([^\]]+)\]\([^\)]+\)"#, "$1"),
        (#"(?m)^[ \t]{0,3}#{1,6}[ \t]+"#, ""),
        (#"(?m)[ \t]+#+[ \t]*$"#, ""),
        (#"(?m)^[ \t]{0,3}(?:=+|-+)[ \t]*$"#, ""),
        (#"(?m)^[ \t]*(?:>[ \t]*)+"#, ""),
        (#"(?m)^[ \t]*[-*+][ \t]+(.+?)[ \t]*$"#, "$1."),
        (#"(\*\*|__)(.+?)\1"#, "$2"),
        (#"(\*|_)(.+?)\1"#, "$2"),
    ].map { pattern, template in
        (try! NSRegularExpression(pattern: pattern), template)
    }

    private static let whitespace = try! NSRegularExpression(pattern: #"\s+"#)

    func prepare(text: String, mode: SpeechMode) -> String {
        var prepared = replacingFencedCode(in: text)
        for rule in Self.rules {
            prepared = Self.replacingMatches(in: prepared, using: rule.expression, with: rule.template)
        }
        prepared = prepared.replacingOccurrences(of: "`", with: "")
        prepared = Self.replacingMatches(in: prepared, using: Self.whitespace, with: " ")
        return prepared.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replacingMatches(
        in text: String,
        using expression: NSRegularExpression,
        with template: String
    ) -> String {
        expression.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: template
        )
    }
```

If the compiler reports `static property 'rules' is not concurrency-safe` (an SDK where `NSRegularExpression` is not `Sendable`), declare both properties as `nonisolated(unsafe) private static let`. That is safe because `NSRegularExpression` is immutable and documented thread-safe.

- [ ] **Step 3: Run the tests again**

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/relay-dd-cleanup4 -only-testing:RelayTests/RulesSpeechPreprocessorTests`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 4: Full suite, then commit**

```bash
git add Relay/SpeechOut/RulesSpeechPreprocessor.swift
git commit -m "perf(speech): compile speech preprocessor regexes once"
```

---

## Task 17: Clamp the Kokoro speed (review item 11)

FluidAudio declares no speed range for KokoroAne. Relay's valid input is `AppSettings.validTTSRateRange` (0.1…1.0) mapped by `rate / 0.5`, which gives 0.2…2.0. That is exactly what the existing slow and fast tests pin. The clamp keeps an unnormalized or NaN `TTSOptions.rate` from ever reaching the model.

**Files:**
- Modify: `Relay/Backends/KokoroTTSBackend.swift` (lines 34–36: the two-line rate comment and `let speed = options.rate / 0.5`)
- Modify: `RelayTests/Backends/KokoroTTSBackendTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `KokoroTTSBackendTests`:

```swift
    func testSpeedIsClampedToTheSupportedRange() {
        XCTAssertEqual(KokoroTTSBackend.speed(forRate: 0.5), 1.0, accuracy: 0.0001)
        XCTAssertEqual(KokoroTTSBackend.speed(forRate: 5), 2.0, accuracy: 0.0001)
        XCTAssertEqual(KokoroTTSBackend.speed(forRate: 0), 0.2, accuracy: 0.0001)
        XCTAssertEqual(KokoroTTSBackend.speed(forRate: -1), 0.2, accuracy: 0.0001)
        XCTAssertEqual(KokoroTTSBackend.speed(forRate: .nan), 1.0, accuracy: 0.0001)
    }
```

- [ ] **Step 2: Run to confirm failure**

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/relay-dd-cleanup4 -only-testing:RelayTests/KokoroTTSBackendTests/testSpeedIsClampedToTheSupportedRange`
Expected: build failure, `type 'KokoroTTSBackend' has no member 'speed'`.

- [ ] **Step 3: Implement**

Add to `KokoroTTSBackend`:

```swift
    /// Kokoro `voiceSpeed` range Relay drives: the shared slider range
    /// (`AppSettings.validTTSRateRange`, 0.1...1.0) mapped through `rate / 0.5`, so 0.5 (the
    /// shared default) maps to 1.0 (normal speed).
    nonisolated static let speedRange: ClosedRange<Float> = 0.2...2.0

    nonisolated static func speed(forRate rate: Float) -> Float {
        guard rate.isFinite else { return 1 }
        return min(max(rate / 0.5, speedRange.lowerBound), speedRange.upperBound)
    }
```

In `makeAudioSource`, replace the comment and `let speed = options.rate / 0.5` with:

```swift
        let speed = Self.speed(forRate: options.rate)
```

- [ ] **Step 4: Run the Kokoro backend tests**

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/relay-dd-cleanup4 -only-testing:RelayTests/KokoroTTSBackendTests`
Expected: `** TEST SUCCEEDED **`. The old proportional-mapping tests still pass.

- [ ] **Step 5: Full suite, then commit**

```bash
git add Relay/Backends/KokoroTTSBackend.swift RelayTests/Backends/KokoroTTSBackendTests.swift
git commit -m "fix(speech): clamp Kokoro speed to the supported range"
```

---

## Task 18: Remove the redundant `@unchecked Sendable` and a duplicate `TTSRouter` catch (review item 11)

The compiler proves this change: a `@MainActor` class is already `Sendable`.

**Files:**
- Modify: `Relay/SpeechOut/SpeechCoordinator.swift` (lines 20–24)
- Modify: `Relay/SpeechOut/TTSRouter.swift` (lines 87–90)

`AgentAutoReadCoordinator` is owned by plan 3 (which rewrites it). This task only mentions it in a doc comment and runs its tests; do not edit `Relay/Sessions/` or its tests. If plan 3 has merged first and the test class was renamed, drop that `-only-testing` flag and rely on the full suite.

- [ ] **Step 1: `SpeechCoordinator`**

Replace the four-line doc comment and `extension SpeechCoordinator: SpeechSubmitting, @unchecked Sendable {}` with:

```swift
/// `SpeechCoordinator` is `@MainActor`, so it is already `Sendable`; cross-isolation callers
/// such as `AgentAutoReadCoordinator` can hold it as `any SpeechSubmitting & Sendable`.
extension SpeechCoordinator: SpeechSubmitting {}
```

- [ ] **Step 2: `TTSRouter`**

In the `makeAudioSource` do/catch, delete the branch

```swift
            } catch let error as SpeechBackendError {
                guard generation == routingGeneration else { throw CancellationError() }
                eventHandler?(.failed(sessionID: sessionID), nil)
                throw error
```

Its body is identical to the trailing `catch { … }`, which stays. Keep the `where error.isFallbackWorthy` branch before it. If plan 1 or 2 changed either body so they are no longer identical, leave both branches alone and note that in Execution Notes.

- [ ] **Step 3: Run the TTS tests**

```bash
xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/relay-dd-cleanup4 -only-testing:RelayTests/TTSRouterTests -only-testing:RelayTests/SpeechCoordinatorTests -only-testing:RelayTests/AgentAutoReadCoordinatorTests
```

Expected: `** TEST SUCCEEDED **`, with no new warnings about `SpeechCoordinator` sendability.

- [ ] **Step 4: Full suite, then commit**

```bash
git add Relay/SpeechOut/SpeechCoordinator.swift Relay/SpeechOut/TTSRouter.swift
git commit -m "refactor(speech): drop redundant Sendable escape hatch and duplicate catch"
```

---

## Task 19: Stop double-buffering the PocketTTS stream (review item 11)

Finding (verified in FluidAudio 0.15.7, `PocketTtsSynthesizer.makeStream` and `PocketTtsSession.frames`): FluidAudio's generator yields frames from its own eager `Task` into an **unbounded** `AsyncThrowingStream`, and `yield` never suspends. No wrapper Relay writes can slow synthesis itself; that would need an upstream FluidAudio change. What Relay *can* fix: `PocketTtsManagerSession.synthesizeStream` adds a second forwarding `Task` that drains FluidAudio's stream as fast as it arrives into another unbounded buffer. Replace it with a lazy pull-through, so Relay holds each frame once, and only as far as the bounded `TTSAudioPipe` downstream has asked for it.

**Files:**
- Modify: `Relay/Backends/FluidAudioPocketTTSEngine.swift` (`PocketTtsManagerSession.synthesizeStream` and its doc comment, lines 329–348 before Task 5; ~70 lines earlier after Task 5 shrinks the actor)
- Modify: `RelayTests/Backends/FluidAudioPocketTTSEngineTests.swift`

- [ ] **Step 1: Write the failing tests**

Add to `FluidAudioPocketTTSEngineTests`:

```swift
    func testFrameStreamAdapterPullsUpstreamOnlyAsTheConsumerAsks() async throws {
        let pulls = PullCounter()
        let upstream = AsyncThrowingStream<Int, Error>(unfolding: {
            let pull = await pulls.increment()
            return pull <= 5 ? pull : nil
        })
        let mapped = PocketTTSFrameStream.samples(from: upstream) { [Float($0)] }

        var iterator = mapped.makeAsyncIterator()
        let first = try await iterator.next()
        for _ in 0..<50 { await Task.yield() }

        XCTAssertEqual(first, [1])
        let pulled = await pulls.value
        XCTAssertEqual(pulled, 1, "the adapter must not drain FluidAudio's stream ahead of the consumer")
    }

    func testFrameStreamAdapterForwardsElementsThenUpstreamErrors() async {
        let upstream = AsyncThrowingStream<Int, Error> { continuation in
            continuation.yield(7)
            continuation.finish(throwing: FakeLoaderError.boom)
        }
        let mapped = PocketTTSFrameStream.samples(from: upstream) { [Float($0)] }

        var received: [[Float]] = []
        do {
            for try await samples in mapped { received.append(samples) }
            XCTFail("Expected the upstream error")
        } catch {
            XCTAssertEqual(error as? FakeLoaderError, .boom)
        }
        XCTAssertEqual(received, [[7]])
    }
```

At file scope:

```swift
private actor PullCounter {
    private(set) var value = 0
    func increment() -> Int {
        value += 1
        return value
    }
}
```

- [ ] **Step 2: Run to confirm failure**

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/relay-dd-cleanup4 -only-testing:RelayTests/FluidAudioPocketTTSEngineTests`
Expected: build failure, `cannot find 'PocketTTSFrameStream' in scope`.

- [ ] **Step 3: Implement**

Add this at file scope in `FluidAudioPocketTTSEngine.swift`, before `PocketTtsManagerSession`:

```swift
/// Adapts FluidAudio's PocketTTS frame stream to raw sample arrays without an intermediate buffer
/// or task: each pull on the returned stream pulls exactly one upstream element. FluidAudio's
/// generator still runs ahead into its own unbounded buffer (its `makeStream` yields from an eager
/// task and `yield` never suspends), so this cannot throttle synthesis itself. It removes Relay's
/// second copy and forwarding task; the bounded `TTSAudioPipe` downstream bounds what Relay holds.
enum PocketTTSFrameStream {
    static func samples<Element>(
        from upstream: AsyncThrowingStream<Element, Error>,
        transform: @escaping @Sendable (Element) -> [Float]
    ) -> AsyncThrowingStream<[Float], Error> {
        let iterator = IteratorBox(upstream.makeAsyncIterator())
        return AsyncThrowingStream(unfolding: {
            guard let element = try await iterator.next() else { return nil }
            return transform(element)
        })
    }

    /// The upstream iterator is not `Sendable`. `AsyncThrowingStream(unfolding:)` calls its
    /// closure serially from the single consumer, so the box is never accessed concurrently.
    private final class IteratorBox<Element>: @unchecked Sendable {
        private var iterator: AsyncThrowingStream<Element, Error>.Iterator

        init(_ iterator: AsyncThrowingStream<Element, Error>.Iterator) {
            self.iterator = iterator
        }

        func next() async throws -> Element? {
            try await iterator.next()
        }
    }
}
```

Replace the body of `PocketTtsManagerSession.synthesizeStream(text:voice:)` and its doc comment with:

```swift
    /// Adapts FluidAudio's `AudioFrame` stream down to raw samples, pulling lazily (see
    /// `PocketTTSFrameStream`). Cancelling the consumer drops the upstream iterator, which ends
    /// FluidAudio's stream and cancels its generator task.
    func synthesizeStream(text: String, voice: String) async throws -> AsyncThrowingStream<[Float], Error> {
        let frames = try await manager.synthesizeStreaming(text: text, voice: voice)
        return PocketTTSFrameStream.samples(from: frames) { $0.samples }
    }
```

If the compiler rejects `try await iterator.next()` on the class property ("cannot call mutating async function"), change `next()` to:

```swift
        func next() async throws -> Element? {
            var local = iterator
            defer { iterator = local }
            return try await local.next()
        }
```

This is safe because access is serial.

- [ ] **Step 4: Run the Pocket tests**

```bash
xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/relay-dd-cleanup4 -only-testing:RelayTests/FluidAudioPocketTTSEngineTests -only-testing:RelayTests/PocketTTSBackendTests -only-testing:RelayTests/PocketTTSAudioSourceTests
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Full suite, then commit**

```bash
git add Relay/Backends/FluidAudioPocketTTSEngine.swift RelayTests/Backends/FluidAudioPocketTTSEngineTests.swift
git commit -m "perf(speech): pull PocketTTS frames lazily instead of double-buffering"
```

---

## Task 20: Remove the default `= FluidAudioXEngine()` arguments (review item 11)

A default engine argument lets a call site build a second copy of a multi-hundred-MB model by accident. `RelayRuntime` already passes one shared engine to each backend and manager pair (lines 203–208, 234–236), so this task does NOT edit `Relay/App/RelayRuntime.swift` (plan 3 edits it in parallel). Verified on `main`: no call site constructs any of these six types without `engine:`, so Step 2's grep is expected to be empty.

**Files:**
- Modify:
  - `Relay/Backends/KokoroTTSBackend.swift:16`
  - `Relay/Backends/PocketTTSBackend.swift:17`
  - `Relay/Backends/ParakeetBackend.swift:50`
  - `Relay/Backends/ParakeetModelManager.swift:34`
  - `Relay/Backends/KokoroModelManager.swift:15`
  - `Relay/Backends/PocketTTSModelManager.swift:14`
- Possibly modify: `RelayTests/Domain/SpeechBackendContractsTests.swift` (only if a no-argument construction survived plan 2)

- [ ] **Step 1: Remove the defaults**

In each of the six files, change `init(engine: any XEngine = FluidAudioXEngine())` to `init(engine: any XEngine)`. For example:

```swift
    init(engine: any KokoroEngine) {
        self.engine = engine
    }
```

- [ ] **Step 2: Find call sites that relied on the defaults**

```bash
grep -rnE "(KokoroTTSBackend|PocketTTSBackend|ParakeetBackend|ParakeetModelManager|KokoroModelManager|PocketTTSModelManager)\(\)" Relay RelayTests
```

Expected: no output. If `SpeechBackendContractsTests` still has `PocketTTSBackend()` or `KokoroTTSBackend()`, pass `engine: FluidAudioPocketTTSEngine()` or `engine: FluidAudioKokoroEngine()`. Constructing them does no I/O and loads nothing.

- [ ] **Step 3: Full suite**

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/relay-dd-cleanup4`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add Relay/Backends/KokoroTTSBackend.swift Relay/Backends/PocketTTSBackend.swift Relay/Backends/ParakeetBackend.swift Relay/Backends/ParakeetModelManager.swift Relay/Backends/KokoroModelManager.swift Relay/Backends/PocketTTSModelManager.swift
# add RelayTests/Domain/SpeechBackendContractsTests.swift too if Step 2 changed it
git commit -m "refactor(speech): require an explicit shared engine for backends and managers"
```

---

## Task 21: Final verification

**Files:** none (plus the Execution Notes in this plan)

- [ ] **Step 1: Clean full-suite run**

```bash
rm -rf /tmp/relay-dd-cleanup4
xcodegen generate
git status --short
xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/relay-dd-cleanup4 2>&1 | tail -5
```

Expected: `git status --short` shows nothing, or only this plan file, and the output ends with `** TEST SUCCEEDED **`.

- [ ] **Step 2: Re-check names and leftovers against the code**

```bash
grep -rn "inFlightLoad\|enum LoadKind" Relay | grep -v ModelSessionLoader.swift
grep -rn "AppleSpeechBufferBridge\|NSCondition" Relay | grep -v CaptureCallbackGate.swift
grep -rn "preferredBackendDisplayName\|cachedCandidateOrder\|MicrophoneLevelMeter\|level(forFrame" Relay RelayTests
grep -rnE "engine: any [A-Za-z]+Engine = FluidAudio" Relay
grep -rn "inferenceFailed(error.localizedDescription" Relay
```

Expected: every command prints nothing.

- [ ] **Step 3: Manual smoke test in the Debug app**

1. **Dictation with live transcription on**, using Parakeet or Whisper. The pill shows interim text. The final text is inserted. With Whisper selected, the first dictation after launch loads the model once: check Activity Monitor for a single memory ramp.
2. **Read a long reply with Kokoro, then with PocketTTS, then with Apple.** The speaking waveform moves in step with the audio, with no burst at the start. Stop mid-reply ends it immediately.
3. **Switch the output device while speaking.** The session ends right away, with no 300-second hang, and the next reply plays on the new device.
4. **Switch the input device while dictating.** Covered in Task 13, Step 7.

Record the results and the Task 8 spike line in **Execution Notes**.

- [ ] **Step 4: Commit the plan notes**

```bash
git add docs/superpowers/plans/2026-09-23-relay-cleanup-4-speech-engines.md
git commit -m "docs: record cleanup-4 execution notes"
```

- [ ] **Step 5: Finish the branch**

Use superpowers:finishing-a-development-branch. If a PR body is written, it must not contain a "Generated with Claude Code" line or any Claude session link.
