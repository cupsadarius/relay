import XCTest

@testable import Relay

final class VerifiedModelStoreTests: XCTestCase {
    private var root: URL!
    private let files: [String: Data] = ["config.json": Data("{}".utf8), "weights/model.bin": Data("weights".utf8)]

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func snapshot(
        required: Set<String> = ["config.json"], pinned: [String: String] = [:], allowlist: Set<String>? = nil
    ) -> PinnedSnapshot {
        PinnedSnapshot(
            repo: "org/model", revision: "abc123", allowlist: allowlist ?? Set(files.keys), requiredFiles: required, pinnedSHA256: pinned
        )
    }

    private func store(_ downloader: FakeSnapshotDownloader) -> VerifiedModelStore {
        VerifiedModelStore(root: root, downloader: downloader)
    }

    func testDownloadVerifiesAndPromotesAtomically() async throws {
        let store = store(FakeSnapshotDownloader(files: files))
        XCTAssertFalse(store.presence(of: "m@abc123"))

        try await store.download(snapshot(), as: "m@abc123", siblingPrefix: nil) { _ in }

        XCTAssertTrue(store.presence(of: "m@abc123"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.directory(named: "m@abc123").appendingPathComponent("weights/model.bin").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("m@abc123.incomplete").path))
    }

    func testChecksumMismatchDiscardsStagingAndKeepsNothing() async {
        let store = store(FakeSnapshotDownloader(files: files, lie: ["weights/model.bin"]))
        do {
            try await store.download(snapshot(), as: "m@abc123", siblingPrefix: nil) { _ in }
            XCTFail("expected a checksum mismatch")
        } catch {
            XCTAssertEqual(error as? VerifiedModelStoreError, .checksumMismatch)
        }
        XCTAssertFalse(store.presence(of: "m@abc123"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("m@abc123.incomplete").path))
    }

    func testMissingRequiredFileFails() async {
        let store = store(FakeSnapshotDownloader(files: files))
        do {
            try await store.download(snapshot(required: ["config.json", "tokenizer.json"]), as: "m@abc123", siblingPrefix: nil) { _ in }
            XCTFail("expected missing required file")
        } catch {
            XCTAssertEqual(error as? VerifiedModelStoreError, .missingRequiredFile)
        }
        XCTAssertFalse(store.presence(of: "m@abc123"))
    }

    func testReportedOidMustEqualThePinnedHash() async {
        let store = store(FakeSnapshotDownloader(files: files))
        do {
            try await store.download(
                snapshot(pinned: ["weights/model.bin": String(repeating: "a", count: 64)]), as: "m@abc123", siblingPrefix: nil
            ) { _ in }
            XCTFail("expected a checksum mismatch")
        } catch {
            XCTAssertEqual(error as? VerifiedModelStoreError, .checksumMismatch)
        }
    }

    func testPinnedHashThatMatchesIsAccepted() async throws {
        let store = store(FakeSnapshotDownloader(files: files))
        let pinned = ["weights/model.bin": sha256Hex(Data("weights".utf8))]
        try await store.download(snapshot(pinned: pinned), as: "m@abc123", siblingPrefix: nil) { _ in }
        XCTAssertTrue(store.presence(of: "m@abc123"))
    }

    /// Review fix 12: a reported path that is not one of the snapshot's allowed repo paths must
    /// be rejected outright, never verified or written into the manifest.
    func testFileNotInTheAllowlistIsRejected() async {
        let store = store(FakeSnapshotDownloader(files: files, claimedPath: ["config.json": "unexpected.json"]))
        do {
            try await store.download(snapshot(), as: "m@abc123", siblingPrefix: nil) { _ in }
            XCTFail("expected an invalid path")
        } catch {
            XCTAssertEqual(error as? VerifiedModelStoreError, .invalidPath)
        }
        XCTAssertFalse(store.presence(of: "m@abc123"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("m@abc123.incomplete").path))
    }

    /// Even a path the snapshot's own allowlist contains must not escape the staging directory
    /// with a `..` component (review fix 12).
    func testPathTraversalIsRejectedEvenWhenAllowlisted() async {
        let evil = "../evil.json"
        let store = store(FakeSnapshotDownloader(files: files, claimedPath: ["config.json": evil]))
        do {
            try await store.download(snapshot(allowlist: Set(files.keys).union([evil])), as: "m@abc123", siblingPrefix: nil) { _ in }
            XCTFail("expected an invalid path")
        } catch {
            XCTAssertEqual(error as? VerifiedModelStoreError, .invalidPath)
        }
    }

    /// Nor with a leading `/`, even if allowlisted (review fix 12).
    func testAbsolutePathIsRejectedEvenWhenAllowlisted() async {
        let evil = "/etc/evil.json"
        let store = store(FakeSnapshotDownloader(files: files, claimedPath: ["config.json": evil]))
        do {
            try await store.download(snapshot(allowlist: Set(files.keys).union([evil])), as: "m@abc123", siblingPrefix: nil) { _ in }
            XCTFail("expected an invalid path")
        } catch {
            XCTAssertEqual(error as? VerifiedModelStoreError, .invalidPath)
        }
    }

    /// Review fix 12: promotion replaces an existing ready directory in one atomic step, leaving
    /// no trace of the old content.
    func testPromotingOverAnExistingReadyDirectoryReplacesItEntirely() async throws {
        let first = store(FakeSnapshotDownloader(files: files))
        try await first.download(snapshot(), as: "m@abc123", siblingPrefix: nil) { _ in }
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.directory(named: "m@abc123").appendingPathComponent("weights/model.bin").path))

        let newFiles: [String: Data] = ["config.json": Data("{\"v\":2}".utf8)]
        let second = VerifiedModelStore(root: root, downloader: FakeSnapshotDownloader(files: newFiles))
        let secondSnapshot = PinnedSnapshot(
            repo: "org/model", revision: "def456", allowlist: Set(newFiles.keys), requiredFiles: ["config.json"], pinnedSHA256: [:]
        )
        try await second.download(secondSnapshot, as: "m@abc123", siblingPrefix: nil) { _ in }

        XCTAssertTrue(second.presence(of: "m@abc123"))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: second.directory(named: "m@abc123").appendingPathComponent("weights/model.bin").path),
            "the old file must be gone after replacement"
        )
        XCTAssertEqual(
            try Data(contentsOf: second.directory(named: "m@abc123").appendingPathComponent("config.json")), Data("{\"v\":2}".utf8)
        )
    }

    func testPresenceFailsWhenAListedFileIsDeleted() async throws {
        let store = store(FakeSnapshotDownloader(files: files))
        try await store.download(snapshot(), as: "m@abc123", siblingPrefix: nil) { _ in }
        try FileManager.default.removeItem(at: store.directory(named: "m@abc123").appendingPathComponent("config.json"))
        XCTAssertFalse(store.presence(of: "m@abc123"))
    }

    func testInvalidateThenRemove() async throws {
        let store = store(FakeSnapshotDownloader(files: files))
        try await store.download(snapshot(), as: "m@abc123", siblingPrefix: nil) { _ in }

        store.invalidatePresence(of: "m@abc123")
        XCTAssertFalse(store.presence(of: "m@abc123"))
        try await store.remove("m@abc123")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory(named: "m@abc123").path))
        try await store.remove("m@abc123") // no-op when absent
    }

    func testSuccessfulDownloadSweepsOtherRevisionsOnly() async throws {
        let store = store(FakeSnapshotDownloader(files: files))
        for name in ["m@old", "m@older.incomplete", "other@old"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }

        try await store.download(snapshot(), as: "m@abc123", siblingPrefix: "m@") { _ in }

        let remaining = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        XCTAssertEqual(remaining, ["m@abc123", "other@old"])
    }

    func testFailedDownloadDoesNotSweep() async throws {
        let store = store(FakeSnapshotDownloader(files: files, error: URLError(.notConnectedToInternet)))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("m@old"), withIntermediateDirectories: true)

        try? await store.download(snapshot(), as: "m@abc123", siblingPrefix: "m@") { _ in }

        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("m@old").path))
    }
}
