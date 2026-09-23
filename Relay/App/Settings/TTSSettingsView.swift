import SwiftUI

struct TTSSettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            SpeechBackendSettingsSection(
                title: "Backends",
                backends: model.ttsBackendList.rows,
                domain: .textToSpeech,
                controller: model.modelController,
                message: model.modelController.messages[.textToSpeech] ?? model.ttsBackendList.message,
                setEnabled: model.ttsBackendList.setEnabled,
                move: model.ttsBackendList.move,
                hasExpandedContent: { !model.voiceCatalog.voices(for: $0).isEmpty }
            ) { backendID in
                let activeID = model.voiceCatalog.activeVoiceID(for: backendID, settings: model.settings)
                ForEach(model.voiceCatalog.voices(for: backendID)) { voice in
                    SpeechVoiceRow(
                        voice: voice,
                        isActive: voice.id == activeID,
                        select: { model.selectVoice(backendID: backendID, voiceID: voice.id) },
                        test: { Task { await model.previewVoice(backendID: backendID, voiceID: voice.id) } }
                    )
                }
            }
            Section("Speech") {
                HStack {
                    Slider(
                        value: Binding(
                            get: { Double(model.settings.ttsRate) },
                            set: { model.settingsController.setSpeechRate(Float($0)) }
                        ),
                        in: 0.1...1.0,
                        step: 0.05,
                        onEditingChanged: { editing in
                            if !editing { model.settingsController.flushPendingSave() }
                        }
                    )
                    Text(model.settings.ttsRate, format: .number.precision(.fractionLength(2)))
                        .monospacedDigit().frame(width: 38, alignment: .trailing)
                }
                .accessibilityLabel("Speech rate")
            }
        }
        .formStyle(.grouped)
        .task {
            await model.ttsBackendList.refresh()
            await model.modelController.refresh(domain: .textToSpeech)
        }
    }
}
