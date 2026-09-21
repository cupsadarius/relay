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

/// Transitional source-producing capability. PocketTTS and Kokoro use this immediately; Apple
/// keeps its native AVSpeechSynthesizer playback until the owner-Mac generated-audio quality gate
/// is passed. The final cutover can fold this method directly into `TextToSpeechBackend`.
@MainActor
protocol TTSAudioSourceProducing: AnyObject {
    func makeAudioSource(text: String, options: TTSOptions) async throws -> any TTSAudioSource
}

/// Playback seam used by `TTSRouter` for source-producing backends.
/// `UnifiedStreamingAudioPlayer` implements it during the Apple compatibility window.
@MainActor
protocol TTSAudioPlaying: AnyObject {
    var onEvent: (@MainActor (TTSPlaybackEvent) -> Void)? { get set }
    func startPlayback(_ source: any TTSAudioSource, sessionID: UUID) async throws
    func stop()
    func pause()
    func resume()
}
