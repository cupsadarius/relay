/// A speech backend's stable identifier. `rawValue` is persisted in `AppSettings` (backend
/// orders, per-backend voice/model maps) and in registry keys, so the static members' strings must
/// never change. `displayName` is the single user-facing name for the backend everywhere (Settings
/// rows, error messages, diagnostics).
struct BackendID: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }
    init(stringLiteral value: String) { rawValue = value }

    var description: String { rawValue }

    // Speech-to-text
    static let appleSpeech: BackendID = "apple-speech"
    static let parakeet: BackendID = "parakeet"
    static let whisper: BackendID = "whisper"
    // Text-to-speech
    static let pocketTTS: BackendID = "pocket-tts"
    static let appleTTS: BackendID = "apple-tts"
    static let kokoro: BackendID = "kokoro"

    static let allSpeechToText: [BackendID] = [.appleSpeech, .parakeet, .whisper]
    static let allTextToSpeech: [BackendID] = [.pocketTTS, .appleTTS, .kokoro]

    var displayName: String {
        switch self {
        case .appleSpeech: "Apple Speech"
        case .parakeet: "Parakeet"
        case .whisper: "OpenAI Whisper"
        case .pocketTTS: "PocketTTS"
        case .appleTTS: "Apple System Voice"
        case .kokoro: "Kokoro"
        default: rawValue
        }
    }

    static func displayName(for rawValue: String) -> String {
        BackendID(rawValue: rawValue).displayName
    }

    /// Lets `switch someString { case BackendID.kokoro: … }` match registry/settings strings.
    static func ~= (pattern: BackendID, value: String) -> Bool {
        pattern.rawValue == value
    }
}
