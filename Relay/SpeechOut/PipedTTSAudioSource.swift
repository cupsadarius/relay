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
    private let box: ProducerBox

    init(
        highWatermark: TimeInterval = 30,
        lowWatermark: TimeInterval = 15,
        produce: @escaping @Sendable (TTSAudioPipe.Sink) async throws -> Void
    ) {
        let pipe = TTSAudioPipe.make(highWatermark: highWatermark, lowWatermark: lowWatermark)
        source = pipe.source
        let producer = Task {
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
        box = ProducerBox(producer: producer, sink: pipe.sink)
    }

    func next() async throws -> TTSAudioFrame? {
        try await source.next()
    }

    func cancel() async {
        box.producer.cancel()
        await source.cancel()
    }
}

/// `PipedTTSAudioSource` is a struct (value semantics, required by `TTSAudioSource: Sendable`), so
/// it has no deinit of its own to end an abandoned producer. This box is the one
/// reference-counted piece of it: once every copy of the source goes away without `cancel()` ever
/// being called, this deinit runs.
///
/// Cancelling the `Task` alone is not enough: `TTSAudioPipe`'s backpressure wait (`yield` blocked
/// at the high watermark) is a plain `withCheckedContinuation`, not cancellation-aware, so it only
/// ever resumes via the pipe's own `finish`/`fail`/`cancel`. Calling `sink.cancel()` here is what
/// actually wakes a producer stuck there and lets its task finish.
private final class ProducerBox: Sendable {
    let producer: Task<Void, Never>
    private let sink: TTSAudioPipe.Sink

    init(producer: Task<Void, Never>, sink: TTSAudioPipe.Sink) {
        self.producer = producer
        self.sink = sink
    }

    deinit {
        producer.cancel()
        let sink = sink
        Task { await sink.cancel() }
    }
}
