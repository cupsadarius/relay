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

    func prepare(text: String) -> String {
        var prepared = Self.replacingTables(in: replacingFencedCode(in: text))
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

    private static let cellSeparators: Set<Character> = ["│", "┃", "|"]
    private static let tableJunctions: Set<Character> = cellSeparators.union("┌┐└┘├┤┬┴┼╭╮╯╰┏┓┗┛┣┫┳┻╋+")
    private static let ruleCharacters: Set<Character> = tableJunctions.union("─━═-=: \t")

    private static let maxSpokenTableRows = 15
    private static let maxSpokenTableColumns = 5

    /// Box-drawn rows (`│`) can wrap over several lines, so their fragments merge until the
    /// next rule line; pipe rows are one line each. A table ends at the first non-table line.
    private static func replacingTables(in text: String) -> String {
        var result: [String] = []
        var rows: [[String]] = []
        var row: [[String]] = []

        func endRow() {
            let cells = row.map { $0.filter { !$0.isEmpty }.joined(separator: " ") }
            if cells.contains(where: { !$0.isEmpty }) { rows.append(cells) }
            row = []
        }

        func endTable() {
            endRow()
            if !rows.isEmpty { result.append(spokenTable(rows)) }
            rows = []
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, trimmed.allSatisfy(ruleCharacters.contains),
                trimmed.contains(where: tableJunctions.contains)
            {
                endRow()
                continue
            }
            guard let first = trimmed.first, cellSeparators.contains(first) else {
                endTable()
                result.append(String(line))
                continue
            }
            let cells = trimmed.split(separator: first, omittingEmptySubsequences: false)
                .dropFirst().dropLast(trimmed.count > 1 && trimmed.last == first ? 1 : 0)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            for (index, cell) in cells.enumerated() {
                if index < row.count { row[index].append(cell) } else { row.append([cell]) }
            }
            if first == "|" { endRow() }
        }
        endTable()
        return result.joined(separator: "\n")
    }

    /// `rows[0]` is the header. Each body row is labelled by its first cell; other cells are
    /// prefixed with their column name unless the table has only two columns.
    private static func spokenTable(_ rows: [[String]]) -> String {
        let header = rows[0]
        let body = rows.dropFirst()
        guard !body.isEmpty else {
            return header.filter { !$0.isEmpty }.map(sentence).joined(separator: " ")
        }

        let rowCount = body.count == 1 ? "1 row" : "\(body.count) rows"
        guard body.count <= maxSpokenTableRows, header.count <= maxSpokenTableColumns else {
            return "There is a table on screen with \(rowCount). Please read it there."
        }

        let intro =
            header.count == 2
            ? "Table with \(rowCount), by \(header[0]) and \(header[1])."
            : "Table with \(rowCount). Columns: \(header.joined(separator: ", "))."
        let spokenRows = body.map { cells in
            let label = cells[0].isEmpty ? [] : [cells[0] + ":"]
            let values = cells.indices.dropFirst().filter { !cells[$0].isEmpty }.map { index in
                header.count == 2 || index >= header.count
                    ? sentence(cells[index]) : "\(header[index]) \(sentence(cells[index]))"
            }
            return (label + values).joined(separator: " ")
        }
        return ([intro] + spokenRows + ["End of table."]).joined(separator: "\n")
    }

    private static func sentence(_ text: String) -> String {
        ".!?:;".contains(text.last ?? ".") ? text : text + "."
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
