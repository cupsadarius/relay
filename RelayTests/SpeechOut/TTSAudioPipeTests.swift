import XCTest
@testable import Relay

final class TTSAudioPipeTests: XCTestCase {
    private let format = TTSAudioFormat(sampleRate: 10, channelCount: 1)

    func testFinishDrainsFramesThenReturnsNil() async throws {
        let pipe = TTSAudioPipe.make(highWatermark: 10, lowWatermark: 5)
        try await pipe.sink.yield(.init(samples: [1, 2], format: format))
        await pipe.sink.finish()

        let first = try await pipe.source.next()
        let end = try await pipe.source.next()
        XCTAssertEqual(first?.samples, [1, 2])
        XCTAssertNil(end)
    }

    func testFailureDrainsBufferedFrameThenThrows() async throws {
        enum Boom: Error { case boom }
        let pipe = TTSAudioPipe.make(highWatermark: 10, lowWatermark: 5)
        try await pipe.sink.yield(.init(samples: [1], format: format))
        await pipe.sink.fail(Boom.boom)

        let first = try await pipe.source.next()
        XCTAssertEqual(first?.samples, [1])
        do {
            _ = try await pipe.source.next()
            XCTFail("Expected stored failure")
        } catch is Boom {
            // expected
        }
    }

    func testCancellationDiscardsBufferedAudio() async throws {
        let pipe = TTSAudioPipe.make(highWatermark: 10, lowWatermark: 5)
        try await pipe.sink.yield(.init(samples: [1, 2, 3], format: format))
        await pipe.source.cancel()

        do {
            _ = try await pipe.source.next()
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // expected
        }
    }

    private func second() -> TTSAudioFrame {
        TTSAudioFrame(samples: [Float](repeating: 0, count: 10), format: format)
    }

    private func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }

    func testProducerBlocksAtHighWatermarkAndResumesOnlyBelowLowWatermark() async throws {
        let pipe = TTSAudioPipe.make(highWatermark: 2, lowWatermark: 1)
        let progress = PipeProgress()
        let frame = second()
        let producer = Task {
            for _ in 0..<3 {
                try await pipe.sink.yield(frame)
                await progress.increment()
            }
        }

        // Deterministically wait for "the third yield is now blocked" instead of guessing with a
        // fixed number of yields: poll the pipe's own count of suspended producers.
        let blockedDeadline = Date().addingTimeInterval(5)
        while await pipe.sink.waitingProducerCount != 1, Date() < blockedDeadline {
            await Task.yield()
        }
        let waitingBeforeDrain = await pipe.sink.waitingProducerCount
        XCTAssertEqual(waitingBeforeDrain, 1, "the third 1s frame must wait: 2s buffered reached the 2s high watermark")
        let beforeDrain = await progress.value
        XCTAssertEqual(beforeDrain, 2, "the third 1s frame must wait: 2s buffered reached the 2s high watermark")

        _ = try await pipe.source.next()   // 1s buffered: not below the 1s low watermark yet
        // `next()` is an actor call that runs to completion (including any `resumeProducers()`
        // decision) before returning, so the count is already settled here -- no settle() needed.
        let waitingAfterFirstDrain = await pipe.sink.waitingProducerCount
        XCTAssertEqual(waitingAfterFirstDrain, 1, "hysteresis: the producer stays blocked until buffered < low watermark")
        let afterFirstDrain = await progress.value
        XCTAssertEqual(afterFirstDrain, 2, "hysteresis: the producer stays blocked until buffered < low watermark")

        _ = try await pipe.source.next()   // 0s buffered: below low watermark
        try await producer.value
        let afterSecondDrain = await progress.value
        XCTAssertEqual(afterSecondDrain, 3)
    }

    func testBlockedProducerIsWokenByCancelAndThrowsCancellation() async throws {
        let pipe = TTSAudioPipe.make(highWatermark: 1, lowWatermark: 0.5)
        let frame = second()
        try await pipe.sink.yield(frame)
        let blocked = Task { try await pipe.sink.yield(frame) }
        await settle()

        await pipe.source.cancel()

        do {
            try await blocked.value
            XCTFail("A producer woken by cancel must throw")
        } catch is CancellationError {
            // expected
        }
    }

    func testBlockedProducerIsWokenByFinishAndThrowsCancellation() async throws {
        let pipe = TTSAudioPipe.make(highWatermark: 1, lowWatermark: 0.5)
        let frame = second()
        try await pipe.sink.yield(frame)
        let blocked = Task { try await pipe.sink.yield(frame) }
        await settle()

        await pipe.sink.finish()

        do {
            try await blocked.value
            XCTFail("A producer woken by finish must not enqueue after the terminal state")
        } catch is CancellationError {
            // expected
        }
        let first = try await pipe.source.next()
        let end = try await pipe.source.next()
        XCTAssertEqual(first?.samples.count, 10, "audio accepted before finish is kept")
        XCTAssertNil(end)
    }

    func testBlockedConsumerIsWokenByYield() async throws {
        let pipe = TTSAudioPipe.make(highWatermark: 10, lowWatermark: 5)
        let consumer = Task { try await pipe.source.next() }
        await settle()

        try await pipe.sink.yield(.init(samples: [7], format: format))

        let frame = try await consumer.value
        XCTAssertEqual(frame?.samples, [7])
    }

    func testBlockedConsumerIsWokenByFinishWithNil() async throws {
        let pipe = TTSAudioPipe.make(highWatermark: 10, lowWatermark: 5)
        let consumer = Task { try await pipe.source.next() }
        await settle()

        await pipe.sink.finish()

        let frame = try await consumer.value
        XCTAssertNil(frame)
    }

    func testBlockedConsumerIsWokenByFailureWithTheError() async {
        enum Boom: Error { case boom }
        let pipe = TTSAudioPipe.make(highWatermark: 10, lowWatermark: 5)
        let consumer = Task { try await pipe.source.next() }
        await settle()

        await pipe.sink.fail(Boom.boom)

        do {
            _ = try await consumer.value
            XCTFail("Expected the failure")
        } catch is Boom {
            // expected
        } catch {
            XCTFail("Unexpected \(error)")
        }
    }

    func testBlockedConsumerIsWokenByCancelWithCancellation() async {
        let pipe = TTSAudioPipe.make(highWatermark: 10, lowWatermark: 5)
        let consumer = Task { try await pipe.source.next() }
        await settle()

        await pipe.source.cancel()

        do {
            _ = try await consumer.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("Unexpected \(error)")
        }
    }

    func testYieldAfterAnyTerminalStateThrowsCancellation() async {
        enum Boom: Error { case boom }
        let finished = TTSAudioPipe.make(highWatermark: 10, lowWatermark: 5)
        await finished.sink.finish()
        let failed = TTSAudioPipe.make(highWatermark: 10, lowWatermark: 5)
        await failed.sink.fail(Boom.boom)
        let cancelled = TTSAudioPipe.make(highWatermark: 10, lowWatermark: 5)
        await cancelled.sink.cancel()

        for sink in [finished.sink, failed.sink, cancelled.sink] {
            do {
                try await sink.yield(.init(samples: [1], format: format))
                XCTFail("yield after a terminal state must throw")
            } catch is CancellationError {
                // expected
            } catch {
                XCTFail("Unexpected \(error)")
            }
        }
    }
}

private actor PipeProgress {
    private(set) var value = 0
    func increment() { value += 1 }
}
