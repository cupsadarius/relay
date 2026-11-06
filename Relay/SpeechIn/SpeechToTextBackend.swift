protocol SpeechToTextBackend: Sendable {
    var id: BackendID { get }

    func availability() async -> BackendAvailability
    func transcribe(audio: AudioInput, options: STTOptions) async throws -> Transcript
}
