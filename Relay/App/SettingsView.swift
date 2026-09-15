import AppKit
import AVFoundation
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    private let voices = AVSpeechSynthesisVoice.speechVoices().sorted {
        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }

    var body: some View {
        Form {
            Section("Speech") {
                Picker("Voice", selection: voiceBinding) {
                    Text("System Default").tag(nil as String?)
                    ForEach(voices, id: \.identifier) { voice in
                        Text("\(voice.name) — \(voice.language)")
                            .tag(voice.identifier as String?)
                    }
                }

                HStack {
                    Slider(value: rateBinding, in: 0.1...1.0, step: 0.05)
                    Text(model.settings.ttsRate, format: .number.precision(.fractionLength(2)))
                        .monospacedDigit()
                        .frame(width: 38, alignment: .trailing)
                }
                .accessibilityLabel("Speech rate")
            }

            Section("Dictation") {
                Picker("Mode", selection: dictationModeBinding) {
                    ForEach(DictationMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
            }

            Section("Speech Recognition") {
                ForEach(orderedSpeechBackends) { backend in
                    speechBackendRow(backend)
                }
                Text("Relay tries enabled backends in order and falls back to the next one. Parakeet runs fully on-device after a one-time model download (about 1 GB).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Activity Overlay") {
                Picker("Style", selection: activityOverlayStyleBinding) {
                    Text("Off").tag(ActivityOverlayStyle.off)
                    Text("Minimal").tag(ActivityOverlayStyle.minimal)
                    Text("Interactive").tag(ActivityOverlayStyle.interactive)
                }
                .pickerStyle(.segmented)
            }

            Section("Permissions") {
                permissionRow(
                    title: "Microphone",
                    granted: model.microphonePermissionGranted,
                    request: { Task { await model.requestMicrophonePermission() } },
                    settings: { model.openPrivacySettings(.microphone) }
                )
                permissionRow(
                    title: "Accessibility",
                    granted: model.permissionSnapshot.accessibilityGranted,
                    settings: { model.openPrivacySettings(.accessibility) }
                )
                Button("Request Accessibility") { model.requestPermissions() }
                    .controlSize(.small)
            }

            Section("Global Hotkeys") {
                ForEach(HotkeyAction.allCases, id: \.self) { action in
                    LabeledContent(action.title) {
                        HotkeyRecorder(
                            definition: model.settings.hotkeys[action] ?? .chord(
                                keyCode: 0,
                                modifiers: []
                            )
                        ) { definition in
                            model.setHotkey(definition, for: action)
                        }
                        Menu("Double Tap") {
                            ForEach(HotkeyModifier.allCases, id: \.self) { modifier in
                                Button("\(modifier.symbol) \(modifier.symbol)") {
                                    model.setHotkey(.doubleTapModifier(modifier), for: action)
                                }
                            }
                        }
                    }
                }

                if let conflict = model.hotkeyConflictMessage {
                    Text(conflict)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("hotkey-conflict-message")
                }

                Text("Click a shortcut to record a key combination, or choose Double Tap. The Fn key can be recorded by itself. Hotkeys are listen-only, so keys such as Escape still reach the active app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(width: 620, height: 610)
        .task { await model.refreshSpeechBackendStatuses() }
    }

    private var orderedSpeechBackends: [STTBackendStatus] {
        model.sttBackends.sorted { lhs, rhs in
            if lhs.isEnabled != rhs.isEnabled { return lhs.isEnabled && !rhs.isEnabled }
            if lhs.isEnabled { return lhs.position < rhs.position }
            return lhs.id < rhs.id
        }
    }

    private func speechBackendRow(_ backend: STTBackendStatus) -> some View {
        let enabledCount = model.sttBackends.filter(\.isEnabled).count
        return HStack {
            Toggle(isOn: Binding(
                get: { backend.isEnabled },
                set: { model.setSTTBackendEnabled(backend.id, $0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(backend.displayName)
                    Text(speechBackendStatusLabel(backend.state))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            speechBackendActionView(backend)

            if backend.isEnabled {
                VStack(spacing: 2) {
                    Button {
                        model.moveSTTBackend(backend.id, up: true)
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .disabled(backend.position == 0)

                    Button {
                        model.moveSTTBackend(backend.id, up: false)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .disabled(backend.position == enabledCount - 1)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    @ViewBuilder
    private func speechBackendActionView(_ backend: STTBackendStatus) -> some View {
        switch backend.state {
        case let .downloading(progress):
            ProgressView(value: progress)
                .frame(width: 80)
        case .modelNotDownloaded, .failed:
            Button("Download") {
                Task { await model.downloadSpeechModel(backend.id) }
            }
            .controlSize(.small)
        case .ready, .unsupported, .unavailable:
            EmptyView()
        }
    }

    private func speechBackendStatusLabel(_ state: STTBackendStatus.State) -> String {
        switch state {
        case .ready: "Ready"
        case .modelNotDownloaded: "Model not downloaded"
        case let .downloading(progress): "Downloading \(Int((progress * 100).rounded()))%"
        case let .unsupported(reason): reason
        case let .unavailable(reason): reason
        case .failed: "Download failed"
        }
    }

    private func permissionRow(
        title: String,
        granted: Bool,
        request: (() -> Void)? = nil,
        settings: @escaping () -> Void
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(granted ? "Allowed" : "Required")
                .foregroundStyle(granted ? .green : .orange)
            if !granted {
                if let request { Button("Allow", action: request) }
                Button("Open Settings", action: settings)
            }
        }
    }

    private var voiceBinding: Binding<String?> {
        Binding(
            get: { model.settings.ttsVoiceIdentifier },
            set: { model.setVoiceIdentifier($0) }
        )
    }

    private var rateBinding: Binding<Double> {
        Binding(
            get: { Double(model.settings.ttsRate) },
            set: { model.setSpeechRate(Float($0)) }
        )
    }

    private var dictationModeBinding: Binding<DictationMode> {
        Binding(
            get: { model.settings.dictationMode },
            set: { model.setDictationMode($0) }
        )
    }

    private var activityOverlayStyleBinding: Binding<ActivityOverlayStyle> {
        Binding(
            get: { model.settings.activityOverlayStyle },
            set: { model.setActivityOverlayStyle($0) }
        )
    }
}

private struct HotkeyRecorder: NSViewRepresentable {
    let definition: HotkeyDefinition
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
    var definition: HotkeyDefinition = .chord(keyCode: 0, modifiers: []) {
        didSet {
            if !isRecording { title = definition.displayName }
        }
    }
    private var isRecording = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        title = definition.displayName
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

private extension DictationMode {
    var title: String {
        switch self {
        case .holdToTalk: "Hold to Talk"
        case .toggle: "Toggle"
        }
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
    static let allCases: [HotkeyModifier] = [.control, .option, .shift, .command, .function]
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
