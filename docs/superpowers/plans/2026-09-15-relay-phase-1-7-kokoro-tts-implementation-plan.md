# Relay Phase 1.7 — Kokoro TTS Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add FluidAudio Kokoro as an on-device neural TTS backend alongside Apple, with its own audio playback layer, model download, per-backend voice selection, a Test Voice control, and an Auto fallback to Apple.

**Architecture:** Kokoro synthesizes to WAV `Data` and does not play audio, so a new `SynthesizedAudioPlayer` (AVAudioEngine) plays it and emits the existing `TTSPlaybackEvent` values — including `.level` from an output tap, which makes the overlay pill's speaking waveform live (Apple's backend emits no level today). An engine seam mirrors the Parakeet pattern for testability. The existing `TTSRouter` already does ordered, availability-gated fallback, so the routing work is registering Kokoro and surfacing "model missing" as non-available. A TTS backend catalog mirrors the race-safe STT `SpeechBackendCatalog` for the settings UI.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI + AppKit, AVFoundation (AVAudioEngine), FluidAudio 0.12.6 (`KokoroTtsManager`, `TtsModels`, `TtsConstants`), XCTest, XcodeGen, macOS 14+.

**Spec:** `docs/superpowers/specs/2026-09-15-relay-settings-remodel-and-kokoro-tts-design.md`
**Prerequisite:** Phase 1.6 (settings tabs) is merged. The TTS tab is `Relay/App/Settings/TTSSettingsView.swift`.

---

## Ground rules for the implementer

- Work on `main` directly. No worktrees. Repo root `/Users/darius/Personal/relay`.
- Generate the project only via `xcodegen generate`. Never hand-edit `Relay.xcodeproj`. New files under `Relay/Backends/`, `Relay/SpeechOut/`, `Relay/App/` are auto-included by the recursive `sources: path: Relay` glob.
- TDD: write the failing test first, run it red, implement minimally, run it green, commit. One logical change per commit.
- Build/test:
  ```
  xcodegen generate
  xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -derivedDataPath .derived-data test
  ```
  Every build ends `** BUILD SUCCEEDED **` with zero warnings; the suite ends `** TEST SUCCEEDED **`.
- Commit trailers on every commit:
  ```
  Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01ACV8BiPqWH9ioEVQF8fouE
  ```
- **Privacy rule (hard):** never log, record in Diagnostics, or place in overlay state any spoken text, transcript, audio samples, file paths, or raw error strings. Diagnostics may record only a phase/category (mirror how the dictation and TTS paths already do it). Kokoro's own `logger.notice(...)` lines live inside FluidAudio, not our code; do not add any text-bearing logging in Relay.
- **Do not download at speak time.** Synthesis and playback must never trigger a model download. Downloads happen only from the explicit Settings "Download" action, exactly like Parakeet.
- **Mirror, do not reinvent.** Reuse the existing patterns:
  - Engine seam + single-flight + local-presence gate: `Relay/Backends/FluidAudioParakeetEngine.swift` and `Relay/Backends/ParakeetBackend.swift`.
  - Race-safe catalog + downloader + AppModel methods: `Relay/App/SpeechBackendCatalog.swift` (types `STTBackendStatus`, `STTBackendStatus.State`, protocol `SpeechModelDownloading`, `refreshSpeechBackendStatuses`, `downloadSpeechModel`, `canDownloadSpeechModel`, order/enable methods, `refreshGeneration`).
  - TTS backend contract and event forwarding: `Relay/SpeechOut/TextToSpeechBackend.swift`, `Relay/SpeechOut/AppleTTSBackend.swift`, `Relay/SpeechOut/TTSRouter.swift`.
  Read those files first.

## Key FluidAudio Kokoro API (version 0.12.6, verified in the checkout)

- `KokoroTtsManager(defaultVoice:defaultSpeakerId:directory:...)` — actor-like manager.
- `initialize(models: TtsModels, preloadVoices: Set<String>?) async throws` — initialize with already-downloaded models (use this after a presence check; it does not download).
- `initialize(preloadVoices:) async throws` — **downloads** if missing; do not use on the speak path.
- `synthesize(text:voice:voiceSpeed:speakerId:...) async throws -> Data` — returns a complete WAV (24 kHz mono). One call, no streaming.
- `isAvailable: Bool` — true after successful `initialize`.
- `TtsModels.download(variants:from:directory:progressHandler:) async throws -> TtsModels` — explicit download with a `ProgressHandler` (Double progress).
- `TtsModels.cacheDirectoryURL() throws -> URL` — the model cache location, for a network-free presence check.
- `TtsConstants.availableVoices: [String]` — voice ids. Use the American-English block for the picker: `af_*` and `am_*` (the first 20). `TtsConstants.recommendedVoice` is the default.

## File structure (end state)

- Create `Relay/Backends/KokoroTTSBackend.swift` — `KokoroTTSBackend: TextToSpeechBackend`, plus the `KokoroEngine` protocol and `KokoroEngineError`.
- Create `Relay/Backends/FluidAudioKokoroEngine.swift` — production `actor FluidAudioKokoroEngine: KokoroEngine`, plus `KokoroModelLoading` / `KokoroSynthesizing` seams and the FluidAudio wrapper.
- Create `Relay/SpeechOut/SynthesizedAudioPlayer.swift` — AVAudioEngine playback layer emitting `TTSPlaybackEvent`.
- Create `Relay/App/TTSBackendCatalog.swift` — `TTSBackendStatus`, its `State`, `TTSModelDownloading` protocol (or reuse `SpeechModelDownloading` if identical), and the AppModel extension methods for TTS backends. Mirror `SpeechBackendCatalog.swift`.
- Modify `Relay/Domain/AppSettings.swift` — add `kokoroVoice: String?` (Codable, default nil). `ttsBackendOrder` already exists (default `["apple-tts"]`).
- Modify `Relay/App/AppModel.swift` — build and register the Kokoro backend into the `TTSRouter` backends dict and into a TTS registry/downloaders map; add `ttsBackends` observable state and a `kokoroVoice` setter; feed the download progress.
- Modify `Relay/App/Settings/TTSSettingsView.swift` — rebuild as backend list + per-backend voice picker + Test Voice + rate.
- Tests: `RelayTests/Backends/KokoroTTSBackendTests.swift`, `RelayTests/Backends/FluidAudioKokoroEngineTests.swift`, `RelayTests/SpeechOut/SynthesizedAudioPlayerTests.swift`, `RelayTests/App/TTSBackendCatalogTests.swift`, plus additions to `RelayTests/App/AppModelTests.swift`.

---

## Task 1: Kokoro engine seam and production engine

Mirror `FluidAudioParakeetEngine`: a protocol seam with a fake for tests, a network-free local-presence gate, an explicit download path with progress, and single-flight loads keyed by whether a download is allowed. Kokoro is English-capable; there is no v2/v3 choice here.

**Files:**
- Create: `Relay/Backends/FluidAudioKokoroEngine.swift`
- Test: `RelayTests/Backends/FluidAudioKokoroEngineTests.swift`

- [ ] **Step 1: Define the seams.**

```swift
protocol KokoroModelSession: Sendable {
    func synthesize(text: String, voice: String, speed: Float) async throws -> Data
}

protocol KokoroModelLoading: Sendable {
    /// Network-free: true only if a valid model is already on disk.
    func modelsArePresent() async -> Bool
    /// Loads an already-present model. Must NOT download.
    func loadLocal() async throws -> any KokoroModelSession
    /// Explicit download + load.
    func downloadAndLoad(progress: @escaping @Sendable (Double) -> Void) async throws -> any KokoroModelSession
}

protocol KokoroEngine: Sendable {
    func modelsArePresent() async -> Bool
    func load(allowDownload: Bool, progress: @escaping @Sendable (Double) -> Void) async throws
    func synthesize(text: String, voice: String, speed: Float) async throws -> Data
}

enum KokoroEngineError: Error, Equatable {
    case modelsNotDownloaded
    case loadFailed
    case synthesisFailed
}
```

- [ ] **Step 2: Write failing tests** in `FluidAudioKokoroEngineTests.swift` against a fake `KokoroModelLoading`, mirroring the Parakeet engine tests: `load(allowDownload:false)` with no model throws `.modelsNotDownloaded` and never calls download; `load(allowDownload:true)` downloads then synth works; concurrent loads single-flight; a load failure does not cache a false "present"; synthesize before load throws. Run red.

- [ ] **Step 3: Implement `actor FluidAudioKokoroEngine: KokoroEngine`** mirroring `FluidAudioParakeetEngine` (single-flight keyed by `localOnly`/`download`, `validatedModelsPresent` cleared on failure, `awaitAndClear`/`clearIfCurrent`). The production `KokoroModelLoading` wraps FluidAudio: `modelsArePresent()` checks `TtsModels.cacheDirectoryURL()` for the model files without downloading; `loadLocal()` constructs `KokoroTtsManager(...)` and calls `initialize(models:)` with models loaded from the cache directory (never the downloading `initialize(preloadVoices:)`); `downloadAndLoad` calls `TtsModels.download(directory:progressHandler:)` then `initialize(models:)`. The `KokoroModelSession` wrapper calls `manager.synthesize(text:voice:voiceSpeed:)`.

- [ ] **Step 4: Run tests green.**

- [ ] **Step 5: Commit** `feat(tts): add Kokoro engine seam and FluidAudio engine`.

---

## Task 2: SynthesizedAudioPlayer (AVAudioEngine playback + events)

The one genuinely new capability. Plays WAV `Data` and emits `TTSPlaybackEvent`.

**Files:**
- Create: `Relay/SpeechOut/SynthesizedAudioPlayer.swift`
- Test: `RelayTests/SpeechOut/SynthesizedAudioPlayerTests.swift`

- [ ] **Step 1: Define the type.**

```swift
@MainActor
final class SynthesizedAudioPlayer {
    /// Emits lifecycle + level events for one playback. Level values are RMS-based,
    /// clamped to 0...1, matching the dictation MicrophoneLevelMeter cadence so the
    /// pill's speaking waveform behaves consistently.
    var onEvent: (@MainActor (TTSPlaybackEvent) -> Void)?

    /// Decodes `wav` and plays it. Emits .scheduled immediately, .started on the
    /// first rendered buffer, .level from an output tap, and .finished on natural end.
    func play(_ wav: Data, sessionID: UUID) async throws
    func stop()      // emits .cancelled if playing
    func pause()
    func resume()
}
```

- [ ] **Step 2: Decode.** Write the WAV `Data` to a temp file (in `FileManager.default.temporaryDirectory`, deleted after load — never a user path, never logged), open with `AVAudioFile`, read into an `AVAudioPCMBuffer` at the file's own processing format (24 kHz mono). Do not assume it matches the engine output format.

- [ ] **Step 3: Play.** Use `AVAudioEngine` + `AVAudioPlayerNode`. Connect the node to `mainMixerNode` using the buffer's format; the engine handles rate conversion to the output. `scheduleBuffer(...)` with a completion handler that emits `.finished` on the MainActor. Start the engine, emit `.scheduled` then `.started`, play.

- [ ] **Step 4: Level tap.** `installTap(onBus:0,...)` on the player node or main mixer; compute RMS per buffer, clamp to 0...1 (reuse the same RMS→level scaling as `MicrophoneLevelMeter`). **The tap fires off the main thread — hop to the MainActor before calling `onEvent(.level(...))`** (Swift 6). Remove the tap on stop/finish.

- [ ] **Step 5: stop/pause/resume.** `stop()` stops the node + engine, removes the tap, emits `.cancelled`. `pause()`/`resume()` on the node.

- [ ] **Step 6: Tests.** Because AVAudioEngine on a headless test host is unreliable, keep tests to what is deterministic: a tiny synthesized WAV `Data` (generate a fraction-of-a-second sine as bytes in the test) decodes without throwing; `play` emits `.scheduled` then `.started` then eventually `.finished`; `stop()` mid-play emits `.cancelled`; events carry the passed `sessionID`; a malformed `Data` throws (mapped by the backend to `.failed`). Use bounded `waitUntil`/expectations, never unbounded spins. If engine start is not viable in CI, gate the audio-producing assertions behind a capability check and still assert the decode + event-contract paths that do not require a running output device.

- [ ] **Step 7: Commit** `feat(tts): add AVAudioEngine playback layer for synthesized speech`.

---

## Task 3: KokoroTTSBackend

Ties the engine and player into the `TextToSpeechBackend` contract.

**Files:**
- Create: `Relay/Backends/KokoroTTSBackend.swift`
- Test: `RelayTests/Backends/KokoroTTSBackendTests.swift`

- [ ] **Step 1: Failing tests** against a fake `KokoroEngine` and a fake player: `id == "kokoro"`, `displayName == "Kokoro"`, capabilities include fully-offline + neural; `availability()` returns `.available` when the engine reports models present, `.modelNotDownloaded` when not, `.failed`/`.unavailable` on load error; `speak` calls engine `synthesize` (lazy `load(allowDownload:false)` first, like ParakeetBackend's lazy prepare) then hands the WAV to the player and forwards its events with the same `sessionID`; empty text does not crash; a synthesis error surfaces as a fallback-worthy `SpeechBackendError`. Run red.

- [ ] **Step 2: Implement `@MainActor final class KokoroTTSBackend: TextToSpeechBackend`.** `setPlaybackEventHandler` stores the handler; wire the player's `onEvent` to it. `availability()` maps engine presence to `BackendAvailability` the same way `ParakeetBackend` maps its states (`.available` / `.modelNotDownloaded` / `.failed`). `speak(text:options:sessionID:)`: ensure loaded (`load(allowDownload:false)`, throwing `modelNotDownloaded` → a fallback-worthy `SpeechBackendError` so the router falls back to Apple), read the voice from `options` (add a `voiceIdentifier`-style field or reuse the existing `TTSOptions.voiceIdentifier`) or the backend's configured `kokoroVoice`, call `engine.synthesize`, then `await player.play(wav, sessionID:)`. Map errors to `SpeechBackendError` with `isFallbackWorthy == true` for load/model issues.

- [ ] **Step 3: Green. Step 4: Commit** `feat(tts): add Kokoro TTS backend`.

---

## Task 4: Register Kokoro in AppModel and settings model

**Files:**
- Modify: `Relay/Domain/AppSettings.swift` (add `kokoroVoice`), `Relay/App/AppModel.swift`
- Test: additions to `RelayTests/App/AppModelTests.swift`

- [ ] **Step 1: `AppSettings`.** Add `var kokoroVoice: String?`, wire it through `init`, `Codable` (`decodeIfPresent`, default nil), and the memberwise/default builders. Test: round-trips through encode/decode; default nil. `ttsBackendOrder` already exists (default `["apple-tts"]`); do not re-add it.

- [ ] **Step 2: AppModel.** Build `let kokoroTTS = KokoroTTSBackend(...)`. Add it to the `TTSRouter` backends dict: `[appleTTS.id: appleTTS, kokoroTTS.id: kokoroTTS]`. The router's `backendOrder` already reads `state.value.ttsBackendOrder`, so Auto ordering is data-driven — no router code change. Add a TTS registry `[String: any TextToSpeechBackend]` and a TTS downloaders map for the catalog (Task 5), mirroring `sttRegistry`/`speechModelDownloaders`. Add a `setKokoroVoice(_:)` setter using the existing private `updateSettings` path. Keep the default order `["apple-tts"]` so behavior is unchanged until the user enables Kokoro.

- [ ] **Step 3:** Tests — router is constructed with both backends; enabling Kokoro first in order routes to Kokoro when available and falls back to Apple when Kokoro reports model-missing (use fakes, mirror `STTRouter` fallback tests). Green. Commit `feat(tts): register Kokoro backend and kokoroVoice setting`.

---

## Task 5: TTS backend catalog (settings status, download, order)

Mirror `SpeechBackendCatalog.swift` exactly, for TTS.

**Files:**
- Create: `Relay/App/TTSBackendCatalog.swift`
- Test: `RelayTests/App/TTSBackendCatalogTests.swift`

- [ ] **Step 1:** Define `TTSBackendStatus` (Identifiable, Equatable, Sendable) with the same `State` cases as `STTBackendStatus.State` (`ready`, `modelNotDownloaded`, `downloading(progress:)`, `downloadFailed`, `unsupported`, `unavailable`). Apple is always `.ready` (no download). Reuse the `SpeechModelDownloading` protocol if its shape fits; otherwise add a parallel `TTSModelDownloading`.

- [ ] **Step 2:** Add the AppModel extension methods, copied structurally from the STT ones with the race-safety already in place: `refreshTTSBackendStatuses()` (sample downloading/order state only at the merge-and-assign step, guarded by a `ttsRefreshGeneration` counter), `downloadTTSModel(_:)` (progress guarded monotonic + membership; `.downloadFailed` on error; flag+state written together), `canDownloadTTSModel(_:)`, `setTTSBackendEnabled(_:_:)`, `moveTTSBackend(_:up:)`, `knownTTSBackendOrder()`, `ttsBackendMessage`. Add `@Published`/observable `ttsBackends: [TTSBackendStatus]` and `downloadingTTSBackendIDs`.

- [ ] **Step 3:** Tests — port the STT catalog race tests: concurrent refresh during a download does not clobber downloading state; late/out-of-order progress ignored; retry after failure; unknown ids filtered; missing row inserted; message set on refusal and cleared. Use bounded waits. Green. Commit `feat(tts): add race-safe TTS backend catalog`.

---

## Task 6: Rebuild the TTS settings tab

**Files:**
- Modify: `Relay/App/Settings/TTSSettingsView.swift`
- Test: extend `RelayTests/App/SettingsViewsSmokeTests.swift`

- [ ] **Step 1:** Rebuild `TTSSettingsView` with:
  - A backend list (mirror `DictationSettingsView`'s Speech Recognition rows): enable toggle, up/down order, per-backend status label, and a Download button/progress for Kokoro gated on `canDownloadTTSModel`. Apple shows "Ready", no download. `ttsBackendMessage` shown like `speechBackendMessage`.
  - A Voice picker whose contents depend on the selected/primary backend: for Apple, the existing `AVSpeechSynthesisVoice` list bound to `ttsVoiceIdentifier`; for Kokoro, the American-English `TtsConstants.availableVoices` (`af_*`, `am_*`) bound to `kokoroVoice`. Show the picker for whichever backend is enabled/primary, or show both labeled.
  - The existing rate slider (unchanged).
  - A **Test Voice** button that speaks a fixed sample sentence through the current selection. Add an AppModel method `testVoice()` that routes a sample string through the `TTSRouter` (or the selected backend) with the current options; the button calls it. The sample text is a constant in code, not user content.
  - `.formStyle(.grouped)` to match the other tabs.

- [ ] **Step 2:** Add `.task { await model.refreshTTSBackendStatuses() }` so status refreshes when the tab appears (mirror the container's STT refresh).

- [ ] **Step 3:** Extend the smoke test to still construct `TTSSettingsView(model:)`. Green. Commit `feat(tts): rebuild TTS settings tab with backend, voice, and test controls`.

---

## Task 7: Wire Kokoro model download progress into the catalog

**Files:**
- Modify: `Relay/App/AppModel.swift`
- Test: `RelayTests/App/AppModelTests.swift`

- [ ] **Step 1:** Provide a `TTSModelDownloading` implementation for Kokoro that calls `TtsModels.download(directory:progressHandler:)` and reports progress into `downloadTTSModel`, mirroring the Parakeet downloader registration in `speechModelDownloaders`. Register it in the TTS downloaders map. Apple registers none (not downloadable).

- [ ] **Step 2:** Test that `downloadTTSModel("kokoro")` drives the row to `.downloading` then `.ready` on success and `.downloadFailed` on error, using a fake downloader. Green. Commit `feat(tts): wire Kokoro model download into the TTS catalog`.

---

## Acceptance (final check, done by the orchestrator/main session)

- [ ] `xcodegen generate`; clean build, zero warnings; full suite passes (previous count + the new tests).
- [ ] `codesign --verify --deep --strict .derived-data/Build/Products/Debug/Relay.app` passes.
- [ ] Manual, in the running app:
  - Settings → TTS shows Kokoro and Apple. Kokoro shows "Model not downloaded" with a Download button; Apple shows "Ready".
  - Click Download for Kokoro; progress advances to Ready. (~one-time model download.)
  - Enable Kokoro above Apple. Pick a Kokoro voice (e.g. `af_heart`).
  - Test Voice speaks in the Kokoro voice. The overlay pill shows "Kokoro" and a live speaking waveform (not the phased curve).
  - Read Selection uses Kokoro; with Kokoro disabled or its model removed, it falls back to Apple and the pill shows "Apple System Voice".
- [ ] `git diff --check` clean. No transcript/text/audio/path/error strings added to any log, Diagnostics, or overlay state (grep the diff for new logging).

## Notes for the implementer

- The router needs no new fallback logic; if you find yourself editing `TTSRouter.speak`, stop — the work is registration + availability, not routing.
- Apple TTS emits no `.level` today, so the pill uses the phased curve for it; Kokoro is the first backend to emit `.level`. Confirm `SpeechCoordinator` already forwards `.level` to the overlay model (it does for the general TTS path); if a Kokoro `.level` is not reaching the pill, the gap is in the coordinator forwarding, not the backend.
- If the AVAudioEngine playback cannot be exercised in the test host, keep the audio assertions capability-gated but never skip the event-contract and decode tests. Flag this in your report so the orchestrator covers playback in the manual pass.
- Keep every commit building and the suite green.
