import Foundation
import XCTest
@testable import Relay

final class HookEnvelopeReceiverTests: XCTestCase {
    private func temporarySocketPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .path
    }

    private let validLine =
        #"{"schemaVersion":1,"provider":"claude-code","rawPayload":"{}","#
        + #""parentPID":123,"environment":{},"capturedAt":1700000000}"#
        + "\n"

    func testValidEnvelopeIsDecodedAndYieldedThroughEvents() async throws {
        let path = temporarySocketPath()
        let receiver = HookEnvelopeReceiver()
        try receiver.start(path: path)
        defer { receiver.stop() }

        let received = expectation(description: "received envelope")
        nonisolated(unsafe) var observed: HookEnvelope?
        let consumer = Task {
            for await envelope in receiver.events {
                observed = envelope
                received.fulfill()
                break
            }
        }
        defer { consumer.cancel() }

        try await UnixSocketTestClient.send(validLine, to: path)
        await fulfillment(of: [received], timeout: 1)

        XCTAssertEqual(observed?.schemaVersion, 1)
        XCTAssertEqual(observed?.provider, .claudeCode)
        XCTAssertEqual(observed?.parentPID, 123)
    }

    func testMalformedJSONLineIsDroppedWithoutCrashingTheListener() async throws {
        let path = temporarySocketPath()
        let receiver = HookEnvelopeReceiver()
        try receiver.start(path: path)
        defer { receiver.stop() }

        let receivedValid = expectation(description: "received the valid envelope")
        let receivedUnexpected = expectation(description: "no envelope from the malformed line")
        receivedUnexpected.isInverted = true

        nonisolated(unsafe) var deliveryCount = 0
        let consumer = Task {
            for await _ in receiver.events {
                deliveryCount += 1
                if deliveryCount == 1 {
                    receivedValid.fulfill()
                } else {
                    receivedUnexpected.fulfill()
                }
            }
        }
        defer { consumer.cancel() }

        try await UnixSocketTestClient.send("not valid json at all\n", to: path)
        try await UnixSocketTestClient.send(validLine, to: path)

        await fulfillment(of: [receivedValid], timeout: 1)
        await fulfillment(of: [receivedUnexpected], timeout: 0.3)
    }

    func testUnsupportedSchemaVersionIsDroppedWithoutCrashingTheListener() async throws {
        let path = temporarySocketPath()
        let receiver = HookEnvelopeReceiver()
        try receiver.start(path: path)
        defer { receiver.stop() }

        let receivedValid = expectation(description: "received the schemaVersion 1 envelope")
        let receivedUnexpected = expectation(description: "no envelope from the unsupported version")
        receivedUnexpected.isInverted = true

        nonisolated(unsafe) var deliveryCount = 0
        let consumer = Task {
            for await _ in receiver.events {
                deliveryCount += 1
                if deliveryCount == 1 {
                    receivedValid.fulfill()
                } else {
                    receivedUnexpected.fulfill()
                }
            }
        }
        defer { consumer.cancel() }

        let unsupportedVersionLine =
            #"{"schemaVersion":2,"provider":"codex","rawPayload":"{}","#
            + #""parentPID":1,"environment":{},"capturedAt":1700000000}"#
            + "\n"
        try await UnixSocketTestClient.send(unsupportedVersionLine, to: path)
        try await UnixSocketTestClient.send(validLine, to: path)

        await fulfillment(of: [receivedValid], timeout: 1)
        await fulfillment(of: [receivedUnexpected], timeout: 0.3)
    }

    func testIsListeningReflectsStartAndStopLifecycle() throws {
        let path = temporarySocketPath()
        let receiver = HookEnvelopeReceiver()

        XCTAssertFalse(receiver.isListening)

        try receiver.start(path: path)
        XCTAssertTrue(receiver.isListening)

        receiver.stop()
        XCTAssertFalse(receiver.isListening)
    }

    func testStopFinishesTheEventsStream() async throws {
        let path = temporarySocketPath()
        let receiver = HookEnvelopeReceiver()
        try receiver.start(path: path)

        let finished = expectation(description: "stream finished")
        let consumer = Task {
            for await _ in receiver.events {}
            finished.fulfill()
        }
        defer { consumer.cancel() }

        receiver.stop()
        await fulfillment(of: [finished], timeout: 1)
    }

    // MARK: - Diagnostics

    func testMalformedLineRecordsDroppedDiagnosticsEntryWithByteCount() async throws {
        let path = temporarySocketPath()
        let diagnostics = IntegrationDiagnosticsLog()
        let receiver = HookEnvelopeReceiver(diagnostics: diagnostics)
        try receiver.start(path: path)
        defer { receiver.stop() }

        let receivedValid = expectation(description: "received the valid envelope")
        let consumer = Task {
            for await _ in receiver.events {
                receivedValid.fulfill()
                break
            }
        }
        defer { consumer.cancel() }

        let malformedLine = "not valid json at all\n"
        try await UnixSocketTestClient.send(malformedLine, to: path)
        try await UnixSocketTestClient.send(validLine, to: path)
        await fulfillment(of: [receivedValid], timeout: 1)

        let entries = diagnostics.snapshot()
        let dropped = entries.first { $0.outcome == "dropped" }
        let expectedByteCount = malformedLine.trimmingCharacters(in: .newlines).utf8.count
        XCTAssertNotNil(dropped)
        XCTAssertEqual(dropped?.stage, "receiver")
        XCTAssertTrue(dropped?.detail.contains("\(expectedByteCount)") ?? false)
        XCTAssertTrue(dropped?.detail.contains("malformed-json") ?? false)
    }

    func testWellFormedEnvelopeRecordsLineReceivedThenEnvelopeDecoded() async throws {
        let path = temporarySocketPath()
        let diagnostics = IntegrationDiagnosticsLog()
        let receiver = HookEnvelopeReceiver(diagnostics: diagnostics)
        try receiver.start(path: path)
        defer { receiver.stop() }

        let received = expectation(description: "received envelope")
        let consumer = Task {
            for await _ in receiver.events {
                received.fulfill()
                break
            }
        }
        defer { consumer.cancel() }

        try await UnixSocketTestClient.send(validLine, to: path)
        await fulfillment(of: [received], timeout: 1)

        // newest-first snapshot: envelope-decoded should appear before (i.e. at a lower index
        // than) line-received, since it was recorded after it.
        let entries = diagnostics.snapshot()
        let decodedIndex = entries.firstIndex { $0.outcome == "envelope-decoded" }
        let receivedIndex = entries.firstIndex { $0.outcome == "line-received" }
        XCTAssertNotNil(decodedIndex)
        XCTAssertNotNil(receivedIndex)
        if let decodedIndex, let receivedIndex {
            XCTAssertLessThan(decodedIndex, receivedIndex)
        }
        XCTAssertTrue(entries.first { $0.outcome == "envelope-decoded" }?.detail.contains("provider=claude-code") ?? false)
    }

    func testEventStreamKeepsOnlyTheNewestEnvelopesWhenNobodyIsConsuming() async throws {
        let path = temporarySocketPath()
        let diagnostics = IntegrationDiagnosticsLog()
        let receiver = HookEnvelopeReceiver(diagnostics: diagnostics)
        try receiver.start(path: path)

        for pid in 1...20 {
            let line = #"{"schemaVersion":1,"provider":"codex","rawPayload":"{}","#
                + #""parentPID":\#(pid),"environment":{},"capturedAt":1700000000}"# + "\n"
            try await UnixSocketTestClient.send(line, to: path)
        }
        let deadline = Date().addingTimeInterval(2)
        while diagnostics.snapshot().filter({ $0.outcome == "envelope-decoded" }).count < 20, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        receiver.stop() // finishes the stream; buffered elements are still delivered
        var pids: [Int32] = []
        for await envelope in receiver.events {
            pids.append(envelope.parentPID)
        }

        XCTAssertEqual(HookEnvelopeReceiver.eventBufferLimit, 16)
        // 20 separate connections are not guaranteed to be decoded in send order, so compare
        // counts and membership, not order: 16 distinct envelopes kept, 4 dropped.
        XCTAssertEqual(pids.count, 16)
        XCTAssertEqual(Set(pids).count, 16)
        XCTAssertTrue(Set(pids).isSubset(of: Set(Int32(1)...Int32(20))))
        XCTAssertEqual(diagnostics.snapshot().filter { $0.detail.hasPrefix("event-buffer-full") }.count, 4)
    }
}
