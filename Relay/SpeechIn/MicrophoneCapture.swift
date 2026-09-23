import AVFoundation
import Foundation
import os

protocol MicrophoneCapturing: Sendable {
    /// `onLevel` receives only a normalized [0, 1] microphone level for each accepted sample
    /// batch; raw audio samples are never exposed through this callback.
    func start(onLevel: @escaping @Sendable (Float) -> Void) async throws
    func stop() async throws -> AudioInput
    /// Abandons an in-progress start/recording without producing an `AudioInput`. Returns the
    /// actor to `idle` without throwing; a no-op while already idle.
    func cancel() async
}

/// An optional extra capability a `MicrophoneCapturing` implementation can provide — a tap
/// on the same raw 16 kHz mono sample batches `MicrophoneCapture` already accumulates internally,
/// for best-effort live features (e.g. interim transcription) layered on top of dictation without
/// disturbing the existing accumulate+level path. Deliberately separate from `MicrophoneCapturing`
/// itself so existing fakes/tests aren't required to implement it; callers that want it probe for
/// it with `as? any MicrophoneSampleStreaming`.
protocol MicrophoneSampleStreaming: Sendable {
    /// Replaces the current observer (if any). Must be called before `start(onLevel:)` for the
    /// observer to see any samples from that recording session — samples are only ever forwarded
    /// to whichever observer was set when that particular `start(onLevel:)` call began.
    func setSampleObserver(_ observer: (@Sendable ([Float]) -> Void)?) async
}

protocol AudioCaptureSourcing: Sendable {
    /// `stop` does not return until no future sample callbacks can be accepted.
    func start(
        onSamples: @escaping @Sendable ([Float]) -> Void,
        onTerminalError: @escaping @Sendable (Error) async -> Void
    ) async throws
    func stop() async throws
}

/// Optional extra capability an `AudioCaptureSourcing` implementation can provide: the real input
/// device's sample rate (Hz), captured before any resampling to the fixed 16 kHz pipeline rate.
/// Deliberately separate from `AudioCaptureSourcing` itself so existing fakes/tests aren't
/// required to implement it; `MicrophoneCapture` probes for it with `as? any AudioInputFormatReporting`.
protocol AudioInputFormatReporting: Sendable {
    func currentInputSampleRate() -> Double
}

/// Privacy-safe metadata about one microphone capture attempt: counts, rate, and a timestamp
/// only — NEVER audio samples, transcript text, or file paths. Reported once per `stop()` call,
/// including the zero-frame case that goes on to throw `SpeechBackendError.noUsableAudio` (a
/// stale post-rebuild microphone grant), since that's the case worth surfacing most.
struct MicrophoneCaptureDiagnostics: Equatable, Sendable {
    let inputSampleRate: Double
    let frameCount: Int
    let capturedAt: Date
}

enum MicrophoneCaptureError: Error, Equatable, Sendable, LocalizedError {
    case alreadyRecording
    case notRecording
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRecording: "Microphone recording is already in progress."
        case .notRecording: "Microphone recording has not been started."
        case let .unavailable(reason): "Microphone capture is unavailable: \(reason)"
        }
    }
}

actor MicrophoneCapture: MicrophoneCapturing, MicrophoneSampleStreaming {

    private enum State {
        case idle
        case starting(UUID)
        case failedStarting(UUID, Error)
        case recording(UUID)
        case failedRecording(UUID, Error)
        case stopping(UUID)
    }

    private let permission: any MicrophonePermissionAuthorizing
    private let source: any AudioCaptureSourcing
    private let accumulator = AudioSampleAccumulator()
    private var state: State = .idle
    /// MicrophoneSampleStreaming: set by `setSampleObserver` before recording starts;
    /// read once into a local at the top of `start(onLevel:)` and captured by that call's own
    /// sample-batch closure, so a later `setSampleObserver` call mid-recording never changes who
    /// an already-running session's samples are forwarded to.
    private var sampleObserver: (@Sendable ([Float]) -> Void)?

    /// Set by `cancel()` while `.starting`; checked by `start()`'s own post-`source.start()`
    /// switch so the call that actually knows `source.start()` has returned is the one that
    /// tears the real source down — never `cancel()` itself, which would otherwise race a
    /// `source.start()` that hasn't finished installing yet.
    private var startCancelRequested = false
    /// Resumed once the actor reaches `idle`; lets `cancel()` wait out an in-flight
    /// `start()`/`stop()` instead of returning while the real source is still winding down.
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    /// Reports privacy-safe capture diagnostics once per `stop()` call. `@MainActor` closures
    /// (like the production one `AppModel` builds to forward into `DiagnosticsRecorder`) convert
    /// implicitly to this plain `@Sendable async` type — the hop happens at the call site (see
    /// `AppModel`'s own `autoReadEnabled` closure for the same pattern).
    private let onCaptureDiagnostics: (@Sendable (MicrophoneCaptureDiagnostics) async -> Void)?
    private let now: @Sendable () -> Date
    /// The real input device's sample rate for the in-progress/most recent recording, captured
    /// from `source` (via the optional `AudioInputFormatReporting` capability) once `start()`
    /// actually begins recording. Stays `0` when `source` doesn't implement that capability (e.g.
    /// every existing test fake that doesn't opt in), so `stop()` simply reports `0` in that case.
    private var lastInputSampleRate: Double = 0

    init(
        permission: any MicrophonePermissionAuthorizing = SystemMicrophonePermissionAuthorizer(),
        source: any AudioCaptureSourcing = AVAudioEngineSource(),
        onCaptureDiagnostics: (@Sendable (MicrophoneCaptureDiagnostics) async -> Void)? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.permission = permission
        self.source = source
        self.onCaptureDiagnostics = onCaptureDiagnostics
        self.now = now
    }

    func start(onLevel: @escaping @Sendable (Float) -> Void) async throws {
        guard case .idle = state else { throw MicrophoneCaptureError.alreadyRecording }
        let session = UUID()
        state = .starting(session)
        startCancelRequested = false
        guard await permission.requestPermission() else {
            transitionToIdle()
            throw SpeechBackendError.permissionDenied
        }

        accumulator.reset()
        // Captured once, here, on the actor: see `sampleObserver`'s doc comment for why this must
        // happen before `source.start()` rather than reading `sampleObserver` from inside the
        // (non-isolated, `@Sendable`) closure below.
        let sampleTap = sampleObserver
        do {
            try await source.start(
                onSamples: { [accumulator] samples in
                    accumulator.append(samples)
                    onLevel(AudioBufferUtilities.level(of: samples))
                    sampleTap?(samples)
                },
                onTerminalError: { [weak self] error in
                    await self?.sourceTerminated(error, session: session)
                }
            )
            switch state {
            case .starting(session) where !startCancelRequested:
                state = .recording(session)
                lastInputSampleRate = (source as? any AudioInputFormatReporting)?.currentInputSampleRate() ?? 0
            case let .failedStarting(failedSession, error) where failedSession == session:
                transitionToIdle()
                throw error
            case .starting(session):
                // `startCancelRequested` is true and the actor is still `.starting` — nobody
                // else has progressed past this frame, so it still owns the source and must
                // tear it down. `source.start()` has now definitely returned, so this is safe.
                try? await source.stop()
                accumulator.reset()
                transitionToIdle()
                return
            default:
                // The actor has already moved on (e.g. a newer session admitted after this one
                // was cancelled is now recording or further along). This stale frame owns
                // nothing anymore, so touching the source here would tear down whatever session
                // actually owns it now — do nothing.
                return
            }
        } catch {
            accumulator.reset()
            transitionToIdle()
            throw error
        }
    }

    func stop() async throws -> AudioInput {
        let session: UUID
        switch state {
        case let .recording(activeSession):
            session = activeSession
        case let .failedRecording(_, error):
            accumulator.reset()
            transitionToIdle()
            throw error
        default:
            throw MicrophoneCaptureError.notRecording
        }
        state = .stopping(session)

        do {
            // The source removes its tap before returning, so this drain includes every accepted callback.
            try await source.stop()
            transitionToIdle()
            let samples = accumulator.take()
            // Reported EVEN on the zero-frame path below (before the throw): that's the stale
            // post-rebuild microphone grant case the Security settings tab most wants visible.
            // Metadata only — counts, rate, timestamp — never the samples themselves.
            await onCaptureDiagnostics?(MicrophoneCaptureDiagnostics(
                inputSampleRate: lastInputSampleRate,
                frameCount: samples.count,
                capturedAt: now()
            ))
            guard !samples.isEmpty else { throw SpeechBackendError.noUsableAudio }
            return AudioInput(samples: samples, sampleRate: 16_000)
        } catch {
            accumulator.reset()
            transitionToIdle()
            throw error
        }
    }

    func cancel() async {
        switch state {
        case .idle:
            return
        case .starting:
            // `source.start()` is still in flight for this session; flag the cancellation and
            // wait for `start()`'s own post-completion switch to tear the source down exactly
            // once it's safe to do so (see the `default:` branch in `start()`).
            startCancelRequested = true
            await withCheckedContinuation { idleWaiters.append($0) }
        case let .recording(session):
            state = .stopping(session)
            try? await source.stop()
            accumulator.reset()
            transitionToIdle()
        case .stopping:
            // Another in-flight `stop()`/`cancel()` already owns driving the source to a halt;
            // wait for it to actually reach `idle` instead of returning early, so a caller can
            // rely on "no future sample callbacks" once `cancel()` itself returns.
            await withCheckedContinuation { idleWaiters.append($0) }
        case .failedStarting, .failedRecording:
            // The source already terminated on its own; just discard the pending error.
            accumulator.reset()
            transitionToIdle()
        }
    }

    /// The single place `state` is set back to `.idle`. Clears `startCancelRequested` and wakes
    /// every `cancel()` call currently waiting on `.starting`/`.stopping` to resolve.
    private func transitionToIdle() {
        state = .idle
        startCancelRequested = false
        let waiters = idleWaiters
        idleWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    // MicrophoneSampleStreaming conformance: see sampleObserver doc comment for the
    // ordering guarantee this relies on.
    func setSampleObserver(_ observer: (@Sendable ([Float]) -> Void)?) async {
        sampleObserver = observer
    }

    private func sourceTerminated(_ error: Error, session: UUID) {

        switch state {
        case let .starting(activeSession):
            guard activeSession == session else { return }
            accumulator.reset()
            state = .failedStarting(session, error)
        case let .recording(activeSession):
            guard activeSession == session else { return }
            accumulator.reset()
            state = .failedRecording(session, error)
        case .idle, .failedStarting, .failedRecording, .stopping:
            break
        }
    }
}

enum AudioConversionDisposition: Equatable {
    case appendOutput
    case awaitNextCallback
    case fail

    static func resolve(
        status: AVAudioConverterOutputStatus,
        hasConversionError: Bool,
        frameLength: AVAudioFrameCount
    ) -> Self {
        guard !hasConversionError else { return .fail }
        switch status {
        case .haveData, .inputRanDry:
            return frameLength > 0 ? .appendOutput : .awaitNextCallback
        case .error, .endOfStream:
            return .fail
        @unknown default:
            return .fail
        }
    }
}

private final class AudioSampleAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []

    func append(_ newSamples: [Float]) {
        lock.withLock { samples.append(contentsOf: newSamples) }
    }

    func reset() {
        lock.withLock { samples.removeAll(keepingCapacity: true) }
    }

    func take() -> [Float] {
        lock.withLock {
            defer { samples.removeAll(keepingCapacity: true) }
            return samples
        }
    }
}

/// Live microphone source. Threading rules:
/// - The tap callback only takes the gate briefly and delivers samples with no lock held.
/// - Every engine mutation (installTap, start, removeTap, stop) runs on `engineQueue`, which the
///   tap never runs on, so teardown there can wait for an in-flight callback without deadlocking.
/// - A failure seen on the tap thread (or on a route change) closes the gate and *queues* teardown
///   on `engineQueue`, because removing a tap from inside its own callback can deadlock. A later
///   `start()`/`stop()` goes through the same queue, so that teardown always runs before a newer
///   capture installs its tap.
private final class AVAudioEngineSource: AudioCaptureSourcing, AudioInputFormatReporting, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let gate = CaptureCallbackGate()
    private let engineQueue = DispatchQueue(label: "dev.relaymac.Relay.microphone-engine")
    private let notificationCenter: NotificationCenter

    private let stateLock = NSLock()
    /// The real input device rate captured in `start()`, before resampling to 16 kHz. Metadata
    /// for privacy-safe diagnostics only, and (paired with `installedInputChannelCount`) the
    /// baseline `AudioEngineRouteChangeDecision` compares a route-change notification against.
    private var inputSampleRate: Double = 0
    private var installedInputChannelCount: AVAudioChannelCount = 0
    private var terminalErrorHandler: (@Sendable (Error) async -> Void)?
    private var configurationObserver: AudioEngineConfigurationObserver?
    private let logger = Logger(subsystem: "dev.relaymac.Relay", category: "microphone")

    /// Only touched on `engineQueue`.
    private var tapInstalled = false

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
    }

    func currentInputSampleRate() -> Double {
        stateLock.withLock { inputSampleRate }
    }

    func start(
        onSamples: @escaping @Sendable ([Float]) -> Void,
        onTerminalError: @escaping @Sendable (Error) async -> Void
    ) async throws {
        try engineQueue.sync {
            guard !tapInstalled else { throw MicrophoneCaptureError.alreadyRecording }
            let input = engine.inputNode
            let inputFormat = input.inputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
                  let outputFormat = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: 16_000,
                    channels: 1,
                    interleaved: false
                  ),
                  let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
            else {
                throw MicrophoneCaptureError.unavailable("The current input format is unsupported.")
            }

            stateLock.withLock {
                inputSampleRate = inputFormat.sampleRate
                installedInputChannelCount = inputFormat.channelCount
                terminalErrorHandler = onTerminalError
            }
            gate.open()
            input.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) { [weak self] buffer, _ in
                self?.handleTap(buffer, converter: converter, outputFormat: outputFormat, onSamples: onSamples)
            }
            tapInstalled = true

            do {
                try engine.start()
            } catch {
                _ = gate.close()
                tearDownEngine()
                throw MicrophoneCaptureError.unavailable(error.localizedDescription)
            }
        }

        let observer = AudioEngineConfigurationObserver(engine: engine, center: notificationCenter) { [weak self] in
            guard let self else { return }
            // Bracket with the same gate the tap uses: if the gate is already closed (a `stop()`
            // in flight, or a previous failure already reported), this notification is stale for
            // the current -- or a since-superseded -- session and must not fail it.
            guard self.gate.enter() else { return }
            defer { self.gate.leave() }

            // Reads `engine` directly on whatever thread posted this notification, not on
            // `engineQueue`. Safe here because it is bracketed by the same gate the tap uses
            // (above): the gate is only open while a capture is actually running, and `stop()`
            // closes it and waits out any in-flight callback before tearing the engine down, so
            // this read cannot race a `tearDownEngine()` that has already started.
            let current = self.engine.inputNode.inputFormat(forBus: 0)
            let installed = self.stateLock.withLock { (self.inputSampleRate, self.installedInputChannelCount) }
            guard AudioEngineRouteChangeDecision.isDisruptive(
                isEngineRunning: self.engine.isRunning,
                installedSampleRate: installed.0,
                installedChannelCount: installed.1,
                currentSampleRate: current.sampleRate,
                currentChannelCount: current.channelCount
            ) else {
                // Ignore spurious posts where the engine keeps running with the same format:
                // AVFoundation stops the engine on a real route change, so this combination means
                // nothing downstream is actually broken. Failing here would end perfectly healthy
                // dictation sessions on every such spurious post.
                self.logger.debug("Ignoring a non-disruptive audio route change")
                return
            }
            self.fail(MicrophoneCaptureError.unavailable("The audio input device changed."))
        }
        stateLock.withLock { configurationObserver = observer }
    }

    /// Blocks its calling thread briefly, two ways: `gate.close()` waits out at most one
    /// in-flight tap callback (one 4096-frame conversion), and `engineQueue.sync` waits for
    /// `removeTap`/`engine.stop()`. Both are bounded and short. That is acceptable on the
    /// `MicrophoneCapture` actor's executor, and it is what upholds the `AudioCaptureSourcing.stop`
    /// contract that no samples arrive after it returns.
    func stop() async throws {
        let error = gate.close()
        let observer: AudioEngineConfigurationObserver? = stateLock.withLock {
            defer {
                configurationObserver = nil
                terminalErrorHandler = nil
            }
            return configurationObserver
        }
        withExtendedLifetime(observer) {}   // released here, outside the lock
        engineQueue.sync { tearDownEngine() }
        if let error { throw error }
    }

    /// `engineQueue` only.
    private func tearDownEngine() {
        guard tapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        tapInstalled = false
    }

    /// Tap thread.
    private func handleTap(
        _ buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        outputFormat: AVAudioFormat,
        onSamples: @Sendable ([Float]) -> Void
    ) {
        guard gate.enter() else { return }
        defer { gate.leave() }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            fail(MicrophoneCaptureError.unavailable("Unable to allocate an audio conversion buffer."))
            return
        }

        let result = AudioBufferUtilities.convert(buffer, into: output, using: converter)
        switch AudioConversionDisposition.resolve(
            status: result.status,
            hasConversionError: result.error != nil,
            frameLength: output.frameLength
        ) {
        case .appendOutput:
            break
        case .awaitNextCallback:
            return
        case .fail:
            fail(result.error ?? MicrophoneCaptureError.unavailable("Audio conversion failed with status \(result.status.rawValue)."))
            return
        }
        guard let channel = output.floatChannelData?[0] else {
            fail(MicrophoneCaptureError.unavailable("Converted audio has no float samples."))
            return
        }
        onSamples(Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength))))
    }

    /// Tap thread or notification thread. Reports the first failure once and queues teardown.
    /// Also drops `configurationObserver`/`terminalErrorHandler` right away: `stop()` is the only
    /// other place that clears them, and a failed recording's `MicrophoneCapture.stop()` never
    /// calls into this source (it reads the recorded error and returns without touching it), so
    /// without this they would linger -- the observer still watching for further route changes,
    /// the handler closure still retained -- until whatever `start()` eventually replaces them.
    private func fail(_ error: Error) {
        guard gate.fail(error) else { return }
        let (handler, observer) = stateLock.withLock {
            defer {
                configurationObserver = nil
                terminalErrorHandler = nil
            }
            return (terminalErrorHandler, configurationObserver)
        }
        withExtendedLifetime(observer) {}   // released here, outside the lock -- matches stop()
        engineQueue.async { [weak self] in self?.tearDownEngine() }
        if let handler {
            Task { await handler(error) }
        }
    }
}
