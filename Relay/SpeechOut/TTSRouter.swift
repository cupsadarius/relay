@MainActor
final class TTSRouter {
    private let backends: [String: any TextToSpeechBackend]
    private let backendOrder: () -> [String]
    private var activeBackend: (any TextToSpeechBackend)?

    init(
        backends: [String: any TextToSpeechBackend],
        backendOrder: @escaping () -> [String]
    ) {
        self.backends = backends
        self.backendOrder = backendOrder
    }

    func speak(text: String, options: TTSOptions) async throws {
        var lastError: SpeechBackendError = .unavailable("No TTS backend is available")

        for id in backendOrder() {
            guard let backend = backends[id] else { continue }
            guard case .available = await backend.availability() else { continue }

            do {
                if let activeBackend, activeBackend !== backend {
                    activeBackend.stop()
                    self.activeBackend = nil
                }
                try await backend.speak(text: text, options: options)
                activeBackend = backend
                return
            } catch let error as SpeechBackendError where error.isFallbackWorthy {
                lastError = error
            } catch {
                throw error
            }
        }

        throw lastError
    }

    func stop() {
        activeBackend?.stop()
        activeBackend = nil
    }

    func pause() {
        activeBackend?.pause()
    }

    func resume() {
        activeBackend?.resume()
    }
}
