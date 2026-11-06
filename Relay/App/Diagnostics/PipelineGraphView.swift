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

/// The selected run drawn on its flow's fixed graph, scaled to the available width. Steps the
/// run never reached stay grey.
struct PipelineGraphView: View {
    let run: PipelineRun

    var body: some View {
        let graph = PipelineGraph.of(run.flow)
        let rows = (graph.nodes.map(\.row).max() ?? 0) + 1
        GeometryReader { proxy in
            PipelineGraphCanvas(run: run, graph: graph, width: proxy.size.width)
        }
        .frame(height: CGFloat(rows) * PipelineGraphCanvas.nodeHeight + CGFloat(rows - 1) * PipelineGraphCanvas.rowSpacing)
    }
}

private struct PipelineGraphCanvas: View {
    static let nodeHeight: CGFloat = 78
    static let rowSpacing: CGFloat = 22

    let run: PipelineRun
    let graph: PipelineGraph
    let width: CGFloat

    private var columns: Int { (graph.nodes.map(\.column).max() ?? 0) + 1 }
    private var spacing: CGSize { CGSize(width: columns > 5 ? 18 : 26, height: Self.rowSpacing) }
    private var nodeSize: CGSize {
        let available = width - CGFloat(columns - 1) * spacing.width
        return CGSize(width: max(70, available / CGFloat(columns)), height: Self.nodeHeight)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in drawEdges(in: &context) }
            ForEach(graph.nodes, id: \.step) { node in
                PipelineNodeView(step: node.step, status: run.status(of: node.step), isBranch: node.isBranch, level: level(for: node.step))
                    .frame(width: nodeSize.width, height: nodeSize.height)
                    .offset(x: origin(of: node).x, y: origin(of: node).y)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func level(for step: PipelineStep) -> Float? {
        step == .recording && run.status(of: .recording).state == .active ? run.level : nil
    }

    private func origin(of node: PipelineGraph.Node) -> CGPoint {
        CGPoint(
            x: CGFloat(node.column) * (nodeSize.width + spacing.width),
            y: CGFloat(node.row) * (nodeSize.height + spacing.height)
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
                start = CGPoint(x: origin(of: from).x + nodeSize.width, y: origin(of: from).y + nodeSize.height / 2)
                end = CGPoint(x: origin(of: to).x, y: origin(of: to).y + nodeSize.height / 2)
            } else if from.row < to.row {
                start = CGPoint(x: origin(of: from).x + nodeSize.width / 2, y: origin(of: from).y + nodeSize.height)
                end = CGPoint(x: origin(of: to).x + nodeSize.width / 2, y: origin(of: to).y)
            } else {
                start = CGPoint(x: origin(of: from).x + nodeSize.width, y: origin(of: from).y + nodeSize.height / 2)
                end = CGPoint(x: origin(of: to).x + nodeSize.width / 2, y: origin(of: to).y + nodeSize.height)
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

    var body: some View {
        if status.state == .active {
            TimelineView(.animation(minimumInterval: 1 / 15)) { context in
                card(pulse: (sin(context.date.timeIntervalSinceReferenceDate * .pi / 0.7) + 1) / 2)
            }
        } else {
            card(pulse: 0)
        }
    }

    /// `pulse` runs 0...1 on the active node only, so no animation outlives the step.
    private func card(pulse: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: status.state.symbol).foregroundStyle(status.state.tint)
                Text(step.title).font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
            }
            Text(status.detail.isEmpty ? " " : status.detail)
                .font(.caption2)
                .foregroundStyle(status.state == .pending ? .tertiary : .secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                if let level {
                    ProgressView(value: Double(min(max(level, 0), 1))).progressViewStyle(.linear).tint(.blue)
                }
                Spacer(minLength: 0)
                timing.font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
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
                    status.state.tint.opacity(status.state == .active ? 0.35 + 0.65 * pulse : 0.5),
                    style: StrokeStyle(lineWidth: status.state == .active ? 2 : 1, dash: isBranch && status.state == .pending ? [4, 3] : [])
                )
        )
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
