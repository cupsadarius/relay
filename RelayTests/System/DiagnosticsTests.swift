import XCTest
@testable import Relay

@MainActor final class DiagnosticsTests: XCTestCase {
    func testBufferEvictsOldestEventAndFormatsCopyWithoutSensitivePayloads() {
        var buffer = DiagnosticsBuffer(capacity: 2)
        buffer.append(.permissionRechecked)
        buffer.append(.eventTapRegistered)
        buffer.append(.ttsStopped)

        XCTAssertEqual(buffer.entries.map(\.event), [.eventTapRegistered, .ttsStopped])
        XCTAssertEqual(buffer.copyText, "Event tap registered\nSpeech stopped")
    }

    func testBufferClearRemovesAllEntries() {
        var buffer = DiagnosticsBuffer(capacity: 2)
        buffer.append(.permissionRequested)
        buffer.clear()

        XCTAssertTrue(buffer.entries.isEmpty)
        XCTAssertEqual(buffer.copyText, "")
    }

    func testRepeatedEventsHaveUniqueStableIDsAndClearResetsCounters() {
        let recorder = DiagnosticsRecorder(capacity: 3)
        recorder.record(.keyboardEventReceived)
        recorder.record(.keyboardEventReceived)
        recorder.record(.hotkeyMatched(action: .readSelection, phase: .pressed))
        recorder.record(.actionDispatched(action: .readSelection, phase: .pressed))

        XCTAssertEqual(Set(recorder.entries.map(\.id)).count, 3)
        XCTAssertEqual(recorder.counters.received, 2)
        XCTAssertEqual(recorder.counters.matched, 1)
        XCTAssertEqual(recorder.counters.dispatched, 1)
        XCTAssertEqual(recorder.entries.last?.event.message, "Read Selection pressed dispatched")
        recorder.clear()
        XCTAssertTrue(recorder.entries.isEmpty)
        XCTAssertEqual(recorder.counters, .init())
    }

    func testCopyIncludesConciseLocalTimestamp() {
        let date = Date(timeIntervalSince1970: 0)
        let entry = DiagnosticEntry(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, timestamp: date, event: .ttsStopped)
        XCTAssertEqual(entry.copyLine(formatter: DiagnosticTimestampFormatter.fixed), "00:00:00 Speech stopped")
    }

    func testPermissionServiceReportsDistinctPermissionsAndRequestsBoth() {
        let native = FakeNativePermissions(inputMonitoring: false, accessibility: true)
        let service = PermissionService(native: native)

        XCTAssertEqual(service.snapshot(), .init(inputMonitoringGranted: false, accessibilityGranted: true))
        service.requestPermissions()

        XCTAssertEqual(native.requestListenCount, 1)
        XCTAssertEqual(native.requestPostCount, 1)
        XCTAssertEqual(native.requestAccessibilityCount, 1)
    }
}

private final class FakeNativePermissions: NativePermissionChecking {
    var inputMonitoring: Bool
    var accessibility: Bool
    private(set) var requestListenCount = 0
    private(set) var requestPostCount = 0
    private(set) var requestAccessibilityCount = 0

    init(inputMonitoring: Bool, accessibility: Bool) {
        self.inputMonitoring = inputMonitoring
        self.accessibility = accessibility
    }

    func canListenForEvents() -> Bool { inputMonitoring }
    func canPostEvents() -> Bool { accessibility }
    func isAccessibilityTrusted() -> Bool { accessibility }
    func requestListenForEvents() { requestListenCount += 1 }
    func requestPostEvents() { requestPostCount += 1 }
    func requestAccessibilityTrust() { requestAccessibilityCount += 1 }
}
