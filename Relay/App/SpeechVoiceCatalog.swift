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
struct SpeechVoiceCatalog {
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
        self.appleVoices =
            appleVoices
            ?? AVSpeechSynthesisVoice.speechVoices()
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
        case BackendID.appleTTS:
            return [
                .init(id: "apple:default", displayName: "System Default", detail: nil, storedValue: nil)
            ] + appleVoices
        case BackendID.kokoro:
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
        case BackendID.pocketTTS:
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
        let options = voices(for: backendID)
        guard let defaultOption = options.first(where: { $0.storedValue == nil }) else { return nil }
        guard let value = settings.voiceByBackend[backendID], value != recommendedValue(for: backendID) else {
            return defaultOption.id
        }
        return options.first(where: { $0.storedValue == value })?.id
    }

    func storedValue(for voiceID: String, backendID: String) -> String?? {
        voices(for: backendID).first(where: { $0.id == voiceID }).map(\.storedValue)
    }

    func options(for voiceID: String, backendID: String, settings: AppSettings) -> TTSOptions? {
        guard BackendID.allTextToSpeech.contains(BackendID(rawValue: backendID)),
            let mapped = storedValue(for: voiceID, backendID: backendID)
        else { return nil }
        var previewSettings = settings
        previewSettings.voiceByBackend[backendID] = mapped
        return TTSOptions(settings: previewSettings)
    }

    /// The stored value that means "the recommended default" for backends that name one.
    private func recommendedValue(for backendID: String) -> String? {
        switch backendID {
        case BackendID.kokoro: recommendedKokoroVoice
        case BackendID.pocketTTS: pocketVoice
        default: nil
        }
    }
}
