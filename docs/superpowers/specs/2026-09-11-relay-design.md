# Relay Design Specification

**Date:** 2026-09-11  
**Status:** Draft for review  
**Scope:** v1 architecture and behavior

## 1. Summary

Relay is a local-first macOS voice utility built around two permanent core capabilities:

1. **Speech in:** capture microphone input, transcribe it locally when possible, optionally clean it up, and insert the resulting text into the currently focused application.
2. **Speech out:** take text from a user selection or an integration event, prepare it for listening, and read it aloud through a configurable text-to-speech backend.

The core must remain independent from Claude Code, Codex, Herdr, tmux, Ghostty, or any other specific application. Application-specific behavior is implemented through integrations and focus resolvers that plug into the core through narrow interfaces.

Relay is intended first for personal use on macOS, especially for conversational workflows with coding agents in terminals, while still working universally for dictation and selected-text reading across other macOS applications.

---

## 2. Goals

### 2.1 Primary goals

- Provide fast, low-friction voice dictation into any focused macOS application.
- Provide universal text-to-speech for selected text through a configurable global hotkey.
- Automatically speak final responses from supported coding-agent integrations when the relevant agent session is confidently focused.
- Support multiple STT and TTS engines behind stable backend interfaces.
- Allow preferred/fallback backend ordering and graceful failover.
- Keep the default experience local-first and privacy-preserving.
- Support multiple simultaneous Claude Code and Codex sessions without background sessions unexpectedly speaking.
- Work generically across plain terminals, Ghostty, tmux, Herdr, and future terminal environments through pluggable focus resolvers.
- Keep integrations independent from speech engines and system-specific UI mechanics.

### 2.2 Secondary goals

- Make hotkeys configurable.
- Support both hold-to-talk and toggle-to-record dictation modes.
- Allow future STT, TTS, text-processing, terminal, and agent integrations without architectural rewrites.
- Make speech output pleasant for LLM responses by avoiding literal reading of Markdown syntax and large code blocks.

---

## 3. Non-goals for v1

The following are intentionally outside v1 scope:

- Dynamic third-party plugin loading.
- Public plugin SDK/distribution.
- Cloud STT/TTS providers.
- Voice cloning.
- Transcript or audio history.
- Elaborate floating waveform UI.
- Automatic screen scraping of Claude Desktop or Codex Desktop when no reliable integration hook exists.
- Complex app-specific writing styles.
- Personal dictionary and snippets UI.
- Built-in benchmark dashboard.
- Cross-platform support.

Interfaces should not prevent these features later, but v1 must not depend on them.

---

## 4. Core product behavior

### 4.1 Dictation

Default flow:

```text
Configured dictation hotkey
        ↓
Microphone capture
        ↓
STT router
        ↓
Preferred backend
        ↓ fallback if appropriate
Transcript processor
        ↓
Text insertion service
        ↓
Focused application
```

The user may configure dictation as either:

- **Hold-to-talk:** press and hold the configured key to record, release to stop and transcribe.
- **Toggle:** press once to begin recording, press again to finish.

Starting dictation immediately stops any active speech output.

### 4.2 Read selected text

Default flow:

```text
Configured read-selection hotkey
        ↓
Accessibility selected-text lookup
        ↓ if unavailable
Clipboard fallback
        ↓
Speech preprocessor
        ↓
TTS router
        ↓
Audio output
```

Selection reading must work independently of all integrations.

This is the universal fallback for applications such as desktop chat clients, browsers, PDFs, editors, terminals, and any other app that exposes text selection or supports copy.

### 4.3 Automatic coding-agent speech

Supported agent integrations submit completed assistant responses into Relay.

Default behavior:

- Speak automatically only when Relay can confidently identify the response as belonging to the currently focused agent session.
- Keep background-agent responses silent.
- Store the most recent response for manual replay while the app is running.
- If focus cannot be determined confidently, stay silent rather than risk speaking the wrong session.

Current focus at completion time wins over the session that originally received the prompt.

---

## 5. Architectural principles

### 5.1 Dependency direction

Dependencies must point toward the Relay core.

```text
Integrations ───────► Core
Focus resolvers ────► Core
macOS selection ────► Core
Hotkeys ────────────► Core
```

The core must never require knowledge of Claude, Codex, Ghostty, tmux, or Herdr.

### 5.2 Stable interfaces around replaceable engines

STT, TTS, transcript processing, speech preprocessing, integrations, and focus resolution must all be abstracted behind narrow interfaces.

### 5.3 Conservative automation

Automatic speech must prefer false negatives over false positives.

If Relay is uncertain whether an agent response belongs to the focused session, it must not auto-speak.

### 5.4 Local-first operation

Local processing is the default. Network-dependent providers may be added later, but local and cloud backends must share the same high-level interfaces.

---

## 6. High-level component map

```text
RelayApp
│
├── Input
│   ├── HotkeyManager
│   ├── MicrophoneCapture
│   └── SelectionReader
│
├── Speech In
│   ├── STTRouter
│   ├── STTBackend
│   │   ├── ParakeetBackend
│   │   ├── AppleSpeechBackend
│   │   └── WhisperKitBackend
│   └── TranscriptProcessor
│
├── Speech Out
│   ├── TTSRouter
│   ├── TTSBackend
│   │   ├── AppleTTSBackend
│   │   └── LocalNeuralTTSBackend
│   └── SpeechPreprocessor
│
├── System
│   ├── TextInsertionService
│   ├── AccessibilityService
│   ├── ClipboardFallback
│   └── FrontmostAppMonitor
│
├── Sessions
│   ├── AgentSessionRegistry
│   ├── FocusResolver
│   │   ├── GenericTerminalResolver
│   │   ├── TmuxResolver
│   │   └── HerdrResolver
│   └── RecentInteractionTracker
│
└── Integrations
    ├── ClaudeCodeIntegration
    ├── CodexIntegration
    └── Future integrations
```

---

## 7. Speech-to-text backend abstraction

### 7.1 Interface

Conceptual interface:

```swift
protocol SpeechToTextBackend {
    var id: String { get }
    var displayName: String { get }
    var capabilities: STTCapabilities { get }

    func availability() async -> BackendAvailability
    func prepare() async throws

    func transcribe(
        audio: AudioInput,
        options: STTOptions
    ) async throws -> Transcript
}
```

### 7.2 Initial compiled-in backends

- Parakeet
- Apple Speech
- WhisperKit

These are compiled-in providers in v1. The architecture is plugin-ready, but v1 does not implement runtime plugin loading.

### 7.3 Capabilities

Each backend reports capabilities rather than forcing the UI or router to know backend-specific behavior.

Example capability fields:

```text
streaming
multilingual
timestamps
partialResults
customVocabulary
fullyOffline
```

### 7.4 Availability states

Backends should expose states such as:

```text
available
unavailable
modelNotDownloaded
permissionDenied
unsupportedOS
unsupportedHardware
initializing
failed(reason)
```

---

## 8. STT routing and fallback

The STT router is responsible for selecting the backend.

Example policy:

```text
Primary: Parakeet
Fallback 1: Apple Speech
Fallback 2: WhisperKit
```

Fallback should occur only for backend-specific failures.

### 8.1 Fallback-worthy failures

- Backend unavailable.
- Required local model missing.
- Backend initialization failure.
- Unsupported OS/hardware for the preferred backend.
- Recoverable backend runtime failure.
- Resource exhaustion where a lighter configured backend is available.

### 8.2 Non-fallback failures

- Microphone permission denied.
- No usable audio captured.
- Corrupt or invalid input shared by all backends.
- System-level permission failures unrelated to the backend.

Relay must not blindly retry every engine for every error.

---

## 9. Transcript processing

STT produces a raw transcript. A separate transcript processor may improve it before insertion.

Possible processors:

```text
RulesOnlyProcessor
AppleFoundationModelProcessor
FutureLocalLLMProcessor
```

Responsibilities may include:

- Filler-word cleanup.
- Punctuation and capitalization normalization.
- Self-correction handling.
- Formatting spoken lists.
- Developer-term normalization.

The transcript processor must not be coupled to a particular STT backend.

If no advanced processor is available, a rules-only path must remain usable.

---

## 10. Text-to-speech backend abstraction

### 10.1 Interface

Conceptual interface:

```swift
protocol TextToSpeechBackend {
    var id: String { get }
    var displayName: String { get }
    var capabilities: TTSCapabilities { get }

    func availability() async -> BackendAvailability

    func speak(
        text: String,
        options: TTSOptions
    ) async throws

    func stop() async
    func pause() async
    func resume() async
}
```

### 10.2 Initial backends

- Apple system TTS as the v1 default.
- Local neural TTS as an optional compiled-in backend when practical.

### 10.3 TTS routing

TTS uses the same preferred/fallback model as STT.

Example:

```text
Primary: Local Neural TTS
Fallback: Apple System TTS
```

If the preferred backend becomes unavailable, Relay should fall back automatically when configured to do so.

---

## 11. Speech preprocessing

Text intended for speech should pass through a speech-preparation layer before reaching TTS.

The on-screen content must never be modified by this process.

### 11.1 Responsibilities

- Remove or reinterpret Markdown syntax.
- Avoid reading Markdown delimiters literally.
- Handle inline code intelligibly.
- Summarize or skip long code blocks for automatic agent speech.
- Preserve important warnings, conclusions, and action items.
- Make long agent responses pleasant to listen to.

### 11.2 Response-length policy

Default behavior:

- Short/medium responses: read substantially as written after formatting cleanup.
- Long responses: produce a concise spoken version and mention that the full answer is on screen.
- Long code blocks: summarize purpose rather than read every symbol.
- Explicit user-requested selection reading: prefer verbatim reading unless a separate mode is selected.

A rules-only fallback should exist when a local language-model-based speech preprocessor is unavailable.

---

## 12. Speech request model and arbitration

All speech-out paths should converge on a single internal request type.

Conceptually:

```swift
struct SpeechRequest {
    let text: String
    let source: SpeechSource
    let mode: SpeechMode
    let sessionID: String?
}
```

Possible sources:

```text
selection
claudeCode
codex
manualReplay
futureIntegration
```

### 12.1 Priority

The default priority order is:

1. User begins dictating: stop all speech immediately.
2. User explicitly requests selected-text speech: speak immediately.
3. Focused agent response: auto-speak.
4. Background agent response: remain silent and store as latest response for that session.

Only one TTS stream may be active at a time in v1.

---

## 13. Hotkeys

All user-facing hotkeys must be configurable.

Initial actions:

```text
Dictate
Read selection
Stop speech
Replay last
Toggle auto-read
```

Suggested defaults are implementation details and should not be hardcoded into the architecture.

The hotkey system must support at least:

- Hold-to-talk dictation.
- Toggle dictation.
- Standard chord-based global shortcuts.

Conflicts with existing macOS/global shortcuts should be detected where feasible and surfaced clearly.

---

## 14. Universal selected-text reading

SelectionReader should attempt text acquisition in this order:

1. macOS Accessibility selected-text API.
2. Clipboard fallback.

The clipboard fallback should:

- Preserve the user's existing clipboard contents when practical.
- Copy the current selection.
- Read the copied text.
- Restore the prior clipboard contents when safe.

Failure to read a selection should produce a small, non-disruptive error rather than silently doing nothing.

---

## 15. Integrations

Integrations are adapters that translate external application events into stable Relay events.

The core must not contain Claude- or Codex-specific logic.

Conceptual responsibilities:

```text
External event
    ↓
Integration adapter
    ↓
Normalized agent event
    ↓
AgentSessionRegistry
    ↓
Focus resolution
    ↓
Speech pipeline
```

### 15.1 Initial integrations

- Claude Code
- Codex

### 15.2 Integration output

A normalized response event should include enough information to identify the producing session.

Conceptual payload:

```json
{
  "type": "assistant_response",
  "text": "The tests are now passing...",
  "source": "codex",
  "session_id": "...",
  "pid": 12345,
  "tty": "...",
  "cwd": "~/project"
}
```

Exact fields depend on what the external hook provides, but integration-specific fields should be normalized before reaching core routing logic.

---

## 16. Agent session model

Relay must support multiple simultaneous sessions from the same or different coding agents.

Conceptual session state:

```text
AgentSession
├── id
├── provider
├── providerSessionID
├── processID
├── tty
├── cwd
├── terminal metadata
├── multiplexer metadata
├── startedAt
└── lastActivityAt
```

Available environment/session identifiers may include values such as terminal program, tmux pane identifiers, or integration-specific session IDs.

No single identifier should be assumed available in all environments.

---

## 17. Focus resolution

Focus detection is its own subsystem.

Claude and Codex integrations must not contain terminal-specific focus logic.

### 17.1 Resolver interface

Conceptually, resolvers answer:

```text
Given AgentSession X, is X the session the user is currently focused on?
```

The answer should include confidence, not only a boolean.

Suggested result:

```text
focused(confidence: high)
notFocused(confidence: high)
unknown
```

### 17.2 Initial resolvers

- Generic terminal resolver.
- tmux resolver.
- Herdr resolver.

Herdr is an optional enhancement, never a core dependency.

### 17.3 Focus-signal priority

Prefer the strongest available evidence:

1. Exact multiplexer pane focus.
2. Exact terminal/TTY focus.
3. Most recently voice-interacted agent session.
4. Frontmost terminal/application metadata.
5. Unknown.

If the result is uncertain, automatic speech must stay silent.

### 17.4 Current-focus rule

If the user sends a prompt to agent A, switches to agent B while A is working, and A finishes in the background, A should not auto-speak.

If the user returns to A before A finishes, A may speak when it completes because A is focused at completion time.

---

## 18. Recent interaction tracking

Relay should track the session most recently associated with the user's voice interaction.

This is a supporting focus signal, not the sole source of truth.

Example:

```text
User dictates into Claude session A
→ A becomes recent voice-interaction owner

User later dictates into Codex session B
→ ownership moves to B
```

This helps in terminals where exact pane identity is unavailable.

Recent interaction state is ephemeral and should not be persisted across app launches in v1.

---

## 19. Background agent behavior

When a background agent response finishes:

- Do not speak automatically.
- Record it as the latest response for that session in ephemeral memory.
- Optionally show a subtle visual indication or macOS notification if enabled.
- Allow manual replay later.

A future option may speak the latest unread response when the user focuses that session, but this is not required for v1.

---

## 20. System services

### 20.1 AccessibilityService

Responsibilities:

- Obtain selected text when available.
- Support focused-element text insertion where possible.
- Expose required permission state.

### 20.2 TextInsertionService

Responsibilities:

- Insert completed dictation into the focused application.
- Use accessibility APIs when reliable.
- Fall back to paste-based insertion when required.

### 20.3 ClipboardFallback

Responsibilities:

- Provide selected-text and insertion fallbacks.
- Minimize disruption to the user's clipboard.

### 20.4 FrontmostAppMonitor

Responsibilities:

- Track the frontmost macOS application.
- Provide metadata to focus resolvers.
- Avoid application-specific speech decisions.

---

## 21. State and persistence

### 21.1 Persisted preferences

Persist:

- Hotkey configuration.
- Dictation mode.
- Preferred STT backend and fallback order.
- Preferred TTS backend and fallback order.
- Voice and speech-rate preferences.
- Auto-read policy.
- Integration enable/disable settings.
- Downloaded model metadata and paths.

### 21.2 Ephemeral state

Do not persist by default:

- Recorded audio.
- Raw transcripts.
- Processed transcripts.
- Agent response content.
- Speech queue contents.
- Focus/session routing state.
- Recent voice-interaction ownership.

### 21.3 Future optional persistent state

Potential later features:

- Personal dictionary.
- Snippets.
- Pronunciation rules.
- User-enabled transcript history.

---

## 22. Privacy

Default rule:

> No speech, transcript, selected text, or agent response leaves the Mac unless the user explicitly selects a backend or integration that requires network access.

v1 should favor local backends.

If cloud providers are introduced later, settings must clearly distinguish local and network-dependent providers.

Relay should request only the macOS permissions required for enabled features.

Expected v1 permissions include:

- Microphone access for speech input.
- Accessibility access for text insertion, selected-text retrieval, and related system integration.

Broader permissions should not be requested preemptively.

---

## 23. Error handling

Errors should be categorized so the router can decide whether fallback is appropriate.

### 23.1 Backend errors

Examples:

- unavailable
- model missing
- unsupported platform
- initialization failure
- recoverable inference failure
- resource exhaustion

These may trigger fallback according to user policy.

### 23.2 Input/system errors

Examples:

- microphone permission denied
- no audio input
- accessibility permission denied
- selection unavailable
- text insertion unavailable

These should generally not cause attempts across unrelated speech backends.

### 23.3 User experience

Errors should be concise and actionable.

Examples:

```text
Parakeet model unavailable. Using Apple Speech.
```

```text
Relay needs Accessibility permission to insert text.
```

Avoid modal interruptions where a menu-bar notice or notification is sufficient.

---

## 24. Backend comparison strategy

Relay should not hardcode a permanent assumption that one STT/TTS engine is always best.

During development, compare candidate STT engines using the same captured audio samples on the same machine.

Suggested evaluation dimensions:

- Developer-term correctness.
- General transcription accuracy.
- Perceived latency.
- Punctuation/self-correction behavior.
- CPU/GPU/RAM use.
- Offline reliability.

Developer vocabulary should receive disproportionate weight because this app is optimized for coding-agent workflows.

A future user-facing benchmark UI may automate this comparison, but it is not part of v1.

---

## 25. Testing strategy

### 25.1 Unit tests

Test components independently:

- STT router fallback decisions.
- TTS router fallback decisions.
- Error classification.
- Speech request arbitration and priority.
- Markdown/code speech preprocessing.
- Session registry updates.
- Focus-confidence combination logic.
- Recent-interaction ownership.
- Settings serialization.

### 25.2 Backend contract tests

Every STT and TTS implementation should pass a shared contract suite.

For STT:

- Availability reporting.
- Initialization.
- Successful transcription.
- Cancellation.
- Error classification.

For TTS:

- Availability reporting.
- Start speech.
- Stop speech.
- Pause/resume where supported.
- Cancellation and replacement behavior.

### 25.3 Integration tests

Test normalized events from:

- Claude Code hooks.
- Codex hooks.

Verify that integration-specific input is transformed into the same internal agent-response model.

### 25.4 Focus routing tests

Cover at least:

- Plain terminal with one agent.
- Plain terminal with multiple windows/tabs where identifiable.
- tmux with multiple panes.
- Herdr-enhanced environment.
- Multiple Claude sessions.
- Multiple Codex sessions.
- Claude and Codex simultaneously.
- Focus switch before completion.
- Unknown focus resulting in silence.

### 25.5 macOS interaction tests

Manually or automatically validate:

- Selected-text reading.
- Clipboard fallback.
- Text insertion into Terminal/Ghostty/editor/browser text fields.
- Hotkey conflicts.
- Accessibility permission loss/revocation.
- Microphone permission loss/revocation.

### 25.6 Real-world speech test set

Maintain a small repeatable test corpus containing:

- Coding terminology.
- File paths.
- Package/tool names.
- Spoken punctuation.
- Hesitations and filler words.
- Self-corrections.
- Normal prose.
- Longer agent prompts.
- Mixed-language samples when relevant.

---

## 26. v1 scope

### Core

- Configurable global hotkeys.
- Hold-to-talk and toggle dictation.
- STT backend abstraction.
- Parakeet backend.
- Apple Speech backend.
- WhisperKit backend.
- Preferred/fallback STT routing.
- Transcript processing abstraction.
- Text insertion at cursor.

### Speech out

- TTS backend abstraction.
- Apple system TTS.
- Optional local neural TTS if implementation cost remains bounded.
- Preferred/fallback TTS routing.
- Configurable voice and speed.
- Universal read-selection hotkey.
- Stop and replay actions.
- Speech-friendly Markdown/code processing.

### Agent integration

- Claude Code integration.
- Codex integration.
- Focused-session-only auto-read.
- Multiple simultaneous agent sessions.
- Generic focus resolver.
- tmux resolver.
- Herdr resolver as an optional enhancement.
- Silent background responses.

### System behavior

- Dictation interrupts speech immediately.
- Explicit selected-text reading has priority over auto-read.
- Graceful backend fallback.
- No transcript/audio history by default.
- Conservative focus policy.

---

## 27. Future extensions

Possible later additions:

- Dynamic third-party backend/integration plugins.
- Cloud speech providers.
- Better local neural TTS engines.
- Personal dictionary and custom pronunciations.
- Dictation snippets.
- App-specific transcript-cleanup styles.
- Automatic focus/session adapters for more terminals and IDEs.
- Claude Desktop/Codex Desktop integrations when reliable completion events exist.
- Cursor, VS Code, JetBrains, and other coding-agent adapters.
- Optional transcript history.
- User-facing engine benchmark tool.
- Spoken-response profiles such as concise, verbatim, summary, or accessibility mode.

---

## 28. Success criteria

The first usable Relay release succeeds when the following workflow is reliable:

1. The user can run Claude Code or Codex directly in a terminal, in tmux, or through an environment such as Herdr.
2. The user presses their configured dictation key and speaks a prompt.
3. Relay transcribes the speech using the configured STT backend/fallback chain.
4. The transcript is inserted into the currently focused application.
5. The agent works normally.
6. When the currently focused agent session finishes, Relay automatically reads the final response aloud.
7. A background agent finishing in another session remains silent.
8. Anywhere else in macOS, the user can select text and invoke the configured read-selection shortcut.
9. The user can stop speech immediately and replay the latest spoken item.
10. The default workflow does not persist audio, transcripts, or agent responses and does not require a cloud speech service.

---

## 29. Architecture decisions locked for v1

The following decisions are considered approved unless explicitly revised:

- Speech input and speech output are permanent core capabilities.
- STT and TTS are provider abstractions with preference and fallback routing.
- Initial providers are compiled into the app rather than dynamically loaded.
- Integrations are adapters that feed normalized events into the core.
- Claude Code and Codex are the first automatic-response integrations.
- Selected-text speech is universal and independent of integrations.
- All hotkeys are configurable.
- Multiple concurrent agent sessions are first-class.
- Only the confidently focused session auto-speaks by default.
- Current focus at response-completion time determines auto-read eligibility.
- Ghostty, tmux, and Herdr support is implemented through focus-resolution adapters rather than core coupling.
- Herdr is optional and never required.
- Unknown/uncertain focus results in silence.
- Dictation interrupts speech.
- Manual read-selection has priority over automatic agent speech.
- Audio, transcripts, and agent responses are ephemeral by default.
- v1 is local-first and macOS-only.

---

## 30. Open implementation choices

These are implementation decisions to resolve during planning rather than architectural gaps:

- Exact default hotkey values.
- Exact default STT backend ordering after benchmarking on the target Mac.
- Whether local neural TTS remains in v1 or moves to the first follow-up release.
- Exact rules-only transcript cleanup heuristics.
- Exact rules-only speech preprocessing heuristics.
- Exact timeout/retry thresholds for backend failover.
- Exact mechanism for per-terminal TTY/pane focus detection where multiple APIs are available.

These choices do not change the architectural boundaries defined in this document.
