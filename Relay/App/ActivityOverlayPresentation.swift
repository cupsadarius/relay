import CoreGraphics
import Foundation

struct ActivityOverlayPresentation: Equatable {
    enum Kind: Equatable {
        case listening(level: Float)
        case processing
        case speaking
        case error
    }

    enum Accent: Equatable {
        case red
        case amber
        case violetCyan
        case error
    }

    enum AccentColor: Equatable {
        case red
        case amber
        case violet
        case cyan
    }

    let kind: Kind
    let accent: Accent
    let size: CGSize
    let title: String?
    let startedAt: Date?
    let action: ActivityOverlayAction?
    let actionAccessibilityLabel: String?
    let animatesWaveform: Bool
    let usesScaleTransition: Bool

    static func make(
        state: ActivityOverlayState,
        style: ActivityOverlayStyle,
        reduceMotion: Bool
    ) -> Self? {
        guard style != .off, !state.isHidden else { return nil }

        let interactive = style == .interactive
        let size = interactive ? CGSize(width: 282, height: 62) : CGSize(width: 154, height: 40)
        let scaleTransition = !reduceMotion

        switch state {
        case .hidden:
            return nil
        case let .listening(sessionID, startedAt, level):
            return .init(
                kind: .listening(level: level), accent: .red, size: size,
                title: interactive ? "Listening" : nil, startedAt: startedAt,
                action: interactive ? .cancelDictation(sessionID: sessionID) : nil,
                actionAccessibilityLabel: interactive ? "Cancel dictation" : nil,
                animatesWaveform: !reduceMotion, usesScaleTransition: scaleTransition
            )
        case let .processing(sessionID, startedAt):
            return .init(
                kind: .processing, accent: .amber, size: size,
                title: interactive ? "Processing" : nil, startedAt: startedAt,
                action: interactive ? .cancelDictation(sessionID: sessionID) : nil,
                actionAccessibilityLabel: interactive ? "Cancel dictation" : nil,
                animatesWaveform: false, usesScaleTransition: scaleTransition
            )
        case let .speaking(sessionID, startedAt):
            return .init(
                kind: .speaking, accent: .violetCyan, size: size,
                title: interactive ? "Speaking" : nil, startedAt: startedAt,
                action: interactive ? .stopSpeech(sessionID: sessionID) : nil,
                actionAccessibilityLabel: interactive ? "Stop speech" : nil,
                animatesWaveform: !reduceMotion, usesScaleTransition: scaleTransition
            )
        case let .error(_, category, _):
            return .init(
                kind: .error, accent: .error, size: size,
                title: interactive ? errorDisplayCopy(for: category) : nil, startedAt: nil,
                action: nil, actionAccessibilityLabel: nil,
                animatesWaveform: false, usesScaleTransition: scaleTransition
            )
        }
    }

    func waveformBars(at date: Date) -> [CGFloat] {
        guard case .speaking = kind else { return [] }
        let time = date.timeIntervalSinceReferenceDate
        return (0..<5).map { index in
            let phase = time * 5.5 + Double(index) * 1.37
            return CGFloat(0.35 + (sin(phase) + 1) * 0.325)
        }
    }

    func listeningWaveformBars() -> [CGFloat] {
        guard case let .listening(level) = kind else { return [] }
        guard animatesWaveform else { return [0.35, 0.6, 1, 0.6, 0.35] }

        let height = CGFloat(min(max(level, 0), 1))
        return [0.35, 0.6, 1, 0.6, 0.35].map { 0.2 + $0 * (0.25 + height * 0.75) }
    }

    var accentColors: [AccentColor] {
        switch accent {
        case .red, .error: [.red]
        case .amber: [.amber]
        case .violetCyan: [.violet, .cyan]
        }
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
}
