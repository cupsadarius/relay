import XCTest

@testable import Relay

@MainActor
final class SpeechBackendsModelTests: XCTestCase {
    private func makeModel(
        store: SpySettingsStore? = nil,
        speech: SpySpeechCoordinator? = nil,
        sttRegistry: [String: any SpeechToTextBackend] = [:],
        ttsRegistry: [String: any TextToSpeechBackend] = [:],
        speechModelManagers: [String: any SpeechModelManaging] = [:],
        ttsModelManagers: [String: any SpeechModelManaging] = [:],
        cleanupModelManagers: [String: any SpeechModelManaging] = [:],
        transcriptCleanup: (any TranscriptCleaning)? = nil,
        cleanupTester: DictationCleanupTester? = nil,
        cleanupRuntime: (any MLXCleanupRuntimeServing)? = nil
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
                ttsModelManagers: ttsModelManagers,
                cleanupModelManagers: cleanupModelManagers,
                transcriptCleanup: transcriptCleanup,
                cleanupTester: cleanupTester,
                cleanupRuntime: cleanupRuntime
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

        XCTAssertEqual(
            model.models.backendKeys,
            [
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

    /// TTS twin of `testBackendListsPersistOrderThroughSettings`: the TTS list must read and
    /// persist through `ttsBackendOrder`, not accidentally share the STT list's order.
    func testTTSBackendListPersistsOrderThroughSettings() async {
        var settings = AppSettings.defaults
        settings.ttsBackendOrder = ["a"]
        let store = SpySettingsStore(settings: settings)
        let model = makeModel(store: store, ttsRegistry: ["a": FakeTTSBackend(id: "a"), "b": FakeTTSBackend(id: "b")])
        await model.refresh(.textToSpeech)

        model.textToSpeech.setEnabled("b", true)

        XCTAssertEqual(store.saved.last?.ttsBackendOrder, ["a", "b"])
    }

    /// Pins the exact user-facing refusal strings `SpeechBackendsModel` wires per domain — a
    /// generic `BackendListModel` unit test can't catch these two swapping or drifting.
    func testRefusalMessagesUseTheExactProductionStringsPerDomain() async {
        var sttSettings = AppSettings.defaults
        sttSettings.sttBackendOrder = ["a"]
        let sttModel = makeModel(store: SpySettingsStore(settings: sttSettings), sttRegistry: ["a": StubSTTBackend(id: "a")])
        await sttModel.refresh(.dictation)
        sttModel.dictation.setEnabled("a", false)
        XCTAssertEqual(sttModel.dictation.message, "At least one speech recognition backend must stay enabled.")

        var ttsSettings = AppSettings.defaults
        ttsSettings.ttsBackendOrder = ["a"]
        let ttsModel = makeModel(store: SpySettingsStore(settings: ttsSettings), ttsRegistry: ["a": FakeTTSBackend(id: "a")])
        await ttsModel.refresh(.textToSpeech)
        ttsModel.textToSpeech.setEnabled("a", false)
        XCTAssertEqual(ttsModel.textToSpeech.message, "At least one TTS backend must stay enabled.")
    }

    func testSelectVoicePersistsThroughTheCatalogMapping() {
        let store = SpySettingsStore()
        let model = makeModel(store: store)

        model.selectVoice(backendID: BackendID.appleTTS.rawValue, voiceID: "apple:default")

        // The default option maps to "no stored voice" — and it is still a persisted write.
        XCTAssertEqual(store.saved.count, 1)
        XCTAssertNil(store.saved.last?.voiceByBackend[BackendID.appleTTS.rawValue])
    }

    func testCleanupManagersAreWiredToTheCleanupDomain() {
        let model = makeModel(cleanupModelManagers: ["mlx-cleanup": StubModelManager(backendID: "mlx-cleanup", modelIDs: [])])
        XCTAssertEqual(model.models.backendKeys, [SpeechModelBackendKey(domain: .dictationCleanup, backendID: "mlx-cleanup")])
    }

    func testCleanupDomainHasNoBackendList() {
        XCTAssertNil(makeModel().list(for: .dictationCleanup))
    }

    func testRefreshAllIncludesCleanup() async {
        let model = makeModel(cleanupModelManagers: ["mlx-cleanup": StubModelManager(backendID: "mlx-cleanup", modelIDs: ["q"])])

        await model.refreshAll()

        XCTAssertEqual(model.models.models[SpeechModelBackendKey(domain: .dictationCleanup, backendID: "mlx-cleanup")]?.map(\.id), ["q"])
    }

    func testSelectingACleanupModelPrewarms() async {
        let cleaner = SpyTranscriptCleaner()
        let model = makeModel(
            cleanupModelManagers: ["mlx-cleanup": StubModelManager(backendID: "mlx-cleanup", modelIDs: ["q"])], transcriptCleanup: cleaner
        )

        await model.models.select("q", in: SpeechModelBackendKey(domain: .dictationCleanup, backendID: "mlx-cleanup"))

        XCTAssertEqual(cleaner.prewarmCount, 1)
    }

    func testRemovingACleanupModelCancelsTheTestAndRetiresTheGeneration() async {
        let operation = ManualOperation(cooperative: false)
        let runtime = FakeMLXRuntime(handler: { _, _ in try await operation.run() })
        let tester = DictationCleanupTester(apple: FakeAppleCleanup(), mlx: runtime, sleep: TestSleeper().sleepFunction)
        let model = makeModel(
            cleanupModelManagers: ["mlx-cleanup": StubModelManager(backendID: "mlx-cleanup", modelIDs: [CleanupModelID.qwen3_0_6b.rawValue])],
            cleanupTester: tester, cleanupRuntime: runtime
        )
        tester.run(model: .qwen3_0_6b)
        await eventually { operation.startCount == 1 }

        await model.models.remove(
            CleanupModelID.qwen3_0_6b.rawValue, in: SpeechModelBackendKey(domain: .dictationCleanup, backendID: "mlx-cleanup")
        )

        await eventually { tester.phase == .cancelledModelRemoved }
        let retired = await runtime.retireCount
        XCTAssertEqual(retired, 1)
        // Review fix 11: the specific model id being removed is passed through to the runtime,
        // not a blanket retire.
        let retiredInvolving = await runtime.retiredInvolving
        XCTAssertEqual(retiredInvolving, [.qwen3_0_6b])
        operation.finish(.success("late"))
    }

    func testTurningCleanupOnPersistsAndPrewarms() {
        let store = SpySettingsStore()
        let cleaner = SpyTranscriptCleaner()
        let model = makeModel(store: store, transcriptCleanup: cleaner)

        model.setCleanupEnabled(true)
        XCTAssertEqual(store.saved.last?.dictationCleanupEnabled, true)
        XCTAssertEqual(cleaner.prewarmCount, 1)

        model.setCleanupEnabled(false)
        XCTAssertEqual(store.saved.last?.dictationCleanupEnabled, false)
        XCTAssertEqual(cleaner.prewarmCount, 1)
    }

    func testLaunchRefreshPrewarmsOnceAtTheEnd() async {
        let cleaner = SpyTranscriptCleaner()
        let model = makeModel(transcriptCleanup: cleaner)

        await model.refreshAll()

        XCTAssertEqual(cleaner.prewarmCount, 1)
    }

    func testCleanupBackendsAreAppleThenQwenInThatOrder() async {
        let model = makeModel(cleanupModelManagers: [
            "mlx-cleanup": StubModelManager(backendID: "mlx-cleanup", modelIDs: ["mlx.qwen3-1.7b-4bit", "mlx.qwen3-0.6b-4bit"]),
            "apple-foundation-cleanup": StubModelManager(backendID: "apple-foundation-cleanup", modelIDs: ["apple.system-language-model"]),
        ])

        await model.refresh(.dictationCleanup)

        XCTAssertEqual(model.cleanupBackends.map(\.id), ["apple-foundation-cleanup", "mlx-cleanup"])
        XCTAssertEqual(model.cleanupBackends.map(\.displayName), ["Apple Intelligence", "Qwen (MLX)"])
        // StubModelManager always reports its models downloaded and usable.
        XCTAssertEqual(model.cleanupBackends.map(\.state), [.ready, .ready])
    }

    func testCleanupTestableModelsAreDownloadedUsableAppleFirstThenSmallThenLarge() async {
        let model = makeModel(cleanupModelManagers: [
            "mlx-cleanup": StubModelManager(backendID: "mlx-cleanup", modelIDs: ["mlx.qwen3-1.7b-4bit", "mlx.qwen3-0.6b-4bit"]),
            "apple-foundation-cleanup": StubModelManager(backendID: "apple-foundation-cleanup", modelIDs: ["apple.system-language-model"]),
        ])

        await model.refresh(.dictationCleanup)

        XCTAssertEqual(model.cleanupTestableModels, [.appleSystem, .qwen3_0_6b, .qwen3_1_7b])
    }

    func testCleanupProviderStateIsReadyWhenAUsableDownloadedModelExists() {
        let rows = [
            speechModelStatus(id: "a", installState: .notDownloaded),
            speechModelStatus(id: "b", installState: .downloaded, usability: .usable),
        ]
        XCTAssertEqual(SpeechBackendsModel.cleanupProviderState(for: rows), .ready)
    }

    func testCleanupProviderStateIsModelNotDownloadedWhenNothingIsDownloadedOrUnusable() {
        let rows = [speechModelStatus(id: "a", installState: .notDownloaded), speechModelStatus(id: "b", installState: .downloading(progress: 0.5))]
        XCTAssertEqual(SpeechBackendsModel.cleanupProviderState(for: rows), .modelNotDownloaded)
        XCTAssertEqual(SpeechBackendsModel.cleanupProviderState(for: []), .modelNotDownloaded)
    }

    func testCleanupProviderStateIsUnsupportedForADeviceNotEligibleReason() {
        let rows = [speechModelStatus(id: "a", installState: .downloaded, usability: .unusable(reason: AppleUnavailability.deviceNotEligible.rowText))]
        XCTAssertEqual(SpeechBackendsModel.cleanupProviderState(for: rows), .unsupported)
    }

    func testCleanupProviderStateIsUnavailableForAnyOtherUnusableReason() {
        let reason = AppleUnavailability.appleIntelligenceNotEnabled.rowText
        let rows = [speechModelStatus(id: "a", installState: .downloaded, usability: .unusable(reason: reason))]
        XCTAssertEqual(SpeechBackendsModel.cleanupProviderState(for: rows), .unavailable)
    }

    private func speechModelStatus(
        id: String, installState: SpeechModelInstallState, usability: SpeechModelUsability = .usable
    ) -> SpeechModelStatus {
        SpeechModelStatus(
            descriptor: .init(id: id, displayName: id, detail: nil), capabilities: [.select], installState: installState, isSelected: false,
            usability: usability
        )
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
