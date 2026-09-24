import SwiftUI

extension CleanupModelID: Identifiable {
    var id: String { rawValue }
}

struct DictationCleanupSettingsSection: View {
    @Bindable var model: AppModel
    @State private var testModel: CleanupModelID?

    private var rows: [CleanupModelRowItem] { model.speechBackends.cleanupRows }

    /// Models the Test sheet may pick: downloaded and usable.
    private var testableModels: [CleanupModelID] {
        rows.filter { $0.status.installState == .downloaded && $0.status.usability == .usable }.compactMap(\.modelID)
    }

    /// The selected model when testable, otherwise the first testable one.
    private var defaultTestModel: CleanupModelID? {
        let selected = rows.first { $0.status.isSelected }?.modelID
        if let selected, testableModels.contains(selected) { return selected }
        return testableModels.first
    }

    var body: some View {
        let tester = model.speechBackends.cleanupTester
        let testerBusy = tester?.phase.isRunning ?? false
        Section("Dictation Cleanup") {
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
            ForEach(rows) { item in
                CleanupModelRow(item: item, controller: model.speechBackends.models, testerBusy: testerBusy) { testModel = $0 }
            }
            if tester != nil {
                Button("Test Cleanup…") { testModel = defaultTestModel }
                    .disabled(defaultTestModel == nil)
            }
            if let message = model.speechBackends.models.messages[.dictationCleanup] {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
        .sheet(item: $testModel) { initial in
            if let tester {
                DictationCleanupTestSheet(tester: tester, models: testableModels, initialModel: initial)
            }
        }
    }
}
