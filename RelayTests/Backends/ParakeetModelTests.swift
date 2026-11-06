import XCTest

@testable import Relay

/// Parakeet-specific model facts: where each live loader keeps its files, and how audio is padded
/// before the loaded model sees it. Load rules live in `ModelSessionLoaderTests`; the backend path
/// lives in `ParakeetBackendTests`.
final class ParakeetModelTests: XCTestCase {
    func testLiveLoadersUseTheirOwnCacheDirectoriesAndTrailingSilence() {
        let v2 = ParakeetV2ModelLoader()
        let unified = ParakeetUnifiedModelLoader()

        XCTAssertEqual(v2.modelDirectory.lastPathComponent, "parakeet-tdt-0.6b-v2")
        XCTAssertEqual(unified.modelDirectory.lastPathComponent, "parakeet-unified-en-0.6b")
        XCTAssertEqual(v2.trailingSilenceSampleCount, 0)
        XCTAssertEqual(unified.trailingSilenceSampleCount, 6_400)
    }

    func testPadsShortSamplesUpToTheMinimumLength() async throws {
        let received = try await transcribe([0.1, 0.2, 0.3], trailingSilence: 0)

        XCTAssertEqual(received.count, 16_000)
        XCTAssertEqual(Array(received.prefix(3)), [0.1, 0.2, 0.3])
        XCTAssertEqual(Array(received.suffix(4)), [0, 0, 0, 0])
    }

    func testDoesNotPadSamplesAtOrAboveTheMinimumLength() async throws {
        let received = try await transcribe(Array(repeating: Float(0.5), count: 16_000), trailingSilence: 0)

        XCTAssertEqual(received.count, 16_000)
    }

    func testAppendsTrailingSilenceThenPadsToTheMinimum() async throws {
        let received = try await transcribe([0.1, 0.2, 0.3], trailingSilence: 6_400)

        XCTAssertEqual(received.count, 16_000)
        XCTAssertEqual(Array(received.prefix(3)), [0.1, 0.2, 0.3])
        XCTAssertEqual(received.dropFirst(3).allSatisfy { $0 == 0 }, true)
    }

    func testAppendsTrailingSilenceAfterALongClip() async throws {
        let received = try await transcribe(Array(repeating: Float(0.5), count: 32_000), trailingSilence: 6_400)

        XCTAssertEqual(received.count, 38_400)
        XCTAssertEqual(received[31_999], 0.5)
        XCTAssertEqual(received.suffix(6_400).allSatisfy { $0 == 0 }, true)
    }

    func testDownloadedSessionIsPaddedToo() async throws {
        let loader = FakeLoader(trailingSilenceSampleCount: 0)
        let session = try await ParakeetModel.parakeet(loader: loader).load(allowDownload: true)

        _ = try await session.transcribe(samples: [0.1])

        let received = await loader.session.receivedSamples
        XCTAssertEqual(received?.count, 16_000)
    }

    private func transcribe(_ samples: [Float], trailingSilence: Int) async throws -> [Float] {
        let loader = FakeLoader(trailingSilenceSampleCount: trailingSilence)
        let session = try await ParakeetModel.parakeet(loader: loader).load()
        _ = try await session.transcribe(samples: samples)
        return await loader.session.receivedSamples ?? []
    }
}

private actor FakeSession: ParakeetModelSession {
    private(set) var receivedSamples: [Float]?

    func transcribe(samples: [Float]) async throws -> String {
        receivedSamples = samples
        return ""
    }
}

private struct FakeLoader: ParakeetModelLoading {
    let trailingSilenceSampleCount: Int
    let session = FakeSession()

    func modelsArePresent() async -> Bool { true }
    func isModelValid() async throws -> Bool { true }
    func load() async throws -> any ParakeetModelSession { session }
    func downloadAndLoad(progress: @escaping @Sendable (Double) -> Void) async throws -> any ParakeetModelSession {
        session
    }
}
