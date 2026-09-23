import XCTest
@testable import Relay

@MainActor
final class BackendListModelTests: XCTestCase {
    private var order: [String] = []
    private var writes: [[String]] = []
    private var statusSink = StatusSink()

    override func setUp() {
        super.setUp()
        order = []
        writes = []
        statusSink = StatusSink()
    }

    private func makeList(
        _ ids: [String],
        availability: [String: BackendAvailability] = [:],
        refusal: String = "At least one backend must stay enabled."
    ) -> BackendListModel {
        BackendListModel(
            entries: ids.map { id in
                BackendListEntry(id: id, displayName: id.uppercased(), availability: { availability[id] ?? .available })
            },
            order: { [unowned self] in order },
            setOrder: { [unowned self] in order = $0; writes.append($0) },
            refusalMessage: refusal,
            statusSink: statusSink
        )
    }

    func testRowsListEnabledInOrderThenDisabledByID() async {
        order = ["b", "a"]
        let list = makeList(["a", "b", "c"])

        await list.refresh()

        XCTAssertEqual(list.rows.map(\.id), ["b", "a", "c"])
        XCTAssertEqual(list.rows.map(\.isEnabled), [true, true, false])
        XCTAssertEqual(list.rows.map(\.position), [0, 1, Int.max])
        XCTAssertEqual(list.rows.map(\.displayName), ["B", "A", "C"])
        XCTAssertEqual(list.rows.map(\.state), [.ready, .ready, .ready])
    }

    func testEnablingAppendsToOrderAndPersists() async {
        order = ["a"]
        let list = makeList(["a", "b"])
        await list.refresh()

        list.setEnabled("b", true)

        XCTAssertEqual(writes, [["a", "b"]])
        XCTAssertEqual(list.rows.first { $0.id == "b" }?.isEnabled, true)
        XCTAssertEqual(list.rows.first { $0.id == "b" }?.position, 1)
    }

    func testEnablingAlreadyEnabledOrUnknownIDIsANoOp() async {
        order = ["a"]
        let list = makeList(["a"])
        await list.refresh()

        list.setEnabled("a", true)
        list.setEnabled("ghost", true)

        XCTAssertTrue(writes.isEmpty)
    }

    func testMovingEnabledBackendReorders() async {
        order = ["a", "b"]
        let list = makeList(["a", "b"])
        await list.refresh()

        list.move("b", up: true)

        XCTAssertEqual(writes, [["b", "a"]])
        XCTAssertEqual(list.rows.map(\.id), ["b", "a"])
    }

    func testMovingPastEitherEndIsANoOp() async {
        order = ["a", "b"]
        let list = makeList(["a", "b"])
        await list.refresh()

        list.move("a", up: true)
        list.move("b", up: false)

        XCTAssertTrue(writes.isEmpty)
    }

    func testCannotDisableTheLastEnabledBackend() async {
        order = ["a"]
        let list = makeList(["a", "b"], refusal: "At least one TTS backend must stay enabled.")
        await list.refresh()

        list.setEnabled("a", false)

        XCTAssertTrue(writes.isEmpty)
        XCTAssertEqual(list.message, "At least one TTS backend must stay enabled.")
        XCTAssertEqual(statusSink.message, "At least one TTS backend must stay enabled.")
    }

    func testMessageClearsOnNextSuccessfulChange() async {
        order = ["a"]
        let list = makeList(["a", "b"])
        await list.refresh()
        list.setEnabled("a", false)
        XCTAssertNotNil(list.message)

        list.setEnabled("b", true)

        XCTAssertNil(list.message)
    }

    func testUnknownIDsInSettingsOrderAreIgnoredAndDroppedOnPersist() async {
        order = ["ghost", "a"]
        let list = makeList(["a", "b"])
        await list.refresh()

        XCTAssertEqual(list.rows.map(\.id), ["a", "b"])
        XCTAssertEqual(list.rows.first { $0.id == "a" }?.position, 0)

        list.setEnabled("a", false)
        XCTAssertTrue(writes.isEmpty, "ghost must not count toward the last-enabled guard")

        list.setEnabled("b", true)
        XCTAssertEqual(writes, [["a", "b"]])
    }

    func testAvailabilityMapsToFixedStates() async {
        let cases: [(BackendAvailability, BackendStatus.State)] = [
            (.available, .ready),
            (.modelNotDownloaded, .modelNotDownloaded),
            (.unsupportedOS, .unsupported),
            (.unsupportedHardware, .unsupported),
            (.permissionDenied, .unavailable),
            (.unavailable("reason"), .unavailable),
            (.failed("boom"), .unavailable),
        ]
        for (availability, expected) in cases {
            let list = makeList(["x"], availability: ["x": availability])
            await list.refresh()
            XCTAssertEqual(list.rows.first?.state, expected, "availability: \(availability)")
        }
    }

    func testStaleRefreshCannotOverwriteANewerOne() async {
        let gate = AvailabilityGate()
        let list = BackendListModel(
            entries: [BackendListEntry(id: "a", displayName: "A", availability: { await gate.next() })],
            order: { ["a"] },
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
