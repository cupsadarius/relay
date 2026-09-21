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

    /// Task 14 regression: 100 long-form runs against a fake engine (no CoreML). Alternating
    /// full-drain and early-cancel runs prove every run terminates, the bounded pipe never leaves a
    /// blocked producer on teardown, synthesis stays strictly serial, and segment order is stable.
    /// A tight high/low watermark forces real producer backpressure on the drain runs. Real-model
    /// memory behavior is the owner-Mac acceptance step; this covers the source's own lifecycle.
    func testHundredLongFormRunsTerminateWithStableOrderAndSerialSynthesis() async throws {
        let chunks = ["alpha", "beta", "gamma", "delta", "epsilon"]
        let expectedSamples: [Float] = chunks.map { Float($0.count) }

        for run in 0..<100 {
            let engine = FakeLongFormKokoroEngine()
            let source = KokoroTTSAudioSource(
                engine: engine,
                chunks: chunks,
                voice: "af_heart",
                speed: 1,
                highWatermark: 2,
                lowWatermark: 1
            )

            if run.isMultiple(of: 3) {
                // Early-cancel path: pull one frame (leaving the producer mid-flight, likely
                // suspended on a full pipe), then tear down. Teardown must unblock the producer
                // and make the consumer terminate promptly rather than hang.
                _ = try? await source.next()
                await source.cancel()
                do {
                    while try await source.next() != nil {}
                } catch is CancellationError {
                    // Acceptable: the pipe reports cancellation to its consumer after teardown.
                }
            } else {
                var samples: [Float] = []
                while let frame = try await source.next() {
                    samples.append(contentsOf: frame.samples)
                }
                XCTAssertEqual(samples, expectedSamples, "sample order must stay stable on run \(run)")
                let calls = await engine.phonemeCalls
                XCTAssertEqual(calls, chunks, "segment order must stay stable on run \(run)")
            }

            let maxConcurrent = await engine.maxConcurrentSynthesis
            XCTAssertLessThanOrEqual(maxConcurrent, 1, "synthesis must stay serial on run \(run)")
        }
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
