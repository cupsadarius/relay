import XCTest

@testable import Relay

/// A fake `ParakeetEngine` -- the same seam `ParakeetBackend` and `FluidAudioParakeetEngineTests`
/// use -- so `ParakeetModelManager` can be exercised without constructing FluidAudio/CoreML
/// types. Kept local to this file (mirrors `ParakeetBackendTests`' own `FakeParakeetEngine`,
/// which is `private` there too) since the two fakes' needs have already diverged slightly.
private final class FakeParakeetModelEngine: ParakeetEngine, @unchecked Sendable {
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
    private final class SelectionBox: @unchecked Sendable {
        var value: ParakeetModelID?
    }

    private func makeManager(
        unified: FakeParakeetModelEngine = FakeParakeetModelEngine(),
        v2: FakeParakeetModelEngine = FakeParakeetModelEngine(),
        selection: SelectionBox = SelectionBox()
    ) -> ParakeetModelManager {
        ParakeetModelManager(
            engines: ParakeetEngines(unifiedEnglish: unified, v2: v2),
            selectedModel: { selection.value },
            setSelectedModel: { selection.value = $0 }
        )
    }

    func testListsBothModelsAndDefaultsToUnified() async {
        let manager = makeManager()

        XCTAssertEqual(manager.backendID, "parakeet")

        let models = await manager.models()

        XCTAssertEqual(models.map(\.descriptor.id), ["parakeet-unified-en", "parakeet-v2"])
        XCTAssertEqual(models.map(\.isSelected), [true, false])
        XCTAssertEqual(models[0].capabilities, [.download, .select])
    }

    func testSavedSelectionMarksThatModelSelected() async {
        let selection = SelectionBox()
        selection.value = .v2
        let models = await makeManager(selection: selection).models()

        XCTAssertEqual(models.map(\.isSelected), [false, true])
    }

    func testInstallStateReflectsEachModelsOwnPresence() async {
        let unified = FakeParakeetModelEngine()
        unified.modelsPresent = true
        let models = await makeManager(unified: unified).models()

        XCTAssertEqual(models.map(\.installState), [.downloaded, .notDownloaded])
    }

    func testDownloadUsesTheNamedModelsEngineWithProgress() async throws {
        let unified = FakeParakeetModelEngine()
        let v2 = FakeParakeetModelEngine()
        let manager = makeManager(unified: unified, v2: v2)
        var reportedProgress: [Double] = []

        try await manager.downloadModel("parakeet-v2", progress: { reportedProgress.append($0) })

        XCTAssertEqual(v2.loadCalls, [true])
        XCTAssertTrue(unified.loadCalls.isEmpty)
        XCTAssertEqual(reportedProgress, [0.5, 1.0])
    }

    func testSelectModelCallsTheWriterAndNeverDownloads() async throws {
        let unified = FakeParakeetModelEngine()
        let v2 = FakeParakeetModelEngine()
        let selection = SelectionBox()

        try await makeManager(unified: unified, v2: v2, selection: selection).selectModel("parakeet-v2")

        XCTAssertEqual(selection.value, .v2)
        XCTAssertFalse(v2.loadCalls.contains(true), "selectModel must never download")
    }

    func testUnknownModelIdThrows() async {
        let manager = makeManager()

        do {
            try await manager.downloadModel("whisper-large", progress: { _ in })
            XCTFail("Expected unknownModel")
        } catch let error as SpeechModelManagerError {
            XCTAssertEqual(error, .unknownModel("whisper-large"))
        } catch {
            XCTFail("expected SpeechModelManagerError, got \(error)")
        }

        do {
            try await manager.selectModel("whisper-large")
            XCTFail("Expected unknownModel")
        } catch let error as SpeechModelManagerError {
            XCTAssertEqual(error, .unknownModel("whisper-large"))
        } catch {
            XCTFail("expected SpeechModelManagerError, got \(error)")
        }
    }

    func testRemoveBehaviour() async {
        do {
            try await makeManager().removeModel("parakeet-v2")
            XCTFail("Expected removeNotSupported")
        } catch let error as SpeechModelManagerError {
            XCTAssertEqual(error, .removeNotSupported)
        } catch {
            XCTFail("expected SpeechModelManagerError, got \(error)")
        }
    }
}
