import Foundation

/// The text the cleanup model receives after the pre-pass, and the comparison keys
/// (`canonicalDigits ?? value`) of the old values it removed.
struct PrePassedText: Equatable, Sendable {
    let text: String
    let replaced: [String]
}

/// Deterministic self-correction pre-pass (spec §10.1). Applies the literal pairs
/// `SelfCorrectionDetector` finds before the model runs: "port three no four" → "port four".
/// Conservative: it only rewrites a pair when the text between the two values is exactly a cue
/// (optionally preceded by words the replacement repeats: "4 threads actually 8 threads"), and it
/// leaves the whole text unchanged when any pair is part of a chain.
enum SelfCorrectionPrePass {
    static func apply(to text: String) -> PrePassedText {
        let unchanged = PrePassedText(text: text, replaced: [])
        let literals = ProtectedLiteralExtractor.extractAll(from: text)
        let pairs = SelfCorrectionDetector.analyze(text, literals: literals).pairs
        guard !pairs.isEmpty else { return unchanged }
        let endpoints = pairs.flatMap { [$0.old, $0.new] }
        guard Set(endpoints).count == endpoints.count else { return unchanged } // chained

        var result = text
        var replaced: [String] = []
        // Right to left, so earlier ranges stay valid in `result`.
        for pair in pairs.sorted(by: { $0.old > $1.old }) {
            let old = literals[pair.old]
            let new = literals[pair.new]
            guard isPlainCueSpan(text[old.range.upperBound..<new.range.lowerBound], replacement: new, in: text) else { continue }
            result.replaceSubrange(old.range.lowerBound..<new.range.lowerBound, with: "")
            replaced.insert(old.canonicalDigits ?? old.value, at: 0)
        }
        return PrePassedText(text: result, replaced: replaced)
    }

    /// `between` must be whitespace/comma-separated words ending in a detector cue, and any words
    /// before the cue must be repeated right after the replacement.
    private static func isPlainCueSpan(_ between: Substring, replacement: ProtectedLiteral, in text: String) -> Bool {
        guard between.allSatisfy({ $0.isLetter || $0.isWhitespace || ",;'’".contains($0) }) else { return false }
        let words = between.lowercased().split(whereSeparator: { $0.isWhitespace || ",;".contains($0) }).map(String.init)
        guard
            let cue = SelfCorrectionDetector.cues.first(where: { $0.count <= words.count && Array(words.suffix($0.count)) == $0 })
        else { return false }
        if cue == ["no"], replacement.value.lowercased() == "one" { return false } // "no one"
        let repeated = words.dropLast(cue.count)
        guard !repeated.isEmpty else { return true }
        let following = text[replacement.range.upperBound...].lowercased()
            .split(whereSeparator: { $0.isWhitespace || ",;.!?".contains($0) }).prefix(repeated.count).map(String.init)
        return following == Array(repeated)
    }
}
