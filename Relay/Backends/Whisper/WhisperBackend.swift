import Foundation
import os

/// Reads which Whisper model is currently selected, synchronously. `availability()` needs the
/// selected id without awaiting `AppSettings`, so selection is exposed through this narrow
/// closure-based seam rather than an async read of app settings.
typealias WhisperModelSelection = @Sendable () -> WhisperModelID?

/// On-device speech-to-text backend built on WhisperKit's CoreML port of OpenAI Whisper. Fully
/// offline once the selected model is downloaded; never uploads audio or transcript text
/// anywhere. Mirrors `ParakeetBackend`'s shape: presence delegates to `WhisperModelStore`,
/// load/transcribe delegate to `WhisperRuntime`, and every underlying error is mapped onto
/// `SpeechBackendError` with the same fallback-worthiness the router expects from every backend.
///
/// An `actor` because `WhisperRuntime` (the thing that actually does the loading and inference)
/// is itself an actor holding mutable state; `WhisperBackend` adds no additional isolated state of
/// its own beyond forwarding to it.
actor WhisperBackend: SpeechToTextBackend {
    nonisolated let id = BackendID.whisper.rawValue
    nonisolated let displayName = BackendID.whisper.displayName

    private let store: WhisperModelStore
    private let runtime: WhisperRuntime
    private let selectedModel: WhisperModelSelection
    private let logger = Logger(subsystem: "dev.relaymac.Relay", category: "whisper-backend")

    /// - Parameters:
    ///   - store: owns presence/download/remove of verified local model folders.
    ///   - runtime: owns the single loaded Whisper inference context.
    ///   - selectedModel: synchronously reads the currently-selected model id, or `nil` if none
    ///     is selected. In production this reads `AppSettings`' persisted selection; in tests it
    ///     is a fake closure the test controls directly.
    init(store: WhisperModelStore, runtime: WhisperRuntime, selectedModel: @escaping WhisperModelSelection) {
        self.store = store
        self.runtime = runtime
        self.selectedModel = selectedModel
    }

    func availability() async -> BackendAvailability {
        guard let modelID = selectedModel() else {
            return .modelNotDownloaded
        }
        return store.presence(of: modelID) ? .available : .modelNotDownloaded
    }

    func transcribe(audio: AudioInput, options: STTOptions) async throws -> Transcript {
        guard !audio.samples.isEmpty else {
            throw SpeechBackendError.noUsableAudio
        }
        guard audio.sampleRate == 16_000 else {
            throw SpeechBackendError.invalidInput
        }

        try await ensureLoaded()

        do {
            let text = try await runtime.transcribe(audio.samples, options: options)
            return Transcript(text: text, backendID: id)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SpeechBackendError {
            throw error
        } catch WhisperRuntimeError.notLoaded {
            throw SpeechBackendError.initializationFailed("Whisper model is not loaded")
        } catch {
            throw SpeechBackendError.inferenceFailed("Whisper transcription failed")
        }
    }

    /// Activates the selected model on the runtime, loading it on demand. Throws
    /// `.modelNotDownloaded` if nothing is selected or the selection isn't present on disk yet
    /// (never attempts a download here -- that's the Settings "Download" action's job, same as
    /// `ParakeetBackend`), or `.initializationFailed` if the runtime's own load fails.
    private func ensureLoaded() async throws {
        guard let modelID = selectedModel() else {
            throw SpeechBackendError.modelNotDownloaded
        }
        guard store.presence(of: modelID) else {
            throw SpeechBackendError.modelNotDownloaded
        }

        do {
            try await runtime.activate(modelID)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.debug("Whisper model activation failed")
            throw SpeechBackendError.initializationFailed("Whisper model failed to load")
        }
    }
}
