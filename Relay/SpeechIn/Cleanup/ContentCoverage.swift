import Foundation

/// Content-word coverage (spec §11.8): every content word of the (pre-passed) input must appear
/// in the output. Protected literals are left to the literal checks, so their ranges are removed
/// first. Set semantics, so a repeated false start ("the the", "we need to we need to") needs to
/// survive only once. Contractions equal their expansions, and a trailing "s" or "es" is ignored.
enum ContentCoverage {
    static let functionWords: Set<String> = [
        "a", "an", "the", "to", "of", "and", "or", "is", "it", "this", "that", "i", "you", "we", "in", "on", "for", "with", "be",
    ]
    /// "please" is a courtesy word a cleanup may drop ("set the title to \"Weekly Sync\" please").
    static let fillers: Set<String> = ["uh", "um", "er", "like", "please"]
    static let cueWords: Set<String> = Set(SelfCorrectionDetector.cues.joined())
    /// How many words before a cue count as the old side of a correction the model may drop.
    static let cueOldSideWords = 3

    /// The first content word of `input` missing from `output`, or `nil` when all survive.
    static func droppedWord(
        input: String, inputLiterals: [ProtectedLiteral], output: String, outputLiterals: [ProtectedLiteral]
    ) -> String? {
        let outputWords = Set(sentences(of: output, removing: outputLiterals).joined())
        for sentence in sentences(of: input, removing: inputLiterals) {
            var exempt = Set<Int>()
            let words = sentence
            // Leading "so" is a filler; so is "you know".
            if words.first == "so" { exempt.insert(0) }
            for index in words.indices where index + 1 < words.count && words[index] == "you" && words[index + 1] == "know" {
                exempt.formUnion([index, index + 1])
            }
            // The old side of any correction cue may be dropped by a model that applied it.
            for cue in SelfCorrectionDetector.cues {
                for start in words.indices where start + cue.count <= words.count && Array(words[start..<start + cue.count]) == cue {
                    exempt.formUnion(max(0, start - cueOldSideWords)..<start)
                }
            }
            for (index, word) in words.enumerated() where !exempt.contains(index) && isContent(word) {
                if !covers(outputWords, word) { return word }
            }
        }
        return nil
    }

    private static func isContent(_ word: String) -> Bool {
        !functionWords.contains(word) && !fillers.contains(word) && !cueWords.contains(word)
    }

    private static func covers(_ words: Set<String>, _ word: String) -> Bool {
        if words.contains(word) || words.contains(word + "s") || words.contains(word + "es") { return true }
        if word.hasSuffix("es"), words.contains(String(word.dropLast(2))) { return true }
        if word.hasSuffix("s"), words.contains(String(word.dropLast())) { return true }
        return false
    }

    /// Lowercased, contraction-expanded words per sentence (split at `.`, `!`, `?`), with the
    /// literal ranges blanked out.
    private static func sentences(of text: String, removing literals: [ProtectedLiteral]) -> [[String]] {
        var blanked = ""
        var position = text.startIndex
        for literal in literals.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) where literal.range.lowerBound >= position {
            blanked += text[position..<literal.range.lowerBound]
            blanked += " "
            position = literal.range.upperBound
        }
        blanked += text[position...]
        let lowered = blanked.lowercased().replacingOccurrences(of: "’", with: "'")
        return lowered.split(whereSeparator: { ".!?".contains($0) }).map { sentence in
            sentence.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") })
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
