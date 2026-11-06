import AVFoundation
import Foundation

protocol MicrophoneCapturing: Sendable {
    /// `onLevel` receives only a normalized [0, 1] microphone level for each accepted sample
    /// batch; raw audio samples are never exposed through this callback.
    func start(onLevel: @escaping @Sendable (Float) -> Void) async throws
    func stop() async throws -> AudioInput
    /// Abandons an in-progress start/recording without producing an `AudioInput`. Returns the
    /// actor to `idle` without throwing; a no-op while already idle.
    func cancel() async
    /// Taps the raw 16 kHz mono sample batches, for live interim transcription. Replaces the
    /// current observer; only an observer set before `start(onLevel:)` sees that session's samples.
    func setSampleObserver(_ observer: (@Sendable ([Float]) -> Void)?) async
    /// The run the next capture announces its steps into; `nil` announces nothing.
    func setTracer(_ tracer: PipelineTracer?) async
}

extension MicrophoneCapturing {
    func setTracer(_ tracer: PipelineTracer?) async {}
}

protocol AudioCaptureSourcing: Sendable {
    /// `stop` does not return until no future sample callbacks can be accepted.
    func start(
        onSamples: @escaping @Sendable ([Float]) -> Void,
        onTerminalError: @escaping @Sendable (Error) async -> Void
    ) async throws
    /// `path` says why the capture ends, for the release check.
    func stop(path: MicrophoneStopPath) async throws
    /// The input device's sample rate (Hz) before resampling to 16 kHz.
    func currentInputSampleRate() -> Double
    /// The run the next `start` announces mic open and mic released into.
    func setTracer(_ tracer: PipelineTracer?)
}

extension AudioCaptureSourcing {
    func stop() async throws { try await stop(path: .stop) }
    func setTracer(_ tracer: PipelineTracer?) {}
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

actor MicrophoneCapture: MicrophoneCapturing {

    private enum State {
        case idle
        /// `cancelRequested`: set by `cancel()`. Only `start()`, once `source.start()` has
        /// returned, tears the source down; `cancel()` would race an unfinished install.
        case starting(UUID, cancelRequested: Bool)
        case failedStarting(UUID, Error)
        case recording(UUID)
        case failedRecording(UUID, Error)
        case stopping(UUID)
    }

    private let permission: any MicrophonePermissionAuthorizing
    private let source: any AudioCaptureSourcing
    private let accumulator = AudioSampleAccumulator()
    private var state: State = .idle
    /// Set by `setSampleObserver` before recording starts;
    /// read once into a local at the top of `start(onLevel:)` and captured by that call's own
    /// sample-batch closure, so a later `setSampleObserver` call mid-recording never changes who
    /// an already-running session's samples are forwarded to.
    private var sampleObserver: (@Sendable ([Float]) -> Void)?
    /// Announces the recording step of the current or next capture.
    private var tracer: PipelineTracer?

    /// Resumed once the actor reaches `idle`; lets `cancel()` wait out an in-flight
    /// `start()`/`stop()` instead of returning while the real source is still winding down.
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    /// Reports privacy-safe capture diagnostics once per `stop()` call.
    private let onCaptureDiagnostics: (@Sendable (MicrophoneCaptureDiagnostics) async -> Void)?
    private let now: @Sendable () -> Date
    /// The input device's sample rate for the current or last recording; `0` when `source` does
    /// not report it.
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
        state = .starting(session, cancelRequested: false)
        let tracer = self.tracer
        guard await permission.requestPermission() else {
            transitionToIdle()
            tracer?.fail(.micOpen, "Microphone permission denied")
            throw SpeechBackendError.permissionDenied
        }
        source.setTracer(tracer)

        accumulator.reset()
        // Captured once, here, on the actor: see `sampleObserver`'s doc comment for why this must
        // happen before `source.start()` rather than reading `sampleObserver` from inside the
        // (non-isolated, `@Sendable`) closure below.
        let sampleTap = sampleObserver
        do {
            try await source.start(
                onSamples: { [accumulator] samples in
                    accumulator.append(samples)
                    let level = AudioBufferUtilities.level(of: samples)
                    onLevel(level)
                    tracer?.level(.recording, level)
                    sampleTap?(samples)
                },
                onTerminalError: { [weak self] error in
                    await self?.sourceTerminated(error, session: session)
                }
            )
            switch state {
            case .starting(session, cancelRequested: false):
                state = .recording(session)
                lastInputSampleRate = source.currentInputSampleRate()
                tracer?.start(.recording, "Recording")
            case let .failedStarting(failedSession, error) where failedSession == session:
                transitionToIdle()
                throw error
            case .starting(session, cancelRequested: true):
                // Cancel was requested and the actor is still `.starting` — nobody
                // else has progressed past this frame, so it still owns the source and must
                // tear it down. `source.start()` has now definitely returned, so this is safe.
                try? await source.stop(path: .cancel)
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
            tracer?.fail(.recording, Self.reason(error))
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
            await onCaptureDiagnostics?(
                MicrophoneCaptureDiagnostics(
                    inputSampleRate: lastInputSampleRate,
                    frameCount: samples.count,
                    capturedAt: now()
                ))
            guard !samples.isEmpty else {
                tracer?.fail(.recording, "No audio from the microphone")
                throw SpeechBackendError.noUsableAudio
            }
            let seconds = Double(samples.count) / AudioInput.sttSampleRate
            tracer?.finish(.recording, String(format: "%.1f s", seconds))
            return AudioInput(samples: samples, sampleRate: AudioInput.sttSampleRate)
        } catch let error as SpeechBackendError where error == .noUsableAudio {
            throw error
        } catch {
            accumulator.reset()
            transitionToIdle()
            tracer?.fail(.recording, Self.reason(error))
            throw error
        }
    }

    func cancel() async {
        switch state {
        case .idle:
            return
        case let .starting(session, _):
            // `source.start()` is still in flight for this session; flag the cancellation and
            // wait for `start()`'s own post-completion switch to tear the source down exactly
            // once it's safe to do so.
            state = .starting(session, cancelRequested: true)
            await withCheckedContinuation { idleWaiters.append($0) }
        case let .recording(session):
            state = .stopping(session)
            try? await source.stop(path: .cancel)
            tracer?.stop(.recording, "Cancelled")
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

    /// The single place `state` is set back to `.idle`. Wakes every `cancel()` call currently
    /// waiting on `.starting`/`.stopping` to resolve.
    private func transitionToIdle() {
        state = .idle
        let waiters = idleWaiters
        idleWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    func setSampleObserver(_ observer: (@Sendable ([Float]) -> Void)?) async {
        sampleObserver = observer
    }

    func setTracer(_ tracer: PipelineTracer?) async {
        self.tracer = tracer
    }

    private static func reason(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "Recording failed"
    }

    private func sourceTerminated(_ error: Error, session: UUID) {

        switch state {
        case let .starting(activeSession, _):
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
