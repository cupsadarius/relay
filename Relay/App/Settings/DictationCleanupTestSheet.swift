import SwiftUI

struct DictationCleanupTestSheet: View {
    @Bindable var tester: DictationCleanupTester
    let models: [CleanupModelID]
    @State private var selected: CleanupModelID
    @Environment(\.dismiss) private var dismiss

    init(tester: DictationCleanupTester, models: [CleanupModelID], initialModel: CleanupModelID) {
        self.tester = tester
        self.models = models
        _selected = State(initialValue: initialModel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Test Dictation Cleanup").font(.headline)
            Picker("Model", selection: $selected) {
                ForEach(models) { Text($0.displayName).tag($0) }
            }
            TextEditor(text: $tester.input)
                .font(.body)
                .frame(minHeight: 80)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
            HStack {
                Button("Run Test") { tester.run(model: selected) }
                    .disabled(tester.phase.isRunning || tester.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
                if tester.phase.isRunning { ProgressView().controlSize(.small) }
                Text(tester.phase.title).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
            }
            if case let .finished(report) = tester.phase {
                Form {
                    LabeledContent("Raw output") { Text(report.rawOutput).textSelection(.enabled) }
                    LabeledContent("Verdict") { Text(report.verdict) }
                    LabeledContent("Would insert") { Text(report.wouldInsert).textSelection(.enabled) }
                    if let loadTime = report.loadTime {
                        LabeledContent("Load time") { Text(Self.format(loadTime)) }
                    }
                    LabeledContent("Generation time") { Text(Self.format(report.generationTime)) }
                }
                .formStyle(.grouped)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 360)
    }

    private static func format(_ duration: Duration) -> String {
        duration.formatted(.units(allowed: [.seconds, .milliseconds], width: .abbreviated))
    }
}
