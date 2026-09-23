import Darwin
import XCTest

@testable import Relay

final class UnixSocketAddressTests: XCTestCase {
    func testMakeSetsLengthFamilyAndTerminatedPath() throws {
        let address = try UnixSocketAddress.make(path: "/tmp/relay-test.sock")

        XCTAssertEqual(Int(address.sun_len), MemoryLayout<sockaddr_un>.size)
        XCTAssertEqual(Int32(address.sun_family), AF_UNIX)
        let path = withUnsafeBytes(of: address.sun_path) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        XCTAssertEqual(path, "/tmp/relay-test.sock")
    }

    func testMakeRejectsAPathThatCannotFitItsTerminator() {
        let capacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        XCTAssertNoThrow(try UnixSocketAddress.make(path: "/" + String(repeating: "a", count: capacity - 2)))
        XCTAssertThrowsError(try UnixSocketAddress.make(path: "/" + String(repeating: "a", count: capacity - 1))) { error in
            XCTAssertEqual(error as? UnixSocketAddressError, .pathTooLong)
        }
    }

    func testConnectToAMissingSocketFailsFast() {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        let start = Date()

        XCTAssertFalse(
            UnixSocketAddress.connect(
                fd, to: "/tmp/relay-missing-\(UUID().uuidString).sock", withDeadline: Date().addingTimeInterval(0.4)
            ))
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.3)
    }

    func testConnectReachesALiveListener() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let server = UnixSocketServer()
        try server.start(path: path) { _ in }
        defer { server.stop() }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }

        XCTAssertTrue(UnixSocketAddress.connect(fd, to: path, withDeadline: Date().addingTimeInterval(1)))
    }
}
