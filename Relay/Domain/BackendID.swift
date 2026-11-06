/// A speech backend's stable identifier. `rawValue` is persisted in `AppSettings` (backend
/// orders, per-backend voice/model maps), so the case strings must never change. `displayName` is
/// the single user-facing name for the backend everywhere (Settings rows, error messages,
/// diagnostics).
enum BackendID: String, CaseIterable, Codable, Sendable, CustomStringConvertible {
    // Speech-to-text
    case appleSpeech = "apple-speech"
    case parakeet
    case whisper
    // Text-to-speech
    case pocketTTS = "pocket-tts"
    case appleTTS = "apple-tts"
    case kokoro

    static let allSpeechToText: [BackendID] = [.appleSpeech, .parakeet, .whisper]
    static let allTextToSpeech: [BackendID] = [.pocketTTS, .appleTTS, .kokoro]

    var description: String { rawValue }

    var displayName: String {
        switch self {
        case .appleSpeech: "Apple Speech"
        case .parakeet: "Parakeet"
        case .whisper: "OpenAI Whisper"
        case .pocketTTS: "PocketTTS"
        case .appleTTS: "Apple System Voice"
        case .kokoro: "Kokoro"
        }
    }
}
