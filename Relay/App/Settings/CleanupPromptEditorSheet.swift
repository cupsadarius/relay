import SwiftUI

/// Edits the cleanup prompt (spec §10 addendum, §16): the instructions and demonstration examples
/// `TranscriptCleanupService` and `DictationCleanupTester` send to every backend. Edits a draft
/// copy; nothing is written to `AppSettings` until Save. Follows `DictationCleanupTestSheet`'s look.
struct CleanupPromptEditorSheet: View {
    let controller: SettingsController
    @Environment(\.dismiss) private var dismiss
    @State private var draft: CleanupPromptOverride

    init(controller: SettingsController) {
        self.controller = controller
        let current = controller.current.cleanupPromptOverride
        _draft = State(initialValue: current ?? CleanupPromptOverride(instructions: CleanupPrompt.instructions, examples: CleanupPrompt.examples))
    }

    /// Recomputed on every edit, so the error/warning text and the Save button track the draft
    /// live rather than only at Save time.
    private var validation: CleanupPromptValidationResult { CleanupPrompt.validate(draft) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cleanup Prompt").font(.headline)

            Text("Instructions").font(.subheadline)
            TextEditor(text: $draft.instructions)
                .font(.body)
                .frame(minHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))

            HStack {
                Text("Examples").font(.subheadline)
                Spacer()
                Button("Add") { draft.examples.append(CleanupExample(input: "", output: "")) }
                    .controlSize(.small)
                    .disabled(draft.examples.count >= CleanupPrompt.maxExamples)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(draft.examples.enumerated()), id: \.offset) { index, _ in
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 4) {
                                TextField("Input", text: $draft.examples[index].input)
                                TextField("Output", text: $draft.examples[index].output)
                            }
                            Button("Remove", role: .destructive) { draft.examples.remove(at: index) }
                                .controlSize(.small)
                        }
                    }
                }
            }
            .frame(minHeight: 160)

            // Structural problems block Save (spec §10 addendum) and show inline here. An example
            // that would fail the safety validator is a warning only, shown alongside but never
            // disabling Save.
            if let firstError = validation.errors.first {
                Text(firstError.message).foregroundStyle(.red).font(.caption)
            }
            if validation.errors.isEmpty, !validation.warningExampleIndices.isEmpty {
                Text("Example \(warningList) would not pass the safety check, but will still be saved.")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }

            HStack {
                Button("Reset to Default") {
                    controller.setCleanupPromptOverride(nil)
                    dismiss()
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    controller.setCleanupPromptOverride(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!validation.isValid)
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 480)
    }

    private var warningList: String {
        validation.warningExampleIndices.map { "#\($0 + 1)" }.joined(separator: ", ")
    }
}
