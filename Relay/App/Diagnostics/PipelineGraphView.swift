import SwiftUI

/// Colors and symbols for a step state, shared by the graph and the pills.
extension PipelineStepState {
    var tint: Color {
        switch self {
        case .pending: .secondary
        case .active: .blue
        case .done: .green
        case .stopped: .orange
        case .failed: .red
        }
    }

    var symbol: String {
        switch self {
        case .pending: "circle"
        case .active: "circle.dotted.circle"
        case .done: "checkmark.circle.fill"
        case .stopped: "minus.circle.fill"
        case .failed: "xmark.circle.fill"
        }
    }
}

enum PipelineDurationFormat {
    static func string(_ seconds: TimeInterval) -> String {
        seconds < 10 ? String(format: "%.1f s", seconds) : String(format: "%.0f s", seconds)
    }
}

/// The selected run drawn on its flow's fixed graph. Steps the run never reached stay grey.
struct PipelineGraphView: View {
    let run: PipelineRun

    private static let nodeSize = CGSize(width: 132, height: 64)
    private static let spacing = CGSize(width: 34, height: 26)

    private var graph: PipelineGraph { PipelineGraph.of(run.flow) }

    var body: some View {
        let size = canvasSize
        ScrollView(.horizontal, showsIndicators: false) {
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in drawEdges(in: &context) }
                    .frame(width: size.width, height: size.height)
                ForEach(graph.nodes, id: \.step) { node in
                    PipelineNodeView(step: node.step, status: run.status(of: node.step), isBranch: node.isBranch, level: level(for: node.step))
                        .frame(width: Self.nodeSize.width, height: Self.nodeSize.height)
                        .offset(x: origin(of: node).x, y: origin(of: node).y)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .padding(4)
        }
    }

    private func level(for step: PipelineStep) -> Float? {
        step == .recording && run.status(of: .recording).state == .active ? run.level : nil
    }

    private var canvasSize: CGSize {
        let columns = (graph.nodes.map(\.column).max() ?? 0) + 1
        let rows = (graph.nodes.map(\.row).max() ?? 0) + 1
        return CGSize(
            width: CGFloat(columns) * Self.nodeSize.width + CGFloat(columns - 1) * Self.spacing.width,
            height: CGFloat(rows) * Self.nodeSize.height + CGFloat(rows - 1) * Self.spacing.height
        )
    }

    private func origin(of node: PipelineGraph.Node) -> CGPoint {
        CGPoint(
            x: CGFloat(node.column) * (Self.nodeSize.width + Self.spacing.width),
            y: CGFloat(node.row) * (Self.nodeSize.height + Self.spacing.height)
        )
    }

    private func drawEdges(in context: inout GraphicsContext) {
        for edge in graph.edges {
            guard let from = graph.nodes.first(where: { $0.step == edge.from }),
                let to = graph.nodes.first(where: { $0.step == edge.to })
            else { continue }
            let start: CGPoint
            let end: CGPoint
            if from.row == to.row {
                start = CGPoint(x: origin(of: from).x + Self.nodeSize.width, y: origin(of: from).y + Self.nodeSize.height / 2)
                end = CGPoint(x: origin(of: to).x, y: origin(of: to).y + Self.nodeSize.height / 2)
            } else if from.row < to.row {
                start = CGPoint(x: origin(of: from).x + Self.nodeSize.width / 2, y: origin(of: from).y + Self.nodeSize.height)
                end = CGPoint(x: origin(of: to).x + Self.nodeSize.width / 2, y: origin(of: to).y)
            } else {
                start = CGPoint(x: origin(of: from).x + Self.nodeSize.width, y: origin(of: from).y + Self.nodeSize.height / 2)
                end = CGPoint(x: origin(of: to).x + Self.nodeSize.width / 2, y: origin(of: to).y + Self.nodeSize.height)
            }
            var path = Path()
            path.move(to: start)
            if from.row == to.row || from.row < to.row {
                path.addLine(to: end)
            } else {
                path.addQuadCurve(to: end, control: CGPoint(x: end.x, y: start.y))
            }
            let reached = run.status(of: edge.to).state != .pending
            let color = reached ? Color.green.opacity(0.7) : Color.secondary.opacity(0.5)
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.5, dash: edge.isBranch ? [4, 3] : []))
            drawArrowhead(
                at: end,
                from: from.row == to.row
                    ? CGPoint(x: end.x - 1, y: end.y) : (from.row < to.row ? CGPoint(x: end.x, y: end.y - 1) : CGPoint(x: end.x, y: end.y + 1)), color: color,
                in: &context)
        }
    }

    private func drawArrowhead(at tip: CGPoint, from previous: CGPoint, color: Color, in context: inout GraphicsContext) {
        let angle = atan2(tip.y - previous.y, tip.x - previous.x)
        let length: CGFloat = 7
        var head = Path()
        head.move(to: tip)
        head.addLine(to: CGPoint(x: tip.x - length * cos(angle - .pi / 7), y: tip.y - length * sin(angle - .pi / 7)))
        head.addLine(to: CGPoint(x: tip.x - length * cos(angle + .pi / 7), y: tip.y - length * sin(angle + .pi / 7)))
        head.closeSubpath()
        context.fill(head, with: .color(color))
    }
}

/// One step node: title, live detail, and the elapsed or final time.
struct PipelineNodeView: View {
    let step: PipelineStep
    let status: PipelineStepStatus
    let isBranch: Bool
    let level: Float?

    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: status.state.symbol).foregroundStyle(status.state.tint)
                Text(step.title).font(.caption.weight(.semibold))
                Spacer(minLength: 0)
                timing.font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(status.detail.isEmpty ? " " : status.detail)
                .font(.caption2)
                .foregroundStyle(status.state == .pending ? .tertiary : .secondary)
                .lineLimit(2)
            if let level {
                ProgressView(value: Double(min(max(level, 0), 1))).progressViewStyle(.linear).tint(.blue)
            }
        }
        .padding(7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(status.state == .pending ? Color.secondary.opacity(0.08) : status.state.tint.opacity(0.14))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    status.state.tint.opacity(status.state == .active ? (pulse ? 1 : 0.35) : 0.5),
                    style: StrokeStyle(lineWidth: status.state == .active ? 2 : 1, dash: isBranch && status.state == .pending ? [4, 3] : [])
                )
        )
        .onAppear { startPulse() }
        .onChange(of: status.state) { startPulse() }
        .help(status.detail)
    }

    @ViewBuilder private var timing: some View {
        if status.state == .active, let startedAt = status.startedAt {
            TimelineView(.periodic(from: .now, by: 0.1)) { context in
                Text(PipelineDurationFormat.string(context.date.timeIntervalSince(startedAt)))
            }
        } else if let startedAt = status.startedAt, let endedAt = status.endedAt, endedAt.timeIntervalSince(startedAt) >= 0.05 {
            Text(PipelineDurationFormat.string(endedAt.timeIntervalSince(startedAt)))
        }
    }

    private func startPulse() {
        guard status.state == .active else {
            pulse = false
            return
        }
        withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulse = true }
    }
}

/// One compact row per run: flow, time, and a pill per reached step.
struct PipelineRunRow: View {
    let run: PipelineRun
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(run.flow.title).font(.callout.weight(.semibold))
                if run.isLive { Text("live").font(.caption2.weight(.bold)).foregroundStyle(.blue) }
                Spacer()
                Text(run.startedAt, format: .dateTime.hour().minute().second()).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            PillFlow(spacing: 4) {
                ForEach(run.reachedSteps, id: \.self) { step in
                    let status = run.status(of: step)
                    Text(status.detail.isEmpty ? step.title : "\(step.title) · \(status.detail)")
                        .font(.caption2)
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(status.state.tint.opacity(0.16)))
                        .foregroundStyle(status.state == .pending ? Color.secondary : status.state.tint)
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(isSelected ? 0.16 : 0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1))
        .contentShape(Rectangle())
    }
}

/// Wraps pills onto new lines when the row is too narrow.
struct PillFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, point) in zip(subviews, arrange(subviews, width: bounds.width).points) {
            subview.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (points: [CGPoint], size: CGSize) {
        var points: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return (points, CGSize(width: maxX, height: y + rowHeight))
    }
}
