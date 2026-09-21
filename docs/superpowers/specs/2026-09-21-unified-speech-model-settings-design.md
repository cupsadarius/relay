# Unified Speech Model Settings Design

## 1. Summary

Relay will use one model-management module and one settings presentation for speech recognition and text-to-speech. Dictation and TTS will no longer maintain separate implementations of model refresh, download progress, selection, removal, active-state presentation, or model-row actions.

Every speech provider will appear as an expandable row. Its expanded content will contain its managed models and, for TTS providers, its available voices. Model rows expose stable Download/Retry, Select, and Remove actions. Voice rows expose stable Select and Test actions. Provider-specific settings remain behind injected content rather than branching inside the shared model UI.

Kokoro and PocketTTS will support safe removal of their Relay-managed model files. Voice previews will speak with the clicked voice without changing the saved voice selection.

## 2. Goals

1. Have exactly one implementation of model refresh, download, progress merging, retry, selection, removal, active-state calculation, and lifecycle error reporting for both Dictation and TTS.
2. Have exactly one reusable SwiftUI implementation for provider rows and model rows in both settings tabs.
3. Keep model actions visible in stable positions instead of conditionally removing buttons.
4. Move Apple, Kokoro, and PocketTTS voice selection into their owning provider's expanded content.
5. Let users test any voice without changing the saved voice.
6. Support safe deletion and later re-download of Kokoro and PocketTTS models.
7. Preserve backend enablement, fallback ordering, routing behavior, global speech rate, and explicit-download-only behavior.
8. Keep provider-specific voice catalogs and filesystem details out of the shared model-management module.

## 3. Non-goals

- Removing macOS-owned Apple speech or Apple TTS assets.
- Removing Parakeet until its engine has an explicit safe removal operation.
- Downloading or cloning voices.
- Changing backend fallback semantics.
- Changing the persisted voice-setting keys.
- Combining STT and TTS backend registries or routers.
- Deleting an entire shared FluidAudio cache directory.

## 4. Terminology

- **Domain**: either Dictation or TTS. Domains keep separate backend registries, ordering settings, and readiness refresh hooks.
- **Provider**: a speech backend such as Whisper, Parakeet, Apple Speech, Kokoro, PocketTTS, or Apple TTS.
- **Model**: a downloadable or built-in inference asset managed through `SpeechModelManaging`.
- **Voice**: a selectable TTS persona. Voice selection is not model selection.
- **Active model**: a model that is selected, downloaded, and owned by a currently ready backend.
- **Active voice**: the voice persisted in `AppSettings` for its provider, including the provider's default when the stored value is `nil`.

## 5. Shared model-management module

### 5.1 Interface

Introduce a main-actor-observable `SpeechModelController`. Its interface is keyed by a value containing `domain`, `backendID`, and, for model operations, `modelID`. The controller receives:

- the Dictation and TTS `SpeechModelManaging` registries;
- a backend-readiness query for each domain;
- a backend-status refresh hook for each domain;
- a pre-removal hook for each domain;
- a diagnostics recorder.

The controller owns:

- model status collections;
- refresh generations;
- in-flight download keys;
- monotonic download progress merging;
- download, retry, select, and remove operations;
- stable, privacy-preserving user-facing lifecycle errors.

`AppModel` exposes this controller to Settings and supplies domain-specific hooks. It does not reimplement model lifecycle algorithms for either domain.

### 5.2 Model capabilities

`SpeechModelStatus` will carry explicit operation capabilities rather than making the view infer support from provider identity. The capabilities cover:

- download;
- selection;
- removal.

Capabilities describe whether an operation is supported by the adapter, not whether it is currently enabled. Current state determines enablement.

Production adapters report:

| Provider | Download | Select | Remove |
|---|---:|---:|---:|
| Apple Speech | No | Yes | No |
| Parakeet | Yes | Yes | No |
| Whisper | Yes | Yes | Yes |
| Kokoro | Yes | Yes | Yes |
| PocketTTS | Yes | Yes | Yes |

Apple TTS has no separately managed downloadable model. Its provider expands directly to its voice list.

### 5.3 Operation enablement

The shared view always reserves visible action positions. It enables them as follows:

| Model state | Download/Retry | Select | Remove |
|---|---:|---:|---:|
| Not downloaded | Enabled | Disabled | Disabled |
| Downloading | Disabled; progress visible | Disabled | Disabled |
| Download failed | Retry enabled | Disabled | Disabled |
| Downloaded and active | Disabled | Disabled | Enabled when supported |
| Downloaded and inactive | Disabled | Enabled when supported | Enabled when supported |

Unsupported actions remain visible but disabled. They provide concise help text explaining why the operation is unavailable.

Selection never implicitly downloads a model. Removal never changes which model identifier is selected; removing the selected one makes it inactive until it is downloaded again or another downloaded model is selected.

### 5.4 Errors and refreshes

The controller must not swallow selection or removal errors. A failure:

- preserves the last known model state;
- records the appropriate privacy-safe diagnostic;
- publishes a stable message in the owning settings section;
- never exposes raw filesystem or provider error text.

After a successful download, selection, or removal, the controller refreshes both the model collection and the owning backend's readiness. Generation checks prevent stale refreshes from overwriting newer operations.

## 6. Shared settings presentation

### 6.1 Provider rows

Both Settings tabs use one reusable provider-row module. A provider row contains:

- disclosure chevron when the provider has model or voice content;
- provider display name;
- collapsed readiness or active-model summary;
- backend enable toggle;
- enabled-backend ordering controls.

The module accepts closures for enablement and movement so it does not depend on STT or TTS router types.

### 6.2 Model rows

Both tabs use one reusable model-row module. A row contains:

- model display name and detail;
- install or Active status;
- Download/Retry action position;
- Select action position;
- Remove action position.

Remove first presents a confirmation naming the model and explaining that it can be downloaded again. Confirmation is required because the action deletes local files, even though it is recoverable through re-download.

### 6.3 Voice rows

TTS provider expansions render voice rows through a reusable voice-row module. Each row contains:

- voice display name and optional language/detail;
- Active status when it represents the effective saved selection;
- Select action;
- Test action.

Select persists the voice through the existing `AppSettings` fields. Select remains visible and is disabled for the active voice.

Test speaks a fixed, non-sensitive preview phrase with the clicked voice and the current global speech rate. It does not persist or otherwise change the selected voice. Starting a preview cleanly interrupts an earlier preview. Preview uses the owning backend directly rather than normal fallback routing, because testing a specific row must test that exact provider and voice.

### 6.4 TTS layout

The separate Apple Voice, Kokoro Voice, and PocketTTS Voice sections are removed. Their contents move under the corresponding expandable provider.

The global Speech section retains the rate control. Its standalone Test Voice button is removed because testing belongs to individual voice rows.

## 7. Safe TTS model removal

### 7.1 Engine and loader seams

`KokoroEngine` and `PocketTTSEngine` gain an explicit removal operation. Their model-loading seams gain a provider-owned filesystem removal operation.

The engine actor performs removal in this order:

1. cancel and await any in-flight load;
2. release the loaded session;
3. clear cached-positive presence state;
4. call the loader's removal operation;
5. verify that `modelsArePresent()` is false.

The TTS domain's pre-removal hook stops current speech before the engine begins removal. This prevents new audio from relying on a model while its on-disk assets are being deleted.

### 7.2 Exact deletion scope

Kokoro removal deletes only the English ANE model directory and the G2P assets that its presence check requires. It does not delete the shared FluidAudio cache root or unrelated provider assets.

PocketTTS removal deletes only its versioned English model directory. It does not delete sibling languages, versions, providers, or the shared FluidAudio cache root.

Removal is idempotent: an already-absent directory is success. Partial deletion failures are reported as failure and followed by a fresh presence check so Settings reflects the actual remaining state.

## 8. Voice catalogs

Provider-specific adapters describe voice rows without leaking AVFoundation or FluidAudio types into the shared view:

- Apple TTS supplies sorted `AVSpeechSynthesisVoice` entries with name and language.
- Kokoro supplies supported American-English voices and preserves the existing recommended default.
- PocketTTS supplies its documented built-in voice list, currently `alba`.

The existing persisted settings remain authoritative:

- `ttsVoiceIdentifier`;
- `kokoroVoice`;
- `pocketVoice`.

A `nil` stored value continues to mean the provider's recommended or system default and must map to one visible Active voice choice.

## 9. Testing strategy

### 9.1 Shared controller

Controller tests use the same fake manager contract for both domains and cover:

- refresh and stale-generation rejection;
- monotonic per-model progress;
- duplicate-download suppression;
- explicit download without implicit selection;
- selection refreshes model and backend state;
- removal refreshes model and backend state;
- pre-removal hooks run before manager removal;
- failed select/remove preserves state and publishes a stable message;
- domain keys prevent cross-domain state interference.

### 9.2 Presentation

Pure presentation tests cover every action-enabled state in the table above, including visible disabled unsupported actions. SwiftUI smoke tests construct both tabs with the same shared provider/model modules.

Voice tests cover:

- effective default selection;
- persisted selection;
- previewing an inactive voice without persistence;
- previewing the active voice;
- interrupting an earlier preview;
- forwarding the current speech rate and exact clicked provider/voice.

### 9.3 Removal

Kokoro and PocketTTS tests use temporary directories and verify:

- only exact provider paths are deleted;
- sibling files and provider directories survive;
- already-absent removal succeeds;
- a loaded session is released before deletion;
- in-flight loads are cancelled and awaited;
- cached presence becomes false after removal;
- partial filesystem failure is surfaced without claiming success.

The full Relay XCTest suite must pass after integration.

## 10. Migration and compatibility

No settings migration is required. Existing backend order, enablement, selected model, voice, and speech-rate values remain valid.

The old TTS backend-level download path and Dictation-only per-model state path are removed after their callers move to `SpeechModelController`. Compatibility wrappers are not retained: keeping them would preserve the duplicate maintenance burden this design removes.

Documentation describing the TTS Settings UI as intentionally separate will be updated to reflect the unified interface and safe-removal support.
