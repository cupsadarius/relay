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
    case doubleTapModifier(HotkeyModifier)
    case chord(keyCode: UInt16, modifiers: Set<HotkeyModifier>)
}

extension HotkeyDefinition {
    func conflicts(with other: HotkeyDefinition) -> Bool {
        if self == other { return true }
        switch (self, other) {
        case let (.modifierOnly(left), .doubleTapModifier(right)),
             let (.doubleTapModifier(left), .modifierOnly(right)):
            return left == right
        default:
            return false
        }
    }
}

enum HotkeyAction: String, Codable, CaseIterable, Sendable {
    case dictate
    case readSelection
    case stopSpeech
    case replayLast
    case toggleAutoRead
}

enum DictationMode: String, Codable, CaseIterable, Sendable {
    case holdToTalk
    case toggle
}
