# Live pipeline Diagnostics — design

Date: 2026-11-06

## Intent

Darius opens Diagnostics while he dictates or while an agent reply comes in, to see what Relay is
doing. Today's window (screenshot in the brainstorm, 2026-11-06) is "not very human friendly":
two flat logs of raw event names ("envelope-decoded", "session-upserted"), newest first, several
lines per run, mixed together. Dictation does not show as a story at all. The agent log updates
only on Refresh. Permissions take the top third of the window even when all are granted.

He wants to see the seams: **where in the pipeline a run is now, and the live status of the step
it is in.** He does not need to see the transcript or the reply text.

Success: with the window open, he presses the dictation hotkey and watches the run move through
its steps live. When a run stops early, he sees which step stopped it and why, in plain words.

## Goals

- Follow three flows live: **Dictation**, **Agent replies**, **Read aloud**. A toggle per flow
  chooses which flows the window shows. Any combination, all on by default. A flow that is off
  is hidden from the graph and the list, but Relay still records its runs, so turning it back on
  shows them. (Design author's call.)
- A **big graph** of one run: the live run by default. Steps are nodes with arrows. Done steps
  are green, the current step pulses, a step that stopped the run is red with a plain reason, and
  steps not reached are grey. Branches show where the flow can split (see "Flows").
- The **current step shows its live status**, not only "active". Examples:
  "Recording · 2.4 s · level ▮▮▮▯", "Transcribing with Parakeet · 0.6 s", "Loading model…",
  "Speaking with Kokoro · 0:07".
- A **run list** under the graph: one compact row per run, newest first. Each step is a small
  pill with its detail ("Mic open · built-in", "Recorded 3.2 s", "Pasted"). A click on a row
  shows that run in the graph. A new live run takes the graph back, unless the user selected an
  older run less than 10 s ago (builder's call on the exact rule; the user must not lose a run
  they are reading).
- **Permissions collapse** to one status in the top bar: "All permissions OK" when every grant is
  in place. When one is missing, it turns red and opens the existing permission list and buttons.
  "OK" means: global hotkeys effective (Accessibility or Input Monitoring), the event tap
  registered, Microphone granted. Input Monitoring alone stays optional and never turns the
  status red. The list adds the Microphone grant, which today's panel does not show. (Design
  author's call.)

**Mockup:** `docs/superpowers/specs/assets/2026-11-06-live-pipeline-diagnostics-mockup.html`,
option 1 (Darius picked it: "the big one 1"). Option 2 in that file was rejected.

## Non-goals

- Transcript text, interim text, or agent reply text in Diagnostics. The current privacy rule
  stays: counts, durations, backend and device names, reason labels only.
- Persistence across launches. Runs live in memory only.
- Export or sharing of runs beyond the existing Copy.
- Changes to the floating activity overlay.

## Anti-goals

- Raw internal event names as the main view. They may stay in a collapsed raw section, never as
  the thing the user reads first.
- A view that needs a Refresh button to be current.
- Diagnostics work that slows the pipeline it watches (for example, a mic level update on every
  audio buffer reaching SwiftUI).

## Flows and steps

These are the steps the graph shows. Names are the user-facing labels. The builder may merge or
split a step when the code has no clean seam for it, and records that call.

**Dictation**
hotkey → mic open (device name, "built-in" or "fallback to default") → recording (live seconds
and level) → transcribe (backend, live seconds; "loading model" when it loads) → clean up
(fillers removed count) → insert (paste or accessibility) → mic released (the 1 s release check
from the call-safe mic work: "released" or red "still open").
Branches: transcribe falls back to the next backend in order (for example Parakeet → Whisper →
Apple Speech); a short tap or no speech ends the run early ("No speech", grey-red); cancel ends
it ("Cancelled").

**Agent reply**
received (provider, size) → session found (Rex / tmux / herdr / terminal) → focus check
(focused / not focused / last active) → auto-read check → speak (voice backend, live time) →
done.
Branches: auto-read off → stop "Not spoken: auto-read is off"; not focused and not last active
→ stop "Not spoken: another session has focus"; speak failed or cancelled.
A `UserPromptSubmit` prompt is not a run. It may show as a one-line note in the list (builder's
call).

**Read aloud** (design author's call: one flow for every manual speak action)
trigger (Read selection, Replay last, or Speak latest agent reply) → text source (selection via
accessibility or clipboard, character count; or "last spoken"; or "latest reply") → voice
(backend) → speaking (live time) → done.
Branches: no selection → stop "Nothing selected"; nothing to replay → stop; TTS backend
fallback; stopped by the user. Voice previews from Settings are not runs.

**Graph shape (answers the builder check).** Each flow has a fixed graph: every step and every
branch node is always drawn, in the same place. A run only sets the state of the nodes it
reached; nodes it never reached stay grey, and a branch it did not take stays grey and dashed.
So the store holds, per run, a state per known step of that flow, not a free-growing list. The
pill row for a run shows only the steps the run reached.

## Architecture: lifecycle events (Darius's decision, 2026-11-06)

"Each module / step announces when it starts, finishes and status updates, and the diagnostics
just listens and renders."

- **Event.** `PipelineEvent { runID, flow, step, phase, at }`. Phase is the step's lifecycle:
  `started(detail)`, `updated(detail)`, `level(Float)`, `finished(detail)`, `stopped(reason)`,
  `failed(reason)`. Details and reasons are short plain-language labels; never transcript or
  reply text.
- **Bus.** One `PipelineEventBus` in the runtime. `emit` is non-blocking and safe from any
  thread or actor. Subscribers get an `AsyncStream`.
- **Announcers.** The module that owns a step emits its lifecycle, through a small
  `PipelineTracer` (run context + bus) that the run's owner creates and hands down:
  - Dictation: `DictationCoordinator` owns the run (hotkey, clean up, insert);
    `MicrophoneCapture` (recording, level); `AVAudioEngineSource` (mic open with the device
    name, mic released through the release check); `STTRouter` (transcribe, fallback).
  - Agent reply: `AgentAutoReadCoordinator` owns the run (received, session, auto-read, focus);
    `SpeechCoordinator` (speak).
  - Read aloud: `SpeechActions` owns the run (trigger, source); `SpeechCoordinator` (speak).
  - The tracer travels with the call (`SpeechRequest` carries it for speech).
- **Listener.** `PipelineRunStore` (`@MainActor @Observable`) subscribes at app start and folds
  events into runs with a pure reducer. Diagnostics renders the store. It holds no pipeline
  logic. The raw stream also feeds the "Raw events" lines.

## Data and live updates

- One in-memory store of runs, observed by the view. Each run has a flow, a start time, and a
  state for each step of its flow's fixed graph (pending, active, done, stopped, failed), with a
  short detail and its timing. The store keeps the last 50 runs **per flow** (oldest dropped), so
  many silent agent replies never push out dictation runs.
- Producers report into the store at the seams that already exist:
  - Dictation: `DictationCoordinator` already reports every phase to `DictationActivityPublishing`
    (begin, listen, level, backend name, process, complete, cancel, fail). Diagnostics follows the
    same calls. The mic release check reports through the existing
    `MicrophoneReleaseMonitor` callback.
  - Agent replies: `IntegrationManager` and `AgentAutoReadCoordinator` already append each stage
    to `IntegrationDiagnosticsLog`. The new store needs a run identity that ties one reply's
    stages together, from the receiver through the speech it starts.
  - Read aloud and speech: `SpeechActions` / `SpeechCoordinator` / `TTSRouter`. The speak
    step of an agent reply also reports from here.
- Live values (mic level, elapsed seconds) update the view at most about 10 times a second.
- All producers run in different isolation domains today (actors, MainActor, socket threads). The
  store must accept reports from all of them without blocking the audio or socket threads.

## Window layout

Top to bottom: top bar (flow toggles, permission status) → big graph of the selected run → run
list → a collapsed "Raw events" section that holds today's two logs, the hotkey counters, and
Copy/Clear, for bug reports. (Design author's call: the raw logs are the proven tool for
debugging the hook socket, so they stay, but out of the way.)

## Left to the builder

- The exact graph drawing (SwiftUI shapes or Canvas), node sizes, and colors, within the look
  of mockup option 1: dark nodes, green done, blue pulsing active, red stop, grey pending, dashed
  arrow for a fallback branch.
- How the run identity for agent replies is carried.
- Whether the old `DiagnosticsRecorder` event list is replaced or fed into the raw section.
- The rule that decides when a new live run takes over the graph from a selected older run.
