import Foundation

/// Whether a cleanup model row's Test action should be enabled, and the help text to show either
/// way — the model's own unusable reason, "not downloaded yet", "a test is already running", or
/// none when Test is simply available.
enum CleanupTestAvailability {
    static func make(status: SpeechModelStatus, testerBusy: Bool) -> (enabled: Bool, help: String?) {
        let downloaded = status.installState == .downloaded
        let usable = status.usability == .usable
        let enabled = downloaded && usable && !testerBusy
        let help: String? =
            if let reason = status.usability.unusableReason {
                reason
            } else if !downloaded {
                "Download the model first."
            } else if testerBusy {
                "A test is already running."
            } else {
                nil
            }
        return (enabled, help)
    }
}
