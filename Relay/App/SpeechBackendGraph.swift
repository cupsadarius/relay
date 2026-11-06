import Foundation

/// The speech backend registries and their model managers. Constructing these touches no settings
/// storage, event tap, socket, or other process-wide state, so a test can pin the production maps
/// (`SpeechBackendGraphTests`) without building the rest of `RelayRuntime.makeProduction()`.
@MainActor
struct SpeechBackendGraph {
    let ttsRegistry: [String: any TextToSpeechBackend]
    let ttsModelManagers: [String: any SpeechModelManaging]
    let sttRegistry: [String: any SpeechToTextBackend]
    let speechModelManagers: [String: any SpeechModelManaging]

    static func make(
        whisperSelection: @escaping WhisperModelSelection,
        setWhisperSelection: @escaping WhisperModelSelectionWriter
    ) -> SpeechBackendGraph {
        let appleTTS = AppleTTSBackend()
        let kokoroEngine: any KokoroEngine = FluidAudioKokoroEngine()
        let kokoroTTS = KokoroTTSBackend(engine: kokoroEngine)
        let kokoroModelManager = KokoroModelManager(engine: kokoroEngine)
        let pocketEngine: any PocketTTSEngine = FluidAudioPocketTTSEngine()
        let pocketTTS = PocketTTSBackend(engine: pocketEngine)
        let pocketModelManager = PocketTTSModelManager(engine: pocketEngine)

        let appleSpeech = AppleSpeechBackend()
        let appleSpeechModelManager = AppleSpeechModelManager()
        let parakeetEngine: any ParakeetEngine = FluidAudioParakeetEngine()
        let parakeetBackend = ParakeetBackend(engine: parakeetEngine)
        let parakeetModelManager = ParakeetModelManager(engine: parakeetEngine)

        // Whisper is registered but never enabled by default: `sttBackendOrder` defaults to
        // `["apple-speech"]`; the user opts in and picks a model in Settings.
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
            ]
        )
    }
}
