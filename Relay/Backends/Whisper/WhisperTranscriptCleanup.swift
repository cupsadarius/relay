import Foundation

/// Strips WhisperKit's known non-speech and special-token markers out of a raw transcription
/// result. Pure and stateless -- no WhisperKit types involved -- so it is unit-testable directly;
/// see `WhisperTranscriptCleanupTests`.
///
/// Reproduced on `base.en` (and believed to affect every Whisper model): given silence or
/// background noise, WhisperKit's `TranscriptionResult.text` can contain literal bracketed
/// markers like `[BLANK_AUDIO]` right alongside real speech. These are NOT special tokens --
/// they're ordinary word tokens the model decodes that happen to spell out a bracketed marker,
/// carried over from how Whisper's training data annotated non-speech segments -- so
/// `DecodingOptions.skipSpecialTokens` (set in `WhisperKitContext.transcribe`) does not remove
/// them; only `WhisperKitConfig`/`DecodingOptions` special-token handling covers genuine
/// `<|...|>` tokens (e.g. `<|startoftranscript|>`). This type strips both, defensively, so a
/// leaked marker never reaches the transcript pipeline even if the decode-option ever regresses
/// or a future WhisperKit version stops honoring it.
///
/// Deliberately conservative: only an exact (case-insensitive, whitespace/underscore-normalized)
/// match against `nonSpeechMarkers` is stripped. Any other bracketed text -- which could be
/// legitimate user content -- is left untouched.
enum WhisperTranscriptCleanup {
    /// Known non-speech marker words/phrases WhisperKit is documented (and, for `BLANK_AUDIO` on
    /// `base.en`, directly observed) to emit inside brackets for silence, music, noise, or
    /// inaudible segments. Compared case-insensitively with internal whitespace collapsed to a
    /// single underscore, so `[BLANK_AUDIO]`, `[blank_audio]`, and `[ Silence ]` all match.
    private static let nonSpeechMarkers: Set<String> = [
        "BLANK_AUDIO",
        "SILENCE",
        "MUSIC",
        "NOISE",
        "INAUDIBLE",
    ]

    private static let specialTokenRegex = try! NSRegularExpression(pattern: #"<\|[^<>]*\|>"#)
    private static let bracketedRegex = try! NSRegularExpression(pattern: #"\[[^\[\]]*\]"#)

    /// Removes every `<|...|>` special token and every bracketed non-speech marker from `raw`,
    /// collapses any whitespace left behind by the removal down to single spaces, and trims the
    /// result. Text with nothing to strip is returned trimmed but otherwise unchanged.
    static func clean(_ raw: String) -> String {
        var text = replacing(specialTokenRegex, in: raw) { _ in "" }
        text = replacing(bracketedRegex, in: text) { match in
            isNonSpeechMarker(match) ? "" : match
        }
        return collapseWhitespace(text)
    }

    private static func isNonSpeechMarker(_ bracketed: String) -> Bool {
        let inner = bracketed.dropFirst().dropLast()
        let normalized =
            inner
            .trimmingCharacters(in: .whitespaces)
            .uppercased()
            .replacingOccurrences(of: " ", with: "_")
        return nonSpeechMarkers.contains(normalized)
    }

    private static func replacing(
        _ regex: NSRegularExpression,
        in text: String,
        transform: (String) -> String
    ) -> String {
        let nsText = text as NSString
        var result = ""
        var lastIndex = 0
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        for match in matches {
            result += nsText.substring(with: NSRange(location: lastIndex, length: match.range.location - lastIndex))
            result += transform(nsText.substring(with: match.range))
            lastIndex = match.range.location + match.range.length
        }
        result += nsText.substring(from: lastIndex)
        return result
    }

    private static func collapseWhitespace(_ text: String) -> String {
        let collapsed = text.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
