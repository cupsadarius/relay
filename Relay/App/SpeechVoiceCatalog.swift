import AVFoundation
import FluidAudio
import Foundation

struct SpeechVoiceOption: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let detail: String?
    let storedValue: String?
}

@MainActor
protocol SpeechVoiceCataloging {
    func voices(for backendID: String) -> [SpeechVoiceOption]
    func activeVoiceID(for backendID: String, settings: AppSettings) -> String?
    func storedValue(for voiceID: String, backendID: String) -> String??
    func options(for voiceID: String, backendID: String, settings: AppSettings) -> TTSOptions?
}

@MainActor
struct SpeechVoiceCatalog: SpeechVoiceCataloging {
    private let appleVoices: [SpeechVoiceOption]
    private let kokoroVoices: [String]
    private let recommendedKokoroVoice: String
    private let pocketVoice: String

    init(
        appleVoices: [SpeechVoiceOption]? = nil,
        kokoroVoices: [String] = KokoroAneConstants.englishVoices.filter {
            $0.hasPrefix("af_") || $0.hasPrefix("am_")
        },
        recommendedKokoroVoice: String = TtsConstants.recommendedVoice,
        pocketVoice: String = PocketTtsConstants.defaultVoice
    ) {
        self.appleVoices = appleVoices ?? AVSpeechSynthesisVoice.speechVoices()
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map {
                SpeechVoiceOption(
                    id: "apple:\($0.identifier)",
                    displayName: $0.name,
                    detail: $0.language,
                    storedValue: $0.identifier
                )
            }
        self.kokoroVoices = kokoroVoices
        self.recommendedKokoroVoice = recommendedKokoroVoice
        self.pocketVoice = pocketVoice
    }

    func voices(for backendID: String) -> [SpeechVoiceOption] {
        switch backendID {
        case "apple-tts":
            return [
                .init(id: "apple:default", displayName: "System Default", detail: nil, storedValue: nil)
            ] + appleVoices
        case "kokoro":
            let choices = kokoroVoices.filter { $0 != recommendedKokoroVoice }.map {
                SpeechVoiceOption(id: "kokoro:\($0)", displayName: $0, detail: nil, storedValue: $0)
            }
            return [
                .init(
                    id: "kokoro:default",
                    displayName: "Recommended — \(recommendedKokoroVoice)",
                    detail: nil,
                    storedValue: nil
                )
            ] + choices
        case "pocket-tts":
            return [
                .init(
                    id: "pocket:default",
                    displayName: "Recommended — \(pocketVoice)",
                    detail: nil,
                    storedValue: nil
                )
            ]
        default:
            return []
        }
    }

    func activeVoiceID(for backendID: String, settings: AppSettings) -> String? {
        switch backendID {
        case "apple-tts":
            guard let value = settings.ttsVoiceIdentifier else { return "apple:default" }
            return voices(for: backendID).first(where: { $0.storedValue == value })?.id
        case "kokoro":
            guard let value = settings.kokoroVoice, value != recommendedKokoroVoice else {
                return "kokoro:default"
            }
            return voices(for: backendID).first(where: { $0.storedValue == value })?.id
        case "pocket-tts":
            guard let value = settings.pocketVoice, value != pocketVoice else { return "pocket:default" }
            return voices(for: backendID).first(where: { $0.storedValue == value })?.id
        default:
            return nil
        }
    }

    func storedValue(for voiceID: String, backendID: String) -> String?? {
        voices(for: backendID).first(where: { $0.id == voiceID }).map(\.storedValue)
    }

    func options(for voiceID: String, backendID: String, settings: AppSettings) -> TTSOptions? {
        guard let mapped = storedValue(for: voiceID, backendID: backendID) else { return nil }
        var options = TTSOptions(
            voiceIdentifier: settings.ttsVoiceIdentifier,
            rate: settings.ttsRate,
            kokoroVoice: settings.kokoroVoice,
            pocketVoice: settings.pocketVoice
        )
        switch backendID {
        case "apple-tts": options.voiceIdentifier = mapped
        case "kokoro": options.kokoroVoice = mapped
        case "pocket-tts": options.pocketVoice = mapped
        default: return nil
        }
        return options
    }
}
