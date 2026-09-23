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

    func testBufferKeepsTheNewestEntriesInOrderAcrossManyWraps() {
        var buffer = DiagnosticsBuffer(capacity: 3)
        for index in 0..<10 {
            buffer.append(.settingsDecodeFailed(byteCount: index))
        }
        XCTAssertEqual(buffer.entries.map(\.event), [
            .settingsDecodeFailed(byteCount: 7),
            .settingsDecodeFailed(byteCount: 8),
            .settingsDecodeFailed(byteCount: 9),
        ])

        buffer.clear()
        XCTAssertTrue(buffer.entries.isEmpty)
        buffer.append(.permissionRechecked)
        XCTAssertEqual(buffer.entries.map(\.event), [.permissionRechecked])
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

    func testSpeechModelEventsRenderTheGivenBackendName() {
        var buffer = DiagnosticsBuffer()
        buffer.append(.speechModelDownloadStarted(backendName: "Kokoro"))
        buffer.append(.speechModelDownloadFinished(backendName: "Kokoro"))
        buffer.append(.speechModelDownloadFailed(backendName: "Parakeet"))

        XCTAssertEqual(
            buffer.copyText,
            "Kokoro model download started\nKokoro model download finished\nParakeet model download failed"
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
        recorder.record(.hotkeyMatched(action: .readSelection, phase: .pressed))
        recorder.record(.actionDispatched(action: .readSelection, phase: .pressed))

        XCTAssertEqual(recorder.entries.count, 3)
        XCTAssertEqual(Set(recorder.entries.map(\.id)).count, 3)
        XCTAssertEqual(recorder.counters.received, 2)
        XCTAssertEqual(recorder.counters.matched, 2)
        XCTAssertEqual(recorder.counters.dispatched, 1)
        XCTAssertEqual(recorder.entries.last?.event.message, "Read Selection pressed dispatched")
        recorder.clear()
        XCTAssertTrue(recorder.entries.isEmpty)
        XCTAssertEqual(recorder.counters, .init())
    }

    /// Every keystroke system-wide reports `.keyboardEventReceived` while the event tap is live.
    /// It must only bump the counter: buffering it would evict every meaningful entry.
    func testKeyboardEventsAreCountedButNeverBuffered() {
        let recorder = DiagnosticsRecorder(capacity: 5)
        recorder.record(.eventTapRegistered)
        for _ in 0..<20 {
            recorder.record(.keyboardEventReceived)
        }

        XCTAssertEqual(recorder.counters.received, 20)
        XCTAssertEqual(recorder.entries.map(\.event), [.eventTapRegistered])
    }

    func testCopyIncludesConciseLocalTimestamp() {
        let date = Date(timeIntervalSince1970: 0)
        let entry = DiagnosticEntry(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, timestamp: date, event: .ttsStopped)
        XCTAssertEqual(entry.copyLine(formatter: DiagnosticTimestampFormatter.fixed), "00:00:00 Speech stopped")
    }

    func testAccessibilityTrustGrantsEffectiveGlobalHotkeysWithoutInputMonitoring() {
        let native = FakeNativePermissions(
            inputMonitoring: false,
            isAccessibilityTrusted: true
        )
        let service = PermissionService(native: native)

        let snapshot = service.snapshot()

        XCTAssertFalse(snapshot.inputMonitoringGranted)
        XCTAssertTrue(snapshot.accessibilityGranted)
        XCTAssertTrue(snapshot.globalHotkeysGranted)
    }

    func testPermissionServiceRequestsAccessibilityWhenTrustIsMissing() {
        let native = FakeNativePermissions(
            inputMonitoring: false,
            isAccessibilityTrusted: false
        )
        let service = PermissionService(native: native)

        service.requestPermissions()

        XCTAssertEqual(native.requestAccessibilityCount, 1)
    }

    func testPermissionServiceDoesNotRequestAccessibilityWhenTrusted() {
        let native = FakeNativePermissions(
            inputMonitoring: false,
            isAccessibilityTrusted: true
        )
        let service = PermissionService(native: native)

        service.requestPermissions()

        XCTAssertEqual(native.requestAccessibilityCount, 0)
    }
}

@MainActor
private final class FakeNativePermissions: NativePermissionChecking {
    var inputMonitoring: Bool
    var accessibilityTrusted: Bool
    private(set) var requestAccessibilityCount = 0

    init(inputMonitoring: Bool, isAccessibilityTrusted: Bool) {
        self.inputMonitoring = inputMonitoring
        accessibilityTrusted = isAccessibilityTrusted
    }

    func canListenForEvents() -> Bool { inputMonitoring }
    func isAccessibilityTrusted() -> Bool { accessibilityTrusted }
    func requestAccessibilityTrust() { requestAccessibilityCount += 1 }
}

/// Deterministic UTC/POSIX variant of `DiagnosticTimestampFormatter.local`, for tests only.
extension DiagnosticTimestampFormatter {
    static let fixed: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
