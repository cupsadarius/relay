import Foundation

enum ActivityOverlayStyle: String, Codable, CaseIterable, Sendable {
    case off
    case minimal
    case interactive
}

struct AppSettings: Codable, Equatable, Sendable {
    var dictationMode: DictationMode
    var hotkeys: [HotkeyAction: HotkeyDefinition]
    var sttBackendOrder: [String]
    var ttsBackendOrder: [String]
    var ttsVoiceIdentifier: String?
    var ttsRate: Float
    var autoReadEnabled: Bool
    var activityOverlayStyle: ActivityOverlayStyle
    var kokoroVoice: String?
    var pocketVoice: String?
    var liveTranscriptionEnabled: Bool

    private enum CodingKeys: String, CodingKey {
        case dictationMode, hotkeys, sttBackendOrder, ttsBackendOrder
        case ttsVoiceIdentifier, ttsRate, autoReadEnabled, activityOverlayStyle, kokoroVoice, pocketVoice
        case liveTranscriptionEnabled
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        dictationMode = try values.decode(DictationMode.self, forKey: .dictationMode)
        hotkeys = try values.decode([HotkeyAction: HotkeyDefinition].self, forKey: .hotkeys)
        sttBackendOrder = try values.decode([String].self, forKey: .sttBackendOrder)
        ttsBackendOrder = try values.decode([String].self, forKey: .ttsBackendOrder)
        ttsVoiceIdentifier = try values.decodeIfPresent(String.self, forKey: .ttsVoiceIdentifier)
        ttsRate = try values.decode(Float.self, forKey: .ttsRate)
        autoReadEnabled = try values.decode(Bool.self, forKey: .autoReadEnabled)
        activityOverlayStyle = try values.decodeIfPresent(
            ActivityOverlayStyle.self,
            forKey: .activityOverlayStyle
        ) ?? .interactive
        kokoroVoice = try values.decodeIfPresent(String.self, forKey: .kokoroVoice)
        pocketVoice = try values.decodeIfPresent(String.self, forKey: .pocketVoice)
        liveTranscriptionEnabled = try values.decodeIfPresent(Bool.self, forKey: .liveTranscriptionEnabled) ?? true
    }

    init(
        dictationMode: DictationMode,
        hotkeys: [HotkeyAction: HotkeyDefinition],
        sttBackendOrder: [String],
        ttsBackendOrder: [String],
        ttsVoiceIdentifier: String?,
        ttsRate: Float,
        autoReadEnabled: Bool,
        activityOverlayStyle: ActivityOverlayStyle,
        kokoroVoice: String? = nil,
        pocketVoice: String? = nil,
        liveTranscriptionEnabled: Bool = true
    ) {
        self.dictationMode = dictationMode
        self.hotkeys = hotkeys
        self.sttBackendOrder = sttBackendOrder
        self.ttsBackendOrder = ttsBackendOrder
        self.ttsVoiceIdentifier = ttsVoiceIdentifier
        self.ttsRate = ttsRate
        self.autoReadEnabled = autoReadEnabled
        self.activityOverlayStyle = activityOverlayStyle
        self.kokoroVoice = kokoroVoice
        self.pocketVoice = pocketVoice
        self.liveTranscriptionEnabled = liveTranscriptionEnabled
    }

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
        ttsBackendOrder: ["pocket-tts", "apple-tts", "kokoro"],
        ttsVoiceIdentifier: nil,
        ttsRate: 0.5,
        autoReadEnabled: true,
        activityOverlayStyle: .interactive,
        liveTranscriptionEnabled: true
    )
}
