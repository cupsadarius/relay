import XCTest

@testable import Relay

final class PipedTTSAudioSourceTests: XCTestCase {
    private let format = TTSAudioFormat(sampleRate: 10, channelCount: 1)

    func testReturningProducerFinishesAfterItsFrames() async throws {
        let format = self.format
        let source = PipedTTSAudioSource { sink in
            try await sink.yield(TTSAudioFrame(samples: [1], format: format))
            try await sink.yield(TTSAudioFrame(samples: [2], format: format))
        }

        let first = try await source.next()
        let second = try await source.next()
        let end = try await source.next()
        XCTAssertEqual(first?.samples, [1])
        XCTAssertEqual(second?.samples, [2])
        XCTAssertNil(end)
    }

    func testThrowingProducerDeliversBufferedFramesThenTheError() async throws {
        struct Boom: Error {}
        let format = self.format
        let source = PipedTTSAudioSource { sink in
            try await sink.yield(TTSAudioFrame(samples: [1], format: format))
            throw Boom()
        }

        let first = try await source.next()
        XCTAssertEqual(first?.samples, [1])
        do {
            _ = try await source.next()
            XCTFail("Expected the producer error")
        } catch is Boom {
            // expected
        }
    }

    func testProducerCancellationSurfacesAsCancellation() async {
        let source = PipedTTSAudioSource { _ in throw CancellationError() }

        do {
            _ = try await source.next()
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("Unexpected \(error)")
        }
    }

    func testCancelStopsABlockedProducerAndTheConsumerSeesCancellation() async throws {
        let format = self.format
        let producerEnded = ProducerEnded()
        let source = PipedTTSAudioSource(highWatermark: 1, lowWatermark: 0.5) { sink in
            defer { Task { await producerEnded.mark() } }
            while true {
                try await sink.yield(TTSAudioFrame(samples: [Float](repeating: 0, count: 10), format: format))
            }
        }
        for _ in 0..<50 { await Task.yield() }

        await source.cancel()

        do {
            _ = try await source.next()
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // expected
        }
        var spins = 0
        while await !producerEnded.value, spins < 1_000 {
            spins += 1
            await Task.yield()
        }
        let ended = await producerEnded.value
        XCTAssertTrue(ended, "cancel() must end the producer, not just the consumer side")
    }

    func testDroppingABlockedProducerWithoutCancelStillEndsTheProducerTask() async throws {
        let format = self.format
        let producerEnded = ProducerEnded()
        var source: PipedTTSAudioSource? = PipedTTSAudioSource(highWatermark: 1, lowWatermark: 0.5) { sink in
            defer { Task { await producerEnded.mark() } }
            while true {
                try await sink.yield(TTSAudioFrame(samples: [Float](repeating: 0, count: 10), format: format))
            }
        }
        for _ in 0..<50 { await Task.yield() }

        // Drop every reference without ever calling cancel() or draining via next() -- the
        // producer is blocked in `sink.yield` at the high watermark at this point.
        source = nil

        let deadline = Date().addingTimeInterval(5)
        while await !producerEnded.value, Date() < deadline {
            await Task.yield()
        }
        let ended = await producerEnded.value
        XCTAssertTrue(ended, "dropping the source without cancel() must still end the blocked producer")
    }
}

private actor ProducerEnded {
    private(set) var value = false
    func mark() { value = true }
}
