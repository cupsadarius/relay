import SwiftUI

struct ActivityOverlayView: View {
    let model: ActivityOverlayModel
    let style: ActivityOverlayStyle
    let onAction: @MainActor (ActivityOverlayAction) async -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let presentation = ActivityOverlayPresentation.make(
            state: model.state, style: style, reduceMotion: reduceMotion
        ) {
            capsule(for: presentation)
                .transition(presentation.usesScaleTransition ? .scale.combined(with: .opacity) : .opacity)
        }
    }

    @ViewBuilder
    private func capsule(for presentation: ActivityOverlayPresentation) -> some View {
        Group {
            if presentation.title != nil {
                interactiveLayout(for: presentation)
            } else {
                minimalLayout(for: presentation)
            }
        }
        .frame(width: presentation.size.width, height: presentation.size.height)
        .background {
            RoundedRectangle(cornerRadius: presentation.cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: presentation.cornerRadius, style: .continuous)
                .fill(OverlayPalette.chromeFill)
        }
        .overlay(
            RoundedRectangle(cornerRadius: presentation.cornerRadius, style: .continuous)
                .stroke(OverlayPalette.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.6), radius: 12, y: 6)
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private func minimalLayout(for presentation: ActivityOverlayPresentation) -> some View {
        HStack(spacing: 11) {
            StateDot(color: OverlayPalette.dotColor(for: presentation.accent), reduceMotion: reduceMotion)
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
                Button {
                    Task { @MainActor in
                        await onAction(action)
                    }
                } label: {
                    ZStack {
                        Circle().fill(OverlayPalette.buttonFill)
                        actionGlyph(for: action)
                    }
                    .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .contentShape(Circle())
                .accessibilityLabel(label)
            }
        }
        .padding(.horizontal, 15)
    }

    @ViewBuilder
    private func actionGlyph(for action: ActivityOverlayAction) -> some View {
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

/// Small hex-friendly color constants matching the design mockup exactly.
private enum OverlayPalette {
    static let chromeFill = Color(hex: 0x17171B, opacity: 0.94)
    static let border = Color(hex: 0xFFFFFF, opacity: 0.17)
    static let buttonFill = Color(hex: 0x393940)
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

/// The 9pt state dot shown in the Minimal capsule: a colored, glowing circle that gently pulses
/// unless Reduce Motion is on.
private struct StateDot: View {
    let color: Color
    let reduceMotion: Bool
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .shadow(color: color.opacity(0.9), radius: 7)
            .opacity(isPulsing ? 0.5 : 1)
            .scaleEffect(isPulsing ? 0.8 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
            }
    }
}

/// The shared 7-bar waveform, rendered differently per `ActivityOverlayPresentation.Kind`:
/// Listening scales with live mic level, Speaking replays a synthetic per-bar phase animation,
/// Processing breathes uniformly in place of the old spinner, and Error sits static and dimmed.
private struct WaveformView: View {
    let presentation: ActivityOverlayPresentation
    @State private var isBreathing = false

    var body: some View {
        switch presentation.kind {
        case .listening:
            WaveformBars(scales: presentation.listeningWaveformBars())
        case .speaking:
            if presentation.animatesWaveform {
                TimelineView(.animation) { context in
                    WaveformBars(scales: presentation.waveformBars(at: context.date))
                }
            } else {
                WaveformBars(scales: Self.restScales)
            }
        case .processing:
            if presentation.animatesWaveform {
                WaveformBars(
                    scales: Array(repeating: isBreathing ? 0.34 : 1, count: 7),
                    opacity: isBreathing ? 0.65 : 1
                )
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: isBreathing)
                .onAppear { isBreathing = true }
            } else {
                WaveformBars(scales: Self.restScales)
            }
        case .error:
            WaveformBars(scales: Self.restScales, opacity: 0.5)
        }
    }

    private static let restScales = Array(repeating: CGFloat(1), count: 7)
}

/// Renders the 7 bars themselves from a rest-height baseline and a per-bar scale multiplier.
private struct WaveformBars: View {
    let scales: [CGFloat]
    var opacity: Double = 1

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(ActivityOverlayPresentation.waveformRestHeights.enumerated()), id: \.offset) { index, restHeight in
                RoundedRectangle(cornerRadius: 3)
                    .fill(OverlayPalette.waveformGradient)
                    .frame(width: 3, height: restHeight * scale(at: index))
            }
        }
        .frame(height: 25)
        .opacity(opacity)
    }

    private func scale(at index: Int) -> CGFloat {
        index < scales.count ? scales[index] : 1
    }
}
