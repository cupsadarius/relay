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

/// A bounded, synchronous producer / asynchronous consumer bridge for Apple's push-driven
/// `write` callback (which cannot `await`). The `write` callback deep-copies each buffer, converts
/// it, and calls `push` - which blocks the callback thread when the queue is full, giving Apple
/// real backpressure without spawning an unbounded number of tasks. The consumer (`TTSAudioSource`)
/// pulls frames through `next()`.
final class AppleSpeechBufferBridge: @unchecked Sendable {
    private let condition = NSCondition()
    private let capacity: Int
    private var queue: [TTSAudioFrame] = []
    private var waiter: CheckedContinuation<TTSAudioFrame?, Error>?
    private var finished = false
    private var cancelled = false
    private var failure: SpeechBackendError?

    init(capacity: Int = 8) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    /// Producer side. Blocks while the queue is full (and no terminal state has been reached),
    /// applying backpressure to Apple's generation.
    func push(_ frame: TTSAudioFrame) {
        condition.lock()
        while queue.count >= capacity, !cancelled, !finished, failure == nil {
            condition.wait()
        }
        guard !cancelled, !finished, failure == nil else {
            condition.unlock()
            return
        }
        if let waiter {
            self.waiter = nil
            condition.unlock()
            waiter.resume(returning: frame)
        } else {
            queue.append(frame)
            condition.unlock()
        }
    }

    /// Consumer side. Returns the next frame, `nil` on normal end, or throws the stored failure or
    /// `CancellationError`.
    func next() async throws -> TTSAudioFrame? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<TTSAudioFrame?, Error>) in
            condition.lock()
            if !queue.isEmpty {
                let frame = queue.removeFirst()
                condition.signal()
                condition.unlock()
                continuation.resume(returning: frame)
            } else if let failure {
                condition.unlock()
                continuation.resume(throwing: failure)
            } else if finished {
                condition.unlock()
                continuation.resume(returning: nil)
            } else if cancelled {
                condition.unlock()
                continuation.resume(throwing: CancellationError())
            } else {
                waiter = continuation
                condition.unlock()
            }
        }
    }

    func finish() {
        condition.lock()
        guard !finished, !cancelled, failure == nil else {
            condition.unlock()
            return
        }
        finished = true
        // A waiter only exists when the queue was empty at `next()` time; any later `push` would
        // have resumed it. So a waiter here implies an empty queue - resume it with end-of-stream.
        let pending = waiter
        waiter = nil
        condition.broadcast()
        condition.unlock()
        pending?.resume(returning: nil)
    }

    func fail(_ error: SpeechBackendError) {
        condition.lock()
        guard !finished, !cancelled, failure == nil else {
            condition.unlock()
            return
        }
        failure = error
        let pending = waiter
        waiter = nil
        condition.broadcast()
        condition.unlock()
        pending?.resume(throwing: error)
    }

    func cancel() {
        condition.lock()
        guard !cancelled else {
            condition.unlock()
            return
        }
        cancelled = true
        queue.removeAll()
        let pending = waiter
        waiter = nil
        condition.broadcast()
        condition.unlock()
        pending?.resume(throwing: CancellationError())
    }
}

/// Produces PCM from `AVSpeechSynthesizer.write(_:toBufferCallback:)`. Each source owns a dedicated
/// synthesizer so a cancelled attempt's late callbacks cannot leak into a later session. Generation
/// and playback are fully separated: this only generates PCM; the shared `StreamingAudioPlayer`
/// owns speakers and metering.
final class AppleTTSAudioSource: TTSAudioSource, @unchecked Sendable {
    private let synthesizer: any AppleSpeechSynthesizing
    private let converter: any AppleSpeechBufferConverting
    private let bridge: AppleSpeechBufferBridge
    private let text: String
    private let rate: Float
    private let voiceIdentifier: String?

    private let startLock = NSLock()
    private var started = false

    init(
        text: String,
        rate: Float,
        voiceIdentifier: String?,
        synthesizer: any AppleSpeechSynthesizing,
        converter: any AppleSpeechBufferConverting,
        bridgeCapacity: Int = 8
    ) {
        self.text = text
        self.rate = rate
        self.voiceIdentifier = voiceIdentifier
        self.synthesizer = synthesizer
        self.converter = converter
        bridge = AppleSpeechBufferBridge(capacity: bridgeCapacity)
    }

    func next() async throws -> TTSAudioFrame? {
        await startIfNeeded()
        return try await bridge.next()
    }

    func cancel() async {
        bridge.cancel()
        await MainActor.run { [synthesizer] in
            _ = synthesizer.stopSpeaking(at: .immediate)
        }
    }

    private func startIfNeeded() async {
        guard beginStartOnce() else { return }
        let text = self.text
        let rate = self.rate
        let voiceIdentifier = self.voiceIdentifier
        await MainActor.run { [synthesizer, converter, bridge] in
            let utterance = AVSpeechUtterance(string: text)
            utterance.rate = rate
            if let voiceIdentifier, let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
                utterance.voice = voice
            }
            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    bridge.finish()
                    return
                }
                do {
                    bridge.push(try converter.frame(from: pcm))
                } catch {
                    bridge.fail(.inferenceFailed("Apple speech generation failed"))
                }
            }
        }
    }

    private func beginStartOnce() -> Bool {
        startLock.lock()
        defer { startLock.unlock() }
        if started { return false }
        started = true
        return true
    }
}
