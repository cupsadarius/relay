import Foundation

struct RulesSpeechPreprocessor {
    private let codeBlockCue = "There is a code block on screen. Please read it there."

    /// Markdown-to-speech rewrite rules, compiled once. Order matters: each rule runs on the
    /// output of the previous one. The patterns are constants covered by
    /// `RulesSpeechPreprocessorTests`, so a compile failure is a programmer error.
    private static let rules: [(expression: NSRegularExpression, template: String)] = [
        (#"\[([^\]]+)\]\([^\)]+\)"#, "$1"),
        (#"(?m)^[ \t]{0,3}#{1,6}[ \t]+"#, ""),
        (#"(?m)[ \t]+#+[ \t]*$"#, ""),
        (#"(?m)^[ \t]{0,3}(?:=+|-+)[ \t]*$"#, ""),
        (#"(?m)^[ \t]*(?:>[ \t]*)+"#, ""),
        (#"(?m)^[ \t]*[-*+][ \t]+(.+?)[ \t]*$"#, "$1."),
        (#"(\*\*|__)(.+?)\1"#, "$2"),
        (#"(\*|_)(.+?)\1"#, "$2"),
    ].map { pattern, template in
        (try! NSRegularExpression(pattern: pattern), template)
    }

    private static let whitespace = try! NSRegularExpression(pattern: #"\s+"#)

    func prepare(text: String, mode: SpeechMode) -> String {
        var prepared = replacingFencedCode(in: text)
        for rule in Self.rules {
            prepared = Self.replacingMatches(in: prepared, using: rule.expression, with: rule.template)
        }
        prepared = prepared.replacingOccurrences(of: "`", with: "")
        prepared = Self.replacingMatches(in: prepared, using: Self.whitespace, with: " ")
        return prepared.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replacingMatches(
        in text: String,
        using expression: NSRegularExpression,
        with template: String
    ) -> String {
        expression.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: template
        )
    }

    private func replacingFencedCode(in text: String) -> String {
        var result: [Substring] = []
        var openFence: Fence?

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let fence = openFence {
                if isClosingFence(line, for: fence) {
                    openFence = nil
                }
                continue
            }

            if let fence = openingFence(in: line) {
                result.append(Substring(codeBlockCue))
                openFence = fence
            } else {
                result.append(line)
            }
        }

        return result.joined(separator: "\n")
    }

    private func openingFence(in line: Substring) -> Fence? {
        guard let content = markdownIndentedContent(line),
              let marker = content.first,
              marker == "`" || marker == "~"
        else {
            return nil
        }

        let length = content.prefix(while: { $0 == marker }).count
        guard length >= 3 else { return nil }

        let suffix = content.dropFirst(length)
        guard marker != "`" || !suffix.contains("`") else { return nil }
        return Fence(marker: marker, length: length)
    }

    private func isClosingFence(_ line: Substring, for fence: Fence) -> Bool {
        guard let content = markdownIndentedContent(line) else { return false }
        let markerLength = content.prefix(while: { $0 == fence.marker }).count
        guard markerLength >= fence.length else { return false }
        return content.dropFirst(markerLength).allSatisfy(\.isWhitespace)
    }

    private func markdownIndentedContent(_ line: Substring) -> Substring? {
        let indentation = line.prefix(while: { $0 == " " }).count
        guard indentation <= 3 else { return nil }
        return line.dropFirst(indentation)
    }
}

private struct Fence {
    let marker: Character
    let length: Int
}
