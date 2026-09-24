import SwiftUI

extension CleanupModelID: Identifiable {
    var id: String { rawValue }
}

struct DictationCleanupSettingsSection: View {
    @Bindable var model: AppModel
    @State private var testModel: CleanupModelID?

    var body: some View {
        let tester = model.speechBackends.cleanupTester
        let testerBusy = tester?.phase.isRunning ?? false
        SpeechBackendSettingsSection(
            title: "Dictation Cleanup",
            backends: model.speechBackends.cleanupBackends,
            domain: .dictationCleanup,
            controller: model.speechBackends.models,
            message: model.speechBackends.models.messages[.dictationCleanup],
            setEnabled: { _, _ in },
            move: { _, _ in },
            showsProviderControls: false,
            rowExtraAction: { status in
                guard tester != nil, let modelID = CleanupModelID(rawValue: status.id) else { return nil }
                let availability = CleanupTestAvailability.make(status: status, testerBusy: testerBusy)
                return (title: "Test", enabled: availability.enabled, help: availability.help, action: { testModel = modelID })
            },
            leadingContent: {
                Toggle(
                    "Clean up dictated text",
                    isOn: Binding(
                        get: { model.settings.dictationCleanupEnabled },
                        set: { model.speechBackends.setCleanupEnabled($0) }
                    )
                )
                Text(
                    "Uses a local model to fix punctuation, remove filler words and apply spoken corrections before inserting. "
                        + "Falls back to the original text if cleanup fails."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        ) { _ in EmptyView() }
        .sheet(item: $testModel) { initial in
            if let tester {
                DictationCleanupTestSheet(tester: tester, model: initial)
            }
        }
    }
}
