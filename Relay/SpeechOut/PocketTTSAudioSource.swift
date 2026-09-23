import Foundation

/// Pull adapter over PocketTTS's existing native Float32 stream. A producer task drains the
/// engine stream into a bounded pipe; playback pulls frames back out independently.
struct PocketTTSAudioSource: TTSAudioSource {
    private let piped: PipedTTSAudioSource

    init(
        stream: AsyncThrowingStream<[Float], Error>,
        sampleRate: Double,
        highWatermark: TimeInterval = 30,
        lowWatermark: TimeInterval = 15
    ) {
        let format = TTSAudioFormat(sampleRate: sampleRate, channelCount: 1)
        piped = PipedTTSAudioSource(highWatermark: highWatermark, lowWatermark: lowWatermark) { sink in
            for try await samples in stream {
                try Task.checkCancellation()
                try await sink.yield(TTSAudioFrame(samples: samples, format: format))
            }
        }
    }

    /// Throws `CancellationError` after `cancel()`, per the `TTSAudioSource` contract.
    func next() async throws -> TTSAudioFrame? {
        try await piped.next()
    }

    func cancel() async {
        await piped.cancel()
    }
}
