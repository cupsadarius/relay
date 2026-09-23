protocol SpeechToTextBackend: Sendable {
    var id: String { get }
    var displayName: String { get }

    func availability() async -> BackendAvailability
    func transcribe(audio: AudioInput, options: STTOptions) async throws -> Transcript
}
