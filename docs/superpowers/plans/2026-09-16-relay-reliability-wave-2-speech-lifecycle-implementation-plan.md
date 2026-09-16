# Relay Reliability — Wave 2: Speech Lifecycle & Platform Consistency Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Give every TTS backend one identical `speak()` lifecycle contract, collapse the router to a single playback owner, guarantee exactly one terminal event per accepted session, add a watchdog that self-heals a wedged session with no new request, remove disposable interim STT from the final-transcription critical path, and make backend capabilities and platform defaults describe reality.

**Why:** The reliability audit (`relay-reliability-simplification-review.md`, §4, §7) found seven speech/platform defects, all verified TRUE against commit `cfcdf27`:
1. `speak()` completion means different things per backend (Apple returns after scheduling; Kokoro/PocketTTS block until playback terminates).
2. `TTSRouter` keeps parallel routing + active state; `pause()`/`resume()` target only `activeBackend`, which stays `nil` for the entire playback of both on-device backends → pause/resume are no-ops except for Apple.
3. `SynthesizedAudioPlayer` discards `AVAudioPlayer.play()`'s Bool and ignores the delegate `successfully` flag → a failed start hangs `speak()` with no terminal event.
4. A wedged in-flight session self-heals only when the next automatic request arrives; no independent watchdog.
5. Final dictation waits for an uncancellable in-flight interim inference (up to ~15 s); live interim is ON by default.
6. `ParakeetBackend` advertises `.multilingual` while the engine is English-only Parakeet v2 (backend doc even says "v3").
7. Deployment target is macOS 14 but the only default STT backend (Apple Speech) needs macOS 26 → dictation is broken out of the box on macOS 14–25.

**Architecture:** `TTSPlaybackEvent` (`Relay/SpeechOut/TextToSpeechBackend.swift:3-23`) already defines the full lifecycle — `scheduled → started → level → (finished | cancelled | failed)`. Wave 2 makes every backend *return from `speak()` at the same point* (right after playback starts) and report the terminal event through the handler, which then lets the router hold one `ActivePlayback` instead of the routing/active pair. Player-level terminal guarantees, a watchdog, interim-STT isolation, and the metadata/platform corrections follow.

**Tech Stack:** Swift 6 strict concurrency, AVFoundation, FluidAudio, XCTest, XcodeGen.

**Templates to read first:** `Relay/SpeechOut/TextToSpeechBackend.swift`, `Relay/SpeechOut/TTSRouter.swift`, `Relay/SpeechOut/AppleTTSBackend.swift` (the backend that already returns after scheduling and reports terminal via delegate — the target shape), `Relay/Backends/KokoroTTSBackend.swift`, `Relay/Backends/PocketTTSBackend.swift`, `Relay/SpeechOut/SynthesizedAudioPlayer.swift`, `Relay/SpeechOut/StreamingAudioPlayer.swift`, `Relay/SpeechOut/SpeechCoordinator.swift`, `Relay/SpeechIn/DictationCoordinator.swift`, `Relay/Backends/StreamingTranscriber.swift`.

---

## Ground rules
- Work on `main`. No worktrees. **Run implementers one at a time.**
- **Depends on Wave 1 being merged** (it does not strictly require the runner, but the two waves must not be edited concurrently).
- Generate the project only via `xcodegen generate`. Never hand-edit `Relay.xcodeproj`.
- TDD each task; zero warnings; suite ends `** TEST SUCCEEDED **`.
- **No commit trailers.** Plain messages.
- Privacy: no spoken text, transcript, audio, paths, or raw error strings in logs/Diagnostics/overlay.
- **Do NOT remove any backend.** Apple TTS/Speech must remain a boring fallback. Kokoro and PocketTTS stay registered.
- **Task order matters:** Task 1 (unified return point) must land before Task 2 (collapse router state). Task 3 (player terminal guarantee) supports both. Tasks 5–7 are independent.
- Test command template:
  ```bash
  xcodegen generate
  xcodebuild test -scheme Relay -destination 'platform=macOS' -only-testing:RelayTests/<Suite> 2>&1 | tail -30
  ```

---

## Task 1: One `speak()` return-point contract for every TTS backend

**The bug:** `Relay/SpeechOut/AppleTTSBackend.swift:65-66` emits `.scheduled` then `synthesizer.speak(utterance)` and *returns immediately*; the terminal event arrives later via the delegate (lines ~125-139). But `Relay/Backends/KokoroTTSBackend.swift:68` (`try await player.play(wav, sessionID:)`) and `Relay/Backends/PocketTTSBackend.swift:69` block until playback *terminates*, because the players suspend on a continuation until a terminal event (`Relay/SpeechOut/SynthesizedAudioPlayer.swift:97-99`, `Relay/SpeechOut/StreamingAudioPlayer.swift:176-179`). So `speak()` completion is ambiguous.

**Target contract (document it in `TextToSpeechBackend.swift`):**
> `speak(text:options:sessionID:)` validates input, starts (or schedules) playback, and returns as soon as playback has *started* — never waiting for it to finish. It reports progress and completion asynchronously through the playback event handler: `scheduled` → `started` → `level*` → exactly one of `finished | cancelled | failed`. A backend that cannot start playback throws (so the router can fall back) and emits no terminal event itself.

**Files:**
- Modify: `Relay/SpeechOut/TextToSpeechBackend.swift` (add the contract doc comment on `speak`)
- Modify: `Relay/Backends/KokoroTTSBackend.swift`, `Relay/Backends/PocketTTSBackend.swift` (return after playback *starts*, not after it terminates)
- Modify: `Relay/SpeechOut/SynthesizedAudioPlayer.swift`, `Relay/SpeechOut/StreamingAudioPlayer.swift` (expose a "start playback, resume caller at `.started`" entry that reports terminal via the event handler instead of via the awaited call's return)
- Test: `RelayTests/Backends/TTSBackendContractTests.swift` (create — a shared contract test run against each backend using a fake player/synthesizer)

- [ ] **Step 1: Write the failing contract test.** For each backend (Apple, Kokoro, PocketTTS) with a fake audio player/synthesizer seam:
  - `speak()` returns *before* the terminal event fires (assert ordering: `speak` resolves, then a later `.finished` arrives on the handler).
  - the handler observes `scheduled` (or `started`) then exactly one terminal.

```swift
func testSpeakReturnsAtStartNotAtTerminal_forEachBackend() async throws {
    for backend in makeBackendsWithFakePlayers() {
        var events: [TTSPlaybackEvent] = []
        backend.setPlaybackEventHandler { events.append($0) }
        let sid = UUID()
        try await backend.speak(text: "hi", options: .init(), sessionID: sid)
        // At return, no terminal yet:
        XCTAssertFalse(events.contains { isTerminal($0) }, "\(backend.id) blocked speak() until terminal")
        // Fire the fake player's completion:
        fakePlayer(for: backend).finish(sessionID: sid)
        XCTAssertEqual(events.filter { isTerminal($0) }.count, 1)
    }
}
```

- [ ] **Step 2: Run — verify fail** (Kokoro/PocketTTS block; test times out or terminal already present at return).

- [ ] **Step 3: Implement.** Give the players a non-blocking start:
  - Add to `SynthesizedAudioPlayer` / `StreamingAudioPlayer` a `startPlayback(_:sessionID:)` that starts audio, invokes the event handler with `.started`, and arranges the terminal event through the existing delegate/engine callbacks — **without** the caller awaiting a continuation to terminal. (Keep any existing awaited API only if other callers need it; the backends switch to the new start API.)
  - In `KokoroTTSBackend.speak` / `PocketTTSBackend.speak`: synthesize to WAV/stream, then call the player's start API and return. Terminal is reported by the player through the handler, exactly like Apple.
  - Add the contract doc comment to `TextToSpeechBackend.speak`.

- [ ] **Step 4: Run — verify pass** for all three backends.

- [ ] **Step 5: Commit**

```bash
git add Relay/SpeechOut/TextToSpeechBackend.swift Relay/Backends/KokoroTTSBackend.swift \
  Relay/Backends/PocketTTSBackend.swift Relay/SpeechOut/SynthesizedAudioPlayer.swift \
  Relay/SpeechOut/StreamingAudioPlayer.swift RelayTests/Backends/TTSBackendContractTests.swift
git commit -m "refactor(tts): unify speak() to return at playback start and report terminal via handler"
```

**Acceptance:** every backend returns from `speak()` at the same lifecycle point (playback started); terminal events arrive asynchronously through the handler.

---

## Task 2: Collapse `TTSRouter` to one `ActivePlayback`

**The bug:** `Relay/SpeechOut/TTSRouter.swift:7-14` holds `activeBackend`/`activeSessionID` AND `routingBackend`/`routingSessionID`. `activeBackend` is assigned only after `speak()` returns (lines 63-64). `pause()`/`resume()` target only `activeBackend` (lines 101-107). Because Kokoro and PocketTTS blocked in `speak()` (pre-Task 1), `activeBackend` was `nil` for their whole playback → pause/resume were no-ops for both. `stop()` worked because it used `routingBackend ?? activeBackend` (line 85).

**The fix (now that Task 1 makes `speak()` return at start):** collapse to one `ActivePlayback { backend, sessionID }` assigned the moment `speak()` returns (playback started). `pause()`/`resume()`/`stop()` all target it. Delete `routingBackend`/`routingSessionID` and the dual-path `forward` filter.

**Files:**
- Modify: `Relay/SpeechOut/TTSRouter.swift`
- Test: `RelayTests/SpeechOut/TTSRouterTests.swift` (extend)

- [ ] **Step 1: Failing tests.**
  - `testPauseResumeTargetCurrentPlaybackForEveryBackend` (Apple, Kokoro, PocketTTS via fakes): after `speak()`, `pause()` calls `pause()` on the backend that is playing.
  - `testStopTargetsCurrentPlayback`.
  - `testOneSessionEmitsExactlyOneTerminal` through the router handler.
  - `testScheduledAndStartedAreForwardedForEveryBackend`: assert the router forwards the synchronous `.scheduled` and `.started` events for Apple, Kokoro, AND PocketTTS (this is the event-drop regression guard — it fails if `active` is assigned after `speak()` returns).
  - `testStaleStopBySessionIDIsIgnored` (keep current behavior of `stop(sessionID:)`).

- [ ] **Step 2: Run — verify fail** (pause/resume no-op for Kokoro/Pocket today).

- [ ] **Step 3: Implement.** Replace the dual state with:

```swift
private struct ActivePlayback { let backend: any TextToSpeechBackend; let sessionID: UUID }
private var active: ActivePlayback?
```

**Assign `active` BEFORE the `speak()` call, not after.** The players emit `.scheduled` and `.started` *synchronously inside* `backend.speak(...)` (`SynthesizedAudioPlayer.play()` fires `.scheduled` at line 91 and `.started` at line 94, both while `speak()` is still executing). If `active` were assigned only after `speak()` returns, `forward` would filter those in-flight events out for Kokoro/PocketTTS (their `speak()` returns right after `.started` post-Task 1) — silently dropping lifecycle events anything downstream gates on (level metering, overlay). This is exactly why the `routingBackend`/`routingSessionID` pair exists today; one `active` assigned early fully subsumes it. So:

```swift
// inside the backendOrder loop, replacing the routing/active bookkeeping:
if let active, active.backend !== backend { active.backend.stop(); self.active = nil }
active = ActivePlayback(backend: backend, sessionID: sessionID)   // BEFORE speak
do {
    try await backend.speak(text: text, options: options, sessionID: sessionID)
    return
} catch let error as SpeechBackendError where error.isFallbackWorthy {
    active = nil            // this backend declined; try the next one
    lastError = error
} catch {
    active = nil
    eventHandler?(.failed(sessionID: sessionID), nil)
    throw error
}
```

Clear `active` when a terminal event for `active.sessionID` is forwarded. `pause()`/`resume()`/`stop()` → `active?.backend.pause()/resume()/stop()`. `forward` becomes: forward events whose `sessionID == active?.sessionID` from `active?.backend`, plus router-emitted `.failed` (unchanged). Delete `routingBackend`/`routingSessionID`.

- [ ] **Step 4: Run — verify pass.** Full suite green.

- [ ] **Step 5: Commit**

```bash
git add Relay/SpeechOut/TTSRouter.swift RelayTests/SpeechOut/TTSRouterTests.swift
git commit -m "refactor(tts): collapse router routing/active state into one ActivePlayback"
```

**Acceptance:** pause/resume/stop always target the current playback for every backend; one session emits exactly one terminal event; `routingBackend`/`routingSessionID` are gone.

---

## Task 3: Enforce exactly-one terminal event in the audio players

**The bug:** `Relay/SpeechOut/SynthesizedAudioPlayer.swift:93` discards the Bool from `player.play()`; line 94 emits `.started` unconditionally; the delegate `audioPlayerDidFinishPlaying(_:successfully:)` at line ~234 ignores the `successfully` flag. If `AVAudioPlayer.play()` returns false or fails to start, no delegate fires, the continuation (line 97) never resumes, `speak()` hangs, and no terminal event is emitted. **Keep** the existing stale-late-callback guards `guard currentSessionID == sessionID, !didStopExplicitly` (line 121; `StreamingAudioPlayer.swift:307`) — do not regress them.

**Invariant:** once a session is accepted, exactly one of `finished | cancelled | failed` occurs.

**Files:**
- Modify: `Relay/SpeechOut/SynthesizedAudioPlayer.swift`
- Modify: `Relay/SpeechOut/StreamingAudioPlayer.swift` (ensure `engine.start()` throw path, line ~289, emits one terminal)
- Test: `RelayTests/SpeechOut/SynthesizedAudioPlayerTests.swift`, `RelayTests/SpeechOut/StreamingAudioPlayerTests.swift`

- [ ] **Step 1: Failing tests.**
  - `testPlayReturningFalseEmitsFailed`: inject a fake `AVAudioPlayer`-like seam whose `play()` returns false → expect exactly one `.failed`, and `speak()` resolves (does not hang).
  - `testDelegateSuccessfullyFalseEmitsFailed`.
  - `testDecodeErrorEmitsFailed`.
  - `testStaleLateCallbackAfterStopIsIgnored` (assert still ignored — no regression).
  - `testEngineStartThrowEmitsFailed` (StreamingAudioPlayer).

- [ ] **Step 2: Run — verify fail** (today play()==false hangs; `successfully` ignored).

- [ ] **Step 3: Implement.**
  - Treat `player.play() == false` as `.failed`; use the delegate `successfully` value (`false → .failed`); map decode/playback errors to `.failed`.
  - Funnel every terminal path (finish/cancel/fail) through one internal `complete(_ terminal:)` that: checks the stale-callback guard, emits the terminal event exactly once (idempotent — guard a `didComplete` flag), resumes the continuation once, and clears session state.
  - In `StreamingAudioPlayer`, route the `engine.start()` throw through the same single completion so a start failure yields `.failed`, not a hang.

- [ ] **Step 4: Run — verify pass.** Full suite green.

- [ ] **Step 5: Commit**

```bash
git add Relay/SpeechOut/SynthesizedAudioPlayer.swift Relay/SpeechOut/StreamingAudioPlayer.swift \
  RelayTests/SpeechOut/SynthesizedAudioPlayerTests.swift RelayTests/SpeechOut/StreamingAudioPlayerTests.swift
git commit -m "fix(tts): guarantee exactly one terminal event per accepted playback session"
```

**Acceptance:** `play()==false`, `successfully==false`, and decode/start errors all produce exactly one `.failed`; stale late callbacks stay ignored; no path hangs the awaiting caller.

---

## Task 4: Playback watchdog in `SpeechCoordinator`

**The bug:** `Relay/SpeechOut/SpeechCoordinator.swift` — a wedged in-flight session self-heals only when the next `.automatic` request arrives and finds it stale (`staleInFlightTimeout = 300`, line 49; checked only inside `speak()`, lines 96-106; `isInFlightSessionStale()`, lines 167-170, called nowhere else). `.userRequested` force-stops (lines 91-94). If no further request arrives, `isSpeaking == true` sticks forever.

**The fix:** an independent watchdog started when a session starts and cancelled on its terminal event; on expiry → stop backend, mark failed, clear state, continue the queue.

**Files:**
- Modify: `Relay/SpeechOut/SpeechCoordinator.swift`
- Test: `RelayTests/SpeechOut/SpeechCoordinatorWatchdogTests.swift` (create)

- [ ] **Step 1: Failing tests.**
  - `testWedgedSessionSelfHealsWithNoNewRequest`: start a session against a fake backend that never emits a terminal; advance an injected clock/short timeout → coordinator stops the backend, clears `isSpeaking`, drains the queue.
  - `testTerminalEventCancelsWatchdog`: normal finish → watchdog never fires (no spurious stop).
  - `testWatchdogDoesNotDoubleFire`.

- [ ] **Step 2: Run — verify fail** (no watchdog today).

- [ ] **Step 3: Implement.** Start the watchdog from the `speak()` call site when a session is accepted — **not** from a `.started` event (a streaming backend's `.started` timing/forwarding must not gate recovery). Launch a `Task` (or `Timer`) with `staleInFlightTimeout`; store its handle keyed by session. On any terminal event for that session, cancel the handle. On expiry: `router.stop()`, emit/record a privacy-safe `.failed`, set `isSpeaking = false`, and process the next queued request. Make the timeout injectable for tests. Keep the existing on-next-request check as a cheap backstop (or remove it if the watchdog fully subsumes it — prefer removing the duplicated recovery path per the "delete a state" guiding rule; document the choice).

- [ ] **Step 4: Run — verify pass.** Full suite green.

- [ ] **Step 5: Commit**

```bash
git add Relay/SpeechOut/SpeechCoordinator.swift RelayTests/SpeechOut/SpeechCoordinatorWatchdogTests.swift
git commit -m "fix(tts): add independent playback watchdog that self-heals a wedged session"
```

**Acceptance:** a wedged session recovers even if no new request arrives; terminal events cancel the watchdog; no double-fire.

---

## Task 5: Remove interim STT from the final-transcription critical path

**The bug:** `Relay/SpeechIn/DictationCoordinator.swift:182` — `finish()` awaits `stopStreamingTranscription()` *before* building the final-transcription pipeline (lines 184-189; final transcribe at line ~310). `stopStreamingTranscription` awaits `sampleAppendTask?.value` (line 288) then `await transcriber.stop()` (line 290). `Relay/Backends/StreamingTranscriber.swift:118-124` `stop()` cancels `tickTask` then `await tickTask?.value` — cancellation only stops *future* ticks; it blocks on an in-flight `transcribe(...)` of up to a ~15 s window (`maxWindowSamples = 15 * 16_000`, line ~69). Default `liveTranscriptionEnabled = true` (`Relay/Domain/AppSettings.swift:43,57,87`).

**Rule:** final dictation must NEVER wait for disposable interim work.

**The fix (do both):**
- (a) Change the default to `liveTranscriptionEnabled = false` until interim is fully isolated.
- (b) Make `finish()` start the final transcription immediately and let interim be truly fire-and-forget: do not `await` an in-flight interim inference; abandon it (cancel + detach, don't join). Ensure the shared FluidAudio Parakeet actor contention is handled without blocking the final path (e.g. the final transcription proceeds; the abandoned interim result is discarded on arrival via the existing session/stale guard).

**Files:**
- Modify: `Relay/Domain/AppSettings.swift:43,57,87` (default false)
- Modify: `Relay/SpeechIn/DictationCoordinator.swift:182-190` (don't await interim before final)
- Modify: `Relay/Backends/StreamingTranscriber.swift:118-124` (a non-joining `abandon()` alongside `stop()`)
- Test: `RelayTests/SpeechIn/DictationCoordinatorInterimTests.swift`

- [ ] **Step 1: Failing tests.**
  - `testFinalTranscriptionNotBlockedByInFlightInterim`: a fake interim transcriber whose in-flight inference takes a long time; assert the final transcribe starts without waiting for it (measure elapsed, or assert ordering with a fake clock).
  - `testDefaultLiveTranscriptionIsOff`: `AppSettings.defaults.liveTranscriptionEnabled == false`.

- [ ] **Step 2: Run — verify fail** (final currently waits; default is true).

- [ ] **Step 3: Implement.** Flip the default. In `finish()`, cancel interim (fire-and-forget) and immediately proceed to the final pipeline; do not join the interim task. Add `StreamingTranscriber.abandon()` that cancels without awaiting the in-flight call, and rely on the session/stale guard to drop any late interim output. If the shared Parakeet actor cannot run the final while an interim is still executing, document that the final waits only on the actor's *availability*, not on the interim's *result*, and add a test that a stale interim result never overwrites the final.

- [ ] **Step 4: Run — verify pass.** Full suite green.

- [ ] **Step 5: Commit**

```bash
git add Relay/Domain/AppSettings.swift Relay/SpeechIn/DictationCoordinator.swift \
  Relay/Backends/StreamingTranscriber.swift RelayTests/SpeechIn/DictationCoordinatorInterimTests.swift
git commit -m "fix(dictation): stop final transcription from waiting on disposable interim STT; default live interim off"
```

**Acceptance:** final transcription never blocks on an in-flight interim inference; live interim defaults off; a stale interim result never overwrites the authoritative final.

---

## Task 6: Fix Parakeet capability metadata

**The bug:** `Relay/Backends/ParakeetBackend.swift:47-50` advertises `STTCapabilities([.multilingual, .fullyOffline])` while `Relay/Backends/FluidAudioParakeetEngine.swift:28,39,53` uses English-only Parakeet `.v2`. The backend doc comment (lines ~42-43) also wrongly says "Parakeet TDT v3". (Matches the project rule: use FluidAudio v2 English, not v3.)

**Files:**
- Modify: `Relay/Backends/ParakeetBackend.swift:42-50`
- Test: `RelayTests/Backends/ParakeetBackendTests.swift`

- [ ] **Step 1: Failing test.**

```swift
func testCapabilitiesDoNotAdvertiseMultilingual() {
    let backend = ParakeetBackend(/* injected fake engine */)
    XCTAssertFalse(backend.capabilities.contains(.multilingual))
    XCTAssertTrue(backend.capabilities.contains(.fullyOffline))
}
```

- [ ] **Step 2: Run — verify fail.**

- [ ] **Step 3: Implement.** Remove `.multilingual` from `capabilities` (engine is English-only). Fix the doc comment "v3" → "v2 (English)".

- [ ] **Step 4: Run — verify pass.** Full suite green.

- [ ] **Step 5: Commit**

```bash
git add Relay/Backends/ParakeetBackend.swift RelayTests/Backends/ParakeetBackendTests.swift
git commit -m "fix(stt): Parakeet advertises English-only capabilities matching the v2 engine"
```

**Acceptance:** capabilities describe reality (no `.multilingual`); doc says v2.

---

## Task 7: Align minimum macOS with default STT (+ keep zero-download fallbacks)

**The bug:** `project.yml:3-4` deploymentTarget macOS 14.0. Default `sttBackendOrder = ["apple-speech"]` (`Relay/Domain/AppSettings.swift:83`; default `ttsBackendOrder` is line 82). `Relay/Backends/AppleSpeechBackend.swift:31-32` requires macOS 26 (`isMacOS26OrLater` → `.unsupportedOS`; `#available(macOS 26.0,*)` throughout). Because apple-speech is the *only* default entry, dictation fails outright on macOS 14–25; Parakeet exists but is not in the default order.

**Decision (choose ONE — tick the box):**
- [ ] **Option A (recommended, personal-use per audit §15):** set minimum macOS = 26 in `project.yml`. Apple Speech becomes a zero-download baseline; the default order can stay `["apple-speech"]` (optionally `["apple-speech", "parakeet"]`).
- [ ] **Option B (keep macOS 14 support):** leave deploymentTarget at 14 and change the default `sttBackendOrder` to include a backend that works there, e.g. `["apple-speech", "parakeet"]`, so on macOS 14–25 the router falls through Apple Speech's `.unsupportedOS` to Parakeet.

Also (audit §7.3): the default *TTS* order must keep Apple System Voice present as a zero-download fallback — never remove it. **Note the current default is `["pocket-tts", "apple-tts", "kokoro"]`** (`Relay/Domain/AppSettings.swift:83`): PocketTTS is primary, Apple is the middle reliable fallback, Kokoro last — by the earlier PocketTTS design decision. The requirement is that Apple TTS stays *present* in the default order, not that it is last. Do not reorder it to last.

**Files:**
- Modify (Option A): `project.yml:3-4`; (Option B): `Relay/Domain/AppSettings.swift:83`
- Modify (both): confirm default `ttsBackendOrder` still contains Apple TTS (present, middle, unchanged position)
- Test: `RelayTests/Domain/AppSettingsDefaultsTests.swift` and/or `RelayTests/SpeechIn/STTRouterFallbackTests.swift`

- [ ] **Step 1: Failing tests.**
  - `testDefaultSTTOrderProducesAWorkingBackendOnMinimumOS`: with a fake registry where `apple-speech` reports `.unsupportedOS`, the default order still yields a usable backend. (Passes trivially for Option A only if the min OS guarantees Apple Speech; for Option B it asserts Parakeet is the fallback.)
  - `testDefaultTTSOrderKeepsAppleAsFallback`: `AppSettings.defaults.ttsBackendOrder.contains("apple-tts")` — Apple present as a reliable fallback (currently middle: `["pocket-tts", "apple-tts", "kokoro"]`). Do NOT assert `.last`.

- [ ] **Step 2: Run — verify fail** for the chosen option.

- [ ] **Step 3: Implement** the chosen option; ensure Apple TTS stays present in the default TTS order at its current (middle) position — do NOT reorder it to last (that would demote it below Kokoro).

- [ ] **Step 4: Run — verify pass.** Full suite green. If Option A, confirm the project still builds after the deployment-target bump (`xcodegen generate` then build).

- [ ] **Step 5: Commit**

```bash
# Option A:
git add project.yml Relay/Domain/AppSettings.swift RelayTests/Domain/AppSettingsDefaultsTests.swift
git commit -m "fix(platform): raise minimum macOS to 26 so default Apple Speech STT works out of the box"
# Option B:
git add Relay/Domain/AppSettings.swift RelayTests/SpeechIn/STTRouterFallbackTests.swift RelayTests/Domain/AppSettingsDefaultsTests.swift
git commit -m "fix(platform): add Parakeet to default STT order so dictation works below macOS 26"
```

**Acceptance:** the default STT order yields a working backend on the declared minimum OS; Apple TTS remains present in the default TTS order as a reliable fallback (unchanged position).

---

## Execution

Recommended: **superpowers:subagent-driven-development** — fresh implementer per task, review between tasks, one commit per task. **Order:** Task 1 → Task 2 (Task 2 depends on Task 1's return-point change); Task 3 supports both and can land right after Task 1; Tasks 4–7 are independent. Run the full suite (`** TEST SUCCEEDED **`, zero warnings) before every commit. Never remove Apple TTS/Speech. Guiding rule: prefer deleting a state (e.g. the routing/active pair, the on-next-request recovery path) over adding another guard.
