import Foundation

/// One spoken self-correction: `old` was replaced by `new` (indices into the analyzed literals).
struct CorrectionPair: Equatable, Sendable {
    let old: Int
    let new: Int
}

struct SelfCorrectionAnalysis: Equatable, Sendable {
    let pairs: [CorrectionPair]

    /// Every literal reachable from `index` along old → new edges, excluding `index` itself.
    /// Empty when `index` is not the `old` side of any pair.
    func chainTargets(from index: Int) -> [Int] {
        var reached: [Int] = []
        var frontier = [index]
        var visited: Set<Int> = [index]
        while let current = frontier.popLast() {
            for pair in pairs where pair.old == current && visited.insert(pair.new).inserted {
                reached.append(pair.new)
                frontier.append(pair.new)
            }
        }
        return reached
    }
}

/// Deterministic self-correction detection on the input only (spec §11.4). A cue pairs with the
/// nearest literal before it and the first literal after it, each within `window` word/literal
/// tokens, with no clause boundary in between, and only when both share a kind class.
enum SelfCorrectionDetector {
    /// Longest first. A token used by a longer cue is not reused.
    static let cues: [[String]] = [
        ["no", "wait"], ["scratch", "that"], ["or", "rather"], ["i", "mean"], ["no"], ["wait"], ["actually"], ["sorry"],
    ]
    static let window = 4

    private enum Token: Equatable {
        case literal(Int)
        case word(String)
        case soft
        case boundary
    }

    /// Single-word cues whose replacement must sit right after them, with no word tokens between
    /// (soft separators are still allowed) — review fix 4. Multi-word cues, and the "old" side of
    /// every cue, keep the ordinary `window`-word search.
    static let cuesRequiringAnImmediateReplacement: Set<String> = ["no", "wait", "sorry"]

    static func analyze(_ text: String, literals: [ProtectedLiteral]) -> SelfCorrectionAnalysis {
        let tokens = tokenize(text, literals: literals)
        var used = Set<Int>()
        var pairs: [CorrectionPair] = []
        for cue in cues {
            let requiresImmediateNew = cue.count == 1 && cuesRequiringAnImmediateReplacement.contains(cue[0])
            var index = 0
            while index < tokens.count {
                guard let end = match(cue, at: index, in: tokens, used: used) else {
                    index += 1
                    continue
                }
                used.formUnion(index...end)
                if let old = nearestLiteral(in: tokens, from: index - 1, step: -1),
                    let new = nearestLiteral(in: tokens, from: end + 1, step: 1, immediate: requiresImmediateNew),
                    literals[old].kind.kindClass == literals[new].kind.kindClass
                {
                    pairs.append(CorrectionPair(old: old, new: new))
                }
                index = end + 1
            }
        }
        return SelfCorrectionAnalysis(pairs: pairs)
    }

    /// Count and time words: a new value followed by one of these reads as a count ("no 2 people
    /// agree", "wait 10 seconds"), not a correction.
    static let countAndTimeWords: Set<String> = [
        "second", "seconds", "sec", "secs", "minute", "minutes", "min", "mins", "hour", "hours", "day", "days", "week", "weeks",
        "month", "months", "year", "years", "ms", "millisecond", "milliseconds", "time", "times", "people", "person", "persons",
        "item", "items", "user", "users", "thing", "things", "one", "ones", "more", "less", "fewer", "other", "others", "of", "left",
    ]

    /// The pairs that may exempt a missing old value (spec §11.4). A multi-word cue ("no wait",
    /// "scratch that", "or rather", "I mean") keeps every detected pair. A single-word cue ("no",
    /// "wait", "actually", "sorry") keeps a pair only when the text between the values is exactly
    /// ` cue ` or `, cue, ` (or ` words cue ` where the new value repeats those words: "4 threads
    /// actually 8 threads"), the new value is not followed by a count or time word, and the cue is
    /// not "no" before a one.
    static func exemptingPairs(of analysis: SelfCorrectionAnalysis, literals: [ProtectedLiteral], in text: String) -> SelfCorrectionAnalysis {
        SelfCorrectionAnalysis(pairs: analysis.pairs.filter { isUnambiguous($0, literals: literals, in: text) })
    }

    /// The last word between a pair's two values: the cue that formed the pair.
    static func cueWord(of pair: CorrectionPair, literals: [ProtectedLiteral], in text: String) -> String? {
        let old = literals[pair.old]
        let new = literals[pair.new]
        guard old.range.upperBound <= new.range.lowerBound else { return nil }
        return text[old.range.upperBound..<new.range.lowerBound].lowercased()
            .split(whereSeparator: { $0.isWhitespace || ",;".contains($0) }).last.map(String.init)
    }

    private static func isUnambiguous(_ pair: CorrectionPair, literals: [ProtectedLiteral], in text: String) -> Bool {
        let old = literals[pair.old]
        let new = literals[pair.new]
        guard old.range.upperBound <= new.range.lowerBound else { return false }
        let between = text[old.range.upperBound..<new.range.lowerBound].lowercased()
        let words = between.split(whereSeparator: { $0.isWhitespace || ",;".contains($0) }).map(String.init)
        if cues.contains(where: { $0.count > 1 && words.count >= $0.count && Array(words.suffix($0.count)) == $0 }) { return true }

        guard let cue = words.last, cues.contains([cue]) else { return false }
        let repeated = Array(words.dropLast())
        let after = text[new.range.upperBound...]
        if repeated.isEmpty {
            guard between == " \(cue) " || between == ", \(cue), " else { return false }
            let gap = after.prefix { $0 == " " }
            let next = after[gap.endIndex...].prefix { $0.isLetter || $0.isNumber }.lowercased()
            if !gap.isEmpty, countAndTimeWords.contains(next) { return false }
        } else {
            // " words cue " with plain spaces, and the same words right after the new value.
            guard between == " " + (repeated + [cue]).joined(separator: " ") + " " else { return false }
            let following = after.lowercased().split(whereSeparator: { $0.isWhitespace || ",;.!?".contains($0) })
                .prefix(repeated.count).map(String.init)
            guard following == repeated else { return false }
        }
        if cue == "no", new.canonicalDigits == "1" || new.value == "1" || new.value.lowercased() == "one" { return false }
        return true
    }

    /// Protected literals are atomic tokens. `,`/`;` are soft separators; `.`/`!`/`?` are clause
    /// boundaries. Word tokens are lowercased.
    private static func tokenize(_ text: String, literals: [ProtectedLiteral]) -> [Token] {
        var tokens: [Token] = []
        var word = ""
        var literalIndex = 0
        var position = text.startIndex
        func flushWord() {
            if !word.isEmpty {
                tokens.append(.word(word.lowercased()))
                word = ""
            }
        }
        while position < text.endIndex {
            while literalIndex < literals.count, literals[literalIndex].range.lowerBound < position {
                literalIndex += 1
            }
            if literalIndex < literals.count, literals[literalIndex].range.lowerBound == position {
                flushWord()
                tokens.append(.literal(literalIndex))
                position = literals[literalIndex].range.upperBound
                literalIndex += 1
                continue
            }
            let character = text[position]
            if character.isLetter || character.isNumber || "'’_-".contains(character) {
                word.append(character)
            } else {
                flushWord()
                if ",;".contains(character) {
                    tokens.append(.soft)
                } else if ".!?".contains(character) {
                    tokens.append(.boundary)
                }
            }
            position = text.index(after: position)
        }
        flushWord()
        return tokens
    }

    /// The index of the cue's last word when `cue` starts at `start`, skipping soft separators
    /// between its words ("no, wait"). `nil` if it does not match or touches a used token.
    private static func match(_ cue: [String], at start: Int, in tokens: [Token], used: Set<Int>) -> Int? {
        var index = start
        for (position, word) in cue.enumerated() {
            if position > 0 {
                index += 1
                while index < tokens.count, tokens[index] == .soft {
                    index += 1
                }
            }
            guard index < tokens.count, !used.contains(index), tokens[index] == .word(word) else { return nil }
        }
        return index
    }

    /// Walks from `start` in `step` direction. Word and literal tokens count toward `window` (up to
    /// `window` words are allowed — review fix 4's off-by-one); soft separators do not; a clause
    /// boundary stops the search. `immediate` (review fix 4) requires the literal right away, with
    /// no word tokens at all in between — only soft separators may still be skipped.
    private static func nearestLiteral(in tokens: [Token], from start: Int, step: Int, immediate: Bool = false) -> Int? {
        var index = start
        var counted = 0
        while index >= 0, index < tokens.count {
            switch tokens[index] {
            case .boundary:
                return nil
            case .soft:
                break
            case .word:
                if immediate { return nil }
                counted += 1
                if counted > window { return nil }
            case let .literal(literalIndex):
                return literalIndex
            }
            index += step
        }
        return nil
    }
}
