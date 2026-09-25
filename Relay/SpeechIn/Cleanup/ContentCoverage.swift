import Foundation

/// Content-word coverage (spec §11.8): every content word of the (pre-passed) input must appear
/// in the output. Protected literals are left to the literal checks, so their ranges are removed
/// first. Set semantics, so a repeated false start ("the the", "we need to we need to") needs to
/// survive only once. Contractions equal their expansions, and a trailing "s" or "es" is ignored.
enum ContentCoverage {
    static let functionWords: Set<String> = [
        "a", "an", "the", "to", "of", "and", "or", "is", "it", "this", "that", "i", "you", "we", "in", "on", "for", "with", "be",
    ]
    /// Prompt rule 1 fillers, plus "please", a courtesy word a cleanup may drop ("set the title to
    /// \"Weekly Sync\" please").
    static let fillers: Set<String> = ["uh", "um", "er", "like", "basically", "please"]
    /// How many words before an accepted correction's cue count as its old side, which a model
    /// that applies the correction drops.
    static let cueOldSideWords = 3
    /// Stands in for an accepted correction's cue span (private-use character, never dictated).
    private static let cueMarker = "\u{E000}"

    /// The first content word of `input` missing from `output`, or `nil` when all survive.
    /// `correctionCues` are the input spans between the two values of each correction the validator
    /// exemption accepts (spec §11.4); only those cue words may be dropped. Every other cue word
    /// ("the no wait list", "no changes needed") is content.
    /// `droppable` are input spans the output may drop whole (a plain-word correction's old value
    /// and cue, spec §11.9).
    static func droppedWord(
        input: String, inputLiterals: [ProtectedLiteral], correctionCues: [Range<String.Index>] = [],
        droppable: [Range<String.Index>] = [], output: String, outputLiterals: [ProtectedLiteral]
    ) -> String? {
        let outputWords = Set(sentences(of: output, blanking: outputLiterals.map(\.range), marking: []).joined())
        for sentence in sentences(of: input, blanking: inputLiterals.map(\.range) + droppable, marking: correctionCues) {
            var exempt = Set<Int>()
            let words = sentence
            // Leading "so" is a filler; so is "you know".
            if words.first == "so" { exempt.insert(0) }
            for index in words.indices where index + 1 < words.count && words[index] == "you" && words[index + 1] == "know" {
                exempt.formUnion([index, index + 1])
            }
            // An accepted correction's cue, and the words just before it, may be dropped.
            for index in words.indices where words[index] == cueMarker {
                exempt.formUnion(max(0, index - cueOldSideWords)...index)
            }
            for (index, word) in words.enumerated() where !exempt.contains(index) && isContent(word) {
                if !covers(outputWords, word) { return word }
            }
        }
        return nil
    }

    private static func isContent(_ word: String) -> Bool {
        !functionWords.contains(word) && !fillers.contains(word)
    }

    private static func covers(_ words: Set<String>, _ word: String) -> Bool {
        if words.contains(word) || words.contains(word + "s") || words.contains(word + "es") { return true }
        if word.hasSuffix("es"), words.contains(String(word.dropLast(2))) { return true }
        if word.hasSuffix("s"), words.contains(String(word.dropLast())) { return true }
        return false
    }

    /// Lowercased, contraction-expanded words per sentence (split at `.`, `!`, `?`), with the
    /// `blanking` ranges removed and each `marking` range replaced by one `cueMarker` word.
    private static func sentences(
        of text: String, blanking: [Range<String.Index>], marking: [Range<String.Index>]
    ) -> [[String]] {
        let spans = (blanking.map { ($0, " ") } + marking.map { ($0, " \(cueMarker) ") }).sorted { $0.0.lowerBound < $1.0.lowerBound }
        var blanked = ""
        var position = text.startIndex
        for (range, replacement) in spans where range.lowerBound >= position {
            blanked += text[position..<range.lowerBound]
            blanked += replacement
            position = range.upperBound
        }
        blanked += text[position...]
        let lowered = blanked.lowercased().replacingOccurrences(of: "’", with: "'")
        return lowered.split(whereSeparator: { ".!?".contains($0) }).map { sentence in
            sentence.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'" || String($0) == cueMarker) })
                .flatMap { expand(String($0).trimmingCharacters(in: CharacterSet(charactersIn: "'"))) }
        }
    }

    /// "don't" → do not, "can't"/"cannot" → can not, "won't" → will not, "it's" → it is, …
    private static func expand(_ word: String) -> [String] {
        switch word {
        case "": return []
        case "can't", "cannot": return ["can", "not"]
        case "won't": return ["will", "not"]
        case "shan't": return ["shall", "not"]
        default: break
        }
        let suffixes: [(String, String)] = [("n't", "not"), ("'re", "are"), ("'m", "am"), ("'ve", "have"), ("'ll", "will"), ("'d", "would"), ("'s", "is")]
        for (suffix, expansion) in suffixes where word.hasSuffix(suffix) && word.count > suffix.count {
            return [String(word.dropLast(suffix.count)), expansion]
        }
        return [word]
    }
}

/// A self-correction of plain words ("move the meeting to tuesday no thursday", "on staging
/// actually on production"), spec §11.9. The output may drop "OLD cue" when all of these hold:
/// OLD is 1-3 words with a content word and no protected literal; the cue is a listed cue with
/// symmetric separators (` cue ` or `, cue, `); the cue is not "no one"/"no 1" and neither the
/// word after the cue nor the word after NEW is a unit or count word; and NEW (1-3 words after the
/// cue) takes the old value's place in the output, right after the word before OLD.
enum PlainWordCorrection {
    static let maxWords = 3
    private static let nonContent = ContentCoverage.functionWords.union(PhraseCorrection.determiners)
        .union(SelfCorrectionDetector.cues.joined())
    private static let countWords = SelfCorrectionPrePass.unitWords.union(SelfCorrectionDetector.countAndTimeWords)

    private struct Token {
        let range: Range<String.Index>
        /// Lowercased, edge punctuation stripped.
        let core: String
        /// Trailing punctuation that was stripped.
        let trailing: String
    }

    /// The "OLD cue" spans of `input` that `output` drops as a plain-word correction.
    static func droppedSpans(input: String, inputLiterals: [ProtectedLiteral], output: String) -> [Range<String.Index>] {
        let tokens = tokenize(input)
        let outputWords = tokenize(output).map(\.core)
        var spans: [Range<String.Index>] = []
        var cueTokens = Set<Int>()
        for cueStart in tokens.indices where !cueTokens.contains(cueStart) {
            guard
                let cue = SelfCorrectionDetector.cues.first(where: { cue in
                    cueStart + cue.count <= tokens.count && zip(cue, tokens[cueStart...]).allSatisfy { $0 == $1.core }
                })
            else { continue }
            let cueEnd = cueStart + cue.count - 1
            cueTokens.formUnion(cueStart...cueEnd)
            guard cueEnd + 1 < tokens.count, cueStart > 0 else { continue }
            let next = tokens[cueEnd + 1].core
            if cue == ["no"], next == "one" || next == "1" { continue }
            if countWords.contains(next) { continue }
            // Symmetric separators; the cue's own words are joined by single spaces.
            guard tokens[cueStart..<cueEnd].allSatisfy({ $0.trailing.isEmpty }) else { continue }
            let before = tokens[cueStart - 1].trailing
            let after = tokens[cueEnd].trailing
            guard (before.isEmpty && after.isEmpty) || (before == "," && after == ",") else { continue }
            guard (cueStart - 1...cueEnd).allSatisfy({ isSpace(between: tokens[$0], and: tokens[$0 + 1], in: input) }) else { continue }

            for oldCount in 1...maxWords where cueStart - oldCount >= 0 {
                let oldStart = cueStart - oldCount
                let old = tokens[oldStart..<cueStart]
                guard old.dropLast().allSatisfy({ $0.trailing.isEmpty }), old.contains(where: { !nonContent.contains($0.core) }) else { continue }
                let oldRange = old.first!.range.lowerBound..<old.last!.range.upperBound
                guard !inputLiterals.contains(where: { $0.range.overlaps(oldRange) }) else { continue }
                let previous = oldStart > 0 ? tokens[oldStart - 1].core : nil
                let placed = (1...maxWords).contains { newCount in
                    let newEnd = cueEnd + newCount
                    guard newEnd < tokens.count else { return false }
                    if newEnd + 1 < tokens.count, countWords.contains(tokens[newEnd + 1].core) { return false }
                    let new = tokens[(cueEnd + 1)...newEnd].map(\.core)
                    guard let previous else { return Array(outputWords.prefix(new.count)) == new }
                    return contains([previous] + new, in: outputWords) || (new.first == previous && contains(new, in: outputWords))
                }
                if placed {
                    spans.append(oldRange.lowerBound..<tokens[cueEnd].range.upperBound)
                    break
                }
            }
        }
        return spans
    }

    private static func contains(_ needle: [String], in words: [String]) -> Bool {
        guard needle.count <= words.count else { return false }
        return (0...(words.count - needle.count)).contains { Array(words[$0..<($0 + needle.count)]) == needle }
    }

    private static func isSpace(between first: Token, and second: Token, in text: String) -> Bool {
        text[first.range.upperBound..<second.range.lowerBound] == " "
    }

    private static func tokenize(_ text: String) -> [Token] {
        let edge: (Character) -> Bool = { ".,!?;:\"'()".contains($0) }
        var tokens: [Token] = []
        var position = text.startIndex
        while position < text.endIndex {
            guard !text[position].isWhitespace else {
                position = text.index(after: position)
                continue
            }
            var end = position
            while end < text.endIndex, !text[end].isWhitespace { end = text.index(after: end) }
            let raw = text[position..<end]
            let trimmed = raw.reversed().drop(while: edge).reversed()
            let trailing = String(raw.dropFirst(trimmed.count))
            let core = String(trimmed.drop(while: edge)).lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            if !core.isEmpty { tokens.append(Token(range: position..<end, core: core, trailing: trailing)) }
            position = end
        }
        return tokens
    }
}
