import SwiftUI

struct SpeechBackendSettingsSection<ExpandedContent: View>: View {
    let title: String
    let backends: [BackendStatus]
    let domain: SpeechModelDomain
    let controller: SpeechModelController
    let message: String?
    let setEnabled: (String, Bool) -> Void
    let move: (String, Bool) -> Void
    let hasExpandedContent: (String) -> Bool
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
        hasExpandedContent: @escaping (String) -> Bool = { _ in false },
        @ViewBuilder expandedContent: @escaping (String) -> ExpandedContent
    ) {
        self.title = title
        self.backends = backends
        self.domain = domain
        self.controller = controller
        self.message = message
        self.setEnabled = setEnabled
        self.move = move
        self.hasExpandedContent = hasExpandedContent
        self.expandedContent = expandedContent
    }

    var body: some View {
        Section(title) {
            ForEach(backends) { backend in
                let key = SpeechModelBackendKey(domain: domain, backendID: backend.id)
                let rows = controller.models[key] ?? []
                let expandable = !rows.isEmpty || hasExpandedContent(backend.id)
                let expanded = expandedBackendIDs.contains(backend.id)
                backendRow(backend, rows: rows, expandable: expandable, expanded: expanded)
                if expandable, expanded {
                    ForEach(rows) { status in
                        SpeechModelRow(status: status, backend: key, backendReady: backend.state == .ready, controller: controller)
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
                if expanded { expandedBackendIDs.remove(backend.id) }
                else { expandedBackendIDs.insert(backend.id) }
            } label: {
                Image(systemName: expanded ? "chevron.down" : "chevron.right").frame(width: 12)
            }
            .buttonStyle(.plain).disabled(!expandable).opacity(expandable ? 1 : 0)
            VStack(alignment: .leading, spacing: 2) {
                Text(backend.displayName)
                Text(subtitle(backend, rows: rows, expanded: expanded)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { backend.isEnabled }, set: { setEnabled(backend.id, $0) })).labelsHidden()
            if backend.isEnabled {
                VStack(spacing: 2) {
                    Button { move(backend.id, true) } label: { Image(systemName: "chevron.up") }.disabled(backend.position == 0)
                    Button { move(backend.id, false) } label: { Image(systemName: "chevron.down") }.disabled(backend.position == enabledCount - 1)
                }.buttonStyle(.borderless)
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
