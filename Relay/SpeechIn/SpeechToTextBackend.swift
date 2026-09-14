protocol SpeechToTextBackend: Sendable {
    var id: String { get }
    var displayName: String { get }
    var capabilities: STTCapabilities { get }

    func availability() async -> BackendAvailability
    func prepare() async throws
    func transcribe(audio: AudioInput, options: STTOptions) async throws -> Transcript
}
