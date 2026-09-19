import SwiftUI

struct DictationSettingsView: View {
    @Bindable var model: AppModel

    /// Which providers' nested model lists are currently expanded, keyed by backend id. Absent
    /// (or explicitly removed) means collapsed -- the default state for every provider, per-view-
    /// session only (SwiftUI `@State`), never persisted to disk.
    @State private var expandedBackendIDs: Set<String> = []

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

                    if speechModelDisplayMode(for: backend.id) == .nestedList, isExpanded(backend.id) {
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

    /// The provider row: display name, a status/subtitle caption, an enable toggle, and (for a
    /// backend with at least one model, i.e. `speechModelDisplayMode(for:) == .nestedList`) a
    /// disclosure control that shows/hides the nested model list below. Every backend renders
    /// through this SAME code path -- no per-backend branching -- so Apple Speech, Parakeet, and
    /// OpenAI Whisper all look and behave identically here regardless of how many models they
    /// have (0, 1, or 11).
    private func speechBackendRow(_ backend: STTBackendStatus) -> some View {
        let enabledCount = model.sttBackends.filter(\.isEnabled).count
        let isEnabledBinding = Binding(
            get: { backend.isEnabled },
            set: { model.setSTTBackendEnabled(backend.id, $0) }
        )
        let displayMode = speechModelDisplayMode(for: backend.id)
        let expanded = isExpanded(backend.id)

        return HStack(alignment: .center) {
            if displayMode == .nestedList {
                Button {
                    toggleExpanded(backend.id)
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? "Collapse \(backend.displayName) models" : "Expand \(backend.displayName) models")
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(backend.displayName)
                Text(speechBackendSubtitle(backend: backend, displayMode: displayMode, expanded: expanded))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

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

    /// What the provider row's caption shows: the plain status label while expanded (the nested
    /// rows below already show which model is active) or while there's no active model to
    /// summarize, otherwise (collapsed, with an active model) that model's name -- see
    /// `CollapsedProviderSubtitle`.
    private func speechBackendSubtitle(backend: STTBackendStatus, displayMode: SpeechBackendModelDisplayMode, expanded: Bool) -> String {
        let statusLabel = speechBackendStatusLabel(backend.state)
        guard displayMode == .nestedList, !expanded else { return statusLabel }
        return CollapsedProviderSubtitle.make(models: model.speechModels[backend.id] ?? [], statusLabel: statusLabel)
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

    private func isExpanded(_ backendID: String) -> Bool {
        expandedBackendIDs.contains(backendID)
    }

    private func toggleExpanded(_ backendID: String) {
        if expandedBackendIDs.contains(backendID) {
            expandedBackendIDs.remove(backendID)
        } else {
            expandedBackendIDs.insert(backendID)
        }
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

            speechModelStateLabel(presentation)

            speechModelActionView(backendID: backendID, status: status, presentation: presentation)
        }
        .padding(.leading, 20)
    }

    /// Renders `presentation.stateLabel`, with the leading "Active" bubble drawn in green when
    /// `presentation.isActive` -- the rest of the label keeps its normal color.
    @ViewBuilder
    private func speechModelStateLabel(_ presentation: SpeechModelRowPresentation) -> some View {
        if presentation.isActive {
            HStack(spacing: 4) {
                Text("\u{25CF}")
                    .foregroundStyle(.green)
                Text("Active")
                    .foregroundStyle(.primary)
            }
            .font(.caption)
        } else {
            Text(presentation.stateLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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

/// What a speech backend's row shows below it, based solely on how many models
/// `AppModel.speechModels` reports for that backend -- separated from `DictationSettingsView` so
/// it is unit-testable without SwiftUI (`SpeechBackendModelDisplayModeTests` in
/// `RelayTests/App/SettingsViewsSmokeTests.swift`).
///
/// Every registered backend (Apple Speech, Parakeet, OpenAI Whisper) has a `SpeechModelManaging`
/// today, so in production this is always `.nestedList` once `speechModels` is populated --
/// `.none` covers the brief window before `DictationSettingsView`'s `.task { await
/// model.refreshSpeechModels() }` has completed, and any future backend that genuinely has no
/// model manager at all.
enum SpeechBackendModelDisplayMode: Equatable {
    /// Nothing to show yet: `speechModels` hasn't been populated for this backend (the `.task`
    /// hasn't completed) or the backend has no model manager at all. No disclosure control and no
    /// nested list render for this backend.
    case none
    /// One or more models: a disclosure control and (when expanded) the nested per-model list
    /// render, showing every model (Apple Speech's one, Parakeet's one, or Whisper's eleven)
    /// through the identical row UI -- there is no longer a distinct "single aggregate action"
    /// case for a one-model backend.
    case nestedList

    static func make(modelCount: Int) -> SpeechBackendModelDisplayMode {
        modelCount > 0 ? .nestedList : .none
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

/// What a multi-model provider row's caption shows while its nested list is collapsed --
/// separated from `DictationSettingsView` so it is unit-testable without SwiftUI. See
/// `CollapsedProviderSubtitleTests` in `RelayTests/App/SettingsViewsSmokeTests.swift`.
enum CollapsedProviderSubtitle {
    /// The active (selected AND downloaded) model's display name, if there is one; otherwise
    /// `statusLabel` unchanged -- e.g. "Model not downloaded" or "Ready" when nothing is selected
    /// or downloaded yet. Lets the collapsed provider row surface which model is in use without
    /// requiring the user to expand it.
    static func make(models: [SpeechModelStatus], statusLabel: String) -> String {
        guard let active = models.first(where: { $0.isSelected && $0.installState == .downloaded }) else {
            return statusLabel
        }
        return active.descriptor.displayName
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
