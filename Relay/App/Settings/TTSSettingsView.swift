import SwiftUI

struct TTSSettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            SpeechBackendSettingsSection(
                title: "Backends",
                backends: model.speechBackends.textToSpeech.rows,
                domain: .textToSpeech,
                controller: model.speechBackends.models,
                message: model.speechBackends.models.messages[.textToSpeech] ?? model.speechBackends.textToSpeech.message,
                setEnabled: model.speechBackends.textToSpeech.setEnabled,
                move: model.speechBackends.textToSpeech.move,
                hasExpandedContent: { !model.speechBackends.voices.voices(for: $0).isEmpty }
            ) { backendID in
                let activeID = model.speechBackends.voices.activeVoiceID(for: backendID, settings: model.settings)
                ForEach(model.speechBackends.voices.voices(for: backendID)) { voice in
                    SpeechVoiceRow(
                        voice: voice,
                        isActive: voice.id == activeID,
                        select: { model.speechBackends.selectVoice(backendID: backendID, voiceID: voice.id) },
                        test: { Task { await model.speechActions.previewVoice(backendID: backendID, voiceID: voice.id) } }
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
        .task { await model.speechBackends.refresh(.textToSpeech) }
    }
}
