# Relay

**Voice in, voice out, anywhere on your Mac.**

Relay is a local-first macOS voice interface for dictation, text-to-speech, and coding-agent workflows.

The goal is to make tools such as Claude Code and Codex feel conversational without requiring them to provide their own voice interface.

## What Relay Does

### Speech In

Hold a configurable hotkey, speak, and Relay transcribes your voice locally and inserts the result at the current cursor.

```text
Hold hotkey
    ↓
Speak
    ↓
Local speech-to-text
    ↓
Optional transcript cleanup
    ↓
Insert at cursor
```

### Speech Out

Select text anywhere on macOS, press a configurable hotkey, and Relay reads it aloud.

```text
Select text
    ↓
Read Selection hotkey
    ↓
Speech preprocessing
    ↓
Local text-to-speech
```

### Agent Integrations

Relay can integrate with coding agents such as:

- Claude Code
- Codex

When the currently focused agent finishes responding, Relay can automatically read the response aloud.

Background agent sessions remain silent.

## Principles

- Local-first
- No account required
- No server required
- No transcript or audio history by default
- Configurable hotkeys
- Replaceable STT and TTS backends
- Graceful backend fallback
- Integrations remain separate from the speech core
- Conservative automatic speech: if session focus is uncertain, stay silent

## Architecture

Relay separates speech processing from integrations.

```text
                    Relay Core

       Speech In                 Speech Out
           │                         │
       STT Router                 TTS Router
           │                         │
    ┌──────┼──────┐            ┌─────┼─────┐
    │      │      │            │           │
Parakeet Apple WhisperKit    Apple TTS   Future
    │      │      │            │           │
    └──────┴──────┘            └─────┬─────┘
                                      │
                              Speech Coordinator
                                      ▲
                        ┌─────────────┼─────────────┐
                        │             │             │
                   Selection       Claude        Codex
                    Reader          Code
```

Integrations feed normalized events into Relay. They do not implement speech themselves.

## Terminal and Session Support

Relay is designed to work independently of any particular terminal or multiplexer.

Examples include:

```text
Ghostty → Claude Code
Ghostty → Codex
Ghostty → tmux → Claude Code
Ghostty → tmux → Codex
Ghostty → Herdr → Claude Code
Terminal.app → tmux → Codex
```

Terminal-specific and multiplexer-specific focus detection is handled through separate resolvers.

## Project Status

Relay is currently in the implementation phase.

Development is split into three phases:

1. **Core**
   - macOS app
   - hotkeys
   - selected-text reading
   - speech-to-text
   - text-to-speech
   - backend routing and fallback

2. **Agent Integrations**
   - integration event protocol
   - Claude Code
   - Codex

3. **Session Intelligence**
   - concurrent sessions
   - focused-session detection
   - generic terminal support
   - tmux
   - optional Herdr integration

## Documentation

```text
docs/
└── superpowers/
    ├── specs/
    │   └── 2026-09-11-relay-design.md
    └── plans/
        ├── 2026-09-11-relay-phase-1-core.md
        ├── 2026-09-11-relay-phase-2-agent-integrations.md
        └── 2026-09-11-relay-phase-3-session-intelligence.md
```

## Tech Stack

- Swift
- SwiftUI
- macOS
- AVFoundation
- macOS Accessibility APIs
- Swift Package Manager

Speech backends are abstracted so models and providers can be replaced without changing the rest of Relay.

## Privacy

Relay is local-first.

By default:

- recorded audio is discarded after transcription
- transcripts are not stored
- agent responses are not logged
- session state is kept in memory
- local speech backends do not send content off-device

Any future network-backed provider must be explicitly enabled by the user.

## License

Not yet selected.