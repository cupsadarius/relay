@MainActor
protocol TextToSpeechBackend: AnyObject {
    var id: String { get }
    var displayName: String { get }
    var capabilities: TTSCapabilities { get }

    func availability() async -> BackendAvailability
    func speak(text: String, options: TTSOptions) async throws
    func stop()
    func pause()
    func resume()
}
