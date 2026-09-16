import SwiftUI

struct GeneralSettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("Live Transcription") {
                Toggle("Live transcription in the pill", isOn: liveTranscriptionBinding)
                Text("Show interim text while you speak. Re-transcribes about once a second (uses more CPU).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var liveTranscriptionBinding: Binding<Bool> {
        Binding(
            get: { model.settings.liveTranscriptionEnabled },
            set: { model.setLiveTranscriptionEnabled($0) }
        )
    }
}
