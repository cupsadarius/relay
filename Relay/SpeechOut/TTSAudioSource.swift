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
///
/// Contract every conforming source must follow:
/// - `next()` returns the next frame, or `nil` exactly when the stream has FINISHED normally
///   (every frame was produced).
/// - Once `cancel()` has run, or the producer itself was cancelled, `next()` throws
///   `CancellationError`. It never returns `nil` for a cancelled stream:
///   `StreamingAudioPlayer` ends the session as `.finished` on `nil` and as `.cancelled` on
///   `CancellationError`, so `nil` would report a cancelled response as fully spoken.
/// - Any other producer failure is thrown as is.
/// - `cancel()` is idempotent.
protocol TTSAudioSource: Sendable {
    func next() async throws -> TTSAudioFrame?
    func cancel() async
}
