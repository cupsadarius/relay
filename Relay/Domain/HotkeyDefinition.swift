import Foundation

enum HotkeyModifier: String, Codable, Hashable, Sendable {
    case command
    case option
    case control
    case shift
    case function
}

enum HotkeyDefinition: Codable, Equatable, Sendable {
    case modifierOnly(HotkeyModifier)
    case chord(keyCode: UInt16, modifiers: Set<HotkeyModifier>)
}

enum HotkeyAction: String, Codable, CaseIterable, Sendable {
    case dictate
    case readSelection
    case stopSpeech
    case replayLast
    case toggleAutoRead
}

enum DictationMode: String, Codable, Sendable {
    case holdToTalk
    case toggle
}
