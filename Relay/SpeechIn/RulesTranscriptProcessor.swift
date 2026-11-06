import Foundation

struct RulesTranscriptProcessor {
    func process(_ transcript: String) -> String {
        let withoutExcessBlankLines = FillerWords.remove(from: transcript).replacingOccurrences(
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

/// Drops hesitations a model writes verbatim, with the comma or ellipsis that comes with them.
/// Only lowercase or first-letter-capitalised whole words match, so "umbrella", "uh-huh", "ER" stay.
// Port of anomalyco/hex src/dictation/filler_words.rs (MIT).
enum FillerWords {
    private static let fillers: [[Character]] = ["um", "umm", "uh", "uhh", "erm", "er", "ah"].map(Array.init)

    static func remove(from transcript: String) -> String {
        let chars = Array(transcript)
        var out: [Character] = []
        var removed = false
        var capitalize = false
        var index = 0
        while index < chars.count {
            if let end = fillerEnd(chars, at: index) {
                trimEnd(&out)
                if !removed {
                    capitalize = chars[index].isUppercase && sentenceStart(out)
                }
                index = afterFiller(chars, end)
                removed = true
                continue
            }
            let c = chars[index]
            index += 1
            if removed {
                if isSpace(c) { continue }
                if c.isNewline {
                    removed = false
                    capitalize = false
                    out.append(c)
                    continue
                }
                if ".!?,".contains(c) && sentenceStart(out) { continue }
                removed = false
                let closing =
                    ".,;:!?)]}”’…".contains(c)
                    || (c == "\"" && (index == chars.count || !isAlphanumeric(chars[index])))
                if closing {
                    trimEnd(&out, also: ",")
                    capitalize = false
                } else {
                    if needsSpace(out) { out.append(" ") }
                    if capitalize {
                        capitalize = false
                        out.append(contentsOf: c.uppercased())
                        continue
                    }
                }
            }
            out.append(c)
        }
        if removed { trimEnd(&out, also: ",") }
        return String(out)
    }

    private static func fillerEnd(_ chars: [Character], at start: Int) -> Int? {
        if start > 0 && joinsWord(chars[start - 1]) { return nil }
        for word in fillers {
            let end = start + word.count
            guard end <= chars.count else { continue }
            let matches = zip(chars[start..<end], word).enumerated().allSatisfy { offset, pair in
                pair.0 == pair.1 || (offset == 0 && String(pair.0) == pair.1.uppercased())
            }
            if matches && (end == chars.count || !joinsWord(chars[end])) { return end }
        }
        return nil
    }

    private static func afterFiller(_ chars: [Character], _ end: Int) -> Int {
        var index = skipSpaces(chars, end)
        if index < chars.count {
            if chars[index] == "," || chars[index] == "…" {
                index += 1
            } else if chars[index] == ".", index + 2 < chars.count,
                chars[index + 1] == ".", chars[index + 2] == "."
            {
                index += 3
            }
        }
        return skipSpaces(chars, index)
    }

    private static func isAlphanumeric(_ c: Character) -> Bool { c.isLetter || c.isNumber }
    private static func joinsWord(_ c: Character) -> Bool { isAlphanumeric(c) || "-'’".contains(c) }
    private static func isSpace(_ c: Character) -> Bool { c.isWhitespace && !c.isNewline }

    private static func skipSpaces(_ chars: [Character], _ start: Int) -> Int {
        var index = start
        while index < chars.count && isSpace(chars[index]) { index += 1 }
        return index
    }

    private static func trimEnd(_ out: inout [Character], also extra: Character? = nil) {
        while let last = out.last, isSpace(last) || last == extra { out.removeLast() }
    }

    private static func sentenceStart(_ out: [Character]) -> Bool {
        guard let last = out.last else { return true }
        return ".!?".contains(last) || last.isNewline
    }

    private static func needsSpace(_ out: [Character]) -> Bool {
        guard let last = out.last else { return false }
        if last.isNewline || "([{“‘".contains(last) { return false }
        if last == "\"" {
            return out.count >= 2 && !out[out.count - 2].isWhitespace
        }
        return true
    }
}
