import AVFoundation
import Foundation

/// Normalizes an `AVSpeechSynthesizer.write` callback buffer into the shared interleaved Float32
/// PCM contract. Injected so unit tests do not depend on Apple's live system voices.
protocol AppleSpeechBufferConverting: Sendable {
    func frame(from buffer: AVAudioPCMBuffer) throws -> TTSAudioFrame
}

/// Production converter: converts each callback buffer to interleaved Float32 via `AVAudioConverter`
/// when it is not already in that layout.
struct AVAudioPCMBufferConverter: AppleSpeechBufferConverting {
    enum ConversionError: Error, Sendable {
        case unsupportedFormat
        case allocationFailed
        case conversionFailed
    }

    func frame(from buffer: AVAudioPCMBuffer) throws -> TTSAudioFrame {
        let inputFormat = buffer.format
        let channelCount = max(Int(inputFormat.channelCount), 1)
        let sampleRate = inputFormat.sampleRate
        guard sampleRate > 0 else { throw ConversionError.unsupportedFormat }

        // Already non-interleaved Float32: interleave directly.
        if inputFormat.commonFormat == .pcmFormatFloat32, !inputFormat.isInterleaved,
           let channels = buffer.floatChannelData {
            let frameLength = Int(buffer.frameLength)
            var interleaved = [Float](repeating: 0, count: frameLength * channelCount)
            for channel in 0..<channelCount {
                let source = channels[channel]
                for index in 0..<frameLength {
                    interleaved[index * channelCount + channel] = source[index]
                }
            }
            return TTSAudioFrame(
                samples: interleaved,
                format: TTSAudioFormat(sampleRate: sampleRate, channelCount: channelCount)
            )
        }

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channelCount),
            interleaved: true
        ) else { throw ConversionError.unsupportedFormat }

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw ConversionError.unsupportedFormat
        }
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: max(buffer.frameCapacity, buffer.frameLength)
        ) else { throw ConversionError.allocationFailed }

        try convert(buffer, to: outputBuffer, using: converter)

        let frameLength = Int(outputBuffer.frameLength)
        guard let interleavedData = outputBuffer.floatChannelData else {
            throw ConversionError.conversionFailed
        }
        let count = frameLength * channelCount
        let samples = Array(UnsafeBufferPointer(start: interleavedData[0], count: count))
        return TTSAudioFrame(
            samples: samples,
            format: TTSAudioFormat(sampleRate: sampleRate, channelCount: channelCount)
        )
    }

    private func convert(
        _ input: AVAudioPCMBuffer,
        to output: AVAudioPCMBuffer,
        using converter: AVAudioConverter
    ) throws {
        let state = SingleBufferInput(buffer: input)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if state.consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            state.consumed = true
            inputStatus.pointee = .haveData
            return state.buffer
        }
        if status == .error {
            throw conversionError ?? ConversionError.conversionFailed
        }
    }

    /// Boxes the single input buffer for `AVAudioConverter`'s `@Sendable`-imported input block,
    /// which is only ever called synchronously on the calling thread.
    private final class SingleBufferInput: @unchecked Sendable {
        var consumed = false
        let buffer: AVAudioPCMBuffer
        init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    }
}

/// Produces PCM from `AVSpeechSynthesizer.write(_:toBufferCallback:)`. Each source owns a
/// dedicated synthesizer, so a cancelled attempt's late callbacks cannot leak into a later
/// session.
///
/// Apple's write callback is synchronous and push-driven, and it must never block (see the
/// cleanup-4 spike). Each buffer is converted in the callback (a deep copy: Apple may reuse the
/// buffer once the callback returns) and yielded into an unbounded `AsyncStream`. A producer
/// inside `PipedTTSAudioSource` is that stream's single consumer (`AsyncStream` supports exactly
/// one) and moves frames into the bounded, duration-based `TTSAudioPipe` the player pulls from.
/// Apple cannot pause `write`, so generation runs ahead at its own pace; Relay's memory for it is
/// bounded by the utterance (~96 KB per second of 24 kHz mono), not by playback.
///
/// Synthesis starts on the first `next()`. `cancel()` before that never starts it.
final class AppleTTSAudioSource: TTSAudioSource, @unchecked Sendable {
    private enum GenerationEvent: Sendable {
        case frame(TTSAudioFrame)
        case finished
        case failed
    }

    private enum StartState {
        case idle
        case started
        case cancelled
    }

    private let synthesizer: any AppleSpeechSynthesizing
    private let converter: any AppleSpeechBufferConverting
    private let text: String
    private let rate: Float
    private let voiceIdentifier: String?
    private let events: AsyncStream<GenerationEvent>.Continuation
    private let piped: PipedTTSAudioSource

    private let stateLock = NSLock()
    private var startState: StartState = .idle

    init(
        text: String,
        rate: Float,
        voiceIdentifier: String?,
        synthesizer: any AppleSpeechSynthesizing,
        converter: any AppleSpeechBufferConverting,
        highWatermark: TimeInterval = 30,
        lowWatermark: TimeInterval = 15
    ) {
        self.text = text
        self.rate = rate
        self.voiceIdentifier = voiceIdentifier
        self.synthesizer = synthesizer
        self.converter = converter

        let (stream, continuation) = AsyncStream.makeStream(of: GenerationEvent.self)
        events = continuation
        piped = PipedTTSAudioSource(highWatermark: highWatermark, lowWatermark: lowWatermark) { sink in
            for await event in stream {
                switch event {
                case let .frame(frame):
                    try await sink.yield(frame)
                case .finished:
                    return
                case .failed:
                    throw SpeechBackendError.inferenceFailed("Apple speech generation failed")
                }
            }
            // The event stream ended with no terminal event: the source was cancelled.
            throw CancellationError()
        }
    }

    func next() async throws -> TTSAudioFrame? {
        if claimStart() {
            await startGeneration()
        }
        return try await piped.next()
    }

    func cancel() async {
        stateLock.withLock { startState = .cancelled }
        events.finish()
        await piped.cancel()
        await MainActor.run { [synthesizer] in
            _ = synthesizer.stopSpeaking(at: .immediate)
        }
    }

    private func claimStart() -> Bool {
        stateLock.withLock {
            guard startState == .idle else { return false }
            startState = .started
            return true
        }
    }

    private func isCancelled() -> Bool {
        stateLock.withLock { startState == .cancelled }
    }

    private func startGeneration() async {
        let text = self.text
        let rate = self.rate
        let voiceIdentifier = self.voiceIdentifier
        let converter = self.converter
        let events = self.events
        await MainActor.run { [synthesizer] in
            // `cancel()` may have run between `claimStart()` and this hop. It stops the
            // synthesizer on the main actor too, so this check orders `write` strictly before
            // or after that stop.
            guard !self.isCancelled() else { return }
            let utterance = AVSpeechUtterance(string: text)
            utterance.rate = rate
            if let voiceIdentifier, let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
                utterance.voice = voice
            }
            // Explicitly `@Sendable`: Apple may call this off the main thread (Task 8 spike), and
            // a closure inferred as main-actor isolated would trap there.
            synthesizer.write(utterance) { @Sendable buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    events.yield(.finished)
                    events.finish()
                    return
                }
                do {
                    events.yield(.frame(try converter.frame(from: pcm)))
                } catch {
                    events.yield(.failed)
                    events.finish()
                }
            }
        }
    }
}
