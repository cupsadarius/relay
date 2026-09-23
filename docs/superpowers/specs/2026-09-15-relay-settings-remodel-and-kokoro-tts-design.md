# Relay Phases 1.6 & 1.7 — Settings Remodel and Kokoro TTS

> **Historical — superseded.** Playback (`SynthesizedAudioPlayer`) was replaced by the
> `TTSAudioSource` + shared `StreamingAudioPlayer` pipeline in the
> [Unified TTS Migration Design](2026-09-19-relay-unified-tts-migration-design.md), and settings /
> model management by the [Unified Speech Model Settings Design](2026-09-21-unified-speech-model-settings-design.md).
> For the current architecture see the [README architecture section](../../../README.md#architecture).

Date: 2026-09-15
Status: Approved (design)
Depends on: Phase 1.5 (Activity Overlay), Parakeet STT backend (committed `fdfda0d`)

This document covers two related phases:

- **Phase 1.6 — Settings remodel.** Restructure the single settings pane into four toolbar tabs. Pure UI reorganization; no behavior change.
- **Phase 1.7 — Kokoro TTS backend.** Add FluidAudio Kokoro as a neural, on-device text-to-speech backend, with per-backend voice selection, a test-voice control, model download, and an Auto fallback to Apple.

Phase 1.6 ships first (its own implementation plan). Phase 1.7 follows and builds inside the finished TTS tab.

---

## Motivation

The settings pane is one growing `Form` in `Relay/App/SettingsView.swift`. As of Phase 1.5 it stacks Speech (TTS voice + rate), Dictation mode, Speech Recognition backends, Activity Overlay style, Permissions, and Global Hotkeys in a single scroll. It is crowded and the file is large.

Relay already ships FluidAudio for Parakeet STT. The pinned version (0.12.6) also contains `KokoroTtsManager`, a Core ML neural TTS engine that runs fully on-device. Apple's system voice is the only current TTS backend; Kokoro is the most sensible next one because it needs no new dependency, no network at speak time, and produces more natural speech than the default system voices. It supports about 20 American-English voices and pronunciation overrides.

---

## Phase 1.6 — Settings Remodel

### Goal

Replace the single settings `Form` with a native macOS toolbar-tab container (`TabView` whose tabs carry `.tabItem { Label(...) }`, giving the standard Preferences toolbar-tab appearance). Four tabs, backends split by direction.

### Tabs

| Tab | Contents (moved verbatim from today's settings) |
|---|---|
| **Keybinds** | Global Hotkeys: Dictate, Read Selection, Stop Speech, Replay Last, Toggle Auto-read. Each keeps its shortcut recorder and Double-Tap option. The existing hotkey-conflict message. |
| **Dictation** | Mode picker (Toggle/Hold). Speech Recognition backends (Parakeet, Apple Speech) with enable, order, download, and status — the current `SpeechBackendCatalog`-driven section unchanged. Activity Overlay style (Off/Minimal/Interactive). |
| **TTS** | Voice picker and speech-rate slider, unchanged for Phase 1.6. Phase 1.7 rebuilds this tab. |
| **Security & Permissions** | Microphone and Accessibility permission rows, with their request/open-settings actions. |

Rationale for placement: Speech Recognition is dictation input, so it lives under Dictation. Voice backends are output, so they live under TTS. Activity Overlay is a dictation-session visual, so it sits under Dictation.

### Components

Split `SettingsView` into focused view files, each taking `@Bindable var model: AppModel`:

- `Relay/App/Settings/SettingsView.swift` — the tab container only.
- `Relay/App/Settings/KeybindsSettingsView.swift`
- `Relay/App/Settings/DictationSettingsView.swift`
- `Relay/App/Settings/TTSSettingsView.swift`
- `Relay/App/Settings/PermissionsSettingsView.swift`

Shared row helpers (`permissionRow`, `speechBackendRow`, bindings) move next to the view that uses them, or into a small `SettingsControls.swift` if shared by more than one tab. Existing bindings and `AppModel` API do not change.

### Constraints

- No behavior change. Every control keeps its current binding, label, and action.
- No change to `AppModel`, settings persistence, or any backend.
- The settings window still opens from the menu bar and from `WindowFocusCoordinator` exactly as now.

### Testing

- A build-smoke test per tab view (each view constructs against a test `AppModel`).
- Existing `AppModelTests` binding tests stay green.

---

## Phase 1.7 — Kokoro TTS Backend

### Goal

Add Kokoro as a selectable, on-device TTS backend alongside Apple. Rebuild the TTS tab to offer a backend list (with Auto fallback), a per-backend voice picker, a Test Voice control, and a Kokoro model download. The Activity Overlay pill already shows the active backend name and a live waveform; Kokoro must feed both.

### Key integration fact

`KokoroTtsManager.synthesize(text:voice:...)` returns WAV `Data`. It does not play audio. Apple's backend gets playback for free from `AVSpeechSynthesizer`; the Kokoro backend must supply its own playback layer. This is the main new surface.

FluidAudio Kokoro API (version 0.12.6, confirmed in the checkout):
- `KokoroTtsManager.init(...)`, `initialize(preloadVoices:)`, `isAvailable`.
- `synthesize(text:voice:voiceSpeed:speakerId:...) async throws -> Data` (WAV).
- `setDefaultVoice(_:speakerId:)`, `setCustomLexicon(_:)` for pronunciation overrides.
- `TtsConstants.availableVoices: [String]` — the American-English voice list.
- `TtsModels.download(...)` for the model; `TtsModels.cacheDirectoryURL()` for the presence check.
- FluidAudio marks this TTS path beta.

### Components

1. **Engine seam.** `KokoroEngine` protocol plus `KokoroModelLoading` / `KokoroSynthesizing`, wrapping `KokoroTtsManager`, `TtsModels.download`, and `TtsModels.cacheDirectoryURL`. Production type `FluidAudioKokoroEngine` (actor), fakeable in tests. Mirrors `FluidAudioParakeetEngine`: local-presence check that never triggers a download, explicit download path with progress, single-flight loads.

2. **Playback layer.** `SynthesizedAudioPlayer` (AVAudioEngine) plays the WAV `Data` and emits the existing `TTSPlaybackEvent` values:
   - `.scheduled` on enqueue,
   - `.started` on the first rendered sample,
   - `.level` from an output tap, driving the pill's live speaking waveform,
   - `.finished` on natural end, `.cancelled` on stop, `.failed` on error.
   Supports `stop`, `pause`, `resume` to satisfy `TextToSpeechBackend`.

   Audio format: Kokoro's WAV is 24 kHz mono, which need not match the engine's output format. Decode the WAV `Data` at its source format (via `AVAudioFile` / `AVAudioPCMBuffer`) and let the engine or an `AVAudioConverter` handle sample-rate conversion; do not assume the buffer is directly schedulable at the output format.

   Concurrency: `TextToSpeechBackend` is `@MainActor`, but `installTap` callbacks fire off the main thread. `.level` emission must hop to the MainActor (Swift 6 strict concurrency). Match the RMS-to-level cadence `AppleTTSBackend` already feeds the pill, so the speaking waveform behaves identically across backends.

3. **Backend.** `KokoroTTSBackend: TextToSpeechBackend` in `Relay/Backends/`: id `kokoro`, displayName `Kokoro`, capabilities `[.fullyOffline, .voiceSelection, .pauseResume, .outputLevel]` (the real `TTSCapability` cases; `.outputLevel` because Kokoro is the first backend to emit a live `.level`). `availability()` reports ready / model-not-downloaded / unavailable. `speak` synthesizes through the engine, then plays through `SynthesizedAudioPlayer`, forwarding events. No network at speak time.

4. **Router and Auto.** `TTSRouter` already tries enabled backends in configured order and already falls back on a non-available backend and on a fallback-worthy error. So the 1.7 work here is not new routing: it is registering the Kokoro backend, and making "model missing" surface as a non-available `availability()` (or a fallback-worthy error), so the existing router skips Kokoro and uses Apple. Auto mode is the ordered list `["kokoro", "apple-tts"]`. Note `TTSRouter.speak` resolves a backend by id and silently skips an id it cannot find, so order lists must use real ids.

5. **TTS backend catalog.** A TTS analogue of `SpeechBackendCatalog`: a `TTSBackendStatus` list (Kokoro, Apple) with enable, order, download, and status, reusing the race-safe patterns landed in `449337a` (merge-at-assign refresh, generation counter, guarded progress, split `.downloadFailed`, download gated on a registered downloader).

6. **TTS tab UI (rebuild).**
   - Backend list with enable/order and a Kokoro download row (progress, retry on failure).
   - Voice picker populated from the selected backend: Kokoro from `TtsConstants.availableVoices`, Apple from `AVSpeechSynthesisVoice`.
   - Speech-rate slider (existing).
   - **Test Voice** button: speaks a fixed sample sentence through the selected backend and voice.

7. **Settings model.** `AppSettings` already has `ttsBackendOrder` (Codable-persisted, default `["apple-tts"]`) and `ttsVoiceIdentifier` (Apple's voice, maps to `TTSOptions.voiceIdentifier`). The 1.7 work does not re-declare these. It adds the Kokoro id into the existing order (default stays `["apple-tts"]`, so behavior is unchanged until the user enables Kokoro) and adds a per-backend Kokoro voice field, `kokoroVoice`. The registered Apple backend id is `apple-tts` (displayName "Apple System Voice"); use that exact id everywhere, never `apple-system`.

### Error handling and privacy

- Download failure sets a `.downloadFailed` row and a user-visible message, reusing the STT settings message pattern.
- Synthesis or playback failure emits `.failed`; the router falls back to the next backend, matching STT.
- No transcript, spoken text, audio samples, paths, or raw error strings in logs, Diagnostics, or overlay state — the standing privacy rule.

### Callouts

- `synthesize` returns the full WAV in one call, so there is a total synthesis latency before any playback begins (about 250 ms per 5 s of audio), not incremental chunk streaming. A planner should not expect to start playback on partial output. Acceptable for Read Selection; note it in Diagnostics only as a phase/category, never with content.
- Kokoro downloads its own model, separate from Parakeet. The TTS download row must state this and its size.

### Testing

- Fake `KokoroEngine` and fake playback controller.
- Backend unit tests: id/displayName/capabilities, availability mapping, synthesis forwarding, event emission order, download path, empty-text handling.
- `TTSRouter` fallback tests (Kokoro unavailable or model missing → Apple).
- TTS catalog race tests, reusing the STT catalog test patterns.
- Bounded waits only; no unbounded spin loops.

---

## Out of scope (deferred)

- FluidAudio PocketTTS (voice cloning) — a possible later local option.
- Cloud TTS (ElevenLabs, OpenAI) — requires API keys and sends text off-device; a later optional premium mode.
- WhisperKit STT.
- Phase 2 (agent integrations) and Phase 3 (session intelligence), already documented.

## Delivery process

Sonnet implementers, Opus reviewers (spec then quality), main session does the final check and writes no code. Work on `main`, no worktrees. Phase 1.6 gets its own implementation plan and ships first; Phase 1.7 follows.
