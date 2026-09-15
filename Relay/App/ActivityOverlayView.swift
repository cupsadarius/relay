import SwiftUI

struct ActivityOverlayView: View {
    let model: ActivityOverlayModel
    let style: ActivityOverlayStyle
    let onAction: @MainActor (ActivityOverlayAction) async -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let presentation = ActivityOverlayPresentation.make(
            state: model.state, style: style, reduceMotion: reduceMotion, backendName: model.backendName
        ) {
            capsule(for: presentation)
                .transition(presentation.usesScaleTransition ? .scale.combined(with: .opacity) : .opacity)
        }
    }

    @ViewBuilder
    private func capsule(for presentation: ActivityOverlayPresentation) -> some View {
        Group {
            switch presentation.layout {
            case .interactive:
                interactiveLayout(for: presentation)
            case .minimal:
                minimalLayout(for: presentation)
            }
        }
        .frame(width: presentation.size.width, height: presentation.size.height)
        .background {
            RoundedRectangle(cornerRadius: presentation.cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: presentation.cornerRadius, style: .continuous)
                .fill(OverlayPalette.chromeFill)
                .shadow(color: .black.opacity(0.6), radius: 12, y: 6)
        }
        .overlay(
            RoundedRectangle(cornerRadius: presentation.cornerRadius, style: .continuous)
                .strokeBorder(OverlayPalette.border, lineWidth: 1)
                .allowsHitTesting(false)
        )
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private func minimalLayout(for presentation: ActivityOverlayPresentation) -> some View {
        HStack(spacing: 11) {
            if presentation.accent == .error {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(OverlayPalette.dotError)
            } else {
                StateDot(color: OverlayPalette.dotColor(for: presentation.accent), pulses: !reduceMotion)
            }
            WaveformView(presentation: presentation)
        }
    }

    @ViewBuilder
    private func interactiveLayout(for presentation: ActivityOverlayPresentation) -> some View {
        HStack(spacing: 13) {
            WaveformView(presentation: presentation)

            VStack(alignment: .leading, spacing: 2) {
                if let title = presentation.title {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                if let subtitle = presentation.subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(OverlayPalette.subtitleText)
                        .lineLimit(1)
                }
            }
            .frame(minWidth: 91, alignment: .leading)

            Spacer(minLength: 0)

            if let startedAt = presentation.startedAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(ActivityOverlayPresentation.elapsedTime(since: startedAt, now: context.date))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(OverlayPalette.timeText)
                }
            }

            if let action = presentation.action, let label = presentation.actionAccessibilityLabel {
                OverlayActionButton(action: action, label: label, onAction: onAction)
            }
        }
        .padding(.horizontal, 15)
    }
}

/// The 30pt round capsule action button (Stop / Cancel). Owns its own hover state so SwiftUI
/// resets it whenever the button leaves the screen (the surrounding `if let` in
/// `interactiveLayout` removes and later reinserts this view rather than mutating it in place).
private struct OverlayActionButton: View {
    let action: ActivityOverlayAction
    let label: String
    let onAction: @MainActor (ActivityOverlayAction) async -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        Button {
            Task { @MainActor in
                await onAction(action)
            }
        } label: {
            ZStack {
                Circle()
                    .fill(isHovered ? OverlayPalette.buttonHover : OverlayPalette.buttonFill)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
                glyph
            }
            .frame(width: 30, height: 30)
        }
        .buttonStyle(OverlayActionButtonStyle(reduceMotion: reduceMotion))
        .contentShape(Circle())
        .accessibilityLabel(label)
        .help(label)
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var glyph: some View {
        switch action {
        case .stopSpeech:
            RoundedRectangle(cornerRadius: 2)
                .fill(.white)
                .frame(width: 8, height: 8)
        case .cancelDictation:
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
        }
    }
}

/// Scales the button down while pressed; suppressed under Reduce Motion per the same convention
/// used for the hover fill animation above.
private struct OverlayActionButtonStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Small hex-friendly color constants matching the design mockup exactly.
private enum OverlayPalette {
    static let chromeFill = Color(hex: 0x17171B, opacity: 0.94)
    static let border = Color(hex: 0xFFFFFF, opacity: 0.17)
    static let buttonFill = Color(hex: 0x393940)
    static let buttonHover = Color(hex: 0xFF5261)
    static let subtitleText = Color(hex: 0xA9AAB2)
    static let timeText = Color(hex: 0xC8C9D0)

    static let waveformGradient = LinearGradient(
        colors: [Color(hex: 0x7DEAFF), Color(hex: 0x9781FF)],
        startPoint: .top, endPoint: .bottom
    )

    static let dotListening = Color(hex: 0xFF5261)
    static let dotProcessing = Color(hex: 0xFFB340)
    static let dotSpeaking = Color(hex: 0x9781FF)
    static let dotError = Color(hex: 0xFF5261)

    static func dotColor(for accent: ActivityOverlayPresentation.Accent) -> Color {
        switch accent {
        case .red: dotListening
        case .amber: dotProcessing
        case .violetCyan: dotSpeaking
        case .error: dotError
        }
    }
}

private extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

/// The 9pt state dot shown in the Minimal capsule (non-error states): a colored, glowing circle
/// that gently pulses unless Reduce Motion is on. The `.animation(value:)` + plain `onAppear`
/// assignment (rather than wrapping the assignment in `withAnimation`) keeps the pulse running
/// across later updates that only change `color` — a `withAnimation` block tied to the one-time
/// `onAppear` call can otherwise be implicitly cancelled by an unrelated property change.
private struct StateDot: View {
    let color: Color
    let pulses: Bool
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .shadow(color: color.opacity(0.9), radius: 7)
            .opacity(isPulsing ? 0.5 : 1)
            .scaleEffect(isPulsing ? 0.8 : 1)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear {
                guard pulses else { return }
                isPulsing = true
            }
    }
}

/// The shared 7-bar waveform, rendered differently per `ActivityOverlayPresentation.Kind`:
/// Listening scales with live mic level, Speaking replays a synthetic per-bar phase animation,
/// Processing breathes uniformly in place of the old spinner, and Error sits static and dimmed.
private struct WaveformView: View {
    let presentation: ActivityOverlayPresentation

    var body: some View {
        switch presentation.kind {
        case let .listening(level):
            WaveformBars(scales: presentation.listeningWaveformBars())
                .animation(presentation.animatesWaveform ? .linear(duration: 0.08) : nil, value: level)
        case .speaking:
            if let level = presentation.speakingLevel {
                WaveformBars(scales: presentation.speakingLevelBars())
                    .animation(presentation.animatesWaveform ? .linear(duration: 0.08) : nil, value: level)
            } else if presentation.animatesWaveform {
                TimelineView(.animation) { context in
                    let scales = presentation.waveformBars(at: context.date)
                    WaveformBars(scales: scales, opacities: scales.map(Self.speakingOpacity))
                }
            } else {
                WaveformBars(scales: Self.restScales)
            }
        case .processing:
            if presentation.animatesWaveform {
                ProcessingWaveform()
            } else {
                WaveformBars(scales: Self.restScales)
            }
        case .error:
            WaveformBars(scales: Self.restScales, opacities: Self.dimOpacities)
        }
    }

    private static let restScales = Array(repeating: CGFloat(1), count: 7)
    private static let dimOpacities = Array(repeating: 0.5, count: 7)

    /// The mockup's `wave` keyframe moves opacity (0.65...1) in lockstep with scale (0.34...1).
    private static func speakingOpacity(forScale scale: CGFloat) -> Double {
        0.65 + Double((scale - 0.34) / 0.66) * 0.35
    }
}

/// Owns its own animation state so SwiftUI resets it whenever this view is removed and later
/// reinserted (e.g. Processing ends and starts again): a `@State` living on the shared
/// `WaveformView` instead would persist `isBreathing == true` across that gap, leaving the next
/// Processing pass rendered as a frozen, dim set of bars instead of a fresh breathing animation.
private struct ProcessingWaveform: View {
    @State private var isBreathing = false

    var body: some View {
        WaveformBars(
            scales: Array(repeating: isBreathing ? 0.34 : 1, count: 7),
            opacities: Array(repeating: isBreathing ? 0.65 : 1, count: 7)
        )
        .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: isBreathing)
        .onAppear { isBreathing = true }
    }
}

/// Renders the 7 bars themselves from a rest-height baseline and a per-bar scale multiplier.
private struct WaveformBars: View {
    let scales: [CGFloat]
    var opacities: [Double] = Self.fullOpacities

    private static let fullOpacities = Array(repeating: 1.0, count: 7)

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(ActivityOverlayPresentation.waveformRestHeights.enumerated()), id: \.offset) { index, restHeight in
                RoundedRectangle(cornerRadius: 3)
                    .fill(OverlayPalette.waveformGradient)
                    .frame(width: 3, height: restHeight * scale(at: index))
                    .opacity(opacity(at: index))
            }
        }
        .frame(height: 25)
    }

    private func scale(at index: Int) -> CGFloat {
        index < scales.count ? scales[index] : 1
    }

    private func opacity(at index: Int) -> Double {
        index < opacities.count ? opacities[index] : 1
    }
}
