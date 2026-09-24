import Foundation

enum ValidationVerdict: Equatable, Sendable {
    /// The whitespace-trimmed output, safe to insert.
    case accept(String)
    case reject(ValidationRejection)
}

/// Pure, deterministic judge of one cleanup output against its input (spec §11). Production and
/// the Test tool use the same instance. Checks run in `ValidationRejection` declaration order.
struct CleanupSafetyValidator: Sendable {
    static let reasoningMarkers = ["<think>", "</think>", "<|im_start|>", "<|im_end|>", "<|endoftext|>"]
    static let wrapperPrefixes = ["here is", "here's", "here’s", "sure", "certainly", "of course", "cleaned text:", "output:", "result:"]
    /// Openings of a refusal or an assistant reply (spec §11.1), in `prefixForm` (no commas,
    /// `’` read as `'`, "can not" read as "cannot").
    static let refusalPrefixes = [
        "i cannot", "i can't", "i'm unable", "i am unable", "i won't", "as an ai", "i'm sorry but", "i am sorry but", "sorry but",
        "i apologize", "unfortunately", "i'm afraid", "i am afraid", "i'm not able", "i am not able", "i don't have", "i do not have",
    ]

    /// `input` is the pre-passed text the model received; `replaced` holds the comparison keys
    /// (`canonicalDigits ?? value`) of the old values the pre-pass removed (spec §10.1). An output
    /// may not hold a replaced value more often than `input` still does.
    func validate(input: String, output: String, replaced: [String]) -> ValidationVerdict {
        let verdict = validate(input: input, output: output)
        guard case let .accept(cleaned) = verdict, !replaced.isEmpty else { return verdict }
        func counts(_ text: String) -> [String: Int] {
            ProtectedLiteralExtractor.extractAll(from: text).reduce(into: [:]) { $0[$1.canonicalDigits ?? $1.value, default: 0] += 1 }
        }
        let inputCounts = counts(input)
        let outputCounts = counts(cleaned)
        for key in Set(replaced) where outputCounts[key, default: 0] > inputCounts[key, default: 0] {
            return .reject(.literalInvented)
        }
        return verdict
    }

    func validate(input: String, output: String) -> ValidationVerdict {
        let cleaned = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return .reject(.empty) }
        if Self.reasoningMarkers.contains(where: { cleaned.contains($0) }) { return .reject(.reasoningMarkup) }
        if Self.isWrapped(cleaned, input: input) { return .reject(.wrapper) }
        if Self.isRefusal(cleaned, input: input) { return .reject(.refusal) }
        if Double(cleaned.count) > Double(input.count) * 1.75 + 16 { return .reject(.tooLong) }

        let inputLiterals = ProtectedLiteralExtractor.extractAll(from: input)
        var outputLiterals = ProtectedLiteralExtractor.extractAll(from: cleaned)

        // Review fix 7: a camelCase or dotted (`.identifier`) literal that is the FIRST token of
        // both the input and the output may have its first character's case changed — a sentence
        // that opens with it is capitalized like any other sentence. Once matched, its output
        // value is normalized to the input's exact value so every check below (invented, missing,
        // order) treats the two as identical, the same as any other exact match. A literal that is
        // not the very first token (e.g. "readme.md" in "open readme.md") never qualifies.
        if let inputFirst = inputLiterals.first, Self.isFirstToken(inputFirst, in: input), inputFirst.kind == .identifier,
            let outIndex = outputLiterals.indices.first(where: { Self.isFirstToken(outputLiterals[$0], in: cleaned) }),
            outputLiterals[outIndex].kind == .identifier,
            Self.differsOnlyInFirstCharacterCase(outputLiterals[outIndex].value, inputFirst.value)
        {
            let literal = outputLiterals[outIndex]
            outputLiterals[outIndex] = ProtectedLiteral(
                kind: literal.kind, value: inputFirst.value, canonicalDigits: literal.canonicalDigits, range: literal.range)
        }

        // `allowed` covers every kind, keyed by exact value, plus the canonical digit form of
        // each input spoken number. `allowedSpokenPhrases` covers the input's spoken-number word
        // forms, so an output that echoes the same words back is never "invented".
        let allowed = Set(inputLiterals.filter { $0.kind != .spokenNumber }.map(\.value))
            .union(inputLiterals.compactMap(\.canonicalDigits))
        let allowedSpokenPhrases = Set(inputLiterals.filter { $0.kind == .spokenNumber }.map(\.value))
        for literal in outputLiterals {
            if literal.kind == .spokenNumber {
                let matchesDigits = literal.canonicalDigits.map { allowed.contains($0) } ?? false
                if !matchesDigits && !allowedSpokenPhrases.contains(literal.value) { return .reject(.literalInvented) }
            } else if !allowed.contains(literal.value) {
                return .reject(.literalInvented)
            }
        }

        let outputValues = Set(outputLiterals.filter { $0.kind != .spokenNumber }.map(\.value))
        let outputWords = SpokenNumberParser.wordSequence(of: cleaned)
        func isPresent(_ literal: ProtectedLiteral) -> Bool {
            guard literal.kind == .spokenNumber else { return outputValues.contains(literal.value) }
            if let digits = literal.canonicalDigits, outputValues.contains(digits) { return true }
            return SpokenNumberParser.contains(literal.value.split(separator: " ").map(String.init), in: outputWords)
        }
        let corrections = SelfCorrectionDetector.analyze(input, literals: inputLiterals)
        for (index, literal) in inputLiterals.enumerated() where !isPresent(literal) {
            let exempt = corrections.chainTargets(from: index).contains { isPresent(inputLiterals[$0]) }
            if !exempt { return .reject(.literalMissing) }
        }
        // Review fix 5: with no correction in play, the output cannot reassign which value went
        // with which literal — every input literal is already known to be present (the loop above
        // would have rejected otherwise), so its order in the output must match the input's order.
        func sequenceKey(_ literal: ProtectedLiteral) -> String { literal.kind == .spokenNumber ? (literal.canonicalDigits ?? literal.value) : literal.value }
        if corrections.pairs.isEmpty, inputLiterals.map(sequenceKey) != outputLiterals.map(sequenceKey) {
            return .reject(.literalMissing)
        }
        return .accept(cleaned)
    }

    /// Fillers dropped from the input before checking whether it itself starts with a wrapper
    /// phrase — "uh sure, do it" still exempts "sure" the way "sure, do it" does.
    private static let leadingFillers: Set<String> = ["uh", "um", "so", "okay", "ok", "like"]

    /// A wrapper prefix is exempt only when the input itself — after trimming whitespace and
    /// leading fillers — STARTS with that phrase (review fix 2); merely containing the phrase
    /// anywhere is not enough, or a dictated "here's the plan…" would exempt a real "Here's the
    /// cleaned text: …" preamble. Separately, `<prefix> … :` is always a wrapper when the input
    /// has no colon at all, regardless of the exemption: echoing the input's opening word is not
    /// the same as wrapping the answer in a preamble that ends with a colon.
    private static func isWrapped(_ output: String, input: String) -> Bool {
        let lowered = output.lowercased()
        let inputOpening = dictatedOpening(of: input)
        for prefix in wrapperPrefixes where lowered.hasPrefix(prefix) {
            let previewEnd = lowered.index(lowered.startIndex, offsetBy: min(60, lowered.count))
            if lowered[..<previewEnd].contains(":"), !input.contains(":") { return true }
            if inputOpening.hasPrefix(prefixForm(prefix)) { continue }
            let rest = lowered.dropFirst(prefix.count)
            if prefix.hasSuffix(":") || rest.first.map({ !$0.isLetter }) ?? true { return true }
        }
        return output.contains("```") && !input.contains("```")
    }

    /// A refusal opening is exempt only when the input itself (fillers trimmed) starts with it:
    /// "I can't make the meeting" is dictation, not a refusal.
    private static func isRefusal(_ output: String, input: String) -> Bool {
        let outputOpening = prefixForm(output)
        let inputOpening = dictatedOpening(of: input)
        return refusalPrefixes.contains { outputOpening.hasPrefix($0) && !inputOpening.hasPrefix($0) }
    }

    /// Lowercased, `’` read as `'`, commas removed, whitespace collapsed, "can not" read as
    /// "cannot": the form both sides of a prefix test use, so "Sorry, but" matches "sorry but".
    private static func prefixForm(_ text: String) -> String {
        let words = text.lowercased().replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return words.replacingOccurrences(of: "can not", with: "cannot")
    }

    /// `prefixForm` of the input with leading fillers ("uh", "um", "so", "okay", "ok", "like",
    /// "you know") and an immediately repeated first word ("I I can't") dropped.
    private static func dictatedOpening(of input: String) -> String {
        var words = trimmedLeadingFillers(of: prefixForm(input)).split(separator: " ").map(String.init)
        if words.count >= 2, words[0] == words[1] { words.removeFirst() }
        return words.joined(separator: " ")
    }

    /// Whether `literal` is the first token of `text` — nothing but whitespace precedes it.
    private static func isFirstToken(_ literal: ProtectedLiteral, in text: String) -> Bool {
        text[text.startIndex..<literal.range.lowerBound].allSatisfy(\.isWhitespace)
    }

    /// Whether `candidate` and `original` are identical except possibly for the case of their
    /// first character (review fix 7): "UserService" vs. "userService", but not "Userservice".
    private static func differsOnlyInFirstCharacterCase(_ candidate: String, _ original: String) -> Bool {
        guard candidate.count == original.count, let first = candidate.first, let originalFirst = original.first else { return false }
        return first.lowercased() == originalFirst.lowercased() && candidate.dropFirst() == original.dropFirst()
    }

    /// `text`, trimmed of whitespace and any leading filler words ("uh", "um", "so", "okay", "ok",
    /// "like", "you know").
    private static func trimmedLeadingFillers(of text: String) -> String {
        var words = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", omittingEmptySubsequences: true).map(
            String.init)
        while let first = words.first {
            if leadingFillers.contains(first.trimmingCharacters(in: .punctuationCharacters)) {
                words.removeFirst()
            } else if first == "you", words.count > 1, words[1].trimmingCharacters(in: .punctuationCharacters) == "know" {
                words.removeFirst(2)
            } else {
                break
            }
        }
        return words.joined(separator: " ")
    }
}
