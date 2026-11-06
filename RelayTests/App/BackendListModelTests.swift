import XCTest

@testable import Relay

@MainActor
final class BackendListModelTests: XCTestCase {
    private var order: [BackendID] = []
    private var writes: [[BackendID]] = []
    private var statusSink = StatusSink()

    override func setUp() {
        super.setUp()
        order = []
        writes = []
        statusSink = StatusSink()
    }

    private func makeList(
        _ ids: [BackendID],
        availability: [BackendID: BackendAvailability] = [:],
        refusal: String = "At least one backend must stay enabled."
    ) -> BackendListModel {
        BackendListModel(
            entries: ids.map { id in
                BackendListEntry(id: id, availability: { availability[id] ?? .available })
            },
            order: { [unowned self] in order },
            setOrder: { [unowned self] in
                order = $0; writes.append($0)
            },
            refusalMessage: refusal,
            statusSink: statusSink
        )
    }

    func testRowsListEnabledInOrderThenDisabledByID() async {
        order = [.parakeet, .appleSpeech]
        let list = makeList([.appleSpeech, .parakeet, .whisper])

        await list.refresh()

        XCTAssertEqual(list.rows.map(\.id), [.parakeet, .appleSpeech, .whisper])
        XCTAssertEqual(list.rows.map(\.isEnabled), [true, true, false])
        XCTAssertEqual(list.rows.map(\.position), [0, 1, Int.max])
        XCTAssertEqual(list.rows.map(\.state), [.ready, .ready, .ready])
    }

    func testEnablingAppendsToOrderAndPersists() async {
        order = [.appleSpeech]
        let list = makeList([.appleSpeech, .parakeet])
        await list.refresh()

        list.setEnabled(.parakeet, true)

        XCTAssertEqual(writes, [[.appleSpeech, .parakeet]])
        XCTAssertEqual(list.rows.first { $0.id == .parakeet }?.isEnabled, true)
        XCTAssertEqual(list.rows.first { $0.id == .parakeet }?.position, 1)
    }

    func testEnablingAlreadyEnabledOrUnknownIDIsANoOp() async {
        order = [.appleSpeech]
        let list = makeList([.appleSpeech])
        await list.refresh()

        list.setEnabled(.appleSpeech, true)
        list.setEnabled(.kokoro, true)

        XCTAssertTrue(writes.isEmpty)
    }

    func testMovingEnabledBackendReorders() async {
        order = [.appleSpeech, .parakeet]
        let list = makeList([.appleSpeech, .parakeet])
        await list.refresh()

        list.move(.parakeet, up: true)

        XCTAssertEqual(writes, [[.parakeet, .appleSpeech]])
        XCTAssertEqual(list.rows.map(\.id), [.parakeet, .appleSpeech])
    }

    func testMovingPastEitherEndIsANoOp() async {
        order = [.appleSpeech, .parakeet]
        let list = makeList([.appleSpeech, .parakeet])
        await list.refresh()

        list.move(.appleSpeech, up: true)
        list.move(.parakeet, up: false)

        XCTAssertTrue(writes.isEmpty)
    }

    func testCannotDisableTheLastEnabledBackend() async {
        order = [.appleSpeech]
        let list = makeList([.appleSpeech, .parakeet], refusal: "At least one TTS backend must stay enabled.")
        await list.refresh()

        list.setEnabled(.appleSpeech, false)

        XCTAssertTrue(writes.isEmpty)
        XCTAssertEqual(list.message, "At least one TTS backend must stay enabled.")
        XCTAssertEqual(statusSink.message, "At least one TTS backend must stay enabled.")
    }

    func testMessageClearsOnNextSuccessfulChange() async {
        order = [.appleSpeech]
        let list = makeList([.appleSpeech, .parakeet])
        await list.refresh()
        list.setEnabled(.appleSpeech, false)
        XCTAssertNotNil(list.message)

        list.setEnabled(.parakeet, true)

        XCTAssertNil(list.message)
    }

    func testUnregisteredIDsInSettingsOrderAreIgnoredAndDroppedOnPersist() async {
        order = [.kokoro, .appleSpeech]
        let list = makeList([.appleSpeech, .parakeet])
        await list.refresh()

        XCTAssertEqual(list.rows.map(\.id), [.appleSpeech, .parakeet])
        XCTAssertEqual(list.rows.first { $0.id == .appleSpeech }?.position, 0)

        list.setEnabled(.appleSpeech, false)
        XCTAssertTrue(writes.isEmpty, "an unregistered id must not count toward the last-enabled guard")

        list.setEnabled(.parakeet, true)
        XCTAssertEqual(writes, [[.appleSpeech, .parakeet]])
    }

    func testAvailabilityMapsToFixedStates() async {
        let cases: [(BackendAvailability, BackendStatus.State)] = [
            (.available, .ready),
            (.modelNotDownloaded, .modelNotDownloaded),
            (.unsupportedHardware, .unsupported),
            (.permissionDenied, .unavailable),
            (.unavailable("reason"), .unavailable),
            (.failed("boom"), .unavailable),
        ]
        for (availability, expected) in cases {
            let list = makeList([.appleSpeech], availability: [.appleSpeech: availability])
            await list.refresh()
            XCTAssertEqual(list.rows.first?.state, expected, "availability: \(availability)")
        }
    }

    func testStaleRefreshCannotOverwriteANewerOne() async {
        let gate = AvailabilityGate()
        let list = BackendListModel(
            entries: [BackendListEntry(id: .appleSpeech, availability: { await gate.next() })],
            order: { [.appleSpeech] },
            setOrder: { _ in },
            refusalMessage: "",
            statusSink: statusSink
        )

        let stale = Task { await list.refresh() }
        while gate.pending == nil { await Task.yield() }
        gate.value = .available
        await list.refresh()
        gate.pending?.resume()
        await stale.value

        XCTAssertEqual(list.rows.first?.state, .ready)
    }

    /// A `setEnabled` landing while `refresh()` is still awaiting a probe must win: the refresh
    /// must read the order again after its awaits, not apply the order it started with.
    func testConcurrentOrderChangeDuringRefreshIsNotClobbered() async {
        order = [.appleSpeech, .parakeet]
        let gate = AvailabilityGate()
        gate.value = .available
        let list = BackendListModel(
            entries: [
                BackendListEntry(id: .appleSpeech, availability: { await gate.next() }),
                BackendListEntry(id: .parakeet, availability: { .available }),
            ],
            order: { [unowned self] in order },
            setOrder: { [unowned self] in
                order = $0; writes.append($0)
            },
            refusalMessage: "",
            statusSink: statusSink
        )

        let refreshTask = Task { await list.refresh() }
        while gate.pending == nil { await Task.yield() }
        list.setEnabled(.parakeet, false)
        gate.pending?.resume()
        await refreshTask.value

        XCTAssertEqual(order, [.appleSpeech])
        XCTAssertEqual(list.rows.first { $0.id == .parakeet }?.isEnabled, false)
        XCTAssertEqual(list.rows.first { $0.id == .appleSpeech }?.isEnabled, true)
    }
}

/// First call suspends (returning the value captured at call time); later calls return `value`.
@MainActor
private final class AvailabilityGate {
    var value: BackendAvailability = .modelNotDownloaded
    var pending: CheckedContinuation<Void, Never>?
    private var calls = 0

    func next() async -> BackendAvailability {
        calls += 1
        let captured = value
        if calls == 1 { await withCheckedContinuation { pending = $0 } }
        return captured
    }
}
