import Foundation

/// A `TTSAudioSource` fed by a producer task through a bounded `TTSAudioPipe`. The producer runs
/// `produce` against the pipe's sink; the player pulls from the pipe independently, so synthesis
/// suspends at the pipe's high watermark instead of filling memory.
///
/// Terminal mapping:
/// - `produce` returns → finish (buffered audio then `nil`).
/// - `produce` throws `CancellationError`, or returns after its task was cancelled → cancel.
/// - `produce` throws anything else → fail (buffered audio then that error).
///
/// `cancel()` cancels the producer task and the pipe, which wakes a producer blocked in `yield`.
struct PipedTTSAudioSource: TTSAudioSource {
    private let source: TTSAudioPipe.Source
    private let producer: Task<Void, Never>

    init(
        highWatermark: TimeInterval = 30,
        lowWatermark: TimeInterval = 15,
        produce: @escaping @Sendable (TTSAudioPipe.Sink) async throws -> Void
    ) {
        let pipe = TTSAudioPipe.make(highWatermark: highWatermark, lowWatermark: lowWatermark)
        source = pipe.source
        producer = Task {
            do {
                try await produce(pipe.sink)
                if Task.isCancelled {
                    await pipe.sink.cancel()
                } else {
                    await pipe.sink.finish()
                }
            } catch is CancellationError {
                await pipe.sink.cancel()
            } catch {
                await pipe.sink.fail(error)
            }
        }
    }

    func next() async throws -> TTSAudioFrame? {
        try await source.next()
    }

    func cancel() async {
        producer.cancel()
        await source.cancel()
    }
}
