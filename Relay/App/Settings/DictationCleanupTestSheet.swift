import SwiftUI

/// Tests one cleanup model. The row's Test button picks the model, so the sheet has no model picker.
struct DictationCleanupTestSheet: View {
    @Bindable var tester: DictationCleanupTester
    let model: CleanupModelID
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Test \(model.displayName)").font(.headline)
            TextEditor(text: $tester.input)
                .font(.body)
                .frame(minHeight: 80)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
            HStack {
                Button("Run Test") { tester.run(model: model) }
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
        .onDisappear { tester.sheetClosed() }
    }

    private static func format(_ duration: Duration) -> String {
        duration.formatted(.units(allowed: [.seconds, .milliseconds], width: .abbreviated))
    }
}
