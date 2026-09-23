import SwiftUI

struct SpeechModelRowPresentation: Equatable {
    let title: String
    let detail: String
    let stateLabel: String
    let isActive: Bool
    let downloadTitle: String
    let canDownload: Bool
    let canSelect: Bool
    let canRemove: Bool
    let downloadHelp: String?
    let selectHelp: String?
    let removeHelp: String?

    static func make(status: SpeechModelStatus, backendReady: Bool = true) -> Self {
        let downloaded = status.installState == .downloaded
        let active = backendReady && status.isSelected && downloaded
        let supportsDownload = status.capabilities.contains(.download)
        let supportsSelect = status.capabilities.contains(.select)
        let supportsRemove = status.capabilities.contains(.remove)
        let canDownload = supportsDownload && (status.installState == .notDownloaded || status.installState == .downloadFailed)
        let canSelect = supportsSelect && downloaded && !status.isSelected
        let canRemove = supportsRemove && downloaded
        let stateLabel: String
        switch status.installState {
        case .notDownloaded: stateLabel = "Not downloaded"
        case let .downloading(progress): stateLabel = "Downloading \(Int((progress * 100).rounded()))%"
        case .downloaded: stateLabel = active ? "● Active" : "Downloaded"
        case .downloadFailed: stateLabel = "Download failed"
        }
        return Self(
            title: status.descriptor.displayName,
            detail: status.descriptor.detail ?? "",
            stateLabel: stateLabel,
            isActive: active,
            downloadTitle: status.installState == .downloadFailed ? "Retry" : "Download",
            canDownload: canDownload,
            canSelect: canSelect,
            canRemove: canRemove,
            downloadHelp: supportsDownload ? (canDownload ? nil : "This model is already downloaded or busy.") : "This provider does not support model downloads.",
            selectHelp: supportsSelect ? (canSelect ? nil : "Download the model first, or it is already selected.") : "This provider does not support model selection.",
            removeHelp: supportsRemove ? (canRemove ? nil : "Download the model before removing it.") : "This provider does not support model removal."
        )
    }
}

struct SpeechModelRow: View {
    let status: SpeechModelStatus
    let backend: SpeechModelBackendKey
    let backendReady: Bool
    let controller: SpeechModelController
    @State private var confirmsRemoval = false

    var body: some View {
        let presentation = SpeechModelRowPresentation.make(status: status, backendReady: backendReady)
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.title)
                if !presentation.detail.isEmpty {
                    Text(presentation.detail).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(presentation.stateLabel)
                .font(.caption)
                .foregroundStyle(presentation.isActive ? .green : .secondary)
                .frame(minWidth: 92, alignment: .trailing)
            Button(presentation.downloadTitle) { Task { await controller.download(status.id, in: backend) } }
                .disabled(!presentation.canDownload)
                .help(presentation.downloadHelp ?? "Download this model")
            Button("Select") { Task { await controller.select(status.id, in: backend) } }
                .disabled(!presentation.canSelect)
                .help(presentation.selectHelp ?? "Make this model active")
            Button("Remove", role: .destructive) { confirmsRemoval = true }
                .disabled(!presentation.canRemove)
                .help(presentation.removeHelp ?? "Delete this model from this Mac")
        }
        .controlSize(.small)
        .padding(.leading, 20)
        .confirmationDialog("Remove \(presentation.title)?", isPresented: $confirmsRemoval, titleVisibility: .visible) {
            Button("Remove Model", role: .destructive) { Task { await controller.remove(status.id, in: backend) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the local model. You can download it again later.")
        }
    }
}
