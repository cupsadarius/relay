import AppKit
import SwiftUI

/// Live view of the pipeline: flow toggles and a permission status on top, the selected run's
/// graph, the run list, and the raw logs out of the way at the bottom. It only renders
/// `PipelineRunStore`; it owns no pipeline logic.
struct DiagnosticsView: View {
    static let accessibilityPermissionLabel = "Accessibility"

    @Bindable var model: AppModel
    /// Comma-separated raw values of the flows the user turned off.
    @AppStorage("diagnostics.hiddenFlows") private var hiddenFlowsRaw = ""
    @State private var selection: (id: UUID, at: Date)?
    @State private var showsPermissions = false
    @State private var integrationDiagnosticsEntries: [IntegrationDiagnosticsEntry] = []

    private var store: PipelineRunStore { model.pipelineRuns }

    private var visibleFlows: Set<PipelineFlow> {
        let hidden = Set(hiddenFlowsRaw.split(separator: ",").compactMap { PipelineFlow(rawValue: String($0)) })
        return Set(PipelineFlow.allCases).subtracting(hidden)
    }

    private var permissionsOK: Bool {
        model.permissions.snapshot.globalHotkeysGranted && model.hotkeys.eventTapStatus == .registered
            && model.permissions.microphoneGranted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            topBar
            if showsPermissions || !permissionsOK { permissionDetails }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                graphSection(now: context.date)
            }
            runList
            rawEvents
        }
        .padding(16)
        .frame(minWidth: 820, minHeight: 640, alignment: .topLeading)
        .task { integrationDiagnosticsEntries = model.integrationDiagnosticsEntries() }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 8) {
            ForEach(PipelineFlow.allCases) { flow in
                Toggle(flow.title, isOn: visibility(of: flow)).toggleStyle(.button)
            }
            Spacer()
            Button {
                showsPermissions.toggle()
            } label: {
                Label(
                    permissionsOK ? "All permissions OK" : "Permissions need attention",
                    systemImage: permissionsOK ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(permissionsOK ? .green : .red)
            }
            .buttonStyle(.borderless)
        }
    }

    private func visibility(of flow: PipelineFlow) -> Binding<Bool> {
        Binding(
            get: { visibleFlows.contains(flow) },
            set: { isOn in
                var hidden = Set(PipelineFlow.allCases).subtracting(visibleFlows)
                if isOn { hidden.remove(flow) } else { hidden.insert(flow) }
                hiddenFlowsRaw = hidden.map(\.rawValue).sorted().joined(separator: ",")
            }
        )
    }

    private var permissionDetails: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                permissionRow("Global hotkeys", model.permissions.snapshot.globalHotkeysGranted)
                permissionRow(Self.accessibilityPermissionLabel, model.permissions.snapshot.accessibilityGranted)
                permissionRow("Input Monitoring (optional)", model.permissions.snapshot.inputMonitoringGranted, optional: true)
                permissionRow("Keyboard event tap", model.hotkeys.eventTapStatus == .registered)
                permissionRow("Microphone", model.permissions.microphoneGranted)
                HStack {
                    Button("Request Accessibility") { model.permissions.requestAccessibility() }
                    Button("Recheck / Retry") { model.recheckDiagnostics() }
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func permissionRow(_ title: String, _ granted: Bool, optional: Bool = false) -> some View {
        Label {
            Text("\(title): \(granted ? "Granted" : "Not granted")")
        } icon: {
            Image(systemName: granted ? "checkmark.circle.fill" : (optional ? "circle" : "xmark.circle.fill"))
                .foregroundStyle(granted ? .green : (optional ? .secondary : .red))
        }
        .font(.callout)
    }

    // MARK: Graph

    @ViewBuilder private func graphSection(now: Date) -> some View {
        let run = PipelineRunStore.displayedRun(in: store.runs, visible: visibleFlows, selected: selection, now: now)
        GroupBox {
            if let run {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(run.flow.title).font(.headline)
                        Text(run.startedAt, format: .dateTime.hour().minute().second()).foregroundStyle(.secondary)
                        if run.isLive { Text("live").font(.caption.weight(.bold)).foregroundStyle(.blue) }
                        Spacer()
                    }
                    PipelineGraphView(run: run)
                    if let reason = stopReason(of: run) {
                        Label(reason.text, systemImage: reason.state.symbol)
                            .font(.callout)
                            .foregroundStyle(reason.state.tint)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Dictate, read a selection, or wait for an agent reply. Each run shows up here live.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 90)
            }
        }
    }

    private func stopReason(of run: PipelineRun) -> (text: String, state: PipelineStepState)? {
        for step in run.reachedSteps {
            let status = run.status(of: step)
            if status.state == .failed { return ("\(step.title) failed: \(status.detail)", .failed) }
            if status.state == .stopped { return ("Stopped at \(step.title): \(status.detail)", .stopped) }
        }
        return nil
    }

    // MARK: Run list

    private var runList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(store.runs.filter { visibleFlows.contains($0.flow) }) { run in
                    PipelineRunRow(run: run, isSelected: selection?.id == run.id)
                        .onTapGesture { selection = (run.id, .now) }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: Raw events

    private var rawEvents: some View {
        DisclosureGroup("Raw events") {
            VStack(alignment: .leading, spacing: 8) {
                Text(
                    "Hotkey events received: \(model.diagnosticsCounters.received)  matched: \(model.diagnosticsCounters.matched)  dispatched: \(model.diagnosticsCounters.dispatched)"
                )
                .font(.caption)
                List {
                    Section("Pipeline events") {
                        ForEach(Array(store.rawEvents.reversed().enumerated()), id: \.offset) { _, event in
                            Text(Self.line(for: event)).font(.caption.monospaced())
                        }
                    }
                    Section("App events") {
                        ForEach(model.diagnosticsEntries) { Text($0.copyLine()).font(.caption.monospaced()) }
                    }
                    Section("Agent hook socket") {
                        ForEach(integrationDiagnosticsEntries) { entry in
                            Text("\(DiagnosticTimestampFormatter.local.string(from: entry.timestamp)) [\(entry.stage)] \(entry.outcome) — \(entry.detail)")
                                .font(.caption.monospaced())
                        }
                    }
                }
                .frame(height: 220)
                HStack {
                    Button("Refresh hook log") { integrationDiagnosticsEntries = model.integrationDiagnosticsEntries() }
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(copyText, forType: .string)
                    }
                    Button("Clear") {
                        store.clear()
                        model.clearDiagnostics()
                        model.clearIntegrationDiagnostics()
                        integrationDiagnosticsEntries = []
                        selection = nil
                    }
                }
            }
            .padding(.top, 6)
        }
    }

    private var copyText: String {
        (store.rawEvents.map(Self.line(for:)) + [""] + [model.diagnosticsCopyText]).joined(separator: "\n")
    }

    private static func line(for event: PipelineEvent) -> String {
        let phase: String
        switch event.phase {
        case let .started(detail): phase = "started — \(detail)"
        case let .updated(detail): phase = "updated — \(detail)"
        case let .level(value): phase = "level \(value)"
        case let .finished(detail): phase = "finished — \(detail)"
        case let .stopped(reason): phase = "stopped — \(reason)"
        case let .failed(reason): phase = "failed — \(reason)"
        }
        return "\(DiagnosticTimestampFormatter.local.string(from: event.at)) \(event.flow.title) · \(event.step.title) · \(phase)"
    }
}
