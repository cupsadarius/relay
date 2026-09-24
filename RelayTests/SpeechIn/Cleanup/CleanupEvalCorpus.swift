import Foundation

@testable import Relay

/// One case of `RelayTests/Fixtures/DictationCleanup/eval-corpus.json` (spec §19).
struct CleanupEvalCase: Decodable, Sendable {
    struct Rejection: Decodable, Sendable {
        let output: String
        let reason: ValidationRejection
    }

    let id: String
    let category: String
    let input: String
    let reference: String
    let acceptable: [String]
    let mustReject: [Rejection]
    /// Set only for `nonEnglish` cases.
    let locale: String?
}

enum CleanupEvalCorpus {
    private final class BundleToken {}

    static func load() throws -> [CleanupEvalCase] {
        guard let url = Bundle(for: BundleToken.self).url(forResource: "eval-corpus", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode([CleanupEvalCase].self, from: Data(contentsOf: url))
    }
}

/// How the live eval compares a model output with a case's `reference` and `acceptable` outputs.
enum CleanupEvalScoring {
    /// Spec §19 "reference match": normalized for whitespace and case only.
    static func referenceKey(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// `referenceKey` that also ignores sentence punctuation (`, ; : ! ? .` before whitespace or
    /// the end), so correction application and cue-negative over-corrections judge the words a
    /// model kept, not its commas. Punctuation inside a literal ("1.5", "1,000", "https://") stays.
    static func contentKey(_ text: String) -> String {
        referenceKey(text.replacing(/[,;:!?.]+(?=\s|$)/, with: " "))
    }

    static func matches(_ output: String, good: [String], key: (String) -> String) -> Bool {
        Set(good.map(key)).contains(key(output))
    }
}
