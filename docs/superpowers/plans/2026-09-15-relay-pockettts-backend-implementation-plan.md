# Relay — PocketTTS Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Add FluidAudio PocketTTS as a second on-device neural TTS backend, mirroring the existing Kokoro backend. Make PocketTTS the default primary TTS, Apple the reliable middle fallback, and Kokoro the last (demoted, kept — do NOT remove it).

**Why:** Kokoro (FluidAudio 0.12.6, beta) produces unstable output — it zero-pads short text to a fixed model window and synthesizes the padding as breathing, or truncates multi-chunk text. PocketTTS uses a different pipeline that generates until an end-of-speech token (`PocketTtsConstants.eosThreshold`, only `shortTextPadFrames = 3`), so it should not have the fixed-window padding artifact. It outputs 24 kHz WAV, so the existing `SynthesizedAudioPlayer` (AVAudioPlayer-based) plays it unchanged.

**Architecture:** Exactly mirror the Kokoro backend: an engine seam (`PocketTTSEngine` / `PocketTTSModelLoading` / `PocketTTSModelSession`) wrapping FluidAudio's `PocketTtsManager` + `PocketTtsResourceDownloader`, a `PocketTTSBackend: TextToSpeechBackend` that synthesizes to WAV `Data` and plays it via `SynthesizedAudioPlayer`, registration in `AppModel`, and the existing race-safe `TTSBackendCatalog` (which enumerates the TTS registry, so PocketTTS appears in the TTS tab automatically). No TTSRouter change.

**Tech Stack:** Swift 6 strict concurrency, SwiftUI + AppKit, AVFoundation, FluidAudio 0.12.6, XCTest, XcodeGen.

**Templates to mirror (read these first):** `Relay/Backends/KokoroTTSBackend.swift`, `Relay/Backends/FluidAudioKokoroEngine.swift`, `RelayTests/Backends/KokoroTTSBackendTests.swift`, `RelayTests/Backends/FluidAudioKokoroEngineTests.swift`, and how `AppModel` registers the Kokoro backend/downloader.

---

## Ground rules
- Work on `main`. No worktrees. **Run implementers one at a time — do not let two agents commit to this tree concurrently.**
- Generate the project only via `xcodegen generate`. Never hand-edit `Relay.xcodeproj`.
- TDD each task; build zero warnings; suite `** TEST SUCCEEDED **`.
- **No commit trailers.** Plain messages.
- Privacy: no spoken text, transcript, audio, paths, or raw error strings in logs/Diagnostics/overlay.
- **Do not download at speak time.** Presence-gate exactly like Kokoro; the presence gate is the only guard against FluidAudio re-downloading on missing files.
- **Do NOT remove or break the Kokoro backend.** It stays registered, demoted in the default order.
- Reuse `SynthesizedAudioPlayer` unchanged for playback.

## FluidAudio PocketTTS API (0.12.6, verified in the checkout)
- `PocketTtsManager(defaultVoice: PocketTtsConstants.defaultVoice /* "alba" */)`.
- `initialize() async throws` — downloads all models if missing (via `PocketTtsResourceDownloader.ensureModels`), then loads. Safe (no-op download) when models already present, but treat it as download-capable: only call it on the download path or after a presence check.
- `synthesize(text:voice:...) async throws -> Data` — 24 kHz WAV. `voice` is `String?` (nil → default "alba").
- `isAvailable: Bool`.
- `PocketTtsResourceDownloader.ensureModels(directory:progressHandler:) async throws -> URL` — explicit download with progress; downloads the `.pocketTts` repo into `<cacheDir>/Models/<PocketTtsConstants.defaultModelsSubdirectory>`.
- `PocketTtsModelStore(directory:)` with `loadIfNeeded()`, `repoDir()`, and typed model accessors (`condStep`, `flowlmStep`, `flowDecoder`, `mimiDecoder`); `isMimiEncoderAvailable()` uses `FileManager.fileExists`. Use the model files under `repoDir()` for the presence check.
- Voices: only `"alba"` is a documented built-in voice; cloning exists but is OUT OF SCOPE. The PocketTTS voice picker may be a single "alba" entry (or whatever built-in voice ids `PocketTtsConstants` exposes — check for a voices list; if none, use `["alba"]`).

---

## Task 1: PocketTTS engine seam + production engine
**Files:** Create `Relay/Backends/FluidAudioPocketTTSEngine.swift`; Test `RelayTests/Backends/FluidAudioPocketTTSEngineTests.swift`.

- [ ] **Step 1: Seams** mirroring the Kokoro seam:
  ```swift
  protocol PocketTTSModelSession: Sendable {
      func synthesize(text: String, voice: String) async throws -> Data
  }
  protocol PocketTTSModelLoading: Sendable {
      func modelsArePresent() async -> Bool
      func loadLocal() async throws -> any PocketTTSModelSession
      func downloadAndLoad(progress: @escaping @Sendable (Double) -> Void) async throws -> any PocketTTSModelSession
  }
  protocol PocketTTSEngine: Sendable {
      func modelsArePresent() async -> Bool
      func load(allowDownload: Bool, progress: @escaping @Sendable (Double) -> Void) async throws
      func synthesize(text: String, voice: String) async throws -> Data
  }
  enum PocketTTSEngineError: Error, Equatable { case modelsNotDownloaded, loadFailed, synthesisFailed }
  ```
  Note: PocketTTS synthesize takes no speed parameter (it has no `voiceSpeed`); do not add one. The shared rate slider does not apply to PocketTTS — ignore `options.rate` for this backend.

- [ ] **Step 2: Failing tests** against a fake loader (mirror the Kokoro engine tests): `load(allowDownload:false)` with no model throws `.modelsNotDownloaded` and never downloads; download path loads then synth works; concurrent loads single-flight; load failure clears any cached "present"; synth before load throws.

- [ ] **Step 3: Implement `actor FluidAudioPocketTTSEngine: PocketTTSEngine`** mirroring `FluidAudioParakeetEngine`/`FluidAudioKokoroEngine` (single-flight keyed by localOnly/download, `validatedModelsPresent` cleared on failure, `awaitAndClear`/`clearIfCurrent`). Production `PocketTTSModelLoading`:
  - `modelsArePresent()`: hand-rolled `FileManager` check that the PocketTTS model bundles exist under `PocketTtsModelStore(directory:).repoDir()` (do NOT rely on any auto-creating cache-dir accessor). Return true only if the required model files are present.
  - `loadLocal()`: gated strictly behind the presence check — construct `PocketTtsManager()` and call `initialize()` (which is a no-op download when files are present); never call `initialize()` when absent.
  - `downloadAndLoad(progress:)`: call `PocketTtsResourceDownloader.ensureModels(progressHandler:)` then `PocketTtsManager().initialize()`.
  - `PocketTTSModelSession.synthesize` calls `manager.synthesize(text:voice:)`.

- [ ] **Step 4: Presence regression test** (like Kokoro's): `modelsArePresent()` returns false when only the bare cache dir exists but the model files do not.

- [ ] **Step 5: Green. Commit** `feat(tts): add PocketTTS engine seam and FluidAudio engine`.

## Task 2: PocketTTSBackend
**Files:** Create `Relay/Backends/PocketTTSBackend.swift`; Test `RelayTests/Backends/PocketTTSBackendTests.swift`.

- [ ] Mirror `KokoroTTSBackend` exactly, minus the speed mapping:
  - id `"pocket-tts"`, displayName `"PocketTTS"`, capabilities `[.fullyOffline, .voiceSelection, .outputLevel]` (PocketTTS has no pause/resume speed control — include `.pauseResume` only if the player supports it, which it does via AVAudioPlayer, so keep `.pauseResume` too).
  - `availability()` maps `modelsArePresent()` to `.available` / `.modelNotDownloaded`.
  - `speak`: lazy `load(allowDownload:false)` (model-missing → fallback-worthy `SpeechBackendError`, so the router falls back); voice = `options.kokoroVoice`-equivalent — PocketTTS needs its own voice field, see Task 3; for now read a PocketTTS voice from options (Task 3 adds `pocketVoice`) or default `PocketTtsConstants.defaultVoice`. Ignore `options.rate`. Then `player.play(wav, sessionID:)`.
  - Do NOT emit `.failed` from the backend (router owns it), matching the Kokoro fix.
  - Reuse `SynthesizedAudioPlayer` via the `SynthesizedAudioPlaying` seam.
  - Conform to `SpeechModelDownloading` with `downloadModels(progress:)` → `engine.load(allowDownload:true, progress:)`, like Kokoro.
- [ ] Tests mirror `KokoroTTSBackendTests`. Green. Commit `feat(tts): add PocketTTS backend`.

## Task 3: Settings model — PocketTTS voice + register + reorder default
**Files:** `Relay/Domain/SpeechModels.swift` (TTSOptions), `Relay/Domain/AppSettings.swift`, `Relay/App/AppModel.swift`; Test `RelayTests/App/AppModelTests.swift`.

- [ ] Add `var pocketVoice: String?` to `TTSOptions` and to `AppSettings` (Codable, default nil), and populate it in the AppModel `SpeechCoordinator` options closure alongside `kokoroVoice`. `PocketTTSBackend.speak` reads `options.pocketVoice ?? PocketTtsConstants.defaultVoice`.
- [ ] Register `PocketTTSBackend()` in the `TTSRouter` backends dict and the TTS registry + downloaders map, alongside Kokoro and Apple.
- [ ] Change the default `ttsBackendOrder` to `["pocket-tts", "apple-tts", "kokoro"]` (PocketTTS primary, Apple reliable fallback, Kokoro demoted last, kept). Note: existing users have a persisted order that will not change automatically — that is fine; they reorder in the TTS tab. Do NOT write migration logic unless trivial.
- [ ] Add a `setPocketVoice(_:)` setter mirroring `setKokoroVoice`.
- [ ] Tests: router constructed with all three backends; PocketTTS routes first when available and falls back to Apple when its model is missing; options closure carries `pocketVoice`. Green. Commit `feat(tts): register PocketTTS as primary and demote Kokoro in the order`.

## Task 4: TTS tab — PocketTTS voice picker
**Files:** `Relay/App/Settings/TTSSettingsView.swift`; extend the smoke test.

- [ ] The TTS tab already lists all registry backends via the catalog, so PocketTTS appears automatically with enable/order/download. Add a Voice picker for PocketTTS bound to `pocketVoice`: use the PocketTTS built-in voice list if one exists in `PocketTtsConstants`; otherwise a single `"alba"` entry. Keep the existing Kokoro and Apple voice pickers. Test Voice already routes through the primary backend.
- [ ] Keep the smoke test green. Commit `feat(tts): add PocketTTS voice control to the TTS tab`.

## Task 5: Wire PocketTTS download
**Files:** `Relay/App/AppModel.swift`; Test.

- [ ] Provide a `SpeechModelDownloading` for PocketTTS (the backend already conforms) registered in the TTS downloaders map, so the TTS catalog's Download button drives `PocketTtsResourceDownloader.ensureModels` with progress → `.downloading` → `.ready` / `.downloadFailed`. Test with a fake. Commit `feat(tts): wire PocketTTS model download into the catalog`.

## Acceptance (final check — orchestrator)
- [ ] Clean build zero warnings; full suite passes.
- [ ] `codesign --verify` passes.
- [ ] Manual: TTS tab shows PocketTTS, Apple, Kokoro. Download PocketTTS. Enable it primary. Test Voice speaks the full sample sentence cleanly (no breathing, no truncation), pill shows "PocketTTS" with a live waveform. Kokoro remains present, demoted.
- [ ] No transcript/text/audio/path/error strings added to any log/Diagnostics/overlay.

## Notes
- If PocketTTS also produces bad audio (it is also beta), that is an upstream limitation to report — but its eos-based generation makes the Kokoro padding artifact unlikely.
- Reuse everything already built: `SynthesizedAudioPlayer`, `TTSBackendCatalog`, the catalog UI. This is additive; touch the router not at all.
