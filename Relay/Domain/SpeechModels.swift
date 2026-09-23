import Foundation

struct AudioInput: Sendable, Equatable {
    let samples: [Float]
    let sampleRate: Double
}

struct Transcript: Sendable, Equatable {
    let text: String
    let backendID: String
}

struct STTOptions: Sendable, Equatable {
    var localeIdentifier = Locale.current.identifier
}

struct TTSOptions: Sendable, Equatable {
    var voiceIdentifier: String?
    var rate: Float = 0.5
    /// The Kokoro voice id (e.g. `"af_heart"`), read by `KokoroTTSBackend` and ignored by every
    /// other backend. `voiceIdentifier` remains Apple's own `com.apple.voice.*` id, which is
    /// meaningless to Kokoro.
    var kokoroVoice: String?
    /// The PocketTTS voice id (e.g. `"alba"`), read by `PocketTTSBackend` and ignored by every
    /// other backend.
    var pocketVoice: String?
}

enum SpeechSource: String, Codable, Equatable, Sendable {
    case selection
    case claudeCode
    case codex
}

enum SpeechMode: String, Codable, Equatable, Sendable {
    case automatic
    case userRequested
}

struct SpeechRequest: Sendable, Equatable {
    let text: String
    let source: SpeechSource
    let mode: SpeechMode
    let sessionID: String?
}
