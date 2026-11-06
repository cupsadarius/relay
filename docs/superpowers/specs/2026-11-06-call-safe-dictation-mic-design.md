# Call-safe dictation microphone — design

Date: 2026-11-06

## Intent

Darius uses Bluetooth headphones in calls. When any app opens the headphone mic, macOS switches
the headphones from listen-only mode (A2DP, good stereo sound) to headset mode (HFP, phone-call
quality). Today Relay causes this switch in two ways:

1. Dictation always records from the system default input, and with the headphones connected the
   default input is the headphone mic.
2. Sometimes Relay does not let go of the mic after dictation ends. The macOS orange mic dot in
   the menu bar stays on with nothing dictating, and call sound stays bad until he quits Relay.

He quits Relay before most calls today. Success: he keeps Relay running during calls, dictates
from the Mac's built-in mic, and the headphones never leave listen-only mode because of Relay.

Prior art: Hex has a mic choice saved by CoreAudio device UID. A missing device falls back to the
default with a note ("AirPods Pro isn't connected. Using MacBook Pro Microphone."). Hex opens the
mic only on key press.

## Goals

- A "Microphone" picker for dictation: "System default" plus each connected input device.
- Dictation records from the chosen device. The system default input is not changed.
- The mic opens only while dictation records (unchanged), and always closes after it.
- Relay detects and reports a mic that stays open after dictation ends.
- Remove the most likely cause of the leak now. The detector then confirms the fix in daily use.

## Non-goals

- Automatic switch to the built-in mic when Bluetooth headphones connect. The user picks once.
- Changes to text-to-speech playback or its output device.
- Crashes or other failures during calls. Darius confirmed that the stuck mic and bad sound are
  the problem. Crashes come later, only when they still happen.
- A pre-roll buffer or a warm mic (Hex's 450 ms pre-roll). It needs an open mic, which is the
  opposite of this goal.

## Anti-goals

- Relay changes the system default input device. That changes every other app, the call app too.
- A fix that hides the orange dot without closing the input (for example, a guard that only
  resets UI state).
- A chosen device that is missing makes dictation fail. It must fall back to the default.

## Part 1 — Microphone picker

**Settings.** `AppSettings` gets one optional field, the chosen input device: a small struct
with its UID (`kAudioDevicePropertyDeviceUID`) and its name at the time the user picked it. The
name lets the picker label a missing device after a restart. `nil` means "System default". Decode
stays lossy, as for the other fields: a missing or bad value decodes to `nil`. (Design author's
call, after the builder check.)

**UI.** Settings › Dictation gets a "Microphone" picker in the "Dictation" section, under "Mode".
Entries: "System default", then each connected input device by name, in CoreAudio order. When
the saved UID is not connected, the picker shows it as "<last known name> (not connected)" and a
caption says that Relay uses the system default. The list refreshes when the view appears.
Builder's call: also refresh on a CoreAudio device-list change, if it stays a few lines.

**Device enumeration.** CoreAudio: `kAudioHardwarePropertyDevices`, keep devices with input
streams (`kAudioDevicePropertyStreams`, input scope), read the UID and name. A small pure type
resolves `(saved UID, connected devices, default device) -> device to use + optional note`. That
type gets unit tests. The CoreAudio calls stay a thin wrapper around it.

**Capture.** `AVAudioEngineSource.start()` resolves the device each time it starts. When the
chosen device is connected, it sets `kAudioOutputUnitProperty_CurrentDevice` on
`engine.inputNode.audioUnit` before it reads the input format and installs the tap. When the
device is not connected, it uses the default. The note goes to Diagnostics.

Part 2 gives every dictation a fresh engine, so the device is set once per engine.

## Part 2 — Mic leak

**Detect first.** After every capture stop (stop, cancel, and failure teardown), Relay checks
whether its own process still runs audio input. API (macOS 14+, target is 26.0):
`kAudioHardwarePropertyTranslatePIDToProcessObject` for the Relay PID, then
`kAudioProcessPropertyIsRunningInput` on that process object. Check once right after teardown
and once about 1 s later. When input still runs, record a Diagnostics event "Microphone still
open after dictation stopped" with the stop path (stop, cancel, failure). No audio, no text.

**Reproduce.** With Bluetooth headphones connected and the system default input on the headphone
mic, run these cases and watch the orange dot and the new event:

- normal hold-to-talk and toggle dictations;
- a short tap (start and stop under 300 ms);
- a cancel during start, and a cancel while it records;
- live transcription on and off;
- a headset-mode switch during a dictation (the A2DP → HFP switch changes the input format and
  sends `AVAudioEngineConfigurationChange`);
- headphones disconnected during a dictation.

**Suspects (guesses, not proven):**

- `fail()` after a route change queues teardown on `engineQueue`, and `MicrophoneCapture` moves
  to `failedRecording`. A later path may not reach `tearDownEngine()`, or the system restarts the
  engine after the configuration change while `tapInstalled` is already `false`.
- The long-lived `AVAudioEngine` keeps the input unit initialized after `stop()`. Fix candidate:
  `engine.reset()`, or a fresh engine per session.
- A `DictationCoordinator` path where the capture never reaches `stop()` or `cancel()`.

**Fix (Darius's decision).** The reproduction needs Darius, real Bluetooth headphones and the
hotkey, and the leak is intermittent. So the fix does not wait for a reproduction:

- Use a fresh `AVAudioEngine` for every dictation. Release it fully on every stop path (stop,
  cancel, failure teardown after a route change). This removes the long-lived engine, which is
  the most likely place for input to stay open. It also makes the Part 1 device choice simple:
  set `CurrentDevice` on the new engine's input unit before first use.
- Keep the existing threading rules of `AVAudioEngineSource` (gate, `engineQueue`, no teardown
  from inside the tap).
- Any path the builder finds by reading that can skip teardown gets a test that fails first.
- The detector stays in the app as a permanent check. When it reports the leak after this
  change, that is a new bug with a known stop path, and it gets its own fix.

The reproduction list above stays as a manual test round for Darius after the build. It does not
block the build.

## Order

1. Detector (Part 2 "Detect first"). It is small and gives proof for everything after it.
2. Fresh engine per dictation, with full release on every stop path.
3. Mic picker (Part 1).

The picker alone removes most of the call problem. The leak fix makes Relay safe also when the
user keeps "System default".

## Left to the builder

- The exact Diagnostics event names and text.
- Whether the picker list also refreshes on a device-list change.
- Hidden, virtual and aggregate devices in the picker list.
- How the 1 s detector check avoids a false report when a new dictation starts in that second.
