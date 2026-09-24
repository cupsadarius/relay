import XCTest

@testable import Relay

final class ModelFileVerifierTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ text: String) throws -> URL {
        let url = directory.appendingPathComponent("file.txt")
        try Data(text.utf8).write(to: url)
        return url
    }

    func testSHA256MatchesKnownDigestInAnyChunkSize() throws {
        let url = try write("hello\n")
        let digest = "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03"
        XCTAssertTrue(try ModelFileVerifier.verify(at: url, against: .sha256(digest)))
        XCTAssertTrue(try ModelFileVerifier.verify(at: url, against: .sha256(digest.uppercased()), chunkSize: 1))
    }

    func testGitBlobSHA1MatchesGitHashObject() throws {
        let url = try write("hello\n")
        XCTAssertTrue(try ModelFileVerifier.verify(at: url, against: .gitBlobSHA1("ce013625030ba8dba906f756967f9e9ca394464a"), chunkSize: 2))
    }

    func testMismatchReturnsFalse() throws {
        let url = try write("hello\n")
        XCTAssertFalse(try ModelFileVerifier.verify(at: url, against: .sha256(String(repeating: "0", count: 64))))
    }

    func testWhisperNamesStillResolve() throws {
        let url = try write("hello\n")
        let oid: WhisperFileOID = .gitBlobSHA1("ce013625030ba8dba906f756967f9e9ca394464a")
        XCTAssertTrue(try WhisperModelStore.verifyFile(at: url, against: oid))
        XCTAssertEqual(WhisperModelStore.verificationChunkSize, ModelFileVerifier.defaultChunkSize)
    }
}
