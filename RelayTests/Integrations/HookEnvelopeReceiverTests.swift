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
}
