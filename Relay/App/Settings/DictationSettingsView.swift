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

                    if speechModelDisplayMode(for: backend.id) == .nestedList {
                        ForEach(model.speechModels[backend.id] ?? []) { status in
                            speechModelRow(backendID: backend.id, status: status)
                        }
                    }
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
        }
        .formStyle(.grouped)
        .task { await model.refreshSpeechModels() }
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

            // A backend with more than one model manages downloads/selection per model in the
            // nested rows below instead, so the single aggregate action here would either
            // duplicate those controls or (via the old one-model-per-backend `downloadSpeechModel(_:)`)
            // silently pick "the first model" on behalf of the user. And before `speechModels` is
            // populated (or for a backend with no manager, e.g. Apple Speech, which never appears
            // in it) the model count is 0 -- showing the aggregate action there is exactly that
            // same "picks the first model" bug, so it renders only for a genuine one-model backend.
            if speechModelDisplayMode(for: backend.id) == .aggregateAction {
                speechBackendActionView(backend)
            }

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

    /// What `speechBackendRow`/the nested list should show for a backend, based on how many
    /// models `speechModels` currently reports for it. See `SpeechBackendModelDisplayMode`.
    private func speechModelDisplayMode(for backendID: String) -> SpeechBackendModelDisplayMode {
        .make(modelCount: model.speechModels[backendID]?.count ?? 0)
    }

    private func speechModelRow(backendID: String, status: SpeechModelStatus) -> some View {
        let presentation = SpeechModelRowPresentation.make(status: status)
        return HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.title)
                if !presentation.detailLabel.isEmpty {
                    Text(presentation.detailLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Text(presentation.stateLabel)
                .font(.caption)
                .foregroundStyle(presentation.isActive ? .primary : .secondary)

            speechModelActionView(backendID: backendID, status: status, presentation: presentation)
        }
        .padding(.leading, 20)
    }

    /// Every action here is explicit (a button the user taps), so selecting a not-downloaded
    /// model always means tapping "Download" first -- there is no tap target that selects (and so
    /// implicitly downloads) a model on the user's behalf.
    @ViewBuilder
    private func speechModelActionView(backendID: String, status: SpeechModelStatus, presentation: SpeechModelRowPresentation) -> some View {
        switch status.installState {
        case let .downloading(progress):
            ProgressView(value: progress)
                .frame(width: 60)
        case .notDownloaded, .downloadFailed:
            Button(status.installState == .downloadFailed ? "Retry" : "Download") {
                Task { await model.downloadSpeechModel(backendID: backendID, modelID: status.id) }
            }
            .controlSize(.small)
        case .downloaded:
            if presentation.isActive {
                EmptyView()
            } else {
                HStack(spacing: 8) {
                    Button("Select") {
                        Task { await model.selectSpeechModel(backendID: backendID, modelID: status.id) }
                    }
                    .controlSize(.small)

                    if presentation.showsRemove {
                        Button("Remove") {
                            Task { await model.removeSpeechModel(backendID: backendID, modelID: status.id) }
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }
}

/// What a speech backend's row shows for model download/selection, based solely on how many
/// models `AppModel.speechModels` reports for that backend -- separated from
/// `DictationSettingsView` so it is unit-testable without SwiftUI
/// (`SpeechBackendModelDisplayModeTests` in `RelayTests/App/SettingsViewsSmokeTests.swift`).
enum SpeechBackendModelDisplayMode: Equatable {
    /// Nothing to show yet: either `speechModels` hasn't been populated for this backend (the
    /// `.task { await model.refreshSpeechModels() }` in `DictationSettingsView.body` hasn't
    /// completed) or the backend has no model manager at all (e.g. Apple Speech). Showing the
    /// aggregate action here would resolve to `downloadSpeechModel(_:)`'s "first model" fallback
    /// on the user's behalf before the real model count is known -- exactly the bug this type
    /// exists to prevent.
    case none
    /// Exactly one model: the single aggregate Download row is a faithful one-model action
    /// (Parakeet's case).
    case aggregateAction
    /// More than one model: the nested per-model list replaces the aggregate row so the user
    /// picks explicitly (Whisper's case).
    case nestedList

    static func make(modelCount: Int) -> SpeechBackendModelDisplayMode {
        switch modelCount {
        case 1: .aggregateAction
        case 2...: .nestedList
        default: .none
        }
    }
}

/// Pure presentation mapping from a `SpeechModelStatus` to what a nested model row shows --
/// separated from `DictationSettingsView` so it is unit-testable without SwiftUI
/// (`SpeechModelRowPresentationTests` in `RelayTests/App/SettingsViewsSmokeTests.swift`).
struct SpeechModelRowPresentation: Equatable {
    let title: String
    let detailLabel: String
    let stateLabel: String
    /// True only when the model is both selected AND downloaded -- selection alone (a selected
    /// but not-yet-downloaded model) and download alone (a downloaded but not-selected model)
    /// are each their own state, not "Active".
    let isActive: Bool
    /// Remove is only ever offered for a downloaded model that is NOT the active one -- removing
    /// the active model, or a model that isn't downloaded yet, isn't a valid action.
    let showsRemove: Bool

    static func make(status: SpeechModelStatus) -> SpeechModelRowPresentation {
        let isActive = status.isSelected && status.installState == .downloaded
        let showsRemove = status.installState == .downloaded && !isActive
        let stateLabel: String
        switch status.installState {
        case .notDownloaded:
            stateLabel = "Download"
        case let .downloading(progress):
            stateLabel = "Downloading \(Int((progress * 100).rounded()))%"
        case .downloaded:
            stateLabel = isActive ? "\u{25CF} Active" : "Downloaded"
        case .downloadFailed:
            stateLabel = "Failed"
        }

        return SpeechModelRowPresentation(
            title: status.descriptor.displayName,
            detailLabel: status.descriptor.detail ?? "",
            stateLabel: stateLabel,
            isActive: isActive,
            showsRemove: showsRemove
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
