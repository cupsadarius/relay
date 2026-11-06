import FluidAudio
import XCTest

@testable import Relay

/// PocketTTS-specific model facts: the hand-rolled presence check against real temporary
/// directories, file removal, and the frame stream adapter. Load rules live in
/// `ModelSessionLoaderTests`; the backend path lives in `PocketTTSBackendTests`.
final class PocketTTSModelTests: XCTestCase {
    func testRemoveDropsTheSessionAndRechecksPresence() async throws {
        let loader = FakePocketTTSModelLoader()
        await loader.setPresent(true)
        let model = PocketTTSModel.pocketTTS(loader: loader)
        try await model.load()

        try await model.remove()

        do {
            try await model.load()
            XCTFail("Expected presence to be rechecked")
        } catch {
            XCTAssertEqual(error as? PocketTTSEngineError, .modelsNotDownloaded)
        }
        let loadLocalCalls = await loader.loadLocalCallCount
        XCTAssertEqual(loadLocalCalls, 1)
    }

    func testRemoveModelsDeletesOnlyVersionedEnglishDirectoryAndIsIdempotent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let english = root.appendingPathComponent("Models/pocket-tts/v2.1/english")
        let siblingLanguage = root.appendingPathComponent("Models/pocket-tts/v2.1/spanish")
        let unrelated = root.appendingPathComponent("Models/other-provider")
        for directory in [english, siblingLanguage, unrelated] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let loader = FluidAudioPocketTTSModelLoader(cacheDirectory: root)

        try await loader.removeModels()
        try await loader.removeModels()

        XCTAssertFalse(FileManager.default.fileExists(atPath: english.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: siblingLanguage.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    /// Regression test for the "cache directory always exists" trap: a naive presence check based
    /// on the outer cache directory's existence would always report `true`. This exercises the
    /// real, hand-rolled `FluidAudioPocketTTSModelLoader.modelsArePresent()` against a throwaway
    /// temp directory (never the real cache) that has the outer directory but no
    /// `Models/pocket-tts/*` model bundles.
    func testModelsArePresentReturnsFalseWhenOnlyTheOuterDirectoryExistsButNoModelBundlesDo() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let loader = FluidAudioPocketTTSModelLoader(cacheDirectory: tempDirectory)
        let present = await loader.modelsArePresent()

        XCTAssertFalse(present, "An outer directory with no model bundles must not be reported as present")
    }

    func testModelsArePresentReturnsTrueOnlyWhenEveryRequiredModelExists() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        // Matches `FluidAudioPocketTTSModelLoader.modelsDirectory`: FluidAudio 0.15 nests each
        // language pack under a versioned subdirectory (`v2.1/<language>/`), computed here the
        // same way rather than hardcoded so this test tracks the loader instead of drifting from
        // it.
        let modelsDirectory =
            tempDirectory
            .appendingPathComponent(PocketTtsConstants.defaultModelsSubdirectory)
            .appendingPathComponent(Repo.pocketTts.folderName)
            .appendingPathComponent(PocketTtsLanguage.english.repoSubdirectory)
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let loader = FluidAudioPocketTTSModelLoader(cacheDirectory: tempDirectory)
        let requiredModels = Array(ModelNames.PocketTTS.requiredModels)

        // Only the first required model exists: still not present.
        try FileManager.default.createDirectory(
            at: modelsDirectory.appendingPathComponent(requiredModels[0]),
            withIntermediateDirectories: true
        )
        var present = await loader.modelsArePresent()
        XCTAssertFalse(present, "Must require every model bundle, not just one")

        // Every required model exists: present.
        for model in requiredModels {
            try FileManager.default.createDirectory(
                at: modelsDirectory.appendingPathComponent(model),
                withIntermediateDirectories: true
            )
        }
        present = await loader.modelsArePresent()
        XCTAssertTrue(present)
    }

    func testFrameStreamAdapterPullsUpstreamOnlyAsTheConsumerAsks() async throws {
        let pulls = PullCounter()
        let upstream = AsyncThrowingStream<Int, Error>(unfolding: {
            let pull = await pulls.increment()
            return pull <= 5 ? pull : nil
        })
        let mapped = PocketTTSFrameStream.samples(from: upstream) { [Float($0)] }

        var iterator = mapped.makeAsyncIterator()
        let first = try await iterator.next()
        for _ in 0..<50 { await Task.yield() }

        XCTAssertEqual(first, [1])
        let pulled = await pulls.value
        XCTAssertEqual(pulled, 1, "the adapter must not drain FluidAudio's stream ahead of the consumer")
    }

    func testFrameStreamAdapterForwardsElementsThenUpstreamErrors() async {
        let upstream = AsyncThrowingStream<Int, Error> { continuation in
            continuation.yield(7)
            continuation.finish(throwing: FakeLoaderError.boom)
        }
        let mapped = PocketTTSFrameStream.samples(from: upstream) { [Float($0)] }

        var received: [[Float]] = []
        do {
            for try await samples in mapped { received.append(samples) }
            XCTFail("Expected the upstream error")
        } catch {
            XCTAssertEqual(error as? FakeLoaderError, .boom)
        }
        XCTAssertEqual(received, [[7]])
    }
}

private enum FakeLoaderError: Error, Equatable {
    case boom
}

private actor PullCounter {
    private(set) var value = 0
    func increment() -> Int {
        value += 1
        return value
    }
}

private struct FakePocketTTSSession: PocketTTSModelSession {
    func synthesizeStream(text: String, voice: String) async throws -> AsyncThrowingStream<[Float], Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private actor FakePocketTTSModelLoader: PocketTTSModelLoading {
    private var present = false
    private(set) var loadLocalCallCount = 0

    func setPresent(_ value: Bool) { present = value }
    func modelsArePresent() async -> Bool { present }
    func removeModels() async throws { present = false }

    func loadLocal() async throws -> any PocketTTSModelSession {
        loadLocalCallCount += 1
        return FakePocketTTSSession()
    }

    func downloadAndLoad(progress: @escaping @Sendable (Double) -> Void) async throws -> any PocketTTSModelSession {
        FakePocketTTSSession()
    }
}
