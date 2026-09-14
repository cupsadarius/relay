import Foundation

struct RulesSpeechPreprocessor {
    private let codeBlockCue = "There is a code block on screen. Please read it there."

    func prepare(text: String, mode: SpeechMode) -> String {
        var prepared = replacingMatches(
            in: text,
            pattern: #"(?s)```.*?```"#,
            with: codeBlockCue
        )

        prepared = replacingMatches(
            in: prepared,
            pattern: #"\[([^\]]+)\]\([^\)]+\)"#,
            with: "$1"
        )
        prepared = replacingMatches(
            in: prepared,
            pattern: #"(?m)^[ \t]{0,3}#{1,6}[ \t]+"#,
            with: ""
        )
        prepared = replacingMatches(
            in: prepared,
            pattern: #"(?m)^[ \t]*>[ \t]?"#,
            with: ""
        )
        prepared = replacingMatches(
            in: prepared,
            pattern: #"(?m)^[ \t]*[-*+][ \t]+(.+?)[ \t]*$"#,
            with: "$1."
        )
        prepared = replacingMatches(
            in: prepared,
            pattern: #"(\*\*|__)(.+?)\1"#,
            with: "$2"
        )
        prepared = replacingMatches(
            in: prepared,
            pattern: #"(\*|_)(.+?)\1"#,
            with: "$2"
        )
        prepared = prepared.replacingOccurrences(of: "`", with: "")
        prepared = replacingMatches(in: prepared, pattern: #"\s+"#, with: " ")

        return prepared.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func replacingMatches(
        in text: String,
        pattern: String,
        with replacement: String
    ) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return expression.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: replacement
        )
    }
}
