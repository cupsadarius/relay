import AVFoundation

/// Small pure helpers shared by every place Relay pushes PCM through `AVAudioConverter`,
/// meters it, or switches between planar and interleaved layouts.
enum AudioBufferUtilities {
    /// Empirical gain applied to RMS so speech reads well on the activity overlay's meter. Shared by
    /// the microphone level and the speaking level so both waveforms scale the same way.
    static let levelGain: Float = 4

    /// RMS of `samples` times `levelGain`, clamped to `0...1`. Returns only the level, never the
    /// samples.
    static func level(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sumOfSquares: Float = 0
        for sample in samples {
            sumOfSquares += sample * sample
        }
        return min(max(sqrt(sumOfSquares / Float(samples.count)) * levelGain, 0), 1)
    }

    /// Runs one `AVAudioConverter` pass that hands `input` over exactly once. Once the buffer has
    /// been provided, the converter is told `exhaustedStatus`:
    /// - `.noDataNow` for a live stream, where a later call brings more input and the converter
    ///   keeps its resampler state.
    /// - `.endOfStream` for a one-shot conversion of a complete clip, which flushes the tail.
    static func convert(
        _ input: AVAudioPCMBuffer,
        into output: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        exhaustedStatus: AVAudioConverterInputStatus = .noDataNow
    ) -> (status: AVAudioConverterOutputStatus, error: NSError?) {
        let feeder = SingleBufferFeeder(buffer: input)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            feeder.next(inputStatus: inputStatus, exhaustedStatus: exhaustedStatus)
        }
        return (status, error)
    }

    /// Interleaves `channelCount` planar channels of `frameLength` frames into one array.
    static func interleave(
        _ channels: UnsafePointer<UnsafeMutablePointer<Float>>,
        channelCount: Int,
        frameLength: Int
    ) -> [Float] {
        if channelCount == 1 {
            return Array(UnsafeBufferPointer(start: channels[0], count: frameLength))
        }
        var interleaved = [Float](repeating: 0, count: frameLength * channelCount)
        for channel in 0..<channelCount {
            let source = channels[channel]
            for index in 0..<frameLength {
                interleaved[index * channelCount + channel] = source[index]
            }
        }
        return interleaved
    }

    /// Writes interleaved `samples` into `channelCount` planar channels. `samples.count` must be a
    /// multiple of `channelCount`, and every channel must hold `samples.count / channelCount` frames.
    static func deinterleave(
        _ samples: [Float],
        channelCount: Int,
        into channels: UnsafePointer<UnsafeMutablePointer<Float>>
    ) {
        let framesPerChannel = samples.count / channelCount
        samples.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            if channelCount == 1 {
                channels[0].update(from: base, count: framesPerChannel)
                return
            }
            for channel in 0..<channelCount {
                let destination = channels[channel]
                for index in 0..<framesPerChannel {
                    destination[index] = base[index * channelCount + channel]
                }
            }
        }
    }
}

/// Carries the "already provided" flag and the buffer into `AVAudioConverter`'s input block,
/// which is imported as `@Sendable` but is only ever called synchronously on the calling thread.
/// That synchronous contract is what makes `@unchecked` safe.
private final class SingleBufferFeeder: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private var provided = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(
        inputStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>,
        exhaustedStatus: AVAudioConverterInputStatus
    ) -> AVAudioBuffer? {
        guard !provided else {
            inputStatus.pointee = exhaustedStatus
            return nil
        }
        provided = true
        inputStatus.pointee = .haveData
        return buffer
    }
}
