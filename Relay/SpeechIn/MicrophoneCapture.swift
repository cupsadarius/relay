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
}

/// Reduces a batch of raw audio samples to a single normalized loudness value for the activity
/// overlay's level meter. Never exposes the samples themselves.
enum MicrophoneLevelMeter {
    static func normalized(samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let meanSquare = samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)
        let rms = sqrt(meanSquare)
        return min(max(rms * 4, 0), 1)
    }
}

protocol AudioCaptureSourcing: Sendable {
    /// `stop` does not return until no future sample callbacks can be accepted.
    func start(
        onSamples: @escaping @Sendable ([Float]) -> Void,
        onTerminalError: @escaping @Sendable (Error) async -> Void
    ) async throws
    func stop() async throws
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
    /// Set by `cancel()` while `.starting`; checked by `start()`'s own post-`source.start()`
    /// switch so the call that actually knows `source.start()` has returned is the one that
    /// tears the real source down — never `cancel()` itself, which would otherwise race a
    /// `source.start()` that hasn't finished installing yet.
    private var startCancelRequested = false
    /// Resumed once the actor reaches `idle`; lets `cancel()` wait out an in-flight
    /// `start()`/`stop()` instead of returning while the real source is still winding down.
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        permission: any MicrophonePermissionAuthorizing = SystemMicrophonePermissionAuthorizer(),
        source: any AudioCaptureSourcing = AVAudioEngineSource()
    ) {
        self.permission = permission
        self.source = source
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
        do {
            try await source.start(
                onSamples: { [accumulator] samples in
                    accumulator.append(samples)
                    onLevel(MicrophoneLevelMeter.normalized(samples: samples))
                },
                onTerminalError: { [weak self] error in
                    await self?.sourceTerminated(error, session: session)
                }
            )
            switch state {
            case .starting(session) where !startCancelRequested:
                state = .recording(session)
            case let .failedStarting(failedSession, error) where failedSession == session:
                transitionToIdle()
                throw error
            default:
                // Either a concurrent `cancel()` requested cancellation while this call was
                // still setting up, or the actor moved on for some other reason. Either way,
                // `source.start()` has now definitely returned, so this is the one place that
                // can safely tear the real source down without racing its own setup.
                try? await source.stop()
                accumulator.reset()
                transitionToIdle()
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

private final class AVAudioEngineSource: AudioCaptureSourcing, @unchecked Sendable {
    private let lock = NSLock()
    private let engine = AVAudioEngine()
    private var isCapturing = false
    private var captureError: Error?

    func start(
        onSamples: @escaping @Sendable ([Float]) -> Void,
        onTerminalError: @escaping @Sendable (Error) async -> Void
    ) async throws {
        try lock.withLock {
            guard !isCapturing else { throw MicrophoneCaptureError.alreadyRecording }
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

            captureError = nil
            input.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) { [weak self] buffer, _ in
                self?.convert(
                    buffer,
                    using: converter,
                    outputFormat: outputFormat,
                    onSamples: onSamples,
                    onTerminalError: onTerminalError
                )
            }

            do {
                try engine.start()
                isCapturing = true
            } catch {
                input.removeTap(onBus: 0)
                engine.stop()
                throw MicrophoneCaptureError.unavailable(error.localizedDescription)
            }
        }
    }

    func stop() async throws {
        let error: Error? = lock.withLock {
            // The lock serializes conversion callbacks with tap removal and the caller's subsequent drain.
            if isCapturing {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
            }
            isCapturing = false
            defer { captureError = nil }
            return captureError
        }
        if let error { throw error }
    }

    private func convert(
        _ buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        outputFormat: AVAudioFormat,
        onSamples: @escaping @Sendable ([Float]) -> Void,
        onTerminalError: @escaping @Sendable (Error) async -> Void
    ) {
        lock.withLock {
            guard isCapturing, captureError == nil else { return }
            let ratio = outputFormat.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1)
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
                failCapture(MicrophoneCaptureError.unavailable("Unable to allocate an audio conversion buffer."), onTerminalError: onTerminalError)
                return
            }

            let supplier = AVAudioInputBufferSupplier(buffer: buffer)
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                supplier.next(inputStatus: inputStatus)
            }

            switch AudioConversionDisposition.resolve(
                status: status,
                hasConversionError: conversionError != nil,
                frameLength: output.frameLength
            ) {
            case .appendOutput:
                break
            case .awaitNextCallback:
                return
            case .fail:
                failCapture(conversionError ?? MicrophoneCaptureError.unavailable("Audio conversion failed with status \(status.rawValue)."), onTerminalError: onTerminalError)
                return
            }
            guard let channel = output.floatChannelData?[0] else {
                failCapture(MicrophoneCaptureError.unavailable("Converted audio has no float samples."), onTerminalError: onTerminalError)
                return
            }
            onSamples(Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength))))
        }
    }

    private func failCapture(_ error: Error, onTerminalError: @escaping @Sendable (Error) async -> Void) {
        captureError = error
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isCapturing = false
        Task { await onTerminalError(error) }
    }
}

/// AVFoundation invokes the converter input closure synchronously for this conversion.
/// This wrapper keeps the non-Sendable PCM buffer inside the lock-protected audio callback boundary.
private final class AVAudioInputBufferSupplier: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private var supplied = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(inputStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard !supplied else {
            inputStatus.pointee = .noDataNow
            return nil
        }
        supplied = true
        inputStatus.pointee = .haveData
        return buffer
    }
}
