import XCTest
@testable import Relay

/// Ports the STT `SpeechBackendCatalog` race-safety tests (see `AppModelTests.swift`) onto the
/// TTS catalog: concurrent refresh during a download must not clobber the download's visible
/// state, out-of-order/late progress ticks are ignored, a failed download can be retried, unknown
/// ids in settings are filtered, a missing row is inserted on demand, and the refusal message is
/// set and cleared at the right times.
@MainActor
final class TTSBackendCatalogTests: XCTestCase {
    func testTTSBackendStatusesDeriveFromSettingsOrderEnabledFirstThenDisabled() async {
        var settings = AppSettings.defaults
        settings.ttsBackendOrder = ["kokoro", "apple-tts"]
        let store = FakeSettingsStore(settings: settings)
        let apple = FakeTTSCatalogBackend(id: "apple-tts", displayName: "Apple System Voice")
        let kokoro = FakeTTSCatalogBackend(id: "kokoro", displayName: "Kokoro")
        let other = FakeTTSCatalogBackend(id: "other", displayName: "Other")
        let model = makeModel(store: store, ttsRegistry: ["apple-tts": apple, "kokoro": kokoro, "other": other])
        await model.initialTTSBackendRefresh?.value

        XCTAssertEqual(model.ttsBackends.map(\.id), ["kokoro", "apple-tts", "other"])
        XCTAssertEqual(model.ttsBackends.map(\.isEnabled), [true, true, false])
        XCTAssertEqual(model.ttsBackends.map(\.position), [0, 1, Int.max])
        XCTAssertEqual(model.ttsBackends.map(\.state), [.ready, .ready, .ready])
    }

    func testAppleIsAlwaysReady() async {
        let apple = FakeTTSCatalogBackend(id: "apple-tts", displayName: "Apple System Voice")
        let model = makeModel(ttsRegistry: ["apple-tts": apple])
        await model.initialTTSBackendRefresh?.value

        XCTAssertEqual(model.ttsBackends.first?.state, .ready)
    }

    func testEnablingBackendAppendsItToOrderAndPersists() async {
        var settings = AppSettings.defaults
        settings.ttsBackendOrder = ["apple-tts"]
        let store = FakeSettingsStore(settings: settings)
        let apple = FakeTTSCatalogBackend(id: "apple-tts", displayName: "Apple System Voice")
        let kokoro = FakeTTSCatalogBackend(id: "kokoro", displayName: "Kokoro")
        let model = makeModel(store: store, ttsRegistry: ["apple-tts": apple, "kokoro": kokoro])
        await model.initialTTSBackendRefresh?.value

        model.setTTSBackendEnabled("kokoro", true)

        XCTAssertEqual(model.settings.ttsBackendOrder, ["apple-tts", "kokoro"])
        XCTAssertEqual(store.saved.last?.ttsBackendOrder, ["apple-tts", "kokoro"])
        XCTAssertEqual(model.ttsBackends.first { $0.id == "kokoro" }?.isEnabled, true)
        XCTAssertEqual(model.ttsBackends.first { $0.id == "kokoro" }?.position, 1)
    }

    func testMovingEnabledBackendReordersSettings() async {
        var settings = AppSettings.defaults
        settings.ttsBackendOrder = ["apple-tts", "kokoro"]
        let store = FakeSettingsStore(settings: settings)
        let apple = FakeTTSCatalogBackend(id: "apple-tts", displayName: "Apple System Voice")
        let kokoro = FakeTTSCatalogBackend(id: "kokoro", displayName: "Kokoro")
        let model = makeModel(store: store, ttsRegistry: ["apple-tts": apple, "kokoro": kokoro])
        await model.initialTTSBackendRefresh?.value

        model.moveTTSBackend("kokoro", up: true)

        XCTAssertEqual(model.settings.ttsBackendOrder, ["kokoro", "apple-tts"])
        XCTAssertEqual(model.ttsBackends.map(\.id), ["kokoro", "apple-tts"])
    }

    func testCannotDisableTheLastEnabledBackend() async {
        var settings = AppSettings.defaults
        settings.ttsBackendOrder = ["apple-tts"]
        let store = FakeSettingsStore(settings: settings)
        let apple = FakeTTSCatalogBackend(id: "apple-tts", displayName: "Apple System Voice")
        let model = makeModel(store: store, ttsRegistry: ["apple-tts": apple])
        await model.initialTTSBackendRefresh?.value

        model.setTTSBackendEnabled("apple-tts", false)

        XCTAssertEqual(model.settings.ttsBackendOrder, ["apple-tts"])
        XCTAssertTrue(store.saved.isEmpty)
        XCTAssertEqual(model.statusText, "At least one TTS backend must stay enabled.")
    }

    func testUnknownIDsInSettingsOrderAreIgnoredAndDroppedWhenPersisted() async {
        var settings = AppSettings.defaults
        settings.ttsBackendOrder = ["ghost", "apple-tts"]
        let store = FakeSettingsStore(settings: settings)
        let apple = FakeTTSCatalogBackend(id: "apple-tts", displayName: "Apple System Voice")
        let kokoro = FakeTTSCatalogBackend(id: "kokoro", displayName: "Kokoro")
        let model = makeModel(store: store, ttsRegistry: ["apple-tts": apple, "kokoro": kokoro])
        await model.initialTTSBackendRefresh?.value

        XCTAssertEqual(model.ttsBackends.map(\.id), ["apple-tts", "kokoro"])
        XCTAssertEqual(model.ttsBackends.first { $0.id == "apple-tts" }?.position, 0)

        model.setTTSBackendEnabled("apple-tts", false)
        XCTAssertEqual(model.statusText, "At least one TTS backend must stay enabled.")

        model.setTTSBackendEnabled("kokoro", true)

        XCTAssertEqual(model.settings.ttsBackendOrder, ["apple-tts", "kokoro"])
        XCTAssertEqual(store.saved.last?.ttsBackendOrder, ["apple-tts", "kokoro"])
    }

    func testDownloadTTSModelReportsProgressThenBecomesReady() async {
        var settings = AppSettings.defaults
        settings.ttsBackendOrder = ["kokoro"]
        let store = FakeSettingsStore(settings: settings)
        let diagnostics = DiagnosticsRecorder(capacity: 10)
        let kokoro = FakeTTSCatalogBackend(id: "kokoro", displayName: "Kokoro", availability: .modelNotDownloaded)
        let downloader = FakeTTSModelManager()
        await downloader.setProgressToReport([0.5])
        await downloader.setShouldBlock(true)
        let model = makeModel(
            store: store,
            ttsRegistry: ["kokoro": kokoro],
            ttsModelManagers: ["kokoro": downloader],
            diagnostics: diagnostics
        )
        await model.initialTTSBackendRefresh?.value

        let downloadTask = Task { await model.downloadTTSModel("kokoro") }
        await waitUntil {
            model.ttsBackends.first(where: { $0.id == "kokoro" })?.state == .downloading(progress: 0.5)
        }

        kokoro.setAvailability(.available)
        await downloader.resume()
        await downloadTask.value

        XCTAssertEqual(model.ttsBackends.first(where: { $0.id == "kokoro" })?.state, .ready)
        XCTAssertEqual(model.diagnosticsEntries.map(\.event), [
            .speechModelDownloadFinished(backendID: "kokoro"),
            .speechModelDownloadStarted(backendID: "kokoro"),
        ])
        XCTAssertNil(model.ttsBackendMessage)
    }

    /// Confirms `AppModel`'s real wiring (added alongside PocketTTS's backend/registry
    /// registration) reaches the same generic, backend-agnostic download flow Kokoro already
    /// exercises above - proving the TTS catalog's Download button drives PocketTTS's registered
    /// `SpeechModelManaging` through `.downloading` progress ticks to `.ready`.
    func testDownloadPocketTTSModelReportsProgressThenBecomesReady() async {
        var settings = AppSettings.defaults
        settings.ttsBackendOrder = ["pocket-tts"]
        let store = FakeSettingsStore(settings: settings)
        let diagnostics = DiagnosticsRecorder(capacity: 10)
        let pocket = FakeTTSCatalogBackend(id: "pocket-tts", displayName: "PocketTTS", availability: .modelNotDownloaded)
        let downloader = FakeTTSModelManager()
        await downloader.setProgressToReport([0.5])
        await downloader.setShouldBlock(true)
        let model = makeModel(
            store: store,
            ttsRegistry: ["pocket-tts": pocket],
            ttsModelManagers: ["pocket-tts": downloader],
            diagnostics: diagnostics
        )
        await model.initialTTSBackendRefresh?.value

        let downloadTask = Task { await model.downloadTTSModel("pocket-tts") }
        await waitUntil {
            model.ttsBackends.first(where: { $0.id == "pocket-tts" })?.state == .downloading(progress: 0.5)
        }

        pocket.setAvailability(.available)
        await downloader.resume()
        await downloadTask.value

        XCTAssertEqual(model.ttsBackends.first(where: { $0.id == "pocket-tts" })?.state, .ready)
        XCTAssertEqual(model.diagnosticsEntries.map(\.event), [
            .speechModelDownloadFinished(backendID: "pocket-tts"),
            .speechModelDownloadStarted(backendID: "pocket-tts"),
        ])
        XCTAssertNil(model.ttsBackendMessage)
    }

    func testDownloadPocketTTSModelFailureSetsFailedStateFixedStatusTextAndDiagnostics() async {
        var settings = AppSettings.defaults
        settings.ttsBackendOrder = ["pocket-tts"]
        let store = FakeSettingsStore(settings: settings)
        let diagnostics = DiagnosticsRecorder(capacity: 10)
        let pocket = FakeTTSCatalogBackend(id: "pocket-tts", displayName: "PocketTTS", availability: .modelNotDownloaded)
        let downloader = FakeTTSModelManager()
        await downloader.setErrorToThrow(TestCatalogError.boom)
        let model = makeModel(
            store: store,
            ttsRegistry: ["pocket-tts": pocket],
            ttsModelManagers: ["pocket-tts": downloader],
            diagnostics: diagnostics
        )
        await model.initialTTSBackendRefresh?.value

        await model.downloadTTSModel("pocket-tts")

        XCTAssertEqual(model.ttsBackends.first(where: { $0.id == "pocket-tts" })?.state, .downloadFailed)
        let expectedMessage = "PocketTTS model download failed. Check your connection and try again."
        XCTAssertEqual(model.statusText, expectedMessage)
        XCTAssertEqual(model.ttsBackendMessage, expectedMessage)
        XCTAssertEqual(model.diagnosticsEntries.map(\.event), [
            .speechModelDownloadFailed(backendID: "pocket-tts"),
            .speechModelDownloadStarted(backendID: "pocket-tts"),
        ])
    }

    func testDownloadTTSModelFailureSetsFailedStateFixedStatusTextAndDiagnostics() async {
        var settings = AppSettings.defaults
        settings.ttsBackendOrder = ["kokoro"]
        let store = FakeSettingsStore(settings: settings)
        let diagnostics = DiagnosticsRecorder(capacity: 10)
        let kokoro = FakeTTSCatalogBackend(id: "kokoro", displayName: "Kokoro", availability: .modelNotDownloaded)
        let downloader = FakeTTSModelManager()
        await downloader.setErrorToThrow(TestCatalogError.boom)
        let model = makeModel(
            store: store,
            ttsRegistry: ["kokoro": kokoro],
            ttsModelManagers: ["kokoro": downloader],
            diagnostics: diagnostics
        )
        await model.initialTTSBackendRefresh?.value

        await model.downloadTTSModel("kokoro")

        XCTAssertEqual(model.ttsBackends.first(where: { $0.id == "kokoro" })?.state, .downloadFailed)
        let expectedMessage = "Kokoro model download failed. Check your connection and try again."
        XCTAssertEqual(model.statusText, expectedMessage)
        XCTAssertEqual(model.ttsBackendMessage, expectedMessage)
        XCTAssertEqual(model.diagnosticsEntries.map(\.event), [
            .speechModelDownloadFailed(backendID: "kokoro"),
            .speechModelDownloadStarted(backendID: "kokoro"),
        ])
    }

    func testDownloadCanBeRetriedAfterAFailureWithoutGettingStuck() async {
        var settings = AppSettings.defaults
        settings.ttsBackendOrder = ["kokoro"]
        let store = FakeSettingsStore(settings: settings)
        let kokoro = FakeTTSCatalogBackend(id: "kokoro", displayName: "Kokoro", availability: .modelNotDownloaded)
        let downloader = FakeTTSModelManager()
        await downloader.setErrorToThrow(TestCatalogError.boom)
        let model = makeModel(store: store, ttsRegistry: ["kokoro": kokoro], ttsModelManagers: ["kokoro": downloader])
        await model.initialTTSBackendRefresh?.value

        await model.downloadTTSModel("kokoro")
        XCTAssertEqual(model.ttsBackends.first?.state, .downloadFailed)

        await downloader.setErrorToThrow(nil)
        kokoro.setAvailability(.available)
        await model.downloadTTSModel("kokoro")

        XCTAssertEqual(model.ttsBackends.first?.state, .ready)
        XCTAssertNil(model.ttsBackendMessage)
        let callCount = await downloader.callCount
        XCTAssertEqual(callCount, 2)
    }

    func testSecondDownloadClickWhileDownloadingIsIgnored() async {
        var settings = AppSettings.defaults
        settings.ttsBackendOrder = ["kokoro"]
        let store = FakeSettingsStore(settings: settings)
        let kokoro = FakeTTSCatalogBackend(id: "kokoro", displayName: "Kokoro", availability: .modelNotDownloaded)
        let downloader = FakeTTSModelManager()
        await downloader.setShouldBlock(true)
        let model = makeModel(store: store, ttsRegistry: ["kokoro": kokoro], ttsModelManagers: ["kokoro": downloader])
        await model.initialTTSBackendRefresh?.value

        let firstTask = Task { await model.downloadTTSModel("kokoro") }
        await waitUntil { await downloader.callCount > 0 }

        await model.downloadTTSModel("kokoro")

        let callCountAfterSecondClick = await downloader.callCount
        XCTAssertEqual(callCountAfterSecondClick, 1)

        await downloader.resume()
        await firstTask.value
    }

    func testDownloadInsertsMissingRowWhenNoStatusExistsYet() async {
        var settings = AppSettings.defaults
        settings.ttsBackendOrder = ["kokoro"]
        let store = FakeSettingsStore(settings: settings)
        let kokoro = FakeTTSCatalogBackend(id: "kokoro", displayName: "Kokoro", availability: .modelNotDownloaded)
        let downloader = FakeTTSModelManager()
        await downloader.setShouldBlock(true)
        let model = makeModel(store: store, ttsRegistry: ["kokoro": kokoro], ttsModelManagers: ["kokoro": downloader])
        await model.initialTTSBackendRefresh?.value
        model.ttsBackends = [] // simulate a Download click before any status row exists

        let downloadTask = Task { await model.downloadTTSModel("kokoro") }
        await waitUntil { model.ttsBackends.first(where: { $0.id == "kokoro" }) != nil }

        let row = model.ttsBackends.first(where: { $0.id == "kokoro" })
        XCTAssertEqual(row?.displayName, "Kokoro")
        XCTAssertEqual(row?.state, .downloading(progress: 0))

        await downloader.resume()
        await downloadTask.value
    }

    func testConcurrentRefreshDuringADownloadDoesNotClobberDownloadingState() async {
        var settings = AppSettings.defaults
        settings.ttsBackendOrder = ["kokoro"]
        let store = FakeSettingsStore(settings: settings)
        let kokoro = FakeTTSCatalogBackend(id: "kokoro", displayName: "Kokoro", availability: .modelNotDownloaded)
        let downloader = FakeTTSModelManager()
        await downloader.setShouldBlock(true)
        let model = makeModel(store: store, ttsRegistry: ["kokoro": kokoro], ttsModelManagers: ["kokoro": downloader])
        await model.initialTTSBackendRefresh?.value

        kokoro.setShouldBlockAvailability(true)
        let refreshTask = Task { await model.refreshTTSBackendStatuses() }
        await waitUntil { kokoro.availabilityCallCount > 0 }

        let downloadTask = Task { await model.downloadTTSModel("kokoro") }
        await waitUntil {
            model.ttsBackends.first(where: { $0.id == "kokoro" })?.state == .downloading(progress: 0)
        }

        kokoro.resumeAvailability()
        await refreshTask.value

        XCTAssertEqual(model.ttsBackends.first(where: { $0.id == "kokoro" })?.state, .downloading(progress: 0))

        kokoro.setShouldBlockAvailability(false)
        kokoro.setAvailability(.available)
        await downloader.resume()
        await downloadTask.value

        XCTAssertEqual(model.ttsBackends.first(where: { $0.id == "kokoro" })?.state, .ready)
    }

    func testLateProgressCallbackAfterCompletionDoesNotChangeReadyState() async {
        var settings = AppSettings.defaults
        settings.ttsBackendOrder = ["kokoro"]
        let store = FakeSettingsStore(settings: settings)
        let kokoro = FakeTTSCatalogBackend(id: "kokoro", displayName: "Kokoro", availability: .modelNotDownloaded)
        let downloader = FakeTTSModelManager()
        let model = makeModel(store: store, ttsRegistry: ["kokoro": kokoro], ttsModelManagers: ["kokoro": downloader])
        await model.initialTTSBackendRefresh?.value
        kokoro.setAvailability(.available)

        await model.downloadTTSModel("kokoro")
        XCTAssertEqual(model.ttsBackends.first(where: { $0.id == "kokoro" })?.state, .ready)

        await downloader.reportProgress(1.0) // a tick arriving after the download already finished
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(model.ttsBackends.first(where: { $0.id == "kokoro" })?.state, .ready)
    }

    func testOutOfOrderLowerProgressTickIsIgnored() async {
        var settings = AppSettings.defaults
        settings.ttsBackendOrder = ["kokoro"]
        let store = FakeSettingsStore(settings: settings)
        let kokoro = FakeTTSCatalogBackend(id: "kokoro", displayName: "Kokoro", availability: .modelNotDownloaded)
        let downloader = FakeTTSModelManager()
        await downloader.setShouldBlock(true)
        let model = makeModel(store: store, ttsRegistry: ["kokoro": kokoro], ttsModelManagers: ["kokoro": downloader])
        await model.initialTTSBackendRefresh?.value

        let downloadTask = Task { await model.downloadTTSModel("kokoro") }
        await waitUntil { await downloader.callCount > 0 }

        await downloader.reportProgress(0.7)
        await waitUntil {
            model.ttsBackends.first(where: { $0.id == "kokoro" })?.state == .downloading(progress: 0.7)
        }

        await downloader.reportProgress(0.3) // out of order: must not move progress backwards
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(model.ttsBackends.first(where: { $0.id == "kokoro" })?.state, .downloading(progress: 0.7))

        await downloader.resume()
        await downloadTask.value
    }

    func testCanDownloadTTSModelReflectsWhetherADownloaderIsRegistered() {
        let apple = FakeTTSCatalogBackend(id: "apple-tts", displayName: "Apple System Voice")
        let modelWithoutDownloader = makeModel(ttsRegistry: ["apple-tts": apple])
        XCTAssertFalse(modelWithoutDownloader.canDownloadTTSModel("apple-tts"))

        let downloader = FakeTTSModelManager()
        let modelWithDownloader = makeModel(ttsRegistry: ["apple-tts": apple], ttsModelManagers: ["apple-tts": downloader])
        XCTAssertTrue(modelWithDownloader.canDownloadTTSModel("apple-tts"))
    }

    func testTTSBackendMessageIsSetOnRefusalAndClearedOnNextSuccessfulAction() async {
        var settings = AppSettings.defaults
        settings.ttsBackendOrder = ["apple-tts"]
        let store = FakeSettingsStore(settings: settings)
        let apple = FakeTTSCatalogBackend(id: "apple-tts", displayName: "Apple System Voice")
        let kokoro = FakeTTSCatalogBackend(id: "kokoro", displayName: "Kokoro")
        let model = makeModel(store: store, ttsRegistry: ["apple-tts": apple, "kokoro": kokoro])
        await model.initialTTSBackendRefresh?.value

        model.setTTSBackendEnabled("apple-tts", false)
        XCTAssertEqual(model.ttsBackendMessage, "At least one TTS backend must stay enabled.")

        model.setTTSBackendEnabled("kokoro", true)
        XCTAssertNil(model.ttsBackendMessage)
    }

    func testRefreshMapsBackendAvailabilityCasesToFixedStates() async {
        let cases: [(BackendAvailability, TTSBackendStatus.State)] = [
            (.available, .ready),
            (.modelNotDownloaded, .modelNotDownloaded),
            (.unsupportedOS, .unsupported),
            (.unsupportedHardware, .unsupported),
            (.permissionDenied, .unavailable),
            (.unavailable("some reason"), .unavailable),
            (.initializing, .unavailable),
            (.failed("boom"), .unavailable),
        ]

        for (availability, expected) in cases {
            let backend = FakeTTSCatalogBackend(id: "x", displayName: "X", availability: availability)
            let model = makeModel(ttsRegistry: ["x": backend])
            await model.initialTTSBackendRefresh?.value

            XCTAssertEqual(model.ttsBackends.first?.state, expected, "availability: \(availability)")
        }
    }

    /// Polls `condition` until it's true, yielding between checks. Fails the test instead of
    /// hanging forever if `condition` never becomes true.
    private func waitUntil(
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while await !condition() {
            if Date() > deadline {
                XCTFail("Timed out waiting for condition", file: file, line: line)
                return
            }
            await Task.yield()
        }
    }

    private func makeModel(
        store: FakeSettingsStore? = nil,
        ttsRegistry: [String: any TextToSpeechBackend] = [:],
        ttsModelManagers: [String: any SpeechModelManaging] = [:],
        diagnostics: DiagnosticsRecorder? = nil
    ) -> AppModel {
        AppModel(
            settingsStore: store ?? FakeSettingsStore(settings: .defaults),
            selectionReader: NoOpSelectionReader(),
            preprocessor: RulesSpeechPreprocessor(),
            speechCoordinator: NoOpSpeechCoordinator(),
            hotkeyManager: NoOpHotkeyManager(),
            diagnostics: diagnostics ?? DiagnosticsRecorder(capacity: 10),
            ttsRegistry: ttsRegistry,
            ttsModelManagers: ttsModelManagers
        )
    }
}

private enum TestCatalogError: Error, Equatable {
    case boom
}

@MainActor
private final class FakeTTSCatalogBackend: TextToSpeechBackend {
    nonisolated let id: String
    nonisolated let displayName: String
    let capabilities = TTSCapabilities([])
    private var availabilityValue: BackendAvailability
    private var shouldBlockAvailability = false
    private(set) var availabilityCallCount = 0
    private var availabilityContinuation: CheckedContinuation<Void, Never>?

    init(id: String, displayName: String, availability: BackendAvailability = .available) {
        self.id = id
        self.displayName = displayName
        availabilityValue = availability
    }

    func availability() async -> BackendAvailability {
        availabilityCallCount += 1
        if shouldBlockAvailability {
            await withCheckedContinuation { availabilityContinuation = $0 }
        }
        return availabilityValue
    }

    func setAvailability(_ value: BackendAvailability) { availabilityValue = value }
    func setShouldBlockAvailability(_ value: Bool) { shouldBlockAvailability = value }
    func resumeAvailability() {
        availabilityContinuation?.resume()
        availabilityContinuation = nil
    }

    func setPlaybackEventHandler(_ handler: @escaping @MainActor (TTSPlaybackEvent) -> Void) {}
    func speak(text: String, options: TTSOptions, sessionID: UUID) async throws {}
    func stop() {}
    func pause() {}
    func resume() {}
}

private actor FakeTTSModelManager: SpeechModelManaging {
    let backendID: String
    let modelID: String
    private(set) var callCount = 0
    private var present = false
    private var progressToReport: [Double] = []
    private var errorToThrow: Error?
    private var shouldBlock = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var resumeRequested = false
    private var capturedProgress: (@Sendable (Double) -> Void)?

    init(backendID: String = "tts", modelID: String = "model") {
        self.backendID = backendID
        self.modelID = modelID
    }

    func models() async -> [SpeechModelStatus] {
        [SpeechModelStatus(
            descriptor: .init(id: modelID, displayName: modelID, detail: nil, approximateDownloadBytes: nil),
            installState: present ? .downloaded : .notDownloaded,
            isSelected: true,
            isLoaded: false
        )]
    }

    func setProgressToReport(_ values: [Double]) { progressToReport = values }
    func setErrorToThrow(_ error: Error?) { errorToThrow = error }
    func setShouldBlock(_ value: Bool) { shouldBlock = value }

    func downloadModel(_ id: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        callCount += 1
        capturedProgress = progress
        for value in progressToReport {
            progress(value)
        }
        if shouldBlock {
            // `resume()` may be called before this point is reached (the catalog does an
            // `await manager.models()` hop before entering `downloadModel`). Honor a resume that
            // already arrived instead of suspending forever.
            if resumeRequested {
                resumeRequested = false
            } else {
                await withCheckedContinuation { continuation = $0 }
            }
        }
        if let errorToThrow {
            throw errorToThrow
        }
        present = true
    }

    func removeModel(_ id: String) async throws {}
    func selectModel(_ id: String) async throws {}

    func resume() {
        if let continuation {
            self.continuation = nil
            continuation.resume()
        } else {
            resumeRequested = true
        }
    }

    func reportProgress(_ value: Double) {
        capturedProgress?(value)
    }
}

@MainActor
private final class FakeSettingsStore: SettingsStoring {
    let settings: AppSettings
    private(set) var saved: [AppSettings] = []

    init(settings: AppSettings) {
        self.settings = settings
    }

    func load() -> AppSettings { settings }
    func save(_ value: AppSettings) throws { saved.append(value) }
}

@MainActor
private final class NoOpSelectionReader: SelectionReading {
    func readSelection() throws -> SelectionResult { .init(text: "", source: .accessibility) }
}

@MainActor
private final class NoOpSpeechCoordinator: SpeechCoordinating {
    func speak(_ request: SpeechRequest) async throws {}
    func stop() {}
    func stop(sessionID: UUID) {}
    func replayLast() async throws {}
}

@MainActor
private final class NoOpHotkeyManager: HotkeyManaging {
    func register(
        settings: AppSettings,
        handler: @escaping @MainActor (HotkeyAction, HotkeyPhase) -> Void
    ) -> HotkeyRegistrationStatus {
        .registered
    }
}
