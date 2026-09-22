import Foundation

/// Pull adapter over PocketTTS's existing native Float32 stream. A producer task drains the
/// engine stream into a bounded pipe; playback pulls frames back out independently.
struct PocketTTSAudioSource: TTSAudioSource {
    private let source: TTSAudioPipe.Source
    private let producer: Task<Void, Never>

    init(
        stream: AsyncThrowingStream<[Float], Error>,
        sampleRate: Double,
        highWatermark: TimeInterval = 30,
        lowWatermark: TimeInterval = 15
    ) {
        let format = TTSAudioFormat(sampleRate: sampleRate, channelCount: 1)
        let pipe = TTSAudioPipe.make(highWatermark: highWatermark, lowWatermark: lowWatermark)
        source = pipe.source
        producer = Task {
            do {
                for try await samples in stream {
                    try Task.checkCancellation()
                    try await pipe.sink.yield(TTSAudioFrame(samples: samples, format: format))
                }
                await pipe.sink.finish()
            } catch is CancellationError {
                await pipe.sink.cancel()
            } catch {
                await pipe.sink.fail(error)
            }
        }
    }

    func next() async throws -> TTSAudioFrame? {
        do {
            return try await source.next()
        } catch is CancellationError {
            // A cancelled source yields no more frames rather than surfacing the cancellation.
            return nil
        }
    }

    func cancel() async {
        producer.cancel()
        await source.cancel()
    }
}
