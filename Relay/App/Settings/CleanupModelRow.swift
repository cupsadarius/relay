import SwiftUI

struct CleanupModelRowPresentation: Equatable {
    let base: SpeechModelRowPresentation
    let stateLabel: String
    let showsDownload: Bool
    let showsRemove: Bool
    let canTest: Bool
    let testHelp: String?

    static func make(status: SpeechModelStatus, testerBusy: Bool) -> Self {
        let base = SpeechModelRowPresentation.make(status: status)
        let builtIn = !status.capabilities.contains(.download)
        let usable = status.usability == .usable
        let downloaded = status.installState == .downloaded
        let stateLabel = builtIn && usable && !base.isActive ? "Built in · Available" : base.stateLabel
        let canTest = downloaded && usable && !testerBusy
        let testHelp: String? =
            if let reason = status.usability.unusableReason {
                reason
            } else if !downloaded {
                "Download the model first."
            } else if testerBusy {
                "A test is already running."
            } else {
                nil
            }
        return Self(
            base: base, stateLabel: stateLabel, showsDownload: !builtIn, showsRemove: status.capabilities.contains(.remove),
            canTest: canTest, testHelp: testHelp
        )
    }
}

struct CleanupModelRow: View {
    let item: CleanupModelRowItem
    let controller: SpeechModelController
    let testerBusy: Bool
    let test: (CleanupModelID) -> Void
    @State private var confirmsRemoval = false

    var body: some View {
        let presentation = CleanupModelRowPresentation.make(status: item.status, testerBusy: testerBusy)
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.base.title)
                if !presentation.base.detail.isEmpty {
                    Text(presentation.base.detail).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(presentation.stateLabel)
                .font(.caption)
                .foregroundStyle(presentation.base.isActive ? .green : .secondary)
                .frame(minWidth: 92, alignment: .trailing)
            if presentation.showsDownload {
                Button(presentation.base.downloadTitle) { Task { await controller.download(item.id, in: item.key) } }
                    .disabled(!presentation.base.canDownload)
                    .help(presentation.base.downloadHelp ?? "Download this model")
            }
            Button("Select") { Task { await controller.select(item.id, in: item.key) } }
                .disabled(!presentation.base.canSelect)
                .help(presentation.base.selectHelp ?? "Use this model for dictation cleanup")
            Button("Test") { if let id = item.modelID { test(id) } }
                .disabled(!presentation.canTest)
                .help(presentation.testHelp ?? "Try this model on sample text")
            if presentation.showsRemove {
                Button("Remove", role: .destructive) { confirmsRemoval = true }
                    .disabled(!presentation.base.canRemove)
                    .help(presentation.base.removeHelp ?? "Delete this model from this Mac")
            }
        }
        .controlSize(.small)
        .confirmationDialog("Remove \(presentation.base.title)?", isPresented: $confirmsRemoval, titleVisibility: .visible) {
            Button("Remove Model", role: .destructive) { Task { await controller.remove(item.id, in: item.key) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the local model. You can download it again later.")
        }
    }
}
