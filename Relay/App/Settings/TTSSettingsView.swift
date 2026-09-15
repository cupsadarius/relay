import AVFoundation
import SwiftUI

struct TTSSettingsView: View {
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
        }
        .formStyle(.grouped)
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
}
