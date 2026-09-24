import Foundation

/// One maximal run of English number words (spec §11.3).
struct SpokenNumber: Equatable, Sendable {
    /// Lowercased words as spoken, hyphen compounds split ("twenty-five" → ["twenty", "five"]).
    let words: [String]
    /// Canonical digits: "3", "25", "105", "2.5".
    let canonicalDigits: String
    let range: Range<String.Index>
}

/// Reads number words (0 to 999,999, plus "X point Y…") into canonical digits. Runs end at any
/// punctuation between words; a unit right after a unit starts a new run ("one two" → 1, 2).
enum SpokenNumberParser {
    private enum Category: Equatable {
        case zero, unit, teen, tens, hundred, thousand, million, billion, dozen, and, point
    }

    /// Magnitude words: an explicit "a"/"an" before one, or none at all (a bare magnitude word),
    /// both mean "one" (review fix 1: "a hundred" = 100, "a thousand" = 1000, and a standalone
    /// "hundred"/"thousand"/"million"/"billion"/"dozen" is still a protected literal).
    private static let magnitudeCategories: Set<Category> = [.hundred, .thousand, .million, .billion, .dozen]

    private struct Word {
        let text: String
        let range: Range<String.Index>
    }

    private static let values: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    private static let wordRegex = try! NSRegularExpression(pattern: #"[A-Za-z]+(?:-[A-Za-z]+)*"#)
    private static let letterRegex = try! NSRegularExpression(pattern: #"[A-Za-z]+"#)

    static func parse(_ text: String, excluding claimed: [Range<String.Index>] = []) -> [SpokenNumber] {
        let tokens = words(in: text, excluding: claimed)
        var results: [SpokenNumber] = []
        var index = 0
        while index < tokens.count {
            if let run = parseRun(tokens, from: index, in: text) {
                results.append(run.number)
                index = run.next
            } else {
                index += 1
            }
        }
        return results
    }

    /// Lowercased letter-only words of `text` (hyphen compounds split), for "words present" checks.
    static func wordSequence(of text: String) -> [String] {
        letterRegex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text).map { text[$0].lowercased() } }
    }

    /// Whether `needle` appears as a contiguous subsequence of `sequence`.
    static func contains(_ needle: [String], in sequence: [String]) -> Bool {
        guard !needle.isEmpty, needle.count <= sequence.count else { return false }
        return (0...(sequence.count - needle.count)).contains { Array(sequence[$0..<($0 + needle.count)]) == needle }
    }

    private static func category(of word: String) -> Category? {
        switch word {
        case "zero": return .zero
        case "hundred": return .hundred
        case "thousand": return .thousand
        case "million": return .million
        case "billion": return .billion
        case "dozen": return .dozen
        case "and": return .and
        case "point": return .point
        default:
            guard let value = values[word] else { return nil }
            return value < 10 ? .unit : (value < 20 ? .teen : .tens)
        }
    }

    /// Word tokens outside `claimed`. A hyphenated token counts as number words only in
    /// tens-unit form ("twenty-five"); any other hyphenated token is one non-number word.
    private static func words(in text: String, excluding claimed: [Range<String.Index>]) -> [Word] {
        var result: [Word] = []
        for match in wordRegex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text), !claimed.contains(where: { $0.overlaps(range) }) else { continue }
            let token = text[range].lowercased()
            let parts = token.split(separator: "-").map(String.init)
            if parts.count == 2, category(of: parts[0]) == .tens, category(of: parts[1]) == .unit {
                let firstEnd = text.index(range.lowerBound, offsetBy: parts[0].count)
                result.append(Word(text: parts[0], range: range.lowerBound..<firstEnd))
                result.append(Word(text: parts[1], range: text.index(after: firstEnd)..<range.upperBound))
            } else {
                result.append(Word(text: token, range: range))
            }
        }
        return result
    }

    private static func adjacent(_ first: Word, _ second: Word, in text: String) -> Bool {
        let gap = text[first.range.upperBound..<second.range.lowerBound]
        return gap == "-" || (!gap.isEmpty && gap.allSatisfy(\.isWhitespace))
    }

    private static func nextCategory(after index: Int, in tokens: [Word], text: String) -> Category? {
        let next = index + 1
        guard next < tokens.count, adjacent(tokens[index], tokens[next], in: text) else { return nil }
        return category(of: tokens[next].text)
    }

    private static func parseRun(_ tokens: [Word], from start: Int, in text: String) -> (number: SpokenNumber, next: Int)? {
        var total = 0
        var current = 0
        var last: Category?
        var consumed: [String] = []
        var decimals = ""
        var index = start
        while index < tokens.count {
            if index > start, !adjacent(tokens[index - 1], tokens[index], in: text) { break }
            let word = tokens[index].text
            let category: Category
            var unitOverride: Int?
            // "a"/"an" right before a magnitude word means "one" ("a hundred" = 100); it is not a
            // number word on its own (review fix 1).
            if word == "a" || word == "an", let following = nextCategory(after: index, in: tokens, text: text),
                magnitudeCategories.contains(following)
            {
                category = .unit
                unitOverride = 1
            } else if let resolved = Self.category(of: word) {
                category = resolved
            } else {
                break
            }
            let next = nextCategory(after: index, in: tokens, text: text)
            let accepted: Bool
            switch category {
            case .zero:
                accepted = last == nil
            case .unit:
                accepted =
                    last == nil || last == .tens || last == .hundred || last == .thousand || last == .million || last == .billion
                    || last == .and
            case .teen, .tens:
                accepted = last == nil || last == .hundred || last == .thousand || last == .million || last == .billion || last == .and
            case .hundred:
                accepted = last == nil || (last == .unit && (1...9).contains(current))
            case .dozen:
                accepted = last == nil || (last == .unit && (1...99).contains(current))
            case .thousand, .million, .billion:
                accepted = total == 0 && (last == nil || (current > 0 && [.unit, .teen, .tens, .hundred].contains(last!)))
            case .and:
                accepted = (last == .hundred || last == .thousand) && (next.map { [.unit, .teen, .tens].contains($0) } ?? false)
            case .point:
                accepted = last != nil && last != .and && (next == .unit || next == .zero)
            }
            guard accepted else { break }
            consumed.append(word)
            index += 1
            switch category {
            case .zero, .and:
                break
            case .unit, .teen, .tens:
                current += unitOverride ?? values[word] ?? 0
            case .hundred:
                current = (last == nil ? 1 : current) * 100
            case .dozen:
                current = (last == nil ? 1 : current) * 12
            case .thousand:
                total = (last == nil ? 1 : current) * 1_000
                current = 0
            case .million:
                total = (last == nil ? 1 : current) * 1_000_000
                current = 0
            case .billion:
                total = (last == nil ? 1 : current) * 1_000_000_000
                current = 0
            case .point:
                while index < tokens.count, adjacent(tokens[index - 1], tokens[index], in: text),
                    let digit = Self.category(of: tokens[index].text), digit == .unit || digit == .zero
                {
                    decimals += String(values[tokens[index].text] ?? 0)
                    consumed.append(tokens[index].text)
                    index += 1
                }
            }
            last = category
            if category == .point { break }
        }
        guard !consumed.isEmpty else { return nil }
        let digits = String(total + current) + (decimals.isEmpty ? "" : "." + decimals)
        let range = tokens[start].range.lowerBound..<tokens[index - 1].range.upperBound
        return (SpokenNumber(words: consumed, canonicalDigits: digits, range: range), index)
    }
}

extension ProtectedLiteralExtractor {
    /// Every literal including spoken numbers (read from words no other literal claimed), in text order.
    static func extractAll(from text: String) -> [ProtectedLiteral] {
        let literals = extract(from: text)
        let spoken = SpokenNumberParser.parse(text, excluding: literals.map(\.range)).map {
            ProtectedLiteral(
                kind: .spokenNumber,
                value: $0.words.joined(separator: " "),
                canonicalDigits: $0.canonicalDigits,
                range: $0.range
            )
        }
        return (literals + spoken).sorted { $0.range.lowerBound < $1.range.lowerBound }
    }
}
