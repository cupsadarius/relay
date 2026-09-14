@MainActor
protocol SpeechCoordinating: AnyObject {
    func speak(_ request: SpeechRequest) async throws
    func stop()
    func replayLast() async throws
}

@MainActor
final class SpeechCoordinator: SpeechCoordinating {
    private let router: TTSRouter
    private let options: () -> TTSOptions
    private var lastRequest: SpeechRequest?

    init(router: TTSRouter, options: @escaping () -> TTSOptions) {
        self.router = router
        self.options = options
    }

    func speak(_ request: SpeechRequest) async throws {
        if request.mode == .userRequested {
            router.stop()
        }

        try await router.speak(text: request.text, options: options())
        lastRequest = request
    }

    func stop() {
        router.stop()
    }

    func replayLast() async throws {
        guard let lastRequest else { return }

        router.stop()
        try await router.speak(text: lastRequest.text, options: options())
    }
}
