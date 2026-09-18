import XCTest

@testable import Relay

/// A fake `ParakeetEngine` -- the same seam `ParakeetBackend` and `FluidAudioParakeetEngineTests`
/// use -- so `ParakeetModelManager` can be exercised without constructing FluidAudio/CoreML
/// types. Kept local to this file (mirrors `ParakeetBackendTests`' own `FakeParakeetEngine`,
/// which is `private` there too) since the two fakes' needs have already diverged slightly.
private final class FakeParakeetModelEngine: ParakeetEngine {
    var modelsPresent = false
    var progressToReport: [Double] = [0.5, 1.0]
    private(set) var loadCalls: [Bool] = []

    func modelsArePresent() async -> Bool {
        modelsPresent
    }

    func load(allowDownload: Bool, progress: @escaping @Sendable (Double) -> Void) async throws {
        loadCalls.append(allowDownload)
        for fraction in progressToReport {
            progress(fraction)
        }
    }

    func transcribe(samples: [Float]) async throws -> String {
        ""
    }
}

final class ParakeetModelManagerTests: XCTestCase {
    func testBackendIDAndSingleModel() async {
        let manager = ParakeetModelManager(engine: FakeParakeetModelEngine())

        XCTAssertEqual(manager.backendID, "parakeet")

        let models = await manager.models()

        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models[0].descriptor.id, "parakeet-v2")
        XCTAssertTrue(models[0].isSelected)
    }

    func testInstallStateReflectsPresence() async {
        let presentEngine = FakeParakeetModelEngine()
        presentEngine.modelsPresent = true
        let presentManager = ParakeetModelManager(engine: presentEngine)
        let presentModels = await presentManager.models()
        XCTAssertEqual(presentModels[0].installState, .downloaded)

        let absentEngine = FakeParakeetModelEngine()
        absentEngine.modelsPresent = false
        let absentManager = ParakeetModelManager(engine: absentEngine)
        let absentModels = await absentManager.models()
        XCTAssertEqual(absentModels[0].installState, .notDownloaded)
    }

    func testDownloadDelegatesToParakeetDownloadWithProgress() async throws {
        let engine = FakeParakeetModelEngine()
        let manager = ParakeetModelManager(engine: engine)
        var reportedProgress: [Double] = []

        try await manager.downloadModel("parakeet-v2", progress: { reportedProgress.append($0) })

        XCTAssertEqual(engine.loadCalls, [true])
        XCTAssertEqual(reportedProgress, [0.5, 1.0])
    }

    func testSelectIsNoOpSuccessForTheOneModel() async throws {
        let engine = FakeParakeetModelEngine()
        let manager = ParakeetModelManager(engine: engine)

        try await manager.selectModel("parakeet-v2")

        XCTAssertTrue(engine.loadCalls.isEmpty, "selectModel must not touch the engine")
    }

    func testUnknownModelIdThrows() async {
        let manager = ParakeetModelManager(engine: FakeParakeetModelEngine())

        do {
            try await manager.downloadModel("whisper-large", progress: { _ in })
            XCTFail("Expected unknownModel")
        } catch let error as ParakeetModelManagerError {
            XCTAssertEqual(error, .unknownModel("whisper-large"))
        } catch {
            XCTFail("expected ParakeetModelManagerError, got \(error)")
        }

        do {
            try await manager.selectModel("whisper-large")
            XCTFail("Expected unknownModel")
        } catch let error as ParakeetModelManagerError {
            XCTAssertEqual(error, .unknownModel("whisper-large"))
        } catch {
            XCTFail("expected ParakeetModelManagerError, got \(error)")
        }
    }

    func testRemoveBehaviour() async {
        let manager = ParakeetModelManager(engine: FakeParakeetModelEngine())

        do {
            try await manager.removeModel("parakeet-v2")
            XCTFail("Expected removeNotSupported")
        } catch let error as ParakeetModelManagerError {
            XCTAssertEqual(error, .removeNotSupported)
        } catch {
            XCTFail("expected ParakeetModelManagerError, got \(error)")
        }
    }
}
