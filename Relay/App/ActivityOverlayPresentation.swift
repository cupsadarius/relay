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
        case let .error(_, _, message):
            return .init(
                kind: .error, accent: .error, size: size,
                title: interactive ? sanitizedErrorMessage(message) : nil, startedAt: nil,
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

    private static func sanitizedErrorMessage(_ message: String) -> String {
        let words = message.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        return words.isEmpty ? "Something went wrong" : words.joined(separator: " ")
    }
}
