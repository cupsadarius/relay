import XCTest

@testable import Relay

@MainActor
final class SpeechBackendsModelTests: XCTestCase {
    private func makeModel(
        store: SpySettingsStore? = nil,
        speech: SpySpeechCoordinator? = nil,
        sttRegistry: [BackendID: any SpeechToTextBackend] = [:],
        ttsRegistry: [BackendID: any TextToSpeechBackend] = [:],
        speechModelManagers: [BackendID: any SpeechModelManaging] = [:],
        ttsModelManagers: [BackendID: any SpeechModelManaging] = [:]
    ) -> SpeechBackendsModel {
        let store = store ?? SpySettingsStore()
        let speech = speech ?? SpySpeechCoordinator()
        return SpeechBackendsModel(
            runtime: .testing(
                settingsStore: store,
                speechCoordinator: speech,
                sttRegistry: sttRegistry,
                speechModelManagers: speechModelManagers,
                ttsRegistry: ttsRegistry,
                ttsModelManagers: ttsModelManagers
            ))
    }

    /// Pins the domain mapping `SpeechBackendsModel` wires into `SpeechModelController`:
    /// `speechModelManagers` (from `RelayRuntime.testing`) must land under `.dictation`, and
    /// `ttsModelManagers` under `.textToSpeech` — never swapped or merged into one domain.
    func testModelControllerBackendKeysAreWiredToTheCorrectDomain() async {
        let model = makeModel(
            speechModelManagers: [.appleSpeech: StubModelManager(backendID: .appleSpeech, modelIDs: [])],
            ttsModelManagers: [.kokoro: StubModelManager(backendID: .kokoro, modelIDs: [])]
        )

        await model.models.refresh(domain: .dictation)
        await model.models.refresh(domain: .textToSpeech)
        XCTAssertEqual(
            Set(model.models.models.keys),
            [
                SpeechModelBackendKey(domain: .dictation, backendID: .appleSpeech),
                SpeechModelBackendKey(domain: .textToSpeech, backendID: .kokoro),
            ])
    }

    func testRefreshingADomainUpdatesReadinessAndModelsTogether() async {
        let backend = StubSTTBackend(id: .appleSpeech, availability: .modelNotDownloaded)
        let manager = StubModelManager(backendID: .appleSpeech, modelIDs: ["tiny"])
        let model = makeModel(sttRegistry: [.appleSpeech: backend], speechModelManagers: [.appleSpeech: manager])

        await model.refresh(.dictation)

        XCTAssertEqual(model.dictation.rows.map(\.state), [.modelNotDownloaded])
        XCTAssertEqual(model.models.models[SpeechModelBackendKey(domain: .dictation, backendID: .appleSpeech)]?.map(\.id), ["tiny"])
        XCTAssertTrue(model.textToSpeech.rows.isEmpty)
    }

    func testRefreshAllCoversBothDomains() async {
        let manager = StubModelManager(backendID: .kokoro, modelIDs: ["v1"])
        let model = makeModel(
            sttRegistry: [.appleSpeech: StubSTTBackend(id: .appleSpeech)],
            ttsModelManagers: [.kokoro: manager]
        )

        await model.refreshAll()

        XCTAssertEqual(model.dictation.rows.map(\.id), [.appleSpeech])
        XCTAssertEqual(model.models.models[SpeechModelBackendKey(domain: .textToSpeech, backendID: .kokoro)]?.map(\.id), ["v1"])
    }

    /// Selecting a model changes readiness; the controller's hook must refresh the owning list.
    func testSelectingAModelRefreshesThatDomainsReadiness() async {
        let backend = StubSTTBackend(id: .appleSpeech, availability: .modelNotDownloaded)
        let manager = StubModelManager(backendID: .appleSpeech, modelIDs: ["tiny"])
        let model = makeModel(sttRegistry: [.appleSpeech: backend], speechModelManagers: [.appleSpeech: manager])
        await model.refresh(.dictation)

        await backend.setAvailability(.available)
        await model.models.select("tiny", in: SpeechModelBackendKey(domain: .dictation, backendID: .appleSpeech))

        XCTAssertEqual(model.dictation.rows.map(\.state), [.ready])
    }

    /// The activation recheck only needs readiness; it must not re-list models.
    func testRefreshingReadinessLeavesModelListsAlone() async {
        let backend = StubSTTBackend(id: .appleSpeech, availability: .modelNotDownloaded)
        let manager = StubModelManager(backendID: .appleSpeech, modelIDs: ["tiny"])
        let model = makeModel(sttRegistry: [.appleSpeech: backend], speechModelManagers: [.appleSpeech: manager])

        await model.refreshReadiness(.dictation)

        XCTAssertEqual(model.dictation.rows.map(\.state), [.modelNotDownloaded])
        XCTAssertNil(model.models.models[SpeechModelBackendKey(domain: .dictation, backendID: .appleSpeech)])
    }

    func testRemovingATTSModelStopsSpeechFirst() async {
        let speech = SpySpeechCoordinator()
        let manager = StubModelManager(backendID: .kokoro, modelIDs: ["v1"])
        let model = makeModel(speech: speech, ttsModelManagers: [.kokoro: manager])

        await model.models.remove("v1", in: SpeechModelBackendKey(domain: .textToSpeech, backendID: .kokoro))

        XCTAssertEqual(speech.stopCount, 1)
    }

    func testRemovingADictationModelDoesNotStopSpeech() async {
        let speech = SpySpeechCoordinator()
        let manager = StubModelManager(backendID: .appleSpeech, modelIDs: ["tiny"])
        let model = makeModel(speech: speech, speechModelManagers: [.appleSpeech: manager])

        await model.models.remove("tiny", in: SpeechModelBackendKey(domain: .dictation, backendID: .appleSpeech))

        XCTAssertEqual(speech.stopCount, 0)
    }

    func testBackendListsPersistOrderThroughSettings() async {
        var settings = AppSettings.defaults
        settings.sttBackendOrder = ["apple-speech"]
        let store = SpySettingsStore(settings: settings)
        let model = makeModel(store: store, sttRegistry: [.appleSpeech: StubSTTBackend(id: .appleSpeech), .parakeet: StubSTTBackend(id: .parakeet)])
        await model.refresh(.dictation)

        model.dictation.setEnabled(.parakeet, true)

        XCTAssertEqual(store.saved.last?.sttBackendOrder, ["apple-speech", "parakeet"])
    }

    /// TTS twin of `testBackendListsPersistOrderThroughSettings`: the TTS list must read and
    /// persist through `ttsBackendOrder`, not accidentally share the STT list's order.
    func testTTSBackendListPersistsOrderThroughSettings() async {
        var settings = AppSettings.defaults
        settings.ttsBackendOrder = ["pocket-tts"]
        let store = SpySettingsStore(settings: settings)
        let model = makeModel(store: store, ttsRegistry: [.pocketTTS: FakeTTSBackend(id: .pocketTTS), .appleTTS: FakeTTSBackend(id: .appleTTS)])
        await model.refresh(.textToSpeech)

        model.textToSpeech.setEnabled(.appleTTS, true)

        XCTAssertEqual(store.saved.last?.ttsBackendOrder, ["pocket-tts", "apple-tts"])
    }

    /// Pins the exact user-facing refusal strings `SpeechBackendsModel` wires per domain — a
    /// generic `BackendListModel` unit test can't catch these two swapping or drifting.
    func testRefusalMessagesUseTheExactProductionStringsPerDomain() async {
        var sttSettings = AppSettings.defaults
        sttSettings.sttBackendOrder = ["apple-speech"]
        let sttModel = makeModel(store: SpySettingsStore(settings: sttSettings), sttRegistry: [.appleSpeech: StubSTTBackend(id: .appleSpeech)])
        await sttModel.refresh(.dictation)
        sttModel.dictation.setEnabled(.appleSpeech, false)
        XCTAssertEqual(sttModel.dictation.message, "At least one speech recognition backend must stay enabled.")

        var ttsSettings = AppSettings.defaults
        ttsSettings.ttsBackendOrder = ["pocket-tts"]
        let ttsModel = makeModel(store: SpySettingsStore(settings: ttsSettings), ttsRegistry: [.pocketTTS: FakeTTSBackend(id: .pocketTTS)])
        await ttsModel.refresh(.textToSpeech)
        ttsModel.textToSpeech.setEnabled(.pocketTTS, false)
        XCTAssertEqual(ttsModel.textToSpeech.message, "At least one TTS backend must stay enabled.")
    }

    func testSelectVoicePersistsThroughTheCatalogMapping() {
        let store = SpySettingsStore()
        let model = makeModel(store: store)

        model.selectVoice(backendID: .appleTTS, voiceID: "apple:default")

        // The default option maps to "no stored voice" — and it is still a persisted write.
        XCTAssertEqual(store.saved.count, 1)
        XCTAssertNil(store.saved.last?.voiceByBackend[BackendID.appleTTS.rawValue])
    }
}

private actor StubSTTBackend: SpeechToTextBackend {
    nonisolated let id: BackendID
    private var availabilityValue: BackendAvailability

    init(id: BackendID, availability: BackendAvailability = .available) {
        self.id = id
        availabilityValue = availability
    }

    func setAvailability(_ value: BackendAvailability) { availabilityValue = value }
    func availability() async -> BackendAvailability { availabilityValue }
    func transcribe(audio: AudioInput, options: STTOptions) async throws -> Transcript {
        throw SpeechBackendError.unavailable("stub")
    }
}

private actor StubModelManager: SpeechModelManaging {
    nonisolated let backendID: BackendID
    private var statuses: [SpeechModelStatus]

    init(backendID: BackendID, modelIDs: [String]) {
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
