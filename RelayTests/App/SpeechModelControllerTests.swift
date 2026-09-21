import XCTest
@testable import Relay

@MainActor
final class SpeechModelControllerTests: XCTestCase {
    func testSameBackendIDInDifferentDomainsDoesNotCollide() async {
        let dictationKey = SpeechModelBackendKey(domain: .dictation, backendID: "shared")
        let ttsKey = SpeechModelBackendKey(domain: .textToSpeech, backendID: "shared")
        let controller = SpeechModelController(
            managers: [
                dictationKey: ControllerModelManager(statuses: [status("dictation")]),
                ttsKey: ControllerModelManager(statuses: [status("tts")]),
            ],
            diagnostics: DiagnosticsRecorder()
        )

        await controller.refresh(domain: .dictation)
        await controller.refresh(domain: .textToSpeech)

        XCTAssertEqual(controller.models[dictationKey]?.map(\.id), ["dictation"])
        XCTAssertEqual(controller.models[ttsKey]?.map(\.id), ["tts"])
    }

    func testStaleRefreshCannotOverwriteNewerRefresh() async {
        let key = SpeechModelBackendKey(domain: .dictation, backendID: "whisper")
        let manager = ControllerModelManager(statuses: [status("old")])
        await manager.setModelSnapshots([[status("old")], [status("new")]])
        await manager.setBlockFirstModels(true)
        let controller = SpeechModelController(managers: [key: manager], diagnostics: DiagnosticsRecorder())

        let stale = Task { await controller.refresh(domain: .dictation) }
        await waitUntil { await manager.isFirstModelsBlocked }
        await controller.refresh(domain: .dictation)
        await manager.resumeFirstModels()
        await stale.value

        XCTAssertEqual(controller.models[key]?.map(\.id), ["new"])
    }

    func testDownloadProgressIsMonotonicAndDuplicateDownloadIsIgnored() async {
        let key = SpeechModelBackendKey(domain: .dictation, backendID: "whisper")
        let manager = ControllerModelManager(statuses: [status("tiny")])
        await manager.setDownloadProgress([0.8, 0.3, 2.0])
        await manager.setBlockDownload(true)
        let controller = SpeechModelController(managers: [key: manager], diagnostics: DiagnosticsRecorder())
        await controller.refresh(domain: .dictation)

        let first = Task { await controller.download("tiny", in: key) }
        await waitUntil { await manager.isDownloadBlocked }
        await controller.download("tiny", in: key)
        await Task.yield()

        let downloadCount = await manager.downloadCount
        XCTAssertEqual(downloadCount, 1)
        XCTAssertEqual(controller.models[key]?.first?.installState, .downloading(progress: 1))

        await manager.resumeDownload()
        await first.value
    }

    func testDownloadDoesNotSelectModel() async {
        let key = SpeechModelBackendKey(domain: .dictation, backendID: "whisper")
        let manager = ControllerModelManager(statuses: [status("tiny", selected: false)])
        let controller = SpeechModelController(managers: [key: manager], diagnostics: DiagnosticsRecorder())

        await controller.download("tiny", in: key)

        XCTAssertEqual(controller.models[key]?.first?.installState, .downloaded)
        XCTAssertFalse(controller.models[key]?.first?.isSelected ?? true)
    }

    func testSelectRefreshesModelsAndOwningBackend() async {
        let key = SpeechModelBackendKey(domain: .dictation, backendID: "whisper")
        let manager = ControllerModelManager(statuses: [status("tiny")])
        var refreshedDomains: [SpeechModelDomain] = []
        let controller = SpeechModelController(managers: [key: manager], diagnostics: DiagnosticsRecorder())
        controller.configureHooks(
            refreshBackends: { refreshedDomains.append($0) },
            beforeRemoval: { _ in }
        )

        await controller.select("tiny", in: key)

        let selectCount = await manager.selectCount
        let modelsCount = await manager.modelsCount
        XCTAssertEqual(selectCount, 1)
        XCTAssertEqual(refreshedDomains, [.dictation])
        XCTAssertEqual(modelsCount, 1)
    }

    func testRemoveRunsPreRemovalThenManagerThenRefreshes() async {
        let key = SpeechModelBackendKey(domain: .textToSpeech, backendID: "kokoro")
        let events = ControllerEventLog()
        let manager = ControllerModelManager(statuses: [status("model", state: .downloaded)], events: events)
        let controller = SpeechModelController(managers: [key: manager], diagnostics: DiagnosticsRecorder())
        controller.configureHooks(
            refreshBackends: { _ in await events.append("backend-refresh") },
            beforeRemoval: { _ in await events.append("pre-remove") }
        )

        await controller.remove("model", in: key)

        let recordedEvents = await events.values
        XCTAssertEqual(recordedEvents, ["pre-remove", "manager-remove", "model-refresh", "backend-refresh"])
    }

    func testFailedSelectAndRemovePreserveRowsAndPublishStableMessages() async {
        let key = SpeechModelBackendKey(domain: .textToSpeech, backendID: "kokoro")
        let original = status("model", state: .downloaded)
        let manager = ControllerModelManager(statuses: [original])
        let controller = SpeechModelController(managers: [key: manager], diagnostics: DiagnosticsRecorder())
        await controller.refresh(domain: .textToSpeech)

        await manager.setSelectError(TestFailure())
        await controller.select("model", in: key)
        XCTAssertEqual(controller.models[key], [original])
        XCTAssertEqual(controller.messages[.textToSpeech], "Kokoro model selection failed. Try again.")

        await manager.setRemoveError(TestFailure())
        await controller.remove("model", in: key)
        XCTAssertEqual(controller.models[key], [original])
        XCTAssertEqual(controller.messages[.textToSpeech], "Kokoro model removal failed. Try again.")
    }

    func testPartialRemovalFailureReconcilesModelsAndBackendReadiness() async {
        let key = SpeechModelBackendKey(domain: .textToSpeech, backendID: "kokoro")
        let downloaded = status("model", state: .downloaded, selected: true)
        let absent = status("model", state: .notDownloaded, selected: true)
        let manager = ControllerModelManager(statuses: [downloaded])
        var refreshedDomains: [SpeechModelDomain] = []
        let controller = SpeechModelController(managers: [key: manager], diagnostics: DiagnosticsRecorder())
        controller.configureHooks(
            refreshBackends: { refreshedDomains.append($0) },
            beforeRemoval: { _ in }
        )
        await controller.refresh(domain: .textToSpeech)
        await manager.setRemoveFailure(TestFailure(), resultingStatuses: [absent])

        await controller.remove("model", in: key)

        XCTAssertEqual(controller.models[key], [absent])
        XCTAssertEqual(refreshedDomains, [.textToSpeech])
        XCTAssertEqual(controller.messages[.textToSpeech], "Kokoro model removal failed. Try again.")
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @Sendable () async -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await condition()), clock.now < deadline {
            await Task.yield()
        }
        let didSatisfy = await condition()
        XCTAssertTrue(didSatisfy)
    }
}

private struct TestFailure: Error {}

private func status(
    _ id: String,
    state: SpeechModelInstallState = .notDownloaded,
    selected: Bool = false
) -> SpeechModelStatus {
    SpeechModelStatus(
        descriptor: .init(id: id, displayName: id, detail: nil, approximateDownloadBytes: nil),
        capabilities: [.download, .select, .remove],
        installState: state,
        isSelected: selected,
        isLoaded: false
    )
}

private actor ControllerEventLog {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

private actor ControllerModelManager: SpeechModelManaging {
    let backendID = "test"
    private var statuses: [SpeechModelStatus]
    private var snapshots: [[SpeechModelStatus]] = []
    private var blockFirstModels = false
    private(set) var isFirstModelsBlocked = false
    private var firstModelsContinuation: CheckedContinuation<Void, Never>?
    private var progressValues: [Double] = []
    private var blockDownload = false
    private(set) var isDownloadBlocked = false
    private var downloadContinuation: CheckedContinuation<Void, Never>?
    private(set) var downloadCount = 0
    private(set) var selectCount = 0
    private(set) var modelsCount = 0
    private var selectError: Error?
    private var removeError: Error?
    private var removeFailureStatuses: [SpeechModelStatus]?
    private let events: ControllerEventLog?

    init(statuses: [SpeechModelStatus], events: ControllerEventLog? = nil) {
        self.statuses = statuses
        self.events = events
    }

    func setModelSnapshots(_ value: [[SpeechModelStatus]]) { snapshots = value }
    func setBlockFirstModels(_ value: Bool) { blockFirstModels = value }
    func setDownloadProgress(_ value: [Double]) { progressValues = value }
    func setBlockDownload(_ value: Bool) { blockDownload = value }
    func setSelectError(_ error: Error?) { selectError = error }
    func setRemoveError(_ error: Error?) { removeError = error }
    func setRemoveFailure(_ error: Error, resultingStatuses: [SpeechModelStatus]) {
        removeError = error
        removeFailureStatuses = resultingStatuses
    }

    func resumeFirstModels() {
        firstModelsContinuation?.resume()
        firstModelsContinuation = nil
    }

    func resumeDownload() {
        downloadContinuation?.resume()
        downloadContinuation = nil
    }

    func models() async -> [SpeechModelStatus] {
        modelsCount += 1
        let result = snapshots.isEmpty ? statuses : snapshots.removeFirst()
        if modelsCount == 1, blockFirstModels {
            isFirstModelsBlocked = true
            await withCheckedContinuation { firstModelsContinuation = $0 }
        }
        await events?.append("model-refresh")
        return result
    }

    func downloadModel(_ id: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        downloadCount += 1
        progressValues.forEach(progress)
        if blockDownload {
            isDownloadBlocked = true
            await withCheckedContinuation { downloadContinuation = $0 }
        }
        if let index = statuses.firstIndex(where: { $0.id == id }) {
            statuses[index].installState = .downloaded
        }
    }

    func removeModel(_ id: String) async throws {
        if let removeFailureStatuses {
            statuses = removeFailureStatuses
        }
        if let removeError { throw removeError }
        await events?.append("manager-remove")
        if let index = statuses.firstIndex(where: { $0.id == id }) {
            statuses[index].installState = .notDownloaded
        }
    }

    func selectModel(_ id: String) async throws {
        selectCount += 1
        if let selectError { throw selectError }
        for index in statuses.indices { statuses[index].isSelected = statuses[index].id == id }
    }
}
