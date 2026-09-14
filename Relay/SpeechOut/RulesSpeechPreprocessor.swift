import Foundation

struct RulesSpeechPreprocessor {
    private let codeBlockCue = "There is a code block on screen. Please read it there."

    func prepare(text: String, mode: SpeechMode) -> String {
        var prepared = replacingFencedCode(in: text)

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
            pattern: #"(?m)[ \t]+#+[ \t]*$"#,
            with: ""
        )
        prepared = replacingMatches(
            in: prepared,
            pattern: #"(?m)^[ \t]{0,3}(?:=+|-+)[ \t]*$"#,
            with: ""
        )
        prepared = replacingMatches(
            in: prepared,
            pattern: #"(?m)^[ \t]*(?:>[ \t]*)+"#,
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

private struct Fence {
    let marker: Character
    let length: Int
}
