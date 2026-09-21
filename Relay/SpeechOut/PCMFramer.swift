import Foundation

enum PCMFramerError: Error, Equatable, Sendable {
    case invalidSampleRate
    case invalidChannelCount
    case unalignedSamples
}

/// Splits large interleaved PCM blocks into small fixed-duration frames. The last frame may be
/// shorter. The default 80 ms cadence matches PocketTTS's native streaming cadence.
struct PCMFramer: Sendable {
    let frameDuration: TimeInterval

    init(frameDuration: TimeInterval = 0.08) {
        self.frameDuration = frameDuration
    }

    func frames(
        samples: [Float],
        sampleRate: Double,
        channelCount: Int = 1
    ) throws -> [TTSAudioFrame] {
        guard sampleRate > 0 else { throw PCMFramerError.invalidSampleRate }
        guard channelCount > 0 else { throw PCMFramerError.invalidChannelCount }
        guard samples.count.isMultiple(of: channelCount) else {
            throw PCMFramerError.unalignedSamples
        }
        guard !samples.isEmpty else { return [] }

        let framesPerChannel = max(1, Int((sampleRate * frameDuration).rounded()))
        let samplesPerFrame = framesPerChannel * channelCount
        let format = TTSAudioFormat(sampleRate: sampleRate, channelCount: channelCount)

        var result: [TTSAudioFrame] = []
        result.reserveCapacity((samples.count + samplesPerFrame - 1) / samplesPerFrame)
        var offset = 0
        while offset < samples.count {
            let end = min(offset + samplesPerFrame, samples.count)
            result.append(TTSAudioFrame(samples: Array(samples[offset..<end]), format: format))
            offset = end
        }
        return result
    }
}
