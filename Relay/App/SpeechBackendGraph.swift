import Foundation

/// The speech backend registries and their model managers. Constructing these touches no settings
/// storage, event tap, socket, or other process-wide state, so a test can pin the production maps
/// (`SpeechBackendGraphTests`) without building the rest of `RelayRuntime.makeProduction()`.
@MainActor
struct SpeechBackendGraph {
    let ttsRegistry: [BackendID: any TextToSpeechBackend]
    let ttsModelManagers: [BackendID: any SpeechModelManaging]
    let sttRegistry: [BackendID: any SpeechToTextBackend]
    let speechModelManagers: [BackendID: any SpeechModelManaging]
    let parakeetModelManager: ParakeetModelManager

    static func make(
        whisperSelection: @escaping WhisperModelSelection,
        setWhisperSelection: @escaping WhisperModelSelectionWriter,
        parakeetSelection: @escaping ParakeetModelSelection,
        setParakeetSelection: @escaping ParakeetModelSelectionWriter
    ) -> SpeechBackendGraph {
        let appleTTS = AppleTTSBackend()
        let kokoroModel: KokoroModel = .kokoro()
        let kokoroTTS = KokoroTTSBackend(model: kokoroModel)
        let kokoroModelManager = SingleModelManager.kokoro(model: kokoroModel)
        let pocketModel: PocketTTSModel = .pocketTTS()
        let pocketTTS = PocketTTSBackend(model: pocketModel)
        let pocketModelManager = SingleModelManager.pocketTTS(model: pocketModel)

        let appleSpeech = AppleSpeechBackend()
        let appleSpeechModelManager = SingleModelManager.appleSpeech
        // razor: both models may stay resident (~600 MB each); unload on switch if memory matters
        let parakeetModels = ParakeetModels(
            unifiedEnglish: .parakeet(loader: ParakeetUnifiedModelLoader()),
            v2: .parakeet(loader: ParakeetV2ModelLoader())
        )
        let parakeetBackend = ParakeetBackend(models: parakeetModels, selectedModel: parakeetSelection)
        let parakeetModelManager = ParakeetModelManager(
            models: parakeetModels,
            selectedModel: parakeetSelection,
            setSelectedModel: setParakeetSelection
        )

        // Whisper is registered but never enabled by default: `sttBackendOrder` defaults to
        // `[.appleSpeech]`; the user opts in and picks a model in Settings.
        // Models are shared by Debug and Release (see `RelayPaths.sharedModelsDirectory`).
        let whisperCacheDirectory = RelayPaths.sharedModelsDirectory()
            .appendingPathComponent("Whisper", isDirectory: true)
        let whisperStore = WhisperModelStore(
            cacheDirectory: whisperCacheDirectory,
            downloader: HuggingFaceWhisperDownloader()
        )
        let whisperRuntime = WhisperRuntime(
            engine: WhisperKitEngine(),
            modelFolder: { whisperStore.modelDirectory(for: $0) }
        )
        let whisperBackend = WhisperBackend(
            store: whisperStore,
            runtime: whisperRuntime,
            selectedModel: whisperSelection
        )
        let whisperModelManager = WhisperModelManager(
            store: whisperStore,
            runtime: whisperRuntime,
            selectedModel: whisperSelection,
            setSelectedModel: setWhisperSelection
        )

        return SpeechBackendGraph(
            ttsRegistry: [
                appleTTS.id: appleTTS,
                kokoroTTS.id: kokoroTTS,
                pocketTTS.id: pocketTTS,
            ],
            ttsModelManagers: [
                kokoroModelManager.backendID: kokoroModelManager,
                pocketModelManager.backendID: pocketModelManager,
            ],
            sttRegistry: [
                appleSpeech.id: appleSpeech,
                parakeetBackend.id: parakeetBackend,
                whisperBackend.id: whisperBackend,
            ],
            speechModelManagers: [
                appleSpeechModelManager.backendID: appleSpeechModelManager,
                parakeetModelManager.backendID: parakeetModelManager,
                whisperModelManager.backendID: whisperModelManager,
            ],
            parakeetModelManager: parakeetModelManager
        )
    }
}
