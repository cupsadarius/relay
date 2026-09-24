import Foundation

/// The text the cleanup model receives after the pre-pass, and the comparison keys
/// (`canonicalDigits ?? value`) of the old values it removed.
struct PrePassedText: Equatable, Sendable {
    let text: String
    let replaced: [String]
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

    static func apply(to text: String) -> PrePassedText {
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
