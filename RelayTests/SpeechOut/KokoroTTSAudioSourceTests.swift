import Foundation
import XCTest
@testable import Relay

final class KokoroTTSAudioSourceTests: XCTestCase {
    func testSegmentsSynthesizeSequentiallyAndPreserveOrder() async throws {
        let engine = FakeLongFormKokoroEngine()
        let source = KokoroTTSAudioSource(
            engine: engine,
            chunks: ["one", "two", "three"],
            voice: "af_heart",
            speed: 1,
            highWatermark: 10,
            lowWatermark: 5
        )

        var samples: [Float] = []
        while let frame = try await source.next() {
            samples.append(contentsOf: frame.samples)
        }

        let calls = await engine.phonemeCalls
        XCTAssertEqual(calls, ["one", "two", "three"])
        XCTAssertEqual(samples, [3, 3, 5])
        let maxConcurrent = await engine.maxConcurrentSynthesis
        XCTAssertEqual(maxConcurrent, 1)
    }

    func testAcousticOverflowSplitsOnlyTheOffendingChunkAndRetries() async throws {
        let engine = FakeLongFormKokoroEngine(maxAcceptedLength: 4)
        let source = KokoroTTSAudioSource(
            engine: engine,
            chunks: ["abcdefgh"],
            voice: "af_heart",
            speed: 1,
            highWatermark: 10,
            lowWatermark: 5
        )

        var produced: [Float] = []
        while let frame = try await source.next() {
            produced.append(contentsOf: frame.samples)
        }

        let calls = await engine.phonemeCalls
        XCTAssertEqual(calls.first, "abcdefgh")
        XCTAssertTrue(calls.dropFirst().allSatisfy { $0.count <= 4 })
        XCTAssertEqual(calls.dropFirst().joined(), "abcdefgh")
        XCTAssertEqual(produced, [4, 4])
    }
}

private actor FakeLongFormKokoroEngine: KokoroEngine {
    private let maxAcceptedLength: Int?
    private(set) var phonemeCalls: [String] = []
    private(set) var maxConcurrentSynthesis = 0
    private var inFlightSynthesis = 0

    init(maxAcceptedLength: Int? = nil) {
        self.maxAcceptedLength = maxAcceptedLength
    }

    func modelsArePresent() async -> Bool { true }

    func load(
        allowDownload: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {}

    func synthesize(text: String, voice: String, speed: Float) async throws -> Data {
        Data()
    }

    func phonemes(for text: String) async throws -> String { text }

    func synthesize(phonemes: String, voice: String, speed: Float) async throws -> KokoroPCM {
        phonemeCalls.append(phonemes)
        inFlightSynthesis += 1
        maxConcurrentSynthesis = max(maxConcurrentSynthesis, inFlightSynthesis)
        defer { inFlightSynthesis -= 1 }

        if let maxAcceptedLength, phonemes.count > maxAcceptedLength {
            throw KokoroEngineError.acousticFramesTooLong
        }
        return KokoroPCM(samples: [Float(phonemes.count)], sampleRate: 12.5)
    }
}
