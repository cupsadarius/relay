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
    static func droppedWord(
        input: String, inputLiterals: [ProtectedLiteral], correctionCues: [Range<String.Index>] = [], output: String,
        outputLiterals: [ProtectedLiteral]
    ) -> String? {
        let outputWords = Set(sentences(of: output, blanking: outputLiterals.map(\.range), marking: []).joined())
        for sentence in sentences(of: input, blanking: inputLiterals.map(\.range), marking: correctionCues) {
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
