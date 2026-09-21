import SwiftUI

struct SpeechVoiceRowPresentation: Equatable {
    let isActive: Bool
    let selectTitle = "Select"
    let testTitle = "Test"
    var canSelect: Bool { !isActive }
    let canTest = true
}

struct SpeechVoiceRow: View {
    let voice: SpeechVoiceOption
    let isActive: Bool
    let select: () -> Void
    let test: () -> Void

    var body: some View {
        let presentation = SpeechVoiceRowPresentation(isActive: isActive)
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(voice.displayName)
                if let detail = voice.detail { Text(detail).font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer()
            Text(isActive ? "● Active" : "").font(.caption).foregroundStyle(.green)
                .frame(minWidth: 70, alignment: .trailing)
            Button(presentation.selectTitle, action: select).disabled(!presentation.canSelect)
            Button(presentation.testTitle, action: test).disabled(!presentation.canTest)
        }
        .controlSize(.small)
        .padding(.leading, 20)
    }
}
