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
}

enum SpeechSource: String, Codable, Equatable, Sendable {
    case selection
    case manualReplay
    case futureIntegration
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

enum STTCapability: Sendable {
    case streaming
    case multilingual
    case timestamps
    case partialResults
    case customVocabulary
    case fullyOffline
}

struct STTCapabilities: Equatable, Sendable {
    private let values: Set<STTCapability>

    init(_ values: Set<STTCapability>) {
        self.values = values
    }

    func contains(_ capability: STTCapability) -> Bool {
        values.contains(capability)
    }
}

enum TTSCapability: Sendable {
    case pauseResume
    case voiceSelection
    case fullyOffline
    case outputLevel
}

struct TTSCapabilities: Equatable, Sendable {
    private let values: Set<TTSCapability>

    init(_ values: Set<TTSCapability>) {
        self.values = values
    }

    func contains(_ capability: TTSCapability) -> Bool {
        values.contains(capability)
    }
}
