import Foundation

struct TTSAudioFormat: Sendable, Equatable {
    let sampleRate: Double
    let channelCount: Int
}

struct TTSAudioFrame: Sendable, Equatable {
    /// Interleaved Float32 PCM.
    let samples: [Float]
    let format: TTSAudioFormat

    var durationSeconds: TimeInterval {
        guard format.sampleRate > 0, format.channelCount > 0 else { return 0 }
        return Double(samples.count) / Double(format.channelCount) / format.sampleRate
    }
}

/// Provider-neutral, pull-based synthesized PCM stream.
protocol TTSAudioSource: Sendable {
    func next() async throws -> TTSAudioFrame?
    func cancel() async
}
