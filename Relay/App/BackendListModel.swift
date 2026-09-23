import Foundation
import Observation

/// One backend row in Settings: its place in the user's order and its live readiness. Labels
/// and icons live in the view layer.
struct BackendStatus: Identifiable, Equatable, Sendable {
    enum State: Equatable, Sendable {
        case ready
        case modelNotDownloaded
        case unsupported
        case unavailable
    }

    let id: String
    let displayName: String
    var state: State
    var isEnabled: Bool
    var position: Int
}

/// What the list needs from a backend: identity, label, and a readiness probe. Lets one list type
/// serve both the `Sendable` STT backends and the `@MainActor` TTS backends.
struct BackendListEntry {
    let id: String
    let displayName: String
    let availability: @MainActor () async -> BackendAvailability
}

@MainActor
extension BackendListEntry {
    static func entries(_ registry: [String: any SpeechToTextBackend]) -> [BackendListEntry] {
        registry.map { id, backend in
            BackendListEntry(id: id, displayName: backend.displayName, availability: { await backend.availability() })
        }
    }

    static func entries(_ registry: [String: any TextToSpeechBackend]) -> [BackendListEntry] {
        registry.map { id, backend in
            BackendListEntry(id: id, displayName: backend.displayName, availability: { await backend.availability() })
        }
    }
}

/// The ordered, enable-able backend list for one speech domain (STT or TTS). Owns the visible rows,
/// the refusal message, and refresh race-safety; reads/writes the order through closures so the
/// settings owner stays the only writer. Model lifecycle state lives in `SpeechModelController`.
@MainActor
@Observable
final class BackendListModel {
    private(set) var rows: [BackendStatus] = []
    private(set) var message: String?

    @ObservationIgnored private let entries: [BackendListEntry]
    @ObservationIgnored private let knownIDs: Set<String>
    @ObservationIgnored private let readOrder: @MainActor () -> [String]
    @ObservationIgnored private let writeOrder: @MainActor ([String]) -> Void
    @ObservationIgnored private let refusalMessage: String
    @ObservationIgnored private let statusSink: StatusSink
    @ObservationIgnored private var generation = 0

    init(
        entries: [BackendListEntry],
        order: @escaping @MainActor () -> [String],
        setOrder: @escaping @MainActor ([String]) -> Void,
        refusalMessage: String,
        statusSink: StatusSink
    ) {
        self.entries = entries.sorted { $0.id < $1.id }
        knownIDs = Set(entries.map(\.id))
        readOrder = order
        writeOrder = setOrder
        self.refusalMessage = refusalMessage
        self.statusSink = statusSink
    }

    /// Re-probes every backend. A refresh overtaken by a newer one discards its results. The
    /// order is read again after every probe has returned, not snapshotted before the first
    /// `await`: a `setEnabled`/`move` landing while this refresh is still awaiting probes must
    /// win, not get clobbered by the order this refresh started with.
    func refresh() async {
        generation += 1
        let current = generation
        var fresh: [BackendStatus] = []
        for entry in entries {
            let availability = await entry.availability()
            fresh.append(BackendStatus(
                id: entry.id,
                displayName: entry.displayName,
                state: Self.state(for: availability),
                isEnabled: false,
                position: Int.max
            ))
        }
        guard current == generation else { return }
        let order = knownOrder()
        for index in fresh.indices {
            fresh[index].isEnabled = order.contains(fresh[index].id)
            fresh[index].position = order.firstIndex(of: fresh[index].id) ?? Int.max
        }
        rows = Self.sorted(fresh)
    }

    /// Refuses to disable the last enabled backend; unknown ids and no-op changes are ignored.
    func setEnabled(_ id: String, _ enabled: Bool) {
        guard knownIDs.contains(id) else { return }
        var order = knownOrder()
        if enabled {
            guard !order.contains(id) else { return }
            order.append(id)
        } else {
            guard order.contains(id) else { return }
            guard order.count > 1 else {
                setMessage(refusalMessage)
                return
            }
            order.removeAll { $0 == id }
        }
        apply(order)
    }

    func move(_ id: String, up: Bool) {
        var order = knownOrder()
        guard let index = order.firstIndex(of: id) else { return }
        let target = up ? index - 1 : index + 1
        guard order.indices.contains(target) else { return }
        order.swapAt(index, target)
        apply(order)
    }

    static func state(for availability: BackendAvailability) -> BackendStatus.State {
        switch availability {
        case .available: .ready
        case .modelNotDownloaded: .modelNotDownloaded
        case .unsupportedOS, .unsupportedHardware: .unsupported
        case .permissionDenied, .unavailable, .failed: .unavailable
        }
    }

    private func apply(_ order: [String]) {
        writeOrder(order)
        rows = Self.sorted(rows.map { row in
            var row = row
            row.isEnabled = order.contains(row.id)
            row.position = order.firstIndex(of: row.id) ?? Int.max
            return row
        })
        setMessage(nil)
    }

    private func setMessage(_ newMessage: String?) {
        message = newMessage
        if let newMessage { statusSink.post(newMessage) }
    }

    /// The persisted order restricted to ids this list knows, so stale ids never count.
    private func knownOrder() -> [String] {
        readOrder().filter { knownIDs.contains($0) }
    }

    /// Enabled first (configured order), then disabled alphabetically by id.
    private static func sorted(_ statuses: [BackendStatus]) -> [BackendStatus] {
        statuses.sorted { lhs, rhs in
            if lhs.isEnabled != rhs.isEnabled { return lhs.isEnabled }
            if lhs.isEnabled { return lhs.position < rhs.position }
            return lhs.id < rhs.id
        }
    }
}
