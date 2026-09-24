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
