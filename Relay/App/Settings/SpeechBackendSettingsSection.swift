import SwiftUI

struct SpeechBackendSettingsSection<LeadingContent: View, ExpandedContent: View>: View {
    let title: String
    let backends: [BackendStatus]
    let domain: SpeechModelDomain
    let controller: SpeechModelController
    let message: String?
    let setEnabled: (String, Bool) -> Void
    let move: (String, Bool) -> Void
    /// `false` hides the per-provider enable toggle and the up/down order arrows — for domains
    /// with no per-provider enable and no priority order (dictation cleanup). STT and TTS keep
    /// the default and are unchanged.
    let showsProviderControls: Bool
    let hasExpandedContent: (String) -> Bool
    /// An optional trailing action for a model row beyond Download/Select/Remove, e.g. cleanup's
    /// "Test". `nil` for a row with nothing extra to offer.
    let rowExtraAction: (SpeechModelStatus) -> (title: String, enabled: Bool, help: String?, action: () -> Void)?
    let leadingContent: () -> LeadingContent
    let expandedContent: (String) -> ExpandedContent
    @State private var expandedBackendIDs: Set<String> = []

    init(
        title: String,
        backends: [BackendStatus],
        domain: SpeechModelDomain,
        controller: SpeechModelController,
        message: String?,
        setEnabled: @escaping (String, Bool) -> Void,
        move: @escaping (String, Bool) -> Void,
        showsProviderControls: Bool = true,
        hasExpandedContent: @escaping (String) -> Bool = { _ in false },
        rowExtraAction: @escaping (SpeechModelStatus) -> (title: String, enabled: Bool, help: String?, action: () -> Void)? = { _ in nil },
        @ViewBuilder leadingContent: @escaping () -> LeadingContent = { EmptyView() },
        @ViewBuilder expandedContent: @escaping (String) -> ExpandedContent
    ) {
        self.title = title
        self.backends = backends
        self.domain = domain
        self.controller = controller
        self.message = message
        self.setEnabled = setEnabled
        self.move = move
        self.showsProviderControls = showsProviderControls
        self.hasExpandedContent = hasExpandedContent
        self.rowExtraAction = rowExtraAction
        self.leadingContent = leadingContent
        self.expandedContent = expandedContent
    }

    var body: some View {
        Section(title) {
            leadingContent()
            ForEach(backends) { backend in
                let key = SpeechModelBackendKey(domain: domain, backendID: backend.id)
                let rows = controller.models[key] ?? []
                let expandable = !rows.isEmpty || hasExpandedContent(backend.id)
                let expanded = expandedBackendIDs.contains(backend.id)
                backendRow(backend, rows: rows, expandable: expandable, expanded: expanded)
                if expandable, expanded {
                    ForEach(rows) { status in
                        SpeechModelRow(
                            status: status, backend: key, backendReady: backend.state == .ready, controller: controller,
                            extraAction: rowExtraAction(status)
                        )
                    }
                    expandedContent(backend.id)
                }
            }
            if let message { Text(message).foregroundStyle(.red) }
        }
    }

    private func backendRow(_ backend: BackendStatus, rows: [SpeechModelStatus], expandable: Bool, expanded: Bool) -> some View {
        let enabledCount = backends.filter(\.isEnabled).count
        return HStack {
            Button {
                if expanded { expandedBackendIDs.remove(backend.id) } else { expandedBackendIDs.insert(backend.id) }
            } label: {
                Image(systemName: expanded ? "chevron.down" : "chevron.right").frame(width: 12)
            }
            .buttonStyle(.plain).disabled(!expandable).opacity(expandable ? 1 : 0)
            VStack(alignment: .leading, spacing: 2) {
                Text(backend.displayName)
                Text(subtitle(backend, rows: rows, expanded: expanded)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if showsProviderControls {
                Toggle("", isOn: Binding(get: { backend.isEnabled }, set: { setEnabled(backend.id, $0) })).labelsHidden()
                if backend.isEnabled {
                    VStack(spacing: 2) {
                        Button {
                            move(backend.id, true)
                        } label: {
                            Image(systemName: "chevron.up")
                        }.disabled(backend.position == 0)
                        Button {
                            move(backend.id, false)
                        } label: {
                            Image(systemName: "chevron.down")
                        }.disabled(backend.position == enabledCount - 1)
                    }.buttonStyle(.borderless)
                }
            }
        }
    }

    private func subtitle(_ backend: BackendStatus, rows: [SpeechModelStatus], expanded: Bool) -> String {
        let label = Self.statusLabel(backend.state)
        guard !expanded else { return label }
        return CollapsedProviderSubtitle.make(models: rows, statusLabel: label, backendReady: backend.state == .ready)
    }

    static func statusLabel(_ state: BackendStatus.State) -> String {
        switch state {
        case .ready: "Ready"
        case .modelNotDownloaded: "Model not downloaded"
        case .unsupported: "Unsupported on this Mac"
        case .unavailable: "Unavailable"
        }
    }
}

enum CollapsedProviderSubtitle {
    static func make(models: [SpeechModelStatus], statusLabel: String, backendReady: Bool = true) -> String {
        guard backendReady, let active = models.first(where: { $0.isSelected && $0.installState == .downloaded }) else {
            return statusLabel
        }
        return active.descriptor.displayName
    }
}
