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
}
