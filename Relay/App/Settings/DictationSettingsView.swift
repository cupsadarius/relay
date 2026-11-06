import SwiftUI

struct DictationSettingsView: View {
    @Bindable var model: AppModel
    @State private var microphones: [AudioInputDevice] = []

    var body: some View {
        Form {
            Section("Dictation") {
                Picker(
                    "Mode",
                    selection: Binding(
                        get: { model.settings.dictationMode },
                        set: { model.settingsController.setDictationMode($0) }
                    )
                ) {
                    ForEach(DictationMode.allCases, id: \.self) { mode in
                        Text(mode == .holdToTalk ? "Hold to Talk" : "Toggle").tag(mode)
                    }
                }
                microphonePicker
            }
            SpeechBackendSettingsSection(
                title: "Speech Recognition",
                backends: model.speechBackends.dictation.rows,
                domain: .dictation,
                controller: model.speechBackends.models,
                message: model.speechBackends.models.messages[.dictation] ?? model.speechBackends.dictation.message,
                setEnabled: model.speechBackends.dictation.setEnabled,
                move: model.speechBackends.dictation.move
            ) { _ in EmptyView() }
            Text("Relay tries enabled backends in order and falls back to the next one. Models download only when you choose Download.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .task {
            microphones = await Task.detached { AudioInputDevices.connected() }.value
            await model.speechBackends.refresh(.dictation)
        }
    }

    @ViewBuilder private var microphonePicker: some View {
        let saved = model.settings.selectedMicrophone
        let missing = MicrophoneSelection.resolve(saved, connected: microphones).missing
        Picker(
            "Microphone",
            selection: Binding(
                get: { saved?.uid },
                set: { uid in
                    let device = microphones.first { $0.uid == uid }
                    model.settingsController.setSelectedMicrophone(
                        device.map { SelectedMicrophone(uid: $0.uid, name: $0.name) } ?? (uid == nil ? nil : saved)
                    )
                }
            )
        ) {
            Text("System default").tag(String?.none)
            ForEach(microphones) { device in
                Text(device.name).tag(String?.some(device.uid))
            }
            if let missing {
                Text("\(missing.name) (not connected)").tag(String?.some(missing.uid))
            }
        }
        if let missing, !microphones.isEmpty {
            Text("\(missing.name) is not connected. Relay uses the system default microphone.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Text("Pick your Mac's built-in microphone to keep Bluetooth headphones in high-quality mode during calls.")
            .font(.caption).foregroundStyle(.secondary)
    }
}
