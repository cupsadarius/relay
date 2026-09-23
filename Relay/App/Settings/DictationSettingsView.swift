import SwiftUI

struct DictationSettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("Dictation") {
                Picker("Mode", selection: Binding(
                    get: { model.settings.dictationMode },
                    set: { model.settingsController.setDictationMode($0) }
                )) {
                    ForEach(DictationMode.allCases, id: \.self) { mode in
                        Text(mode == .holdToTalk ? "Hold to Talk" : "Toggle").tag(mode)
                    }
                }
            }
            SpeechBackendSettingsSection(
                title: "Speech Recognition",
                backends: model.sttBackendList.rows,
                domain: .dictation,
                controller: model.modelController,
                message: model.modelController.messages[.dictation] ?? model.sttBackendList.message,
                setEnabled: model.sttBackendList.setEnabled,
                move: model.sttBackendList.move
            ) { _ in EmptyView() }
            Text("Relay tries enabled backends in order and falls back to the next one. Models download only when you choose Download.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .task { await model.modelController.refresh(domain: .dictation) }
    }
}
