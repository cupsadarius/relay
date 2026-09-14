import XCTest
@testable import Relay

@MainActor final class DiagnosticsTests: XCTestCase {
    func testAccessibilityPermissionLabelDoesNotLimitAccessibilityToPostingEvents() {
        XCTAssertEqual(DiagnosticsView.accessibilityPermissionLabel, "Accessibility")
    }

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

    func testDictationLifecycleAndFailureDiagnosticsUseStablePrivacySafeMessages() {
        var buffer = DiagnosticsBuffer()
        buffer.append(.dictation(.listening))
        buffer.append(.dictation(.processing))
        buffer.append(.dictation(.inserted(.accessibility)))
        buffer.append(.dictation(.failed(.microphoneCapture)))

        XCTAssertEqual(
            buffer.copyText,
            "Dictation listening\nDictation processing\nDictation inserted via accessibility\nDictation failed during microphone capture"
        )
    }

    func testInsertedDiagnosticRendersMechanismLabels() {
        var buffer = DiagnosticsBuffer()
        buffer.append(.dictation(.inserted(.accessibility)))
        buffer.append(.dictation(.inserted(.paste)))

        XCTAssertEqual(
            buffer.copyText,
            "Dictation inserted via accessibility\nDictation inserted via paste"
        )
    }

    func testOverlayFailedNeverAttachesRawErrorDetail() {
        var buffer = DiagnosticsBuffer()
        buffer.append(.overlayFailed)

        XCTAssertEqual(buffer.copyText, "Activity overlay failed")
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

    func testAccessibilityTrustGrantsEffectiveGlobalHotkeysWhenPostingIsUnavailable() {
        let native = FakeNativePermissions(
            inputMonitoring: false,
            canPostEvents: false,
            isAccessibilityTrusted: true
        )
        let service = PermissionService(native: native)

        let snapshot = service.snapshot()

        XCTAssertFalse(snapshot.inputMonitoringGranted)
        XCTAssertTrue(snapshot.accessibilityGranted)
        XCTAssertTrue(snapshot.globalHotkeysGranted)
    }

    func testPermissionServiceRequestsAccessibilityWhenTrustIsMissingEvenIfPostingIsAllowed() {
        let native = FakeNativePermissions(
            inputMonitoring: false,
            canPostEvents: true,
            isAccessibilityTrusted: false
        )
        let service = PermissionService(native: native)

        service.requestPermissions()

        XCTAssertEqual(native.requestListenCount, 0)
        XCTAssertEqual(native.requestPostCount, 0)
        XCTAssertEqual(native.requestAccessibilityCount, 1)
    }

    func testPermissionServiceDoesNotRequestAccessibilityWhenTrustedButPostingIsUnavailable() {
        let native = FakeNativePermissions(
            inputMonitoring: false,
            canPostEvents: false,
            isAccessibilityTrusted: true
        )
        let service = PermissionService(native: native)

        service.requestPermissions()

        XCTAssertEqual(native.requestListenCount, 0)
        XCTAssertEqual(native.requestPostCount, 0)
        XCTAssertEqual(native.requestAccessibilityCount, 0)
    }
}

private final class FakeNativePermissions: NativePermissionChecking {
    var inputMonitoring: Bool
    var postEvents: Bool
    var accessibilityTrusted: Bool
    private(set) var requestListenCount = 0
    private(set) var requestPostCount = 0
    private(set) var requestAccessibilityCount = 0

    init(
        inputMonitoring: Bool,
        canPostEvents: Bool,
        isAccessibilityTrusted: Bool
    ) {
        self.inputMonitoring = inputMonitoring
        postEvents = canPostEvents
        accessibilityTrusted = isAccessibilityTrusted
    }

    func canListenForEvents() -> Bool { inputMonitoring }
    func canPostEvents() -> Bool { postEvents }
    func isAccessibilityTrusted() -> Bool { accessibilityTrusted }
    func requestListenForEvents() { requestListenCount += 1 }
    func requestPostEvents() { requestPostCount += 1 }
    func requestAccessibilityTrust() { requestAccessibilityCount += 1 }
}
