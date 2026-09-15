import Foundation

/// A single recorded voice-interaction moment: the frontmost app's PID at the time dictation
/// began, plus when it was captured. Memory-only, in-process — never persisted to disk.
///
/// This is **supporting evidence only**: it must never independently produce a `focused(high)`
/// resolution, and no resolver consumes it as of this writing. It exists so future resolvers can
/// use it to break ties or so it can be surfaced in diagnostics.
struct RecentVoiceInteraction: Equatable, Sendable {
    let frontmostPID: Int32
    let capturedAt: Date
}

/// Tracks the most recent app that was frontmost when dictation started, so it can later be
/// consulted as supporting (never authoritative) evidence for focus resolution. Holds at most one
/// value at a time — the newest recording replaces whatever was there before — and forgets it
/// once `maxAge` has elapsed since it was captured.
actor RecentInteractionTracker {
    private var value: RecentVoiceInteraction?
    private let maxAge: TimeInterval

    init(maxAge: TimeInterval = 120) {
        self.maxAge = maxAge
    }

    /// Records `frontmostApplication` as the app that received the most recent voice
    /// interaction, replacing any prior recording.
    func record(frontmostApplication: FrontmostApplication, at: Date = Date()) {
        value = RecentVoiceInteraction(frontmostPID: frontmostApplication.pid, capturedAt: at)
    }

    /// The most recent recording, or `nil` if none has been made or the last one is older than
    /// `maxAge` relative to `now`.
    func latest(now: Date = Date()) -> RecentVoiceInteraction? {
        guard let value, now.timeIntervalSince(value.capturedAt) <= maxAge else { return nil }
        return value
    }
}
