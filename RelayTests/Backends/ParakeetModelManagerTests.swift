import XCTest

@testable import Relay

/// Both the loader and the session it loads, so `ParakeetModelManager` runs without FluidAudio.
private final class FakeParakeetLoader: ParakeetModelLoading, ParakeetModelSession, @unchecked Sendable {
    let trailingSilenceSampleCount = 0
    var modelsPresent = false
    var progressToReport: [Double] = [0.5, 1.0]
    private(set) var downloadCalls = 0

    func modelsArePresent() async -> Bool {
        modelsPresent
    }

    func isModelValid() async throws -> Bool {
        modelsPresent
    }

    func load() async throws -> any ParakeetModelSession {
        self
    }

    func downloadAndLoad(progress: @escaping @Sendable (Double) -> Void) async throws -> any ParakeetModelSession {
        downloadCalls += 1
        for fraction in progressToReport {
            progress(fraction)
        }
        return self
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
        unified: FakeParakeetLoader = FakeParakeetLoader(),
        v2: FakeParakeetLoader = FakeParakeetLoader(),
        selection: SelectionBox = SelectionBox()
    ) -> ParakeetModelManager {
        ParakeetModelManager(
            models: ParakeetModels(unifiedEnglish: .parakeet(loader: unified), v2: .parakeet(loader: v2)),
            selectedModel: { selection.value },
            setSelectedModel: { selection.value = $0 }
        )
    }

    func testListsBothModelsAndDefaultsToUnified() async {
        let manager = makeManager()

        XCTAssertEqual(manager.backendID, .parakeet)

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
        let unified = FakeParakeetLoader()
        unified.modelsPresent = true
        let models = await makeManager(unified: unified).models()

        XCTAssertEqual(models.map(\.installState), [.downloaded, .notDownloaded])
    }

    func testDownloadUsesTheNamedModelWithProgress() async throws {
        let unified = FakeParakeetLoader()
        let v2 = FakeParakeetLoader()
        let manager = makeManager(unified: unified, v2: v2)
        var reportedProgress: [Double] = []

        try await manager.downloadModel("parakeet-v2", progress: { reportedProgress.append($0) })

        XCTAssertEqual(v2.downloadCalls, 1)
        XCTAssertEqual(unified.downloadCalls, 0)
        XCTAssertEqual(reportedProgress, [0.5, 1.0])
    }

    func testSelectModelCallsTheWriterAndNeverDownloads() async throws {
        let unified = FakeParakeetLoader()
        let v2 = FakeParakeetLoader()
        let selection = SelectionBox()

        try await makeManager(unified: unified, v2: v2, selection: selection).selectModel("parakeet-v2")

        XCTAssertEqual(selection.value, .v2)
        XCTAssertEqual(v2.downloadCalls, 0, "selectModel must never download")
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
