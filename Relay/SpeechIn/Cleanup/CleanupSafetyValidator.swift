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
    static let wrapperPrefixes = ["here is", "here's", "here’s", "sure", "cleaned text:", "output:", "result:"]

    func validate(input: String, output: String) -> ValidationVerdict {
        let cleaned = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return .reject(.empty) }
        if Self.reasoningMarkers.contains(where: { cleaned.contains($0) }) { return .reject(.reasoningMarkup) }
        if Self.isWrapped(cleaned, input: input) { return .reject(.wrapper) }
        if Double(cleaned.count) > Double(input.count) * 1.75 + 16 { return .reject(.tooLong) }

        let inputLiterals = ProtectedLiteralExtractor.extractAll(from: input)
        let outputLiterals = ProtectedLiteralExtractor.extractAll(from: cleaned)

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
        return .accept(cleaned)
    }

    /// Fillers dropped from the input before checking whether it itself starts with a wrapper
    /// phrase — "uh sure, do it" still exempts "sure" the way "sure, do it" does.
    private static let leadingFillers: Set<String> = ["uh", "um", "so", "okay", "ok"]

    /// A wrapper prefix is exempt only when the input itself — after trimming whitespace and
    /// leading fillers — STARTS with that phrase (review fix 2); merely containing the phrase
    /// anywhere is not enough, or a dictated "here's the plan…" would exempt a real "Here's the
    /// cleaned text: …" preamble. Separately, `<prefix> … :` is always a wrapper when the input
    /// has no colon at all, regardless of the exemption: echoing the input's opening word is not
    /// the same as wrapping the answer in a preamble that ends with a colon.
    private static func isWrapped(_ output: String, input: String) -> Bool {
        let lowered = output.lowercased()
        let loweredInput = trimmedLeadingFillers(of: input.lowercased())
        for prefix in wrapperPrefixes where lowered.hasPrefix(prefix) {
            let previewEnd = lowered.index(lowered.startIndex, offsetBy: min(60, lowered.count))
            if lowered[..<previewEnd].contains(":"), !input.contains(":") { return true }
            if loweredInput.hasPrefix(prefix) { continue }
            let rest = lowered.dropFirst(prefix.count)
            if prefix.hasSuffix(":") || rest.first.map({ !$0.isLetter }) ?? true { return true }
        }
        return output.contains("```") && !input.contains("```")
    }

    /// `text`, trimmed of whitespace and any leading filler words ("uh", "um", "so", "okay", "ok").
    private static func trimmedLeadingFillers(of text: String) -> String {
        var words = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", omittingEmptySubsequences: true).map(
            String.init)
        while let first = words.first, leadingFillers.contains(first.trimmingCharacters(in: .punctuationCharacters)) {
            words.removeFirst()
        }
        return words.joined(separator: " ")
    }
}
