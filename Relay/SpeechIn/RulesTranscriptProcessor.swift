import Foundation

struct RulesTranscriptProcessor {
    func process(_ transcript: String) -> String {
        let withoutExcessBlankLines = transcript.replacingOccurrences(
            of: #"\n(?:[ \t]*\n){3,}"#,
            with: "\n",
            options: .regularExpression
        )
        let collapsedSpaces = withoutExcessBlankLines.replacingOccurrences(
            of: #" {2,}"#,
            with: " ",
            options: .regularExpression
        )
        return collapsedSpaces.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
