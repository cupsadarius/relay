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
