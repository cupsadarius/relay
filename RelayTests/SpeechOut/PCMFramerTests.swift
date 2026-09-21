import XCTest
@testable import Relay

final class PCMFramerTests: XCTestCase {
    func testFramesPreserveSamplesAndFormat() throws {
        let samples = Array(repeating: Float(0.25), count: 4_800)
        let frames = try PCMFramer(frameDuration: 0.08).frames(samples: samples, sampleRate: 24_000)

        XCTAssertEqual(frames.count, 3)
        XCTAssertEqual(frames.flatMap(\.samples), samples)
        XCTAssertTrue(frames.allSatisfy { $0.format == TTSAudioFormat(sampleRate: 24_000, channelCount: 1) })
        XCTAssertEqual(frames[0].samples.count, 1_920)
    }

    func testRejectsUnalignedInterleavedSamples() {
        XCTAssertThrowsError(
            try PCMFramer().frames(samples: [0, 1, 2], sampleRate: 24_000, channelCount: 2)
        ) { error in
            XCTAssertEqual(error as? PCMFramerError, .unalignedSamples)
        }
    }
}
