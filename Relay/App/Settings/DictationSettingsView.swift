import SwiftUI

struct DictationSettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("Dictation") {
                Picker("Mode", selection: dictationModeBinding) {
                    ForEach(DictationMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
            }

            Section("Speech Recognition") {
                ForEach(model.sttBackends) { backend in
                    speechBackendRow(backend)
                }

                if let message = model.speechBackendMessage {
                    Text(message)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("speech-backend-message")
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
        }
        .formStyle(.grouped)
    }

    private func speechBackendRow(_ backend: STTBackendStatus) -> some View {
        let enabledCount = model.sttBackends.filter(\.isEnabled).count
        let isEnabledBinding = Binding(
            get: { backend.isEnabled },
            set: { model.setSTTBackendEnabled(backend.id, $0) }
        )
        return HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(backend.displayName)
                Text(speechBackendStatusLabel(backend.state))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            speechBackendActionView(backend)

            Toggle("", isOn: isEnabledBinding)
                .labelsHidden()

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
        case .modelNotDownloaded, .downloadFailed:
            if model.canDownloadSpeechModel(backend.id) {
                Button("Download") {
                    Task { await model.downloadSpeechModel(backend.id) }
                }
                .controlSize(.small)
            }
        case .ready, .unsupported, .unavailable:
            EmptyView()
        }
    }

    private func speechBackendStatusLabel(_ state: STTBackendStatus.State) -> String {
        switch state {
        case .ready: "Ready"
        case .modelNotDownloaded: "Model not downloaded"
        case let .downloading(progress): "Downloading \(Int((progress * 100).rounded()))%"
        case .downloadFailed: "Download failed"
        case .unsupported: "Unsupported on this Mac"
        case .unavailable: "Unavailable"
        }
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

private extension DictationMode {
    var title: String {
        switch self {
        case .holdToTalk: "Hold to Talk"
        case .toggle: "Toggle"
        }
    }
}
