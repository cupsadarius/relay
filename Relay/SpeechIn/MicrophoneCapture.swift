import AVFoundation
import Foundation

protocol MicrophoneCapturing: Sendable {
    func start() async throws
    func stop() async throws -> AudioInput
}

protocol AudioCaptureSourcing: Sendable {
    /// `stop` does not return until no future sample callbacks can be accepted.
    func start(onSamples: @escaping @Sendable ([Float]) -> Void) async throws
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
    private enum State { case idle, recording }

    private let permission: any MicrophonePermissionAuthorizing
    private let source: any AudioCaptureSourcing
    private let accumulator = AudioSampleAccumulator()
    private var state: State = .idle

    init(
        permission: any MicrophonePermissionAuthorizing = SystemMicrophonePermissionAuthorizer(),
        source: any AudioCaptureSourcing = AVAudioEngineSource()
    ) {
        self.permission = permission
        self.source = source
    }

    func start() async throws {
        guard state == .idle else { throw MicrophoneCaptureError.alreadyRecording }
        guard await permission.requestPermission() else { throw SpeechBackendError.permissionDenied }

        accumulator.reset()
        do {
            try await source.start { [accumulator] samples in
                accumulator.append(samples)
            }
            state = .recording
        } catch {
            accumulator.reset()
            state = .idle
            throw error
        }
    }

    func stop() async throws -> AudioInput {
        guard state == .recording else { throw MicrophoneCaptureError.notRecording }

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

    func start(onSamples: @escaping @Sendable ([Float]) -> Void) async throws {
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
                self?.convert(buffer, using: converter, outputFormat: outputFormat, onSamples: onSamples)
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
        onSamples: @escaping @Sendable ([Float]) -> Void
    ) {
        lock.withLock {
            guard isCapturing, captureError == nil else { return }
            let ratio = outputFormat.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1)
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
                failCapture(MicrophoneCaptureError.unavailable("Unable to allocate an audio conversion buffer."))
                return
            }

            let supplier = AVAudioInputBufferSupplier(buffer: buffer)
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                supplier.next(inputStatus: inputStatus)
            }

            guard status == .haveData else {
                failCapture(conversionError ?? MicrophoneCaptureError.unavailable("Audio conversion failed with status \(status.rawValue)."))
                return
            }
            guard let channel = output.floatChannelData?[0] else {
                failCapture(MicrophoneCaptureError.unavailable("Converted audio has no float samples."))
                return
            }
            onSamples(Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength))))
        }
    }

    private func failCapture(_ error: Error) {
        captureError = error
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isCapturing = false
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
