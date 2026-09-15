import AppKit
import SwiftUI

struct KeybindsSettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("Global Hotkeys") {
                ForEach(HotkeyAction.allCases, id: \.self) { action in
                    LabeledContent(action.title) {
                        HotkeyRecorder(
                            definition: model.settings.hotkeys[action]
                        ) { definition in
                            model.setHotkey(definition, for: action)
                        }
                        Button {
                            model.removeHotkey(for: action)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .disabled(model.settings.hotkeys[action] == nil)
                        .accessibilityLabel("Clear \(action.title) shortcut")
                    }
                }

                if let conflict = model.hotkeyConflictMessage {
                    Text(conflict)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("hotkey-conflict-message")
                }

                Text("Click a shortcut to record. Double-tap a modifier (⌘ ⌥ ⌃ ⇧) to bind it. Fn can be recorded alone. ✕ clears. Hotkeys are listen-only, so keys such as Escape still reach the active app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct HotkeyRecorder: NSViewRepresentable {
    let definition: HotkeyDefinition?
    let onChange: (HotkeyDefinition) -> Void

    func makeNSView(context: Context) -> HotkeyRecorderButton {
        let button = HotkeyRecorderButton()
        button.onChange = onChange
        button.definition = definition
        return button
    }

    func updateNSView(_ button: HotkeyRecorderButton, context: Context) {
        button.onChange = onChange
        button.definition = definition
    }
}

private final class HotkeyRecorderButton: NSButton {
    var onChange: ((HotkeyDefinition) -> Void)?
    var definition: HotkeyDefinition? {
        didSet {
            if !isRecording { title = Self.displayName(for: definition) }
        }
    }
    private var isRecording = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        title = Self.displayName(for: definition)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        isRecording = true
        title = "Press shortcut…"
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        finish(with: .chord(
            keyCode: event.keyCode,
            modifiers: Self.modifiers(from: event.modifierFlags)
        ))
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else {
            super.flagsChanged(with: event)
            return
        }
        if Self.modifiers(from: event.modifierFlags) == [.function] {
            finish(with: .modifierOnly(.function))
        }
    }

    private func finish(with definition: HotkeyDefinition) {
        isRecording = false
        self.definition = definition
        onChange?(definition)
    }

    private static func displayName(for definition: HotkeyDefinition?) -> String {
        definition?.displayName ?? "Not set"
    }

    private static func modifiers(from flags: NSEvent.ModifierFlags) -> Set<HotkeyModifier> {
        var result = Set<HotkeyModifier>()
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.function) { result.insert(.function) }
        return result
    }
}

private extension HotkeyDefinition {
    var displayName: String {
        switch self {
        case let .modifierOnly(modifier):
            return modifier.symbol
        case let .doubleTapModifier(modifier):
            return "\(modifier.symbol) \(modifier.symbol)"
        case let .chord(keyCode, modifiers):
            let prefix = HotkeyModifier.displayOrder
                .filter(modifiers.contains)
                .map(\.symbol)
                .joined()
            return prefix + Self.keyName(for: keyCode)
        }
    }

    static func keyName(for keyCode: UInt16) -> String {
        let printableKeys: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L",
            38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
            45: "N", 46: "M", 47: ".", 50: "`",
        ]
        if let name = printableKeys[keyCode] { return name }
        return switch keyCode {
        case 36: "Return"
        case 48: "Tab"
        case 49: "Space"
        case 51: "Delete"
        case 53: "Escape"
        case 123: "←"
        case 124: "→"
        case 125: "↓"
        case 126: "↑"
        default: "Key \(keyCode)"
        }
    }
}

private extension HotkeyModifier {
    static let displayOrder: [HotkeyModifier] = [
        .control, .option, .shift, .command, .function,
    ]

    var symbol: String {
        switch self {
        case .command: "⌘"
        case .option: "⌥"
        case .control: "⌃"
        case .shift: "⇧"
        case .function: "Fn"
        }
    }
}
