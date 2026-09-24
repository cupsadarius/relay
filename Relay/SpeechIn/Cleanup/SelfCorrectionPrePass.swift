import Foundation

/// One phrase-level rewrite: `old` ("user service") was replaced by `new` ("auth service").
/// Both are lowercased words joined by single spaces.
struct PhraseRewrite: Equatable, Sendable {
    let old: String
    let new: String
}

/// The text the cleanup model receives after the pre-pass, the comparison keys
/// (`canonicalDigits ?? value`) of the old values it removed, and its phrase rewrites.
struct PrePassedText: Equatable, Sendable {
    let text: String
    let replaced: [String]
    var phrases: [PhraseRewrite] = []
}

/// Deterministic self-correction pre-pass (spec §10.1). Applies a literal pair that
/// `SelfCorrectionDetector` finds before the model runs: "port three no four" → "port four".
///
/// Much stricter than the detector, because the validator judges the model against the rewritten
/// text and so cannot catch a wrong rewrite. A pair is rewritten only when all of these hold:
/// - the text between the two values is exactly ` cue ` (no punctuation) or `, cue, `;
/// - the cue is one of `prePassCues` (never bare "wait" or bare "actually");
/// - the replacement is not followed by a unit or count word ("no 2 people agree");
/// - the cue is not "no" before a one ("no one came", "no 1 came");
/// - no literal belongs to two pairs (a chain leaves the whole text unchanged).
/// Anything else is left for the model.
enum SelfCorrectionPrePass {
    static let prePassCues: [[String]] = [["no", "wait"], ["scratch", "that"], ["or", "rather"], ["i", "mean"], ["no"], ["sorry"]]

    /// A replacement followed by one of these reads as a count or a measure, not a correction.
    static let unitWords: Set<String> = [
        "second", "seconds", "sec", "secs", "minute", "minutes", "min", "mins", "hour", "hours", "day", "days", "week", "weeks",
        "month", "months", "year", "years", "ms", "millisecond", "milliseconds", "time", "times", "people", "person", "persons",
        "item", "items", "user", "users", "thing", "things", "one", "ones", "more", "less", "fewer", "other", "others", "of",
        "byte", "bytes", "kb", "mb", "gb", "tb", "kilobytes", "megabytes", "gigabytes", "terabytes", "percent", "thread",
        "threads", "worker", "workers", "step", "steps", "left",
    ]

    /// Literal corrections first, then phrase corrections on the result.
    static func apply(to text: String) -> PrePassedText {
        let literal = applyLiteralCorrections(to: text)
        let phrase = PhraseCorrection.apply(to: literal.text)
        return PrePassedText(text: phrase.text, replaced: literal.replaced, phrases: phrase.phrases)
    }

    private static func applyLiteralCorrections(to text: String) -> PrePassedText {
        let unchanged = PrePassedText(text: text, replaced: [])
        let literals = ProtectedLiteralExtractor.extractAll(from: text)
        let pairs = SelfCorrectionDetector.analyze(text, literals: literals).pairs
        guard !pairs.isEmpty else { return unchanged }
        let endpoints = pairs.flatMap { [$0.old, $0.new] }
        guard Set(endpoints).count == endpoints.count else { return unchanged } // chained

        let removals = pairs.sorted { $0.old < $1.old }.compactMap { pair -> (range: Range<String.Index>, key: String)? in
            let old = literals[pair.old]
            let new = literals[pair.new]
            guard isRewritable(old: old, new: new, in: text) else { return nil }
            return (old.range.lowerBound..<new.range.lowerBound, old.canonicalDigits ?? old.value)
        }
        guard !removals.isEmpty else { return unchanged }

        // Rebuild from the kept segments of the original text; never index a mutated string.
        var result = ""
        var kept = text.startIndex
        for removal in removals {
            result += text[kept..<removal.range.lowerBound]
            kept = removal.range.upperBound
        }
        result += text[kept...]
        return PrePassedText(text: result, replaced: removals.map(\.key))
    }

    private static func isRewritable(old: ProtectedLiteral, new: ProtectedLiteral, in text: String) -> Bool {
        guard old.range.upperBound <= new.range.lowerBound, let cue = cue(in: text[old.range.upperBound..<new.range.lowerBound]) else {
            return false
        }
        if cue == ["no"], new.canonicalDigits == "1" || new.value == "1" || new.value.lowercased() == "one" { return false }
        let next = text[new.range.upperBound...].prefix { !$0.isLetter && !$0.isNumber && !".!?,;:".contains($0) }
        let following = text[next.endIndex...].prefix { $0.isLetter || $0.isNumber }.lowercased()
        // Only the word right after the replacement, and only when nothing but spaces separates them.
        if next.allSatisfy({ $0 == " " }), !following.isEmpty, unitWords.contains(following) { return false }
        return true
    }

    /// The cue when `between` is exactly ` cue ` or `, cue, ` (single spaces, lowercase-insensitive).
    private static func cue(in between: Substring) -> [String]? {
        let lowered = between.lowercased()
        for cue in prePassCues {
            let phrase = cue.joined(separator: " ")
            if lowered == " \(phrase) " || lowered == ", \(phrase), " { return cue }
        }
        return nil
    }
}

/// Phrase-level self-corrections (spec §10.1): `[det] A… HEAD <cue> [det] B… HEAD`, where both
/// phrases end in the same head word and have one or two modifiers ("the user service no wait the
/// auth service" → "the auth service"). Multi-word cues only ("no wait", "I mean", "scratch
/// that", "or rather"). The separators must be symmetric (` cue ` or `, cue, `), no phrase word
/// may be a protected literal, a determiner, "no" or "one", and the head may not be a unit or
/// count word. Anything else is left unchanged.
enum PhraseCorrection {
    static let cues: [[String]] = [["no", "wait"], ["scratch", "that"], ["or", "rather"], ["i", "mean"]]
    static let determiners: Set<String> = ["the", "a", "an", "this", "that", "my", "our", "your", "its", "their"]
    static let maxModifiers = 2

    private struct Token {
        let range: Range<String.Index>
        /// Lowercased, trailing `. , ! ? ; :` stripped.
        let core: String
        /// The trailing punctuation that was stripped.
        let trailing: String
        let isPlainWord: Bool
    }

    static func apply(to text: String) -> (text: String, phrases: [PhraseRewrite]) {
        let tokens = tokenize(text)
        let literalRanges = ProtectedLiteralExtractor.extractAll(from: text).map(\.range)
        var removals: [Range<String.Index>] = []
        var phrases: [PhraseRewrite] = []
        var index = 1
        while index < tokens.count {
            if let match = match(at: index, in: tokens, text: text, literalRanges: literalRanges),
                removals.last.map({ $0.upperBound <= match.removal.lowerBound }) ?? true
            {
                removals.append(match.removal)
                phrases.append(match.phrase)
                index = match.resumeIndex
            } else {
                index += 1
            }
        }
        guard !removals.isEmpty else { return (text, []) }
        var result = ""
        var kept = text.startIndex
        for removal in removals {
            result += text[kept..<removal.lowerBound]
            kept = removal.upperBound
        }
        result += text[kept...]
        return (result, phrases)
    }

    /// A phrase correction whose cue starts at `cueStart`.
    private static func match(
        at cueStart: Int, in tokens: [Token], text: String, literalRanges: [Range<String.Index>]
    ) -> (removal: Range<String.Index>, phrase: PhraseRewrite, resumeIndex: Int)? {
        guard
            let cue = cues.first(where: { cue in
                cueStart + cue.count <= tokens.count && zip(cue, tokens[cueStart...]).allSatisfy { $0 == $1.core }
            })
        else { return nil }
        let cueEnd = cueStart + cue.count - 1
        let head = tokens[cueStart - 1]

        // Symmetric separators: "HEAD cue next" with plain spaces, or "HEAD, cue, next".
        guard tokens[cueStart..<cueEnd].allSatisfy({ $0.trailing.isEmpty }) else { return nil }
        let commaForm = head.trailing == "," && tokens[cueEnd].trailing == ","
        let plainForm = head.trailing.isEmpty && tokens[cueEnd].trailing.isEmpty
        guard commaForm || plainForm else { return nil }
        guard (cueStart - 1..<min(cueEnd + 1, tokens.count - 1)).allSatisfy({ isSingleSpace(between: tokens[$0], and: tokens[$0 + 1], in: text) })
        else { return nil }
        guard isHead(head) else { return nil }

        // New phrase: [det] modifier{1,2} HEAD.
        var newStart = cueEnd + 1
        guard newStart < tokens.count else { return nil }
        let newDeterminer = determiners.contains(tokens[newStart].core) && tokens[newStart].trailing.isEmpty ? tokens[newStart] : nil
        if newDeterminer != nil { newStart += 1 }
        guard
            let modifierCount = (1...maxModifiers).first(where: { count in
                newStart + count < tokens.count && tokens[newStart + count].core == head.core
            })
        else { return nil }
        let newModifiers = Array(tokens[newStart..<newStart + modifierCount])
        guard newModifiers.allSatisfy(isModifier) else { return nil }
        for position in (newDeterminer == nil ? newStart : newStart - 1)..<newStart + modifierCount
        where !isSingleSpace(between: tokens[position], and: tokens[position + 1], in: text) {
            return nil
        }

        // Old phrase: the same number of modifiers right before HEAD.
        let oldStart = cueStart - 1 - modifierCount
        guard oldStart >= 0 else { return nil }
        let oldModifiers = Array(tokens[oldStart..<cueStart - 1])
        guard oldModifiers.allSatisfy(isModifier),
            (oldStart..<cueStart - 1).allSatisfy({ isSingleSpace(between: tokens[$0], and: tokens[$0 + 1], in: text) })
        else { return nil }
        let oldPhrase = (oldModifiers + [head]).map(\.core).joined(separator: " ")
        let newPhrase = (newModifiers + [tokens[newStart + modifierCount]]).map(\.core).joined(separator: " ")
        guard oldPhrase != newPhrase else { return nil }

        // No protected literal anywhere in the span.
        let span = tokens[oldStart].range.lowerBound..<tokens[newStart + modifierCount].range.upperBound
        guard !literalRanges.contains(where: { $0.overlaps(span) }) else { return nil }

        // Drop the new determiner when the old phrase already has the same one ("the … the").
        let oldDeterminer = oldStart > 0 ? tokens[oldStart - 1] : nil
        let keepNewDeterminer = newDeterminer != nil && oldDeterminer?.core != newDeterminer?.core
        let end = keepNewDeterminer ? tokens[newStart - 1].range.lowerBound : tokens[newStart].range.lowerBound
        return (tokens[oldStart].range.lowerBound..<end, PhraseRewrite(old: oldPhrase, new: newPhrase), newStart + modifierCount + 1)
    }

    private static func isHead(_ token: Token) -> Bool {
        token.isPlainWord && !determiners.contains(token.core) && !["no", "one", "ones"].contains(token.core)
            && !SelfCorrectionPrePass.unitWords.contains(token.core) && !cues.joined().contains(token.core)
    }

    private static func isModifier(_ token: Token) -> Bool {
        token.isPlainWord && token.trailing.isEmpty && !determiners.contains(token.core) && !["no", "one", "ones"].contains(token.core)
    }

    private static func isSingleSpace(between first: Token, and second: Token, in text: String) -> Bool {
        text[first.range.upperBound..<second.range.lowerBound] == " "
    }

    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var start: String.Index?
        func flush(_ end: String.Index) {
            guard let lower = start else { return }
            let raw = text[lower..<end]
            let core = raw.reversed().drop(while: { ".,!?;:".contains($0) }).reversed()
            let trailing = String(raw.dropFirst(core.count))
            let word = String(core).lowercased()
            let plain = !word.isEmpty && word.allSatisfy { $0.isLetter || "'’-".contains($0) }
            // Token ranges cover the raw token, trailing punctuation included.
            tokens.append(Token(range: lower..<end, core: word, trailing: trailing, isPlainWord: plain))
            start = nil
        }
        var position = text.startIndex
        while position < text.endIndex {
            if text[position].isWhitespace {
                flush(position)
            } else if start == nil {
                start = position
            }
            position = text.index(after: position)
        }
        flush(text.endIndex)
        return tokens
    }
}
