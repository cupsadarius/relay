import Foundation

struct AppSettings: Codable, Equatable, Sendable {
    var dictationMode: DictationMode
    var hotkeys: [HotkeyAction: HotkeyDefinition]
    var sttBackendOrder: [String]
    var ttsBackendOrder: [String]
    var ttsVoiceIdentifier: String?
    var ttsRate: Float
    var autoReadEnabled: Bool

    static let defaults = AppSettings(
        dictationMode: .holdToTalk,
        hotkeys: [
            .dictate: .modifierOnly(.function),
            .readSelection: .chord(keyCode: 15, modifiers: [.option]),
            .stopSpeech: .chord(keyCode: 53, modifiers: []),
            .replayLast: .chord(keyCode: 15, modifiers: [.option, .shift]),
            .toggleAutoRead: .chord(keyCode: 0, modifiers: [.option, .shift]),
        ],
        sttBackendOrder: ["apple-speech"],
        ttsBackendOrder: ["apple-tts"],
        ttsVoiceIdentifier: nil,
        ttsRate: 0.5,
        autoReadEnabled: true
    )
}
