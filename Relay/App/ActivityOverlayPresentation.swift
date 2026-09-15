import CoreGraphics
import Foundation

struct ActivityOverlayPresentation: Equatable {
    enum Kind: Equatable {
        case listening(level: Float)
        case processing
        case speaking
        case error
    }

    /// Drives the Minimal state dot's color. Text/border chrome no longer varies by accent.
    enum Accent: Equatable {
        case red
        case amber
        case violetCyan
        case error
    }

    enum Layout: Equatable {
        case minimal
        case interactive
    }

    let kind: Kind
    let accent: Accent
    let layout: Layout
    let cornerRadius: CGFloat
    let size: CGSize
    let title: String?
    let subtitle: String?
    let startedAt: Date?
    let action: ActivityOverlayAction?
    let actionAccessibilityLabel: String?
    let animatesWaveform: Bool
    let usesScaleTransition: Bool
    let speakingLevel: Float?

    /// Rest-state bar heights (points) for the 7-bar waveform, shared by both styles.
    static let waveformRestHeights: [CGFloat] = [8, 15, 23, 11, 23, 15, 8]

    /// CSS `animation-delay` values (seconds) for the Speaking waveform's per-bar phase offsets.
    private static let speakingBarDelays: [Double] = [0, -0.4, -0.2, -0.55, -0.2, -0.4, 0]

    /// One full ping-pong cycle (0.7s out, 0.7s back) of the mockup's `wave 0.7s infinite alternate`.
    private static let speakingCyclePeriod: Double = 1.4
    private static let speakingHalfCycle: Double = 0.7
    private static let waveformMinScale: CGFloat = 0.34

    static func make(
        state: ActivityOverlayState,
        style: ActivityOverlayStyle,
        reduceMotion: Bool,
        backendName: String? = nil
    ) -> Self? {
        guard style != .off, !state.isHidden else { return nil }

        let interactive = style == .interactive
        let layout: Layout = interactive ? .interactive : .minimal
        let size = interactive ? CGSize(width: 282, height: 62) : CGSize(width: 154, height: 40)
        let cornerRadius: CGFloat = interactive ? 20 : 22
        let scaleTransition = !reduceMotion

        switch state {
        case .hidden:
            return nil
        case let .listening(sessionID, startedAt, level):
            return .init(
                kind: .listening(level: level), accent: .red, layout: layout, cornerRadius: cornerRadius, size: size,
                title: interactive ? "Listening" : nil,
                subtitle: interactive ? (backendName ?? "Microphone") : nil,
                startedAt: startedAt,
                action: interactive ? .cancelDictation(sessionID: sessionID) : nil,
                actionAccessibilityLabel: interactive ? "Cancel dictation" : nil,
                animatesWaveform: !reduceMotion, usesScaleTransition: scaleTransition,
                speakingLevel: nil
            )
        case let .processing(sessionID, startedAt):
            return .init(
                kind: .processing, accent: .amber, layout: layout, cornerRadius: cornerRadius, size: size,
                title: interactive ? "Processing" : nil,
                subtitle: interactive ? (backendName ?? "Transcribing") : nil,
                startedAt: startedAt,
                action: interactive ? .cancelDictation(sessionID: sessionID) : nil,
                actionAccessibilityLabel: interactive ? "Cancel dictation" : nil,
                animatesWaveform: !reduceMotion, usesScaleTransition: scaleTransition,
                speakingLevel: nil
            )
        case let .speaking(sessionID, startedAt, level):
            return .init(
                kind: .speaking, accent: .violetCyan, layout: layout, cornerRadius: cornerRadius, size: size,
                title: interactive ? "Speaking" : nil,
                subtitle: interactive ? (backendName ?? "Speaking") : nil,
                startedAt: startedAt,
                action: interactive ? .stopSpeech(sessionID: sessionID) : nil,
                actionAccessibilityLabel: interactive ? "Stop speech" : nil,
                animatesWaveform: !reduceMotion, usesScaleTransition: scaleTransition,
                speakingLevel: level
            )
        case let .error(_, category, _):
            return .init(
                kind: .error, accent: .error, layout: layout, cornerRadius: cornerRadius, size: size,
                title: interactive ? errorDisplayCopy(for: category) : nil,
                subtitle: interactive ? "Try again" : nil,
                startedAt: nil,
                action: nil, actionAccessibilityLabel: nil,
                animatesWaveform: false, usesScaleTransition: scaleTransition,
                speakingLevel: nil
            )
        }
    }

    /// Per-bar scale multipliers (0.34...1) for the Speaking waveform at a given moment, replaying
    /// the mockup's `wave 0.7s infinite alternate` animation with each bar's phase offset baked in.
    func waveformBars(at date: Date) -> [CGFloat] {
        guard case .speaking = kind else { return [] }
        let time = date.timeIntervalSinceReferenceDate
        return Self.speakingBarDelays.map { delay in
            let effective = time - delay
            var cycle = effective.truncatingRemainder(dividingBy: Self.speakingCyclePeriod)
            if cycle < 0 { cycle += Self.speakingCyclePeriod }
            let progress = cycle <= Self.speakingHalfCycle
                ? cycle / Self.speakingHalfCycle
                : (Self.speakingCyclePeriod - cycle) / Self.speakingHalfCycle
            return CGFloat(1 - progress * Double(1 - Self.waveformMinScale))
        }
    }

    /// Seven identical scale multipliers (0.34...1) for the Listening waveform, driven by the live
    /// mic level. Reflects level regardless of Reduce Motion: this isn't decorative animation, it's
    /// a live value.
    ///
    /// The shape lives in `waveformRestHeights` alone: since the view renders each bar as
    /// `restHeight × scale`, a single uniform multiplier here means level 1 reproduces the rest
    /// heights exactly and level 0 dims every bar to the same 0.34 proportion. Baking the rest-height
    /// shape into this multiplier too (as an earlier version did) would apply it twice — once here,
    /// once more in the view's multiplication — squaring the falloff and leaving short bars almost
    /// motionless across the whole level range.
    func listeningWaveformBars() -> [CGFloat] {
        guard case let .listening(level) = kind else { return [] }
        return Array(repeating: Self.uniformMultiplier(for: level), count: Self.waveformRestHeights.count)
    }

    /// Level-driven bars for the Speaking waveform, used in place of `waveformBars(at:)` whenever
    /// the active TTS backend reports a live output level (`speakingLevel != nil`). Reuses the same
    /// uniform-multiplier shape as `listeningWaveformBars()` since both represent a live scalar
    /// level rather than a synthetic animation.
    func speakingLevelBars() -> [CGFloat] {
        guard case .speaking = kind, let speakingLevel else { return [] }
        return Array(repeating: Self.uniformMultiplier(for: speakingLevel), count: Self.waveformRestHeights.count)
    }

    private static func uniformMultiplier(for level: Float) -> CGFloat {
        let clampedLevel = CGFloat(min(max(level, 0), 1))
        return Self.waveformMinScale + clampedLevel * (1 - Self.waveformMinScale)
    }

    private static func errorDisplayCopy(for category: ActivityOverlayErrorCategory) -> String {
        switch category {
        case .microphone: "Microphone unavailable"
        case .speechRecognition: "Speech recognition unavailable"
        case .noUsableAudio: "No usable audio detected"
        case .speechPlayback: "Speech playback failed"
        case .insertion: "Could not insert text"
        case .unexpected: "Something went wrong"
        }
    }

    /// Formats an elapsed duration as `MM:SS` (e.g. `00:18`), matching the mockup's time readout.
    static func elapsedTime(since start: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
