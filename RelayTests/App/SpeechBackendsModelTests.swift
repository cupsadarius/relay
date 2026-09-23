import XCTest
@testable import Relay

@MainActor
final class SpeechBackendsModelTests: XCTestCase {
    private func makeModel(
        store: SpySettingsStore? = nil,
        speech: SpySpeechCoordinator? = nil,
        sttRegistry: [String: any SpeechToTextBackend] = [:],
        speechModelManagers: [String: any SpeechModelManaging] = [:],
        ttsModelManagers: [String: any SpeechModelManaging] = [:]
    ) -> SpeechBackendsModel {
        let store = store ?? SpySettingsStore()
        let speech = speech ?? SpySpeechCoordinator()
        return SpeechBackendsModel(runtime: .testing(
            settingsStore: store,
            speechCoordinator: speech,
            sttRegistry: sttRegistry,
            speechModelManagers: speechModelManagers,
            ttsModelManagers: ttsModelManagers
        ))
    }

    /// Pins the domain mapping `SpeechBackendsModel` wires into `SpeechModelController`:
    /// `speechModelManagers` (from `RelayRuntime.testing`) must land under `.dictation`, and
    /// `ttsModelManagers` under `.textToSpeech` — never swapped or merged into one domain.
    func testModelControllerBackendKeysAreWiredToTheCorrectDomain() {
        let model = makeModel(
            speechModelManagers: ["a": StubModelManager(backendID: "a", modelIDs: [])],
            ttsModelManagers: ["kokoro": StubModelManager(backendID: "kokoro", modelIDs: [])]
        )

        XCTAssertEqual(model.models.backendKeys, [
            SpeechModelBackendKey(domain: .dictation, backendID: "a"),
            SpeechModelBackendKey(domain: .textToSpeech, backendID: "kokoro"),
        ])
    }

    func testRefreshingADomainUpdatesReadinessAndModelsTogether() async {
        let backend = StubSTTBackend(id: "a", availability: .modelNotDownloaded)
        let manager = StubModelManager(backendID: "a", modelIDs: ["tiny"])
        let model = makeModel(sttRegistry: ["a": backend], speechModelManagers: ["a": manager])

        await model.refresh(.dictation)

        XCTAssertEqual(model.dictation.rows.map(\.state), [.modelNotDownloaded])
        XCTAssertEqual(model.models.models[SpeechModelBackendKey(domain: .dictation, backendID: "a")]?.map(\.id), ["tiny"])
        XCTAssertTrue(model.textToSpeech.rows.isEmpty)
    }

    func testRefreshAllCoversBothDomains() async {
        let manager = StubModelManager(backendID: "kokoro", modelIDs: ["v1"])
        let model = makeModel(
            sttRegistry: ["a": StubSTTBackend(id: "a")],
            ttsModelManagers: ["kokoro": manager]
        )

        await model.refreshAll()

        XCTAssertEqual(model.dictation.rows.map(\.id), ["a"])
        XCTAssertEqual(model.models.models[SpeechModelBackendKey(domain: .textToSpeech, backendID: "kokoro")]?.map(\.id), ["v1"])
    }

    /// Selecting a model changes readiness; the controller's hook must refresh the owning list.
    func testSelectingAModelRefreshesThatDomainsReadiness() async {
        let backend = StubSTTBackend(id: "a", availability: .modelNotDownloaded)
        let manager = StubModelManager(backendID: "a", modelIDs: ["tiny"])
        let model = makeModel(sttRegistry: ["a": backend], speechModelManagers: ["a": manager])
        await model.refresh(.dictation)

        await backend.setAvailability(.available)
        await model.models.select("tiny", in: SpeechModelBackendKey(domain: .dictation, backendID: "a"))

        XCTAssertEqual(model.dictation.rows.map(\.state), [.ready])
    }

    /// The activation recheck only needs readiness; it must not re-list models.
    func testRefreshingReadinessLeavesModelListsAlone() async {
        let backend = StubSTTBackend(id: "a", availability: .modelNotDownloaded)
        let manager = StubModelManager(backendID: "a", modelIDs: ["tiny"])
        let model = makeModel(sttRegistry: ["a": backend], speechModelManagers: ["a": manager])

        await model.refreshReadiness(.dictation)

        XCTAssertEqual(model.dictation.rows.map(\.state), [.modelNotDownloaded])
        XCTAssertNil(model.models.models[SpeechModelBackendKey(domain: .dictation, backendID: "a")])
    }

    func testRemovingATTSModelStopsSpeechFirst() async {
        let speech = SpySpeechCoordinator()
        let manager = StubModelManager(backendID: "kokoro", modelIDs: ["v1"])
        let model = makeModel(speech: speech, ttsModelManagers: ["kokoro": manager])

        await model.models.remove("v1", in: SpeechModelBackendKey(domain: .textToSpeech, backendID: "kokoro"))

        XCTAssertEqual(speech.stopCount, 1)
    }

    func testRemovingADictationModelDoesNotStopSpeech() async {
        let speech = SpySpeechCoordinator()
        let manager = StubModelManager(backendID: "a", modelIDs: ["tiny"])
        let model = makeModel(speech: speech, speechModelManagers: ["a": manager])

        await model.models.remove("tiny", in: SpeechModelBackendKey(domain: .dictation, backendID: "a"))

        XCTAssertEqual(speech.stopCount, 0)
    }

    func testBackendListsPersistOrderThroughSettings() async {
        var settings = AppSettings.defaults
        settings.sttBackendOrder = ["a"]
        let store = SpySettingsStore(settings: settings)
        let model = makeModel(store: store, sttRegistry: ["a": StubSTTBackend(id: "a"), "b": StubSTTBackend(id: "b")])
        await model.refresh(.dictation)

        model.dictation.setEnabled("b", true)

        XCTAssertEqual(store.saved.last?.sttBackendOrder, ["a", "b"])
    }

    func testSelectVoicePersistsThroughTheCatalogMapping() {
        let store = SpySettingsStore()
        let model = makeModel(store: store)

        model.selectVoice(backendID: BackendID.appleTTS.rawValue, voiceID: "apple:default")

        // The default option maps to "no stored voice" — and it is still a persisted write.
        XCTAssertEqual(store.saved.count, 1)
        XCTAssertNil(store.saved.last?.voiceByBackend[BackendID.appleTTS.rawValue])
    }
}

private actor StubSTTBackend: SpeechToTextBackend {
    nonisolated let id: String
    nonisolated let displayName: String
    private var availabilityValue: BackendAvailability

    init(id: String, availability: BackendAvailability = .available) {
        self.id = id
        displayName = id
        availabilityValue = availability
    }

    func setAvailability(_ value: BackendAvailability) { availabilityValue = value }
    func availability() async -> BackendAvailability { availabilityValue }
    func transcribe(audio: AudioInput, options: STTOptions) async throws -> Transcript {
        throw SpeechBackendError.unavailable("stub")
    }
}

private actor StubModelManager: SpeechModelManaging {
    nonisolated let backendID: String
    private var statuses: [SpeechModelStatus]

    init(backendID: String, modelIDs: [String]) {
        self.backendID = backendID
        statuses = modelIDs.map {
            SpeechModelStatus(
                descriptor: .init(id: $0, displayName: $0, detail: nil),
                capabilities: [.download, .select, .remove],
                installState: .downloaded,
                isSelected: false
            )
        }
    }

    func models() async -> [SpeechModelStatus] { statuses }
    func downloadModel(_ id: String, progress: @escaping @Sendable (Double) -> Void) async throws {}
    func removeModel(_ id: String) async throws {}
    func selectModel(_ id: String) async throws {
        for index in statuses.indices { statuses[index].isSelected = statuses[index].id == id }
    }
}
