import XCTest
@testable import Relay

final class PocketTTSAudioSourceTests: XCTestCase {
    func testYieldsFramesInOrderWith24kHzMonoMetadata() async throws {
        let stream = AsyncThrowingStream<[Float], Error> { continuation in
            continuation.yield([0.1, 0.2])
            continuation.yield([0.3, 0.4, 0.5])
            continuation.finish()
        }
        let source = PocketTTSAudioSource(stream: stream, sampleRate: 24_000)

        let first = try await source.next()
        XCTAssertEqual(first?.samples, [0.1, 0.2])
        XCTAssertEqual(first?.format, TTSAudioFormat(sampleRate: 24_000, channelCount: 1))

        let second = try await source.next()
        XCTAssertEqual(second?.samples, [0.3, 0.4, 0.5])
        XCTAssertEqual(second?.format, TTSAudioFormat(sampleRate: 24_000, channelCount: 1))

        let end = try await source.next()
        XCTAssertNil(end, "a finished stream ends the source")
    }

    func testPropagatesSourceError() async {
        struct SynthesisFailure: Error {}
        let stream = AsyncThrowingStream<[Float], Error> { continuation in
            continuation.yield([0.1])
            continuation.finish(throwing: SynthesisFailure())
        }
        let source = PocketTTSAudioSource(stream: stream, sampleRate: 24_000)

        let first = try? await source.next()
        XCTAssertEqual(first?.samples, [0.1])

        do {
            _ = try await source.next()
            XCTFail("Expected the stream failure to propagate")
        } catch is SynthesisFailure {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCancelStopsIteration() async throws {
        let stream = AsyncThrowingStream<[Float], Error> { continuation in
            continuation.yield([0.1])
            continuation.yield([0.2])
            continuation.finish()
        }
        let source = PocketTTSAudioSource(stream: stream, sampleRate: 24_000)

        let first = try await source.next()
        XCTAssertEqual(first?.samples, [0.1])

        await source.cancel()
        let afterCancel = try await source.next()
        XCTAssertNil(afterCancel, "a cancelled source yields no more frames")
    }
}
