import SwiftUI

struct DictationSettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("Dictation") {
                Picker("Mode", selection: Binding(
                    get: { model.settings.dictationMode },
                    set: { model.setDictationMode($0) }
                )) {
                    ForEach(DictationMode.allCases, id: \.self) { mode in
                        Text(mode == .holdToTalk ? "Hold to Talk" : "Toggle").tag(mode)
                    }
                }
            }
            SpeechBackendSettingsSection(
                title: "Speech Recognition",
                backends: model.sttBackends,
                domain: .dictation,
                controller: model.modelController,
                message: model.modelController.messages[.dictation] ?? model.speechBackendMessage,
                setEnabled: model.setSTTBackendEnabled,
                move: model.moveSTTBackend
            ) { _ in EmptyView() }
            Text("Relay tries enabled backends in order and falls back to the next one. Models download only when you choose Download.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .task { await model.modelController.refresh(domain: .dictation) }
    }
}
