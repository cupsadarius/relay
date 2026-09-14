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
                .frame(width: presentation.size.width, height: presentation.size.height)
                .transition(presentation.usesScaleTransition ? .scale.combined(with: .opacity) : .opacity)
        }
    }

    @ViewBuilder
    private func capsule(for presentation: ActivityOverlayPresentation) -> some View {
        HStack(spacing: 10) {
            waveform(for: presentation)

            if let title = presentation.title {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if let startedAt = presentation.startedAt {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(elapsedTime(since: startedAt, now: context.date))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let action = presentation.action, let label = presentation.actionAccessibilityLabel {
                Button {
                    Task { @MainActor in
                        await onAction(action)
                    }
                } label: {
                    Image(systemName: actionSymbol(for: action))
                        .font(.subheadline.weight(.bold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(label)
            }
        }
        .padding(.horizontal, 14)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().fill(.black.opacity(0.48)))
        .overlay(Capsule().stroke(accentColor(for: presentation.accent).opacity(0.45), lineWidth: 1))
        .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
        .foregroundStyle(accentColor(for: presentation.accent))
    }

    @ViewBuilder
    private func waveform(for presentation: ActivityOverlayPresentation) -> some View {
        switch presentation.kind {
        case let .listening(level):
            WaveformBars(values: listeningBars(level: level), color: accentColor(for: presentation.accent))
        case .speaking:
            if presentation.animatesWaveform {
                TimelineView(.animation) { context in
                    WaveformBars(values: presentation.waveformBars(at: context.date), color: accentColor(for: presentation.accent))
                }
            } else {
                WaveformBars(values: presentation.waveformBars(at: .distantPast), color: accentColor(for: presentation.accent))
            }
        case .processing:
            ProgressView().controlSize(.small)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
        }
    }

    private func listeningBars(level: Float) -> [CGFloat] {
        let height = CGFloat(min(max(level, 0), 1))
        return [0.35, 0.6, 1, 0.6, 0.35].map { 0.2 + $0 * (0.25 + height * 0.75) }
    }

    private func elapsedTime(since start: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func actionSymbol(for action: ActivityOverlayAction) -> String {
        switch action {
        case .cancelDictation: "xmark"
        case .stopSpeech: "stop.fill"
        }
    }

    private func accentColor(for accent: ActivityOverlayPresentation.Accent) -> Color {
        switch accent {
        case .red: .red
        case .amber: .orange
        case .violetCyan: .cyan
        case .error: .red
        }
    }
}

private struct WaveformBars: View {
    let values: [CGFloat]
    let color: Color

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                Capsule()
                    .fill(color)
                    .frame(width: 3, height: 18 * value)
            }
        }
        .frame(width: 25, height: 22)
    }
}
