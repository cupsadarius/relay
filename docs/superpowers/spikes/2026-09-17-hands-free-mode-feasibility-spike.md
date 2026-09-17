# Relay Hands-Free Mode — Feasibility Spike v2

**Date:** 2026-09-17  
**Status:** Revised after architecture review  
**Product:** Relay  
**Scope:** Hands-free wake-word interaction with Relay, Claude Code, and Codex  
**Intent:** Prove the two hard feasibility gates before any production integration.

---

## 1. Verdict

**Concept:** Sound.  
**Architecture fit:** Good.  
**Recommended decision today:** **CONDITIONAL GO**.

Relay already has most of the speech and response infrastructure needed:

- `STTRouter`
- `SpeechCoordinator`
- `TTSRouter`
- `AgentSessionRegistry`
- focus resolvers
- latest-response / replay machinery
- local-first privacy behavior

The hands-free feature should reuse those components rather than create a second speech stack.

Two questions gate a full GO:

1. **Can Relay inject a prompt into a known Claude Code / Codex session without keyboard focus?**
2. **Can an always-listening headset microphone coexist with acceptable Bluetooth playback quality?**

Until both are proven, full roaming agent conversation remains conditional.

---

# 2. Primary Scenario

The target experience is:

```text
Mac running Relay at desk
        │
        ├── headset worn around the house
        │
        ├── lightweight local wake detector
        │
        ├── Claude Code / Codex session
        │
        └── Relay TTS → headset

User:
"Hey Relay, ask Claude why the tests are failing."

Relay:
[wake acknowledged]

Relay submits the prompt to a known agent session.

Claude responds.

Relay speaks the response.

Relay opens a short follow-up window.

User:
"Explain that more simply."

Relay routes the follow-up to the same bound session.

User:
"Not now."

Relay closes the conversation and returns to wake-only mode.
```

Later:

```text
"Hey Relay, what was that last message?"
```

Relay replays the latest relevant response locally.

---

# 3. Non-Negotiable Design Rules

1. Hands-Free Mode is **optional**.
2. Existing hotkey Relay continues working unchanged.
3. Full STT does **not** continuously transcribe the room.
4. Only the wake detector runs while dormant.
5. Basic Relay commands are handled locally and deterministically.
6. Unknown agent target means **do not send**.
7. A hands-free agent conversation binds to one session until ended.
8. Optional hands-free behavior may fail without breaking normal Relay.
9. Every external operation remains bounded by timeout/deadline.
10. Audio and transcripts remain ephemeral.

---

# 4. The Two Full-GO Gates

## Gate A — Headless Agent Prompt Injection

### Problem

Relay's current coding-agent integration is fundamentally a **receive path**:

```text
Claude / Codex
      │
      │ hook response
      ▼
RelayHook
      │
      ▼
Unix socket
      │
      ▼
Relay
```

Hands-Free Mode additionally needs:

```text
Relay
   │
   │ prompt
   ▼
known Claude / Codex session
```

That path is not yet proven.

Synthetic typing is insufficient for the intended experience because it generally depends on a focused terminal/app. If the user is walking around the house, terminal focus is not a reliable targeting mechanism.

### Proof required

Demonstrate:

```text
known provider session
+
terminal not frontmost
+
no synthetic keyboard focus dependency
        ↓
submit prompt
        ↓
correct existing agent session receives prompt
```

### Full-GO requirement

A safe session-specific input mechanism exists for at least the primary target agent.

### If this fails

Use the reduced hands-free version:

```text
wake commands
replay / TTS controls
wake-triggered dictation into focused app
```

Full remote Claude/Codex conversation waits for a proper input channel.

---

## Gate B — Bluetooth Headset Mic + Playback

### Problem

A Bluetooth headset may switch to a bidirectional/call audio profile when its microphone is continuously active.

Potential result:

```text
wake detector holds headset mic
        ↓
headset switches audio profile
        ↓
Relay TTS playback quality drops
```

This directly conflicts with the roaming-headset use case.

### Proof required

Test the real preferred headset with:

1. output only
2. microphone opened continuously
3. wake detector running continuously
4. TTS while wake detector still owns input
5. wake → STT → TTS → wake transitions

Observe:

- playback quality
- latency
- device/profile transitions
- reconnect behavior
- stability over 30–60 minutes

### Full-GO requirement

Always-on wake listening must coexist with acceptable spoken-response quality.

### If this fails

Possible alternatives:

- separate input/output devices
- external dedicated wake microphone
- Mac microphone for wake detection when physically viable
- non-continuous wake strategy
- reduced feature scope

The spike must not assume one of these is acceptable without testing.

---

# 5. Wake Detector Gate

The wake detector is the third important feasibility question, but it is subordinate to the two gates above.

Candidates can include:

- open-source ONNX keyword spotting
- commercial/custom wake-word engines
- a custom keyword classifier

The production architecture must keep the wake engine replaceable.

Conceptual interface:

```swift
protocol WakeWordDetecting {
    func start() async throws
    func stop()
    var events: AsyncStream<WakeWordEvent> { get }
}
```

For the spike, pick **one** engine and test it thoroughly. Do not build a provider abstraction first.

---

# 6. Experiment 1 Success Budget

The standalone wake-word experiment should have explicit provisional targets.

These are spike targets, not final product SLOs.

## Reliability target

In ordinary household conditions:

```text
False activations:
≤ 1 per 8 hours of idle listening
```

## Detection target

Across a small scripted test set at expected use distance:

```text
Wake detection:
≥ 90% successful detections
```

Test at minimum:

- quiet room
- music/TV in background
- normal conversation nearby
- different user orientation relative to mic
- expected walking-around distance
- headset microphone
- normal speaking volume

## Runtime target

```text
continuous run:
30–60 minutes minimum
```

No:

- crash
- runaway memory
- steadily increasing CPU
- lost microphone
- required restart

Record:

- average idle CPU
- peak CPU during detection
- memory footprint
- false activations
- missed activations

---

# 7. Hands-Free State Machine

Hands-Free Mode should have one explicit state.

```swift
enum HandsFreeState {
    case disabled
    case wakeListening
    case listening
    case resolvingIntent
    case waitingForAgent
    case speaking
    case followUpListening
}
```

Conceptual transitions:

```text
disabled
   │ enable
   ▼
wakeListening
   │ "Hey Relay"
   ▼
listening
   │ end-of-utterance
   ▼
resolvingIntent
   │
   ├── local command ───────────────┐
   │                               │
   └── agent prompt                │
           │                       │
           ▼                       │
    waitingForAgent                │
           │                       │
           ▼                       │
        speaking ◄─────────────────┘
           │
           ▼
   followUpListening
      │          │
 speech      timeout /
      │       "not now"
      ▼          ▼
resolving   wakeListening
```

Do not model this as a collection of independent booleans.

---

# 8. End-of-Utterance Ownership

End-of-utterance detection is active **only while Relay is accepting user speech**.

Enabled in:

```text
listening
followUpListening
```

Disabled in:

```text
wakeListening
resolvingIntent
waitingForAgent
speaking
disabled
```

This prevents silence timers/VAD from firing while Relay is waiting for an agent or playing speech.

Suggested spike implementation:

```text
voice activity / energy detection
+
700–1200 ms trailing silence
+
hard maximum utterance duration
```

Exact thresholds should be tuned experimentally.

---

# 9. Local Intent Layer

Not every utterance goes to Claude/Codex.

Suggested deterministic intents:

```swift
enum HandsFreeIntent {
    case replayLastSpoken
    case replayLatestAgentMessage
    case endConversation
    case cancelCurrentInput
    case agentPrompt(String)
}
```

Examples:

```text
"repeat that"
"say that again"
"what was that last message?"
"not now"
"go quiet"
"cancel"
```

These should not require an LLM.

---

# 10. Clarified Stop / Barge-In Scope

The original spike implied that Relay could hear:

> "Stop talking"

while TTS was currently playing.

That is **not part of the initial spike**.

## Why

During `speaking`, the initial design does not keep full STT listening.

Listening while Relay itself is producing audio introduces:

- echo from Relay's own TTS
- user/TTS source separation
- acoustic echo cancellation requirements
- false command recognition
- more complex microphone ownership

## v0 behavior

During `speaking`:

```text
full STT listener = off
```

Therefore spoken:

```text
"stop"
"stop talking"
```

is not guaranteed to work mid-response.

The existing keyboard/UI Stop remains available when near the Mac.

## Future barge-in

A later barge-in design may allow:

```text
user speaks during TTS
    ↓
AEC / robust detection
    ↓
stop TTS
    ↓
capture user turn
```

That is a separate follow-up spike.

Do not let barge-in complexity block the core wake/conversation experiment.

---

# 11. "Not Now"

This is a first-class local Relay command.

Meaning:

```text
end follow-up listening
clear bound hands-free agent session
return to wakeListening
require "Hey Relay" for the next turn
```

It is primarily valid during:

```text
listening
followUpListening
```

It should never be forwarded as an ordinary Claude/Codex prompt when recognized as the local command.

Optional acknowledgement:

```text
short tone
```

Prefer a tone over verbose synthesized confirmation.

---

# 12. Replay Commands

## "Repeat that"

Meaning:

```text
replay the last text Relay successfully spoke
```

## "What was that last message?"

Suggested resolution:

```text
1. bound conversation session's latest agent response
2. latest relevant agent response
3. last spoken text
4. nothing available → short local acknowledgement
```

This remains local. It does not contact the agent.

---

# 13. Bound Conversation Session

If full prompt injection is feasible, a roaming conversation should bind to one known session.

Conceptual state:

```swift
struct HandsFreeConversation {
    let sessionID: AgentSessionID
    let startedAt: Date
    var lastActivityAt: Date
}
```

Lifecycle:

```text
initial hands-free agent prompt
        ↓
resolve one safe target
        ↓
bind
        ↓
all follow-ups → same session
        ↓
"not now" / timeout / failure
        ↓
clear binding
```

Do not re-run generic focus resolution for every follow-up.

The user's Mac focus may legitimately change while the conversation continues.

---

# 14. Session Targeting Rules

Initial agent turn:

```text
1. explicitly bound/selected agent, if one exists
2. confidently focused agent session
3. otherwise refuse to guess
```

After binding:

```text
all follow-ups → bound session
```

If that session disappears:

```text
end conversation
return to wakeListening
surface short failure
```

Do not silently switch to another agent.

---

# 15. Audio Input Ownership

Hands-Free Mode should not introduce a second independent microphone owner.

Preferred future shape:

```text
AudioInputCoordinator
        │
        ├── WakeWordDetector
        └── Dictation / STT capture
```

Transition:

```text
wakeListening
    ↓
wake detected
    ↓
suspend wake consumer
    ↓
full utterance capture
    ↓
capture ends
    ↓
resume wake consumer
```

This is real production work because Relay's existing `MicrophoneCapture` lifecycle must remain reliable.

The spike should prove the audio transitions before restructuring production code.

---

# 16. Privacy

## Wake mode

```text
local wake-word inference only
audio not persisted
no transcript
```

## Post-wake

```text
full local STT
audio discarded after use
transcript ephemeral
```

## Agent responses

```text
ephemeral
not written to transcript history
```

Diagnostics may record only structural metadata:

- wake detected
- state transition
- agent target resolved/not resolved
- timeout category
- error category

Never:

- room audio
- transcript text
- response content

---

# 17. UI / Settings — Future Only

Hands-Free Mode is opt-in.

Likely eventual settings:

```text
Hands-Free Mode
[ ] Enable

Wake phrase:
    Hey Relay

Input device:
    Automatic / selected device

Follow-up listening:
    [x] Enabled

Follow-up timeout:
    15 seconds

Agent targeting:
    Focused / bound conversation

Wake sensitivity:
    Normal

Audio feedback:
    [x] Wake tone
    [x] Sleep tone
```

Do not build this UI during the spike.

---

# 18. Failure Policy

## Wake engine fails

```text
Hands-Free Mode unavailable
normal Relay remains functional
```

## Microphone fails

```text
exit active voice state
attempt safe recovery
normal hotkey behavior remains independent
```

## Agent target unknown

```text
do not guess
```

Possible response:

> "I don't have an active agent session."

## Bound agent disappears

```text
end hands-free conversation
clear binding
return to wakeListening
```

## Prompt injection fails

```text
bounded failure
clear waiting state
do not remain stuck
```

## TTS fails

```text
clear speaking state
return to follow-up or wakeListening according to conversation policy
```

---

# 19. Three Experiments Before Any Relay Integration

These are the first milestone.

No production Relay code should be modified until the three questions have answers.

---

## Experiment A — Standalone Wake Detector

Throwaway process:

```text
open microphone
run one chosen wake detector
print WAKE on "Hey Relay"
```

Measure:

- CPU
- memory
- detection rate
- false positives
- 30–60 min stability

Success target:

```text
≥90% test detection
≤1 false activation / 8 idle hours target
acceptable idle CPU
stable microphone
```

---

## Experiment B — Bluetooth Audio Profile Test

No agent integration required.

Test:

```text
headset output only
        ↓
open headset mic continuously
        ↓
play high-quality TTS/audio
        ↓
compare
```

Then test:

```text
wake detector active
    ↓
wake
    ↓
full STT
    ↓
TTS response
    ↓
wake listening resumes
```

Record:

- output quality
- Bluetooth profile behavior
- transition latency
- reconnect behavior
- whether continuous mic ownership is acceptable

This experiment directly decides Gate B.

---

## Experiment C — Headless Prompt Injection Proof

No wake word required.

Goal:

```text
known Claude/Codex session
terminal not focused
    ↓
Relay test harness submits:
"reply with HANDSFREE-PROBE"
    ↓
that exact existing session receives prompt
    ↓
normal Relay receive path observes response
```

Constraints:

- no synthetic keyboard focus
- no frontmost terminal requirement
- target session must be explicit
- operation must be bounded
- failure must not disturb the agent

This experiment directly decides Gate A.

---

# 20. Decision Matrix

## Full GO

Proceed to a production Hands-Free design if:

```text
Wake detector       PASS
Bluetooth audio     PASS
Prompt injection    PASS
```

Then build:

```text
Hey Relay
→ local command or bound agent prompt
→ spoken response
→ follow-up window
→ Not now
```

---

## Conditional GO

Likely initial outcome if:

```text
Wake detector       PASS
Bluetooth audio     PASS
Prompt injection    FAIL / unproven
```

Ship/design only:

```text
wake-triggered local Relay controls
replay last response
read/replay speech
wake-triggered dictation into current focused app
```

Do not pretend full roaming Claude conversation exists.

---

## Alternative Conditional GO

If:

```text
Wake detector       PASS
Prompt injection    PASS
Bluetooth audio     FAIL
```

Investigate a separate-input-device design before production integration.

---

## No-Go

Stop if the preferred real-world setup cannot satisfy:

- stable wake detection
- acceptable audio behavior
- reliable microphone lifecycle

The existing hotkey workflow remains Relay's primary interface.

---

# 21. Follow-Up Spike: Barge-In

Only after the base hands-free loop works.

Question:

> Can Relay safely hear the user while Relay itself is speaking?

Needed for:

```text
"stop"
"wait"
"no"
```

during TTS.

Likely concerns:

- acoustic echo cancellation
- headset sidetone/loopback
- VAD against playback
- false wake/commands from Relay's own voice
- output cancellation latency

This is intentionally out of scope for the initial feasibility gate.

---

# 22. Recommended Order

```text
1. Standalone wake detector
         │
2. Bluetooth mic/output test
         │
3. Headless agent prompt injection proof
         │
         ▼
       DECIDE
     /        \
FULL GO   CONDITIONAL GO
   │             │
design full     local commands +
conversation    focused-app dictation
```

The prompt-injection proof can be investigated in parallel with the audio experiments because the problems are independent.

---

# 23. Final Recommendation

Do not integrate a wake-word library into Relay yet.

First prove:

1. **Wake detection is cheap and stable.**
2. **The preferred headset remains pleasant to listen through while wake detection is active.**
3. **Relay can send a prompt into a known coding-agent session without relying on GUI focus.**

Those three probes determine the viable product.

The most likely safe fallback remains:

> **Hands-free local Relay controls + replay + wake-triggered dictation**, with full roaming Claude/Codex conversations added only after session-specific prompt injection is proven.

The existing hotkey experience remains untouched throughout the spike.
