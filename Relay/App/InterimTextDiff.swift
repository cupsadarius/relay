import Foundation

/// Splits a live interim transcription update into a stable prefix shared with the previous
/// update and a changed tail, so the view can render the prefix as plain, unchanging text and
/// let only the tail update - reading as text extending rather than the whole line rewriting
/// each re-transcription tick.
enum InterimTextDiff {
    struct Result: Equatable {
        let stablePrefix: String
        let changedTail: String
    }

    /// Compares `previous` and `current` character-by-character to find the longest common
    /// prefix, then trims it back to the end of the last completed word (a preceding space) so
    /// the stable prefix never ends mid-word - a word that's still being revised stays entirely
    /// in the tail until a later tick confirms it, rather than flickering between the two parts.
    static func diff(previous: String, current: String) -> Result {
        guard !current.isEmpty else { return Result(stablePrefix: "", changedTail: "") }
        guard previous != current else { return Result(stablePrefix: current, changedTail: "") }

        var commonLength = 0
        for (a, b) in zip(previous, current) {
            guard a == b else { break }
            commonLength += 1
        }

        let candidatePrefix = String(current.prefix(commonLength))
        let stablePrefix = Self.trimToLastWordBoundary(candidatePrefix)
        let changedTail = String(current.dropFirst(stablePrefix.count))
        return Result(stablePrefix: stablePrefix, changedTail: changedTail)
    }

    /// Trims back to just after the last space in `text` - see the type-level doc comment.
    private static func trimToLastWordBoundary(_ text: String) -> String {
        guard let lastSpace = text.lastIndex(of: " ") else { return "" }
        return String(text[...lastSpace])
    }
}
