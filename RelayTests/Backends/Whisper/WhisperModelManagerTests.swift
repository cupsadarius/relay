import Foundation
import XCTest

@testable import Relay

/// Writes a `.verified` marker (empty manifest -- `WhisperModelStore.presence(of:)` only
/// re-checks paths *listed* in the manifest, so an empty one is trivially satisfied) so tests can
/// mark a model "present" without exercising the real download/verify flow. Mirrors
/// `WhisperBackendTests`' helper of the same shape.
private func markWhisperModelPresent(_ id: WhisperModelID, in cacheDirectory: URL) throws {
    let directory = cacheDirectory.appendingPathComponent(id.rawValue, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let markerURL = directory.appendingPathComponent(".verified")
    try JSONEncoder().encode([String]()).write(to: markerURL)
}

/// Maps a `WhisperModelID` to a deterministic fake folder URL for a `WhisperRuntime` under test --
/// mirrors `WhisperRuntimeTests`'/`WhisperBackendTests`' own convention.
private func fakeManagerModelFolder(for id: WhisperModelID) -> URL {
    URL(fileURLWithPath: "/fake/whisper-manager-models/\(id.rawValue)", isDirectory: true)
}

/// A trivial in-memory selection "store" a test can both read and mutate through the closure pair
/// `WhisperModelManager` expects, without touching `AppSettings`.
private final class FakeSelectionStore: @unchecked Sendable {
    private let lock = NSLock()
    private var value: WhisperModelID?

    init(_ initial: WhisperModelID? = nil) {
        value = initial
    }

    var get: WhisperModelSelection {
        { [weak self] in
            self?.lock.lock()
            defer { self?.lock.unlock() }
            return self?.value ?? nil
        }
    }

    var set: WhisperModelSelectionWriter {
        { [weak self] newValue in
            self?.lock.lock()
            self?.value = newValue
            self?.lock.unlock()
        }
    }

    var current: WhisperModelID? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

final class WhisperModelManagerTests: XCTestCase {
    private var tempDirectory: URL!
    private var store: WhisperModelStore!
    private var log: FakeWhisperEventLog!
    private var engine: FakeWhisperEngine!
    private var runtime: WhisperRuntime!
    private var selection: FakeSelectionStore!
    private var manager: WhisperModelManager!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperModelManagerTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        store = WhisperModelStore(cacheDirectory: tempDirectory, downloader: FakeWhisperDownloader())
        log = FakeWhisperEventLog()
        engine = FakeWhisperEngine(log: log)
        runtime = WhisperRuntime(engine: engine, modelFolder: fakeManagerModelFolder(for:))
        selection = FakeSelectionStore()

        manager = WhisperModelManager(
            store: store,
            runtime: runtime,
            selectedModel: selection.get,
            setSelectedModel: selection.set
        )
    }

    override func tearDown() {
        manager = nil
        selection = nil
        runtime = nil
        engine = nil
        log = nil
        store = nil
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
        super.tearDown()
    }

    func testBackendIDIsWhisper() {
        XCTAssertEqual(manager.backendID, "whisper")
    }

    func testModelsReportsAllElevenWithCorrectInstalledFlags() async throws {
        try markWhisperModelPresent(.tinyEn, in: tempDirectory)
        try markWhisperModelPresent(.baseEn, in: tempDirectory)

        let models = await manager.models()

        XCTAssertEqual(models.count, WhisperModelID.allCases.count)
        XCTAssertEqual(models.map(\.id), WhisperModelID.allCases.map(\.rawValue))

        for status in models {
            let expectedInstalled: SpeechModelInstallState = [
                WhisperModelID.tinyEn.rawValue,
                WhisperModelID.baseEn.rawValue,
            ].contains(status.id) ? .downloaded : .notDownloaded
            XCTAssertEqual(status.installState, expectedInstalled, "unexpected installState for \(status.id)")
        }
    }

    func testModelsDescriptorMapsEnglishOnlyAndSize() async {
        let models = await manager.models()

        let tinyEn = models.first { $0.id == WhisperModelID.tinyEn.rawValue }!
        XCTAssertEqual(tinyEn.descriptor.displayName, "Tiny (English)")
        XCTAssertEqual(tinyEn.descriptor.detail, "English only")
        XCTAssertEqual(tinyEn.descriptor.approximateDownloadBytes, 76_650_906)

        let tiny = models.first { $0.id == WhisperModelID.tiny.rawValue }!
        XCTAssertEqual(tiny.descriptor.detail, "Multilingual")
    }

    func testSelectPersistsSelectionAndDoesNotDownloadOrLoad() async throws {
        // .smallEn is deliberately not downloaded.
        try await manager.selectModel(WhisperModelID.smallEn.rawValue)

        XCTAssertEqual(selection.current, .smallEn)
        XCTAssertFalse(store.presence(of: .smallEn))
        let modelsAfter = await manager.models()
        let status = modelsAfter.first { $0.id == WhisperModelID.smallEn.rawValue }!
        XCTAssertTrue(status.isSelected)
        XCTAssertEqual(status.installState, .notDownloaded)
        XCTAssertFalse(status.isLoaded)
        XCTAssertEqual(log.all, [], "selecting must not trigger any runtime load")
    }

    func testDownloadModelDelegatesToStoreWithProgress() async throws {
        var reportedProgress: [Double] = []

        try await manager.downloadModel(WhisperModelID.tinyEn.rawValue) { value in
            reportedProgress.append(value)
        }

        XCTAssertTrue(store.presence(of: .tinyEn))
        XCTAssertEqual(reportedProgress, [1.0])

        let models = await manager.models()
        let status = models.first { $0.id == WhisperModelID.tinyEn.rawValue }!
        XCTAssertEqual(status.installState, .downloaded)
        XCTAssertFalse(status.isSelected)
        XCTAssertFalse(status.isLoaded)
    }

    func testRemoveLoadedModelUnloadsRuntimeFirstThenDeletes() async throws {
        try markWhisperModelPresent(.baseEn, in: tempDirectory)
        try await runtime.activate(.baseEn)
        let loadedBefore = await runtime.currentModelID
        XCTAssertEqual(loadedBefore, .baseEn)

        try await manager.removeModel(WhisperModelID.baseEn.rawValue)

        XCTAssertEqual(log.all, [.loaded(.baseEn), .unloaded(.baseEn)])
        let loadedAfter = await runtime.currentModelID
        XCTAssertNil(loadedAfter)
        XCTAssertFalse(store.presence(of: .baseEn))
    }

    func testRemoveNotLoadedModelDeletesDirectly() async throws {
        try markWhisperModelPresent(.baseEn, in: tempDirectory)
        try markWhisperModelPresent(.smallEn, in: tempDirectory)
        try await runtime.activate(.baseEn)
        let eventsBeforeRemove = log.all

        try await manager.removeModel(WhisperModelID.smallEn.rawValue)

        XCTAssertEqual(log.all, eventsBeforeRemove, "removing a not-loaded model must not touch the runtime")
        XCTAssertFalse(store.presence(of: .smallEn))
        XCTAssertTrue(store.presence(of: .baseEn))
        let stillLoaded = await runtime.currentModelID
        XCTAssertEqual(stillLoaded, .baseEn)
    }

    func testDownloadedSelectedLoadedAreIndependent() async throws {
        // .baseEn: downloaded + selected, but never activated on the runtime -- not loaded.
        try markWhisperModelPresent(.baseEn, in: tempDirectory)
        try await manager.selectModel(WhisperModelID.baseEn.rawValue)

        // .smallEn: loaded on the runtime directly, but neither downloaded (per the store) nor
        // selected -- representable because the manager never forces these three together.
        try await runtime.activate(.smallEn)

        let models = await manager.models()
        let baseEn = models.first { $0.id == WhisperModelID.baseEn.rawValue }!
        XCTAssertEqual(baseEn.installState, .downloaded)
        XCTAssertTrue(baseEn.isSelected)
        XCTAssertFalse(baseEn.isLoaded)

        let smallEn = models.first { $0.id == WhisperModelID.smallEn.rawValue }!
        XCTAssertEqual(smallEn.installState, .notDownloaded)
        XCTAssertFalse(smallEn.isSelected)
        XCTAssertTrue(smallEn.isLoaded)
    }

    func testRemovingSelectedModelLeavesSelectionInPlace() async throws {
        try markWhisperModelPresent(.baseEn, in: tempDirectory)
        try await manager.selectModel(WhisperModelID.baseEn.rawValue)

        try await manager.removeModel(WhisperModelID.baseEn.rawValue)

        XCTAssertEqual(selection.current, .baseEn)
        let models = await manager.models()
        let status = models.first { $0.id == WhisperModelID.baseEn.rawValue }!
        XCTAssertTrue(status.isSelected)
        XCTAssertEqual(status.installState, .notDownloaded)
    }

    func testUnknownModelIdIsHandled() async {
        do {
            try await manager.selectModel("not-a-real-model")
            XCTFail("expected selectModel to throw for an unknown id")
        } catch let error as WhisperModelManagerError {
            XCTAssertEqual(error, .unknownModel("not-a-real-model"))
        } catch {
            XCTFail("expected WhisperModelManagerError, got \(error)")
        }

        do {
            try await manager.downloadModel("not-a-real-model") { _ in }
            XCTFail("expected downloadModel to throw for an unknown id")
        } catch let error as WhisperModelManagerError {
            XCTAssertEqual(error, .unknownModel("not-a-real-model"))
        } catch {
            XCTFail("expected WhisperModelManagerError, got \(error)")
        }

        do {
            try await manager.removeModel("not-a-real-model")
            XCTFail("expected removeModel to throw for an unknown id")
        } catch let error as WhisperModelManagerError {
            XCTAssertEqual(error, .unknownModel("not-a-real-model"))
        } catch {
            XCTFail("expected WhisperModelManagerError, got \(error)")
        }
    }
}
