# Relay Activity Overlay Design

**Date:** 2026-09-14
**Status:** Approved for implementation planning

## 1. Purpose

Relay will display a compact, Whispr Flow-style activity overlay while dictation or text-to-speech is active. The overlay provides immediate confirmation that Relay is listening, processing, or speaking without requiring the menu-bar menu, Settings, or Diagnostics to be visible.

The overlay is a presentation layer over typed Relay activity state. Speech backends, microphone capture, transcription, and text insertion remain independent from AppKit window mechanics.

## 2. User Experience

The overlay floats above other applications at the bottom center of the active display. It appears only while Relay is working or briefly reporting an error.

Users choose one of three persisted styles:

- **Off:** never show the activity overlay.
- **Minimal:** show a small animated capsule without text or controls.
- **Interactive:** show activity state, elapsed time, and one context-aware control.

Interactive is the default for new and migrated settings. Adding the preference must preserve existing voice, rate, hotkeys, backend order, dictation mode, and auto-read settings.

The Interactive control has one purpose per state:

- Listening: Cancel.
- Processing: Cancel.
- Speaking: Stop.

The overlay has no pause/resume control in this version.

## 3. Activity State Model

`ActivityOverlayModel` is the single `@MainActor` observable source of truth. Its public state is provider-neutral:

- `hidden`
- `listening(sessionID, startedAt, level)`
- `processing(sessionID, startedAt)`
- `speaking(sessionID, startedAt)`
- `error(sessionID, category, message)`

Each activity has a unique session ID. A state transition or completion callback applies only when its session ID matches the currently displayed activity. Late callbacks from stopped or superseded sessions cannot hide or mutate a newer overlay.

The state model exposes only sanitized presentation data. It never stores microphone samples, transcript text, selected text, clipboard contents, or speech request text.

## 4. State Producers and Flow

### 4.1 Text-to-speech

Text-to-speech backends expose typed playback lifecycle events through the existing backend/router/coordinator boundary:

- scheduled
- started
- finished
- cancelled
- failed

`AppleTTSBackend` adapts `AVSpeechSynthesizerDelegate` callbacks into those events. `SpeechCoordinator` maps the active playback session to overlay state and ignores stale lifecycle events.

The overlay enters `speaking` when playback actually starts. It hides after a matching finish or cancellation and enters a brief sanitized error state after a matching failure. Because Apple TTS exposes no playback amplitude, speaking uses a deterministic synthetic waveform rather than fabricated audio measurements.

### 4.2 Dictation

The Phase 1 dictation coordinator drives the same model:

```text
capture starts → listening
capture stops → processing
transcription/insertion succeeds → hidden
cancel → hidden
matching failure → error → hidden
```

Listening animation uses normalized microphone level measurements computed by the capture layer without retaining or exposing samples. Starting dictation stops active speech before publishing the dictation session.

### 4.3 Cancellation

The overlay delegates its single action to an activity-control interface. It does not call a concrete backend or microphone service directly. The controller cancels only the session represented by the current state.

## 5. Native Overlay Window

The overlay is hosted by a borderless, transparent, non-activating `NSPanel` managed by a dedicated overlay window controller.

The panel:

- floats above normal application windows but below system alerts;
- joins all Spaces and can appear above full-screen applications;
- does not appear in the Dock, window switcher, or normal window cycle;
- never becomes the key window or steals keyboard focus;
- accepts pointer interaction only for the Interactive mode's control;
- has no title bar, resizing, dragging, or persistence of window position.

When an activity begins, the controller chooses the active display and positions the panel 28 points above the bottom edge of that display's visible frame. It repositions for display configuration and visible-frame changes without jumping between displays merely because the pointer moves during an activity.

Target sizes are approximately:

- Minimal: 154 × 40 points.
- Interactive: 282 × 62 points.

The panel is created lazily, reused between activities, and ordered out while hidden.

## 6. Motion and Visual States

The overlay enters with a short fade and scale transition and exits with a short fade. It uses the approved dark translucent capsule, subtle border/shadow, and state-specific accent color.

- Listening: red activity indicator and waveform driven by microphone level.
- Processing: amber indeterminate breathing motion.
- Speaking: violet/cyan synthetic waveform.
- Error: temporarily expands to show a concise sanitized message, then dismisses automatically.

Completion has a short visual grace period to avoid flicker for fast operations. Errors remain visible long enough to read, approximately 2.5 seconds.

When Reduce Motion is enabled, scale and waveform motion are removed. State changes use opacity and color only.

## 7. Settings

`AppSettings` gains a provider-neutral overlay style value: `off`, `minimal`, or `interactive`.

Settings presents this as a compact segmented picker under an Activity Overlay section. Decoding settings written by earlier builds supplies `interactive` when the field is absent. The migration must not reset any other saved field.

## 8. Error Handling

Errors shown in the overlay are derived from stable categories rather than raw backend error strings when those strings might contain user content. Examples include:

- Microphone unavailable.
- Speech recognition unavailable.
- No usable audio.
- Speech playback failed.

An error timer carries the same session ID as the state. Its delayed dismissal cannot hide a newer activity.

If the overlay panel itself cannot be created or shown, speech and dictation continue normally and Diagnostics records a sanitized overlay failure.

## 9. Privacy and Accessibility

The overlay is entirely local. It creates no persistent activity history and sends no telemetry.

The state and diagnostics boundaries prohibit:

- audio or microphone sample payloads;
- selected text, clipboard contents, transcripts, or TTS request text;
- arbitrary backend error text that could contain user content.

The Interactive control has an accessibility label reflecting its current action. State changes are exposed without repeatedly stealing VoiceOver focus. Reduce Motion is honored.

## 10. Verification

Automated verification covers:

- every activity-state transition and cancellation path;
- stale callback and delayed error-dismissal races;
- Apple TTS scheduled/start/finish/cancel/failure adaptation;
- dictation listening/processing/completion integration;
- persisted style values and migration from pre-overlay settings;
- display selection and visible-frame placement calculations;
- Minimal and Interactive presentation mapping;
- Reduce Motion presentation behavior;
- overlay failure isolation from speech and dictation.

Manual macOS acceptance covers:

- overlay visibility above ordinary and full-screen applications;
- behavior across Spaces and multiple displays;
- no keyboard-focus theft while dictating or listening;
- correct Cancel/Stop action;
- simultaneous use with Settings and Diagnostics windows;
- motion and appearance in both overlay styles;
- VoiceOver labeling and Reduce Motion behavior.

## 11. Delivery Sequence

1. Add the settings value, migration, state model, and state reducer tests.
2. Add the native panel controller, SwiftUI overlay content, placement logic, and presentation tests.
3. Add TTS lifecycle events and connect Apple TTS to the overlay.
4. Connect dictation lifecycle and microphone levels when the Phase 1 dictation coordinator is assembled.
5. Complete manual multi-app, full-screen, Space, display, accessibility, and motion acceptance.

