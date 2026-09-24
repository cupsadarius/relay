import Foundation

/// The kinds of text the cleanup validator protects, in extraction priority order (spec §11.2):
/// an earlier kind claims its characters first, and a later match that overlaps a claimed range
/// is dropped. `spokenNumber` is added last by `SpokenNumberParser`, from unclaimed words only.
enum ProtectedLiteralKind: Int, CaseIterable, Comparable, Sendable {
    case code, quoted, url, path, flag, version, hex, number, identifier, spokenNumber

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Correction pairing only pairs literals of the same class.
    var kindClass: LiteralKindClass {
        switch self {
        case .number, .spokenNumber, .version: .numeric
        case .flag: .flag
        case .path: .path
        case .url: .url
        case .code, .quoted, .identifier, .hex: .symbol
        }
    }
}

enum LiteralKindClass: Equatable, Sendable {
    case numeric, flag, path, url, symbol
}

struct ProtectedLiteral: Equatable, Sendable {
    let kind: ProtectedLiteralKind
    /// Exact, case-sensitive comparison value, edge-trimmed. For `.spokenNumber`: the lowercased
    /// number words joined by single spaces ("twenty five").
    let value: String
    /// `.spokenNumber` only: the canonical digits ("25", "2.5").
    let canonicalDigits: String?
    let range: Range<String.Index>
}

enum ProtectedLiteralExtractor {
    private struct Rule {
        let kind: ProtectedLiteralKind
        let regex: NSRegularExpression
        let trimsEdges: Bool
        let accepts: @Sendable (String) -> Bool
    }

    private static let rules: [Rule] = [
        rule(.code, #"`[^`\n]+`"#, trims: false),
        rule(.quoted, #""[^"\n]+"|“[^”\n]+”|(?<!\S)'[^'\n]+'(?=$|[\s.,;:!?)])"#, trims: false),
        rule(.url, #"(?i)\b[a-z][a-z0-9+.\-]*://\S+|\bwww\.\S+"#),
        rule(.path, #"(?<!\S)\S*/\S*"#, accepts: { isPath($0) }),
        rule(.flag, #"(?<![\w-])--[A-Za-z0-9][\w-]*(?:=\S+)?|(?<!\S)-[A-Za-z]{1,3}(?![\w-])"#),
        rule(.version, #"(?<![\w.])v?\d+(?:\.\d+){1,3}(?:[-+][0-9A-Za-z.]+)?(?!\w)"#),
        rule(.hex, #"\b0x[0-9A-Fa-f]+\b|\b[0-9a-f]{7,40}\b"#, accepts: { isHex($0) }),
        // Sign, currency and magnitude are part of the literal: "-5" and "5" are different
        // numbers, and "5 million" is a different literal from "5 billion" (review fix 1).
        rule(.number, #"(?<![\w.])[-−+$€£]?\d+(?:[.,]\d+)*%?(?:\s+(?:hundred|thousand|million|billion|trillion|k|m|bn)\b)?(?!\w)"#),
        rule(.identifier, #"\b\w+(?:\.\w+)+\b|\b\w*_\w+\b|\b[A-Za-z0-9]*[a-z][A-Z]\w*\b|\b(?=\w*[A-Za-z])(?=\w*\d)\w+\b"#),
    ]

    private static let trailingPunctuation: Set<Character> = [".", ",", ";", ":", "!", "?", ")"]

    /// Every non-spoken literal in `text`, in text order. See `extractAll(from:)` for spoken numbers.
    static func extract(from text: String) -> [ProtectedLiteral] {
        var claimed: [Range<String.Index>] = []
        var literals: [ProtectedLiteral] = []
        let whole = NSRange(text.startIndex..., in: text)
        for rule in rules {
            for match in rule.regex.matches(in: text, range: whole) {
                guard let raw = Range(match.range, in: text) else { continue }
                let range = rule.trimsEdges ? trimmedRange(raw, in: text) : raw
                guard !range.isEmpty, !claimed.contains(where: { $0.overlaps(range) }) else { continue }
                let value = String(text[range])
                guard rule.accepts(value) else { continue }
                claimed.append(range)
                literals.append(ProtectedLiteral(kind: rule.kind, value: value, canonicalDigits: nil, range: range))
            }
        }
        return literals.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// `~/…`, `./…`, `../…`, `/…` with at least one segment, or any `/`-token with a segment
    /// containing `.` or `_` (so "and/or" and "TCP/IP" are not paths).
    static func isPath(_ token: String) -> Bool {
        for prefix in ["~/", "./", "../"] where token.hasPrefix(prefix) {
            return token.count > prefix.count
        }
        if token.hasPrefix("/") {
            return token.dropFirst().contains { $0 != "/" }
        }
        let segments = token.split(separator: "/")
        return segments.count >= 2 && segments.contains { $0.contains(".") || $0.contains("_") }
    }

    static func isHex(_ token: String) -> Bool {
        token.hasPrefix("0x") || (token.contains(where: \.isNumber) && token.contains(where: \.isLetter))
    }

    /// Strips leading `(` and trailing `. , ; : ! ? )`.
    static func trimmedRange(_ range: Range<String.Index>, in text: String) -> Range<String.Index> {
        var lower = range.lowerBound
        var upper = range.upperBound
        while lower < upper, text[lower] == "(" {
            lower = text.index(after: lower)
        }
        while lower < upper, trailingPunctuation.contains(text[text.index(before: upper)]) {
            upper = text.index(before: upper)
        }
        return lower..<upper
    }

    private static func rule(
        _ kind: ProtectedLiteralKind,
        _ pattern: String,
        trims: Bool = true,
        accepts: @escaping @Sendable (String) -> Bool = { _ in true }
    ) -> Rule {
        // The patterns are compile-time constants covered by tests; a bad one is a programmer error.
        Rule(kind: kind, regex: try! NSRegularExpression(pattern: pattern), trimsEdges: trims, accepts: accepts)
    }
}
