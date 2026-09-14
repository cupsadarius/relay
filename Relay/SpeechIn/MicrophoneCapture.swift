import AVFoundation
import Foundation

protocol MicrophoneCapturing: Sendable {
    func start() async throws
    func stop() async throws -> AudioInput
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
        case recording(UUID)
        case stopping(UUID)
    }

    private let permission: any MicrophonePermissionAuthorizing
    private let source: any AudioCaptureSourcing
    private let accumulator = AudioSampleAccumulator()
    private var state: State = .idle
    private var pendingStartTerminalError: (session: UUID, error: Error)?

    init(
        permission: any MicrophonePermissionAuthorizing = SystemMicrophonePermissionAuthorizer(),
        source: any AudioCaptureSourcing = AVAudioEngineSource()
    ) {
        self.permission = permission
        self.source = source
    }

    func start() async throws {
        guard case .idle = state else { throw MicrophoneCaptureError.alreadyRecording }
        let session = UUID()
        pendingStartTerminalError = nil
        state = .starting(session)
        guard await permission.requestPermission() else {
            pendingStartTerminalError = nil
            state = .idle
            throw SpeechBackendError.permissionDenied
        }

        accumulator.reset()
        do {
            try await source.start(
                onSamples: { [accumulator] samples in
                    accumulator.append(samples)
                },
                onTerminalError: { [weak self] error in
                    await self?.sourceTerminated(error, session: session)
                }
            )
            guard case .starting(session) = state else {
                if let pendingStartTerminalError, pendingStartTerminalError.session == session {
                    self.pendingStartTerminalError = nil
                    throw pendingStartTerminalError.error
                }
                return
            }
            state = .recording(session)
        } catch {
            accumulator.reset()
            pendingStartTerminalError = nil
            state = .idle
            throw error
        }
    }

    func stop() async throws -> AudioInput {
        guard case let .recording(session) = state else { throw MicrophoneCaptureError.notRecording }
        state = .stopping(session)

        do {
            // The source removes its tap before returning, so this drain includes every accepted callback.
            try await source.stop()
            state = .idle
            let samples = accumulator.take()
            guard !samples.isEmpty else { throw SpeechBackendError.noUsableAudio }
            return AudioInput(samples: samples, sampleRate: 16_000)
        } catch {
            accumulator.reset()
            state = .idle
            throw error
        }
    }

    private func sourceTerminated(_ error: Error, session: UUID) {
        switch state {
        case let .starting(activeSession):
            guard activeSession == session else { return }
            pendingStartTerminalError = (session, error)
            accumulator.reset()
            state = .idle
        case let .recording(activeSession):
            guard activeSession == session else { return }
            accumulator.reset()
            state = .idle
        case .idle, .starting, .recording, .stopping:
            break
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

            guard status == .haveData else {
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
