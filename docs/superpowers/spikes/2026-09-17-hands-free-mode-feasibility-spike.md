# Relay Hands-Free Mode — Feasibility Spike

**Date:** 2026-09-17  
**Status:** Proposed spike  
**Product:** Relay  
**Scope:** Hands-free wake-word interaction with Relay, Claude Code, and Codex  
**Intent:** Explore feasibility and define the smallest safe architecture before committing to implementation.

## 1. Summary

Relay currently uses explicit keyboard shortcuts for dictation and speech actions.

This spike explores an optional **Hands-Free Mode** that lets the user wear headphones, move away from the Mac, and interact with Relay by voice using a wake phrase such as:

> **“Hey Relay”**

The desired experience is closer to Siri / Google Assistant than ordinary dictation:

```text
Relay idle
    ↓
"Hey Relay"
    ↓
Relay listens
    ↓
user asks something
    ↓
local command or coding-agent prompt
    ↓
Claude/Codex responds
    ↓
Relay reads the response aloud
    ↓
optional short follow-up conversation
```

The existing hotkey workflow must remain unchanged and fully usable. Hands-Free Mode is an additional interaction layer, not a replacement for keyboard-driven Relay.

## 2. Primary User Scenario

The user leaves the Mac running Relay at a desk, wears a headset, and walks around the house.

```text
User:
"Hey Relay, ask Claude why the tests are failing."

Relay:
[wake acknowledged]

Relay sends the prompt to the active/relevant Claude session.

Claude responds.

Relay:
"The tests are failing because..."

Relay remains receptive for a short follow-up window.

User:
"Explain that more simply."

Claude responds again.

User:
"Not now."

Relay:
[quiet acknowledgement]

Relay returns to wake-word-only mode.
```

Later:

```text
User:
"Hey Relay, what was that last message?"

Relay replays the most relevant previous Claude/Codex response.
```

No keyboard interaction is required.

## 3. Goals

The spike should determine whether Relay can provide a reliable hands-free experience with:

- an always-available local wake phrase
- low CPU usage while idle
- no continuous full speech transcription
- headset microphone input
- headset audio output
- deterministic Relay voice commands
- conversational prompts to Claude Code / Codex
- optional short follow-up conversations
- explicit conversational shutdown
- contextual replay of previous messages
- no disruption to the existing hotkey workflow

## 4. Non-Goals

This spike does **not** attempt to build:

- a general-purpose Siri replacement
- a cloud voice assistant
- continuous recording/transcription of the room
- smart-home control
- speaker identification
- multi-user voice profiles
- voice biometrics
- remote access outside the Mac
- an autonomous agent that acts without explicit user input
- a finished wake-word provider abstraction
- production UI polish

The spike exists to answer feasibility and architecture questions.

## 5. Core Principle

Hands-Free Mode should follow this privacy and reliability rule:

> Relay may continuously run a lightweight local wake-word detector, but full STT should start only after the wake phrase is detected.

```text
Idle
    ↓
low-power local wake-word detector
    ↓
"Hey Relay"
    ↓
full microphone capture + STT
```

Relay should **not** continuously run the normal dictation transcription pipeline on everything the microphone hears.

Benefits:

- lower CPU
- lower power usage
- fewer accidental transcripts
- better privacy
- lower model contention
- simpler session boundaries

## 6. Proposed Interaction States

Hands-Free Mode should be modeled explicitly rather than inferred from scattered booleans.

```text
┌────────────────────┐
│    Wake Listening  │
│ wake detector only │
└─────────┬──────────┘
          │ "Hey Relay"
          ▼
┌────────────────────┐
│     Listening      │
│ full STT active    │
└─────────┬──────────┘
          │ utterance
          ▼
┌────────────────────┐
│  Intent Resolution │
└─────────┬──────────┘
          │
     ┌────┴───────────────┐
     │                    │
     ▼                    ▼
Relay command         Agent prompt
     │                    │
     ▼                    ▼
perform locally       Claude / Codex
     │                    │
     └──────────┬─────────┘
                ▼
         ┌──────────────┐
         │   Speaking   │
         └──────┬───────┘
                │ response complete
                ▼
       ┌───────────────────┐
       │ Follow-up Window  │
       └─────────┬─────────┘
                 │
         ┌───────┴──────────────┐
         │                      │
    user speaks          timeout / "not now"
         │                      │
         ▼                      ▼
   next utterance        Wake Listening
```

## 7. Wake Phrase

Initial working wake phrase:

> **“Hey Relay”**

Potential later options:

- Relay
- Okay Relay
- Hey Relay
- user-configurable phrase

For the spike, use one phrase only.

The wake-word engine should be a replaceable dependency rather than something baked into Relay core.

Conceptual interface:

```swift
protocol WakeWordDetecting {
    func start() async throws
    func stop()
    var events: AsyncStream<WakeWordEvent> { get }
}
```

## 8. Wake-Word Engine Requirements

The spike should evaluate at least one practical local engine against:

- native arm64 macOS support
- fully local inference after setup
- low idle CPU
- low memory footprint
- reliable headset-microphone detection
- configurable sensitivity if available
- low false-positive rate
- low false-negative rate
- acceptable licensing/dependency model
- safe lifecycle during audio-device changes
- no interference with Relay's normal microphone capture

The spike should prefer the simplest engine that is reliable enough.

## 9. Voice Command Layer

Not every utterance should go to Claude/Codex.

Relay should first run a small deterministic local intent layer.

Examples:

```text
"repeat that"
"say that again"
"what was the last message?"
"stop"
"not now"
"go quiet"
"cancel"
```

Conceptual result:

```swift
enum HandsFreeIntent {
    case replayLastSpoken
    case replayLatestAgentMessage
    case stopSpeaking
    case endConversation
    case cancel
    case agentPrompt(String)
}
```

The intent recognizer should initially be deterministic and rule-based. No LLM is required for basic Relay controls.

## 10. Important Voice Commands

### 10.1 Stop

Examples:

```text
"stop"
"stop talking"
```

Meaning:

```text
stop current TTS immediately
```

This does not necessarily exit conversational mode.

### 10.2 Not Now

Examples:

```text
"not now"
"go quiet"
"that's enough"
```

Meaning:

```text
stop follow-up listening
return to wake-word-only mode
require "Hey Relay" again
```

This is a first-class Relay control and should never be forwarded to Claude as an ordinary prompt.

### 10.3 Repeat That

Examples:

```text
"repeat that"
"say that again"
```

Meaning:

```text
replay the last thing Relay spoke
```

When dormant:

```text
"Hey Relay, repeat that"
```

should work.

### 10.4 What Was That Last Message?

Example:

```text
"Hey Relay, what was that last message?"
```

Suggested resolution order:

```text
1. latest relevant agent response
2. last spoken Relay content
3. nothing available → short spoken/audio response
```

For the spike, this remains entirely local.

## 11. Conversation Follow-Up Window

After Relay finishes speaking an agent response, it may remain receptive for a short interval.

```text
Relay speaks Claude response
    ↓
follow-up window opens
    ↓
user says:
"Why?"
"Explain that more simply."
"What should I change?"
```

No new wake phrase is required.

Suggested first experiment:

```text
10–20 second follow-up window
```

The exact duration can become configurable later.

## 12. Conversation Shutdown

Primary command:

> **“Not now.”**

Behavior:

```text
cancel follow-up listening
stop active conversational capture
return to wake listening
```

Prefer a subtle acknowledgement tone over a verbose spoken response.

## 13. Conversation Context

Relay needs enough ephemeral state to support replay and follow-up commands.

```swift
struct HandsFreeContext {
    var lastSpokenText: String?
    var lastAgentResponse: AgentResponseEvent?
    var activeAgentSessionID: AgentSessionID?
    var conversationStartedAt: Date?
}
```

No persistent conversation history is required for the spike.

## 14. Agent Target Selection

Hands-Free Mode needs a deterministic rule for which coding-agent session receives a prompt.

Preferred initial policy:

```text
1. confidently focused agent session
2. explicitly selected/remembered hands-free agent session
3. otherwise do not guess
```

Because the user may walk away from the Mac, terminal focus may no longer remain useful after a conversation begins.

The spike should therefore test a temporarily **bound conversation session**.

```text
User begins:
"Hey Relay, ask Claude why..."

Relay resolves one session
    ↓
binds hands-free conversation to it
    ↓
follow-up prompts stay on that session
    ↓
"not now" clears the binding
```

This is safer than re-running focus resolution for every follow-up.

## 15. Hands-Free Session Binding

A bound conversation may store:

```text
provider
providerSessionID
startedAt
lastActivityAt
```

Lifecycle:

```text
wake command targets session
    ↓
bind to session
    ↓
follow-up questions remain with session
    ↓
"not now" / timeout
    ↓
binding cleared
```

The spike must verify whether Claude/Codex integrations can safely inject subsequent prompts into a known session.

If not, a reduced first version may support:

- wake-word dictation into the currently focused terminal/app
- local replay/control commands
- automatic response listening

without true remote prompt injection.

## 16. Headset / Audio Device Requirements

Explicitly test:

- Bluetooth headset microphone
- Bluetooth headset output
- wired headset if available
- AirPods or similar devices
- device disconnect/reconnect
- device switching while idle
- device switching while listening
- device switching while speaking
- Mac sleep/wake
- screen lock/unlock if relevant

### Important Bluetooth question

Some Bluetooth headsets reduce playback quality when the microphone becomes active.

The spike must determine whether keeping wake-word microphone capture active continuously causes the headset to remain in a lower-quality bidirectional audio mode.

If so, alternatives include:

- wake-word detection from the Mac microphone while TTS plays to headphones
- activating the headset microphone only after another signal
- separate wake-listen and conversation input devices

This is one of the most important practical questions in the spike.

## 17. Microphone Ownership

Relay already has an explicit dictation capture lifecycle. Hands-Free Mode adds long-lived microphone access.

These systems should not independently fight over the same audio device.

Preferred architecture:

```text
AudioInputCoordinator
        │
        ├── wake-word consumer
        └── dictation/STT consumer
```

Transition:

```text
wake detector listening
    ↓
wake detected
    ↓
pause/suspend wake detector
    ↓
start full STT capture
    ↓
utterance ends
    ↓
resume wake detector
```

Avoid two unrelated `AVAudioEngine` owners for the same microphone if possible.

## 18. End-of-Utterance Detection

Hands-free input cannot depend on key release.

Relay needs to determine when the user has finished speaking.

Possible approaches:

### A. Silence timeout

```text
speech detected
then ~700–1200 ms silence
→ finish utterance
```

### B. Voice activity detection (VAD)

Track:

```text
speech started
speech continued
speech ended
```

### C. Hard maximum utterance duration

Always useful as a safety bound.

Recommended spike:

```text
VAD or basic energy detection
+
silence timeout
+
hard maximum utterance duration
```

## 19. Barge-In

Ideal future behavior:

```text
Relay is speaking
user says "stop"
    ↓
stop TTS
    ↓
listen to user
```

or natural follow-up speech interrupting Relay.

This is harder because the microphone may hear Relay's own TTS.

The first spike does **not** need full barge-in, but should document its feasibility because it matters to natural conversation.

## 20. Privacy Model

Hands-Free Mode must preserve Relay's local-first philosophy.

```text
wake audio:
    processed locally
    not stored

post-wake audio:
    transcribed locally
    discarded after transcription

transcripts:
    ephemeral

agent responses:
    ephemeral

wake events:
    structural diagnostics only
```

The UI should clearly distinguish wake listening from full transcription.

## 21. Proposed Settings

Hands-Free Mode should be explicitly opt-in.

```text
Hands-Free Mode
[ ] Enable

Wake phrase
    Hey Relay

Input device
    Automatic / selected microphone

Follow-up listening
    [x] Enabled

Follow-up timeout
    15 seconds

Agent targeting
    Focused / bound conversation

Wake sensitivity
    Normal

Audio feedback
    [x] Wake chime
    [x] Sleep chime
```

No polished settings UI is required during the spike.

## 22. Status / Overlay States

Potential states:

```text
Wake Listening
Listening
Processing
Claude Thinking
Speaking
Follow-up Listening
```

Possible menu-bar indicator:

```text
○ Relay ready
◉ Wake listening
● Listening
● Processing
● Speaking
```

Wake-listening should be visually distinct from full transcription.

## 23. Failure Behavior

### Wake engine fails

```text
Hands-Free Mode disables itself
existing keyboard Relay remains functional
```

### Microphone unavailable

Surface a nonfatal status. Existing hotkey behavior remains recoverable.

### No safe agent target

Do not guess.

Possible response:

> “I don't have an active agent session.”

### Agent prompt delivery fails

Signal a short error and return to a known mode.

### TTS fails

Return to follow-up or wake-listening based on conversation state.

### Headset disconnects

Fall back to configured/default audio device where safe, otherwise return to a non-crashing unavailable state.

## 24. Reliability Rules

1. Wake detection has bounded CPU and memory.
2. Full STT starts only after wake.
3. Microphone state has one owner.
4. Every external operation has a timeout.
5. Hands-Free Mode failure never disables keyboard dictation.
6. Unknown agent target means no prompt is sent.
7. `not now` always returns Relay to a known dormant state.
8. Local commands never depend on Claude.
9. Conversation bindings expire.
10. Audio/transcript content remains ephemeral.

## 25. Proposed Architecture

```text
                     HandsFreeController
                             │
           ┌─────────────────┼─────────────────┐
           │                 │                 │
   WakeWordDetector     VoiceCommand      Conversation
           │              Resolver          Session
           │                 │                 │
           └─────────────┬───┴─────────────────┘
                         │
                  AudioInputCoordinator
                         │
                  Microphone / VAD
                         │
                         ▼
                      STTRouter
                         │
                    transcript
                         │
               ┌─────────┴──────────┐
               │                    │
         Relay command          Agent prompt
               │                    │
               │                    ▼
               │              Claude / Codex
               │                    │
               └──────────┬─────────┘
                          ▼
                  SpeechCoordinator
                          │
                         TTS
```

Hands-Free Mode should reuse existing:

- STTRouter
- speech preprocessing
- SpeechCoordinator
- TTSRouter
- agent session registry
- focus resolver
- latest-response/replay mechanisms

It should not create a second speech stack.

## 26. Architectural Boundary

Conceptual controller:

```swift
protocol HandsFreeControlling {
    func enable() async throws
    func disable()
    func endConversation()
}
```

One explicit state machine:

```swift
enum HandsFreeState {
    case disabled
    case wakeListening
    case listening
    case processing
    case waitingForAgent
    case speaking
    case followUpListening
}
```

Avoid implementing this as multiple independent booleans.

## 27. Spike Questions

### Wake word

1. Which local wake-word engine works reliably on macOS arm64?
2. What is idle CPU usage?
3. What is memory usage?
4. How well does “Hey Relay” work through the intended headset?
5. How often does it false-trigger?
6. Does headset microphone quality materially affect detection?

### Audio lifecycle

1. Can wake detection hold the mic continuously without destabilizing Relay?
2. Does this force Bluetooth headsets into poor-quality call mode?
3. Can wake detection pause cleanly while full STT owns the mic?
4. How does reconnection behave?
5. What happens across sleep/wake?

### Utterance detection

1. Is silence timeout sufficient?
2. Is VAD necessary?
3. What silence threshold feels natural?
4. What hard maximum utterance duration is appropriate?

### Agent interaction

1. Can Relay reliably submit a prompt to a known Claude/Codex session without keyboard focus?
2. If not, what is the safest first version?
3. Should hands-free conversations bind to one session until dismissed?

### Conversation UX

1. What follow-up timeout feels natural?
2. Does “not now” reliably terminate conversation?
3. Is a tone preferable to spoken acknowledgements?
4. How should `stop` differ from `not now`?
5. Does contextual replay feel predictable?

## 28. Suggested Prototype Sequence

### Experiment 1 — Wake detector only

Throwaway process:

```text
open microphone
run wake detector
print WAKE when "Hey Relay" is detected
```

Measure:

- CPU
- memory
- false positives
- headset behavior
- 30–60 minute stability

No Relay integration yet.

### Experiment 2 — Wake → STT

```text
wake word
    ↓
pause wake engine
    ↓
capture utterance
    ↓
silence/VAD end
    ↓
transcribe with existing STTRouter
    ↓
print transcript
    ↓
resume wake engine
```

Verify audio ownership and device transitions.

### Experiment 3 — Local commands

Support only:

```text
stop
not now
repeat that
what was the last message
```

Verify intent matching without an LLM.

### Experiment 4 — Agent prompt

Route unrecognized utterances to one explicitly chosen test Claude session.

Validate:

```text
wake
ask
agent responds
Relay speaks response
```

### Experiment 5 — Follow-up conversation

After response:

```text
open 15-second follow-up window
```

Support:

```text
natural follow-up
not now
repeat that
```

Measure whether follow-up capture feels useful or intrusive.

## 29. Success Criteria

### Wake detection

- wake phrase works reliably through the intended headset
- low enough CPU to leave running continuously
- false positives are rare enough not to be annoying
- wake detector survives extended runtime

### Audio

- no repeated microphone failures
- Bluetooth/headset behavior is acceptable
- wake → STT → wake transitions are reliable
- disconnect/reconnect does not require Relay restart

### Conversation

- “Hey Relay” reliably starts a turn
- end-of-utterance feels natural
- “not now” reliably ends conversational mode
- “repeat that” reliably replays last spoken content
- “what was that last message?” behaves predictably
- follow-up window is useful rather than intrusive

### Isolation

- Hands-Free Mode can fail or be disabled without affecting existing hotkey dictation
- no transcripts/audio are persisted
- uncertain agent targeting never sends to the wrong session

## 30. Go / No-Go Decision

### GO

Proceed to a full design and implementation plan if:

- wake detection is stable and lightweight
- continuous microphone ownership is acceptable with the preferred headset
- wake/full-STT handoff is reliable
- session targeting has a safe strategy
- conversational controls feel predictable
- no significant regression occurs in existing Relay functionality

### CONDITIONAL GO

Proceed with a reduced feature if wake-word interaction works but either Bluetooth mic behavior or remote agent prompt injection is unreliable.

Possible reduced first version:

```text
Hey Relay
    ↓
local commands
+
wake-triggered dictation into currently focused app
+
replay / TTS controls
```

True agent-conversation routing can come later.

### NO-GO

Do not implement full Hands-Free Mode if:

- continuous wake detection causes unacceptable CPU/power use
- headset audio remains degraded while wake detection owns the mic
- microphone handoff is unreliable
- wake false positives are frequent
- the feature destabilizes core dictation
- safe agent targeting cannot be established

The existing hotkey experience remains the primary interface in that case.

## 31. Recommendation

The concept is worth prototyping.

It fits Relay's architecture well because most of the expensive components already exist:

- microphone capture
- STT
- TTS
- replay
- agent responses
- session intelligence
- local-first privacy model

The genuinely new technical risks are concentrated in:

1. always-on wake-word detection
2. long-lived microphone/headset behavior
3. end-of-utterance detection
4. hands-free agent session targeting
5. conversation state management

Do **not** begin by deeply integrating a wake-word library into Relay.

Start with a disposable wake-word/audio experiment, validate the headset experience, and only then design the production Hands-Free subsystem.
