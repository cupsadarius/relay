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
    /// The live interim transcription text for the Listening pill, wrapped/scrolled by the view
    /// rather than truncated. `nil` for every other state and for Listening with no interim text
    /// yet - Processing and every non-listening state deliberately never carry this, so they keep
    /// their compact, fixed-size look regardless of how long dictation ran.
    let interimText: String?
    /// How many lines of `interimText` should be visible at once, capped at
    /// `InterimLayout.maxVisibleLines`. `1` when there is no interim text.
    let interimVisibleLineCount: Int
    /// Whether the wrapped interim text overflows `interimVisibleLineCount` and needs a
    /// scrollable container pinned to the newest (bottom) line rather than a fully-grown one.
    let interimNeedsScroll: Bool

    init(
        kind: Kind, accent: Accent, layout: Layout, cornerRadius: CGFloat, size: CGSize,
        title: String?, subtitle: String?, startedAt: Date?, action: ActivityOverlayAction?,
        actionAccessibilityLabel: String?, animatesWaveform: Bool, usesScaleTransition: Bool,
        speakingLevel: Float?, interimText: String? = nil, interimVisibleLineCount: Int = 1,
        interimNeedsScroll: Bool = false
    ) {
        self.kind = kind
        self.accent = accent
        self.layout = layout
        self.cornerRadius = cornerRadius
        self.size = size
        self.title = title
        self.subtitle = subtitle
        self.startedAt = startedAt
        self.action = action
        self.actionAccessibilityLabel = actionAccessibilityLabel
        self.animatesWaveform = animatesWaveform
        self.usesScaleTransition = usesScaleTransition
        self.speakingLevel = speakingLevel
        self.interimText = interimText
        self.interimVisibleLineCount = interimVisibleLineCount
        self.interimNeedsScroll = interimNeedsScroll
    }

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
        case let .listening(sessionID, startedAt, level, interimText):
            let hasInterimText = interactive && !interimText.isEmpty
            let listeningSize: CGSize
            let lineCount: Int
            let needsScroll: Bool
            if hasInterimText {
                let width = InterimLayout.width(for: interimText)
                let wrappedLines = InterimLayout.lineCount(for: interimText, width: width)
                lineCount = min(wrappedLines, InterimLayout.maxVisibleLines)
                needsScroll = wrappedLines > InterimLayout.maxVisibleLines
                listeningSize = CGSize(width: width, height: InterimLayout.height(forLineCount: wrappedLines))
            } else {
                listeningSize = size
                lineCount = 1
                needsScroll = false
            }
            return .init(
                kind: .listening(level: level), accent: .red, layout: layout, cornerRadius: cornerRadius,
                size: listeningSize,
                title: interactive ? "Listening" : nil,
                subtitle: interactive && !hasInterimText ? (backendName ?? "Microphone") : nil,
                startedAt: startedAt,
                action: interactive ? .cancelDictation(sessionID: sessionID) : nil,
                actionAccessibilityLabel: interactive ? "Cancel dictation" : nil,
                animatesWaveform: !reduceMotion, usesScaleTransition: scaleTransition,
                speakingLevel: nil,
                interimText: hasInterimText ? interimText : nil,
                interimVisibleLineCount: lineCount,
                interimNeedsScroll: needsScroll
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
        case let .preparingSpeech(sessionID, startedAt):
            return .init(
                kind: .processing, accent: .amber, layout: layout, cornerRadius: cornerRadius, size: size,
                title: interactive ? "Processing" : nil,
                subtitle: interactive ? (backendName ?? "Preparing") : nil,
                startedAt: startedAt,
                action: interactive ? .stopSpeech(sessionID: sessionID) : nil,
                actionAccessibilityLabel: interactive ? "Stop speech" : nil,
                animatesWaveform: !reduceMotion, usesScaleTransition: scaleTransition,
                speakingLevel: nil
            )
        case let .speaking(sessionID, startedAt, level):
            return .init(
                kind: .speaking, accent: .violetCyan, layout: layout, cornerRadius: cornerRadius, size: size,
                title: interactive ? "Speaking" : nil,
                subtitle: interactive ? (backendName ?? "Voice") : nil,
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

/// Pure sizing math for the Listening pill's interim text: grows the pill's width up to a cap,
/// estimates how many lines that text wraps to at that width, and grows height up to a cap beyond
/// which the view scrolls instead. A character-count approximation rather than real AppKit/
/// SwiftUI text measurement, so this stays a plain, fast, host-free unit under test; any small
/// mismatch against actual on-screen wrapping is absorbed by the view's bounded ScrollView.
enum InterimLayout {
    /// The existing fixed interactive-pill width, used whenever there is no interim text yet.
    static let baseWidth: CGFloat = 282
    /// The interactive pill never grows wider than this — beyond it, text wraps instead.
    static let maxWidth: CGFloat = 420
    /// Roughly how much of the pill's width is chrome (icon, padding, time readout) rather than
    /// available for text.
    static let chromeWidth: CGFloat = 92
    /// A rough average glyph width (points) for the pill's subtitle font, used only to estimate
    /// wrapping — not for precise layout.
    static let averageCharacterWidth: CGFloat = 6.4
    /// Approximate line height (points) for the subtitle font.
    static let lineHeight: CGFloat = 15
    /// Beyond this many visible lines, the pill stops growing taller and scrolls instead.
    static let maxVisibleLines = 4
    /// The existing fixed interactive-pill height for a single line of subtitle text.
    static let baseHeight: CGFloat = 62
    /// Extra headroom (points) folded into every wrapped-text height calculation, covering the
    /// gap between this module's character-count line-wrap estimate and SwiftUI's real
    /// word-boundary wrapping (a line that's almost full but ends mid-word wraps earlier than the
    /// raw character math predicts) — biases toward slightly-too-tall rather than a clipped last
    /// line.
    static let wrapSlack: CGFloat = 6

    /// The pill width for the given interim text: grows from `baseWidth` towards `maxWidth` to
    /// fit it on one line, capping out at `maxWidth` once wrapping is unavoidable.
    static func width(for text: String) -> CGFloat {
        guard !text.isEmpty else { return baseWidth }
        let neededWidth = CGFloat(text.count) * averageCharacterWidth + chromeWidth
        return min(max(neededWidth, baseWidth), maxWidth)
    }

    /// Estimated number of wrapped lines the text needs at the given pill width. Reserves one
    /// extra `averageCharacterWidth` of margin before computing characters-per-line, biasing the
    /// estimate towards slightly more lines rather than fewer — SwiftUI wraps on word boundaries,
    /// so a nearly-full line can wrap earlier than a pure character count predicts, and
    /// overestimating the line count is the safe direction (extra headroom, not a clipped line).
    static func lineCount(for text: String, width: CGFloat) -> Int {
        guard !text.isEmpty else { return 1 }
        let availableWidth = max(width - chromeWidth - averageCharacterWidth, averageCharacterWidth)
        let charactersPerLine = max(1, Int(availableWidth / averageCharacterWidth))
        let lines = Int((Double(text.count) / Double(charactersPerLine)).rounded(.up))
        return max(1, lines)
    }

    /// Height of the wrapped-text area alone for a given (1...`maxVisibleLines`-clamped) visible
    /// line count. This is the single source of truth for how tall wrapped interim text needs:
    /// the view's `ScrollView` frame (once scrolling kicks in) uses this directly, and
    /// `height(forLineCount:)` below derives the pill's total height from it too, so the two can
    /// never independently drift out of agreement and gap or clip the last line.
    static func textAreaHeight(visibleLines: Int) -> CGFloat {
        let clamped = min(max(visibleLines, 1), maxVisibleLines)
        return CGFloat(clamped) * lineHeight + wrapSlack
    }

    /// Pill height for the given (unclamped) wrapped line count: single-line text keeps the
    /// original fixed `baseHeight`, and anything beyond one line adds exactly the growth in
    /// `textAreaHeight` over its single-line value — capped at `maxVisibleLines`, beyond which
    /// the view scrolls instead of the pill growing further.
    static func height(forLineCount lineCount: Int) -> CGFloat {
        let visibleLines = min(max(lineCount, 1), maxVisibleLines)
        guard visibleLines > 1 else { return baseHeight }
        return baseHeight + (textAreaHeight(visibleLines: visibleLines) - textAreaHeight(visibleLines: 1))
    }
}
