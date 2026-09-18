import CryptoKit
import XCTest

@testable import Relay

/// A `WhisperDownloader` fake that never touches the network: it writes caller-supplied bytes
/// into the staging directory `WhisperModelStore` gives it, and reports whatever oid the test
/// wants associated with each file (correct or deliberately wrong, to exercise verification).
final class FakeWhisperDownloader: WhisperDownloader, @unchecked Sendable {
    struct PlannedFile {
        let relativePath: String
        let data: Data
        let oid: WhisperFileOID
    }

    var filesToWrite: [PlannedFile] = []
    var errorToThrow: Error?
    /// Bytes to write (and then throw after) to simulate an interrupted transfer: only some
    /// files land on disk before the failure.
    var partialFileBeforeThrow: PlannedFile?

    private(set) var lastDestinationDirectory: URL?

    func download(
        _ descriptor: WhisperModelDescriptor,
        into directory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [WhisperModelFile] {
        lastDestinationDirectory = directory

        if let partialFileBeforeThrow {
            try write(partialFileBeforeThrow, into: directory)
        }

        if let errorToThrow {
            throw errorToThrow
        }

        var manifest: [WhisperModelFile] = []
        for file in filesToWrite {
            try write(file, into: directory)
            manifest.append(WhisperModelFile(relativePath: file.relativePath, oid: file.oid))
        }
        progress(1.0)
        return manifest
    }

    private func write(_ file: PlannedFile, into directory: URL) throws {
        let destination = directory.appendingPathComponent(file.relativePath)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try file.data.write(to: destination)
    }
}

enum FakeDownloaderError: Error {
    case simulatedInterruption
}

/// Helpers that compute the exact same digests `WhisperModelStore` verifies against, so tests can
/// hand the fake downloader genuinely correct oids for the "everything verifies" cases.
enum TestOID {
    static func sha256(_ data: Data) -> WhisperFileOID {
        .sha256(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    static func gitBlobSHA1(_ data: Data) -> WhisperFileOID {
        var content = Data("blob \(data.count)\0".utf8)
        content.append(data)
        return .gitBlobSHA1(Insecure.SHA1.hash(data: content).map { String(format: "%02x", $0) }.joined())
    }
}

final class WhisperModelStoreTests: XCTestCase {
    private var tempDirectory: URL!
    private var downloader: FakeWhisperDownloader!
    private var store: WhisperModelStore!

    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperModelStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        downloader = FakeWhisperDownloader()
        store = WhisperModelStore(cacheDirectory: tempDirectory, downloader: downloader)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        tempDirectory = nil
        downloader = nil
        store = nil
        try await super.tearDown()
    }

    func testPresenceFalseWhenDirEmpty() {
        XCTAssertFalse(store.presence(of: .tinyEn))
    }

    func testPresenceTrueOnlyWhenAllFilesPresentAndVerifiedMarkerExists() throws {
        let modelDirectory = tempDirectory.appendingPathComponent(WhisperModelID.tinyEn.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        try Data("config".utf8).write(to: modelDirectory.appendingPathComponent("config.json"))

        // Files present, but no `.verified` marker: must not report downloaded.
        XCTAssertFalse(store.presence(of: .tinyEn))

        // Marker present, but it lists a bundle file that isn't actually there: still not
        // downloaded -- the marker alone is not sufficient proof.
        let incompleteManifest = try JSONEncoder().encode(["config.json", "AudioEncoder.mlmodelc/model.mil"])
        try incompleteManifest.write(to: modelDirectory.appendingPathComponent(".verified"))
        XCTAssertFalse(store.presence(of: .tinyEn))

        // Marker present and every listed file actually exists: reports downloaded.
        let completeManifest = try JSONEncoder().encode(["config.json"])
        try completeManifest.write(to: modelDirectory.appendingPathComponent(".verified"))
        XCTAssertTrue(store.presence(of: .tinyEn))
    }

    func testDownloadAtomicallyPromotesOnlyAfterEveryFileVerifies() async throws {
        let configData = Data("{\"key\":\"value\"}".utf8)
        let weightData = Data(repeating: 0xAB, count: 256)
        let tokenizerData = Data("{\"tokenizer\":\"data\"}".utf8)
        let tokenizerConfigData = Data("{\"tokenizer_class\":\"WhisperTokenizer\"}".utf8)
        downloader.filesToWrite = [
            .init(relativePath: "config.json", data: configData, oid: TestOID.gitBlobSHA1(configData)),
            .init(
                relativePath: "AudioEncoder.mlmodelc/weights/weight.bin",
                data: weightData,
                oid: TestOID.sha256(weightData)
            ),
            .init(relativePath: "tokenizer.json", data: tokenizerData, oid: TestOID.gitBlobSHA1(tokenizerData)),
            .init(
                relativePath: "tokenizer_config.json",
                data: tokenizerConfigData,
                oid: TestOID.gitBlobSHA1(tokenizerConfigData)
            ),
        ]

        XCTAssertFalse(store.presence(of: .tinyEn))

        try await store.download(.tinyEn, progress: { _ in })

        XCTAssertTrue(store.presence(of: .tinyEn))
        let modelDirectory = tempDirectory.appendingPathComponent(WhisperModelID.tinyEn.rawValue, isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: modelDirectory.appendingPathComponent("config.json").path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: modelDirectory.appendingPathComponent("AudioEncoder.mlmodelc/weights/weight.bin").path
            )
        )
        // The whole point of this task: `tokenizer.json` must land directly at the model
        // directory's top level, where `WhisperKitEngine.load`'s `tokenizerFolder: modelFolder`
        // makes WhisperKit's local-first tokenizer search (`ModelUtilities.loadTokenizer`) find it
        // without ever falling back to a live Hub fetch.
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: modelDirectory.appendingPathComponent("tokenizer.json").path)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: modelDirectory.appendingPathComponent("tokenizer_config.json").path
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: modelDirectory.appendingPathComponent(".verified").path))
    }

    /// `WhisperModelStore` does not merely pass through whatever a `WhisperDownloader` happens to
    /// report -- it independently requires `tokenizer.json` to be part of any promoted download,
    /// the same way it independently re-hashes every file rather than trusting the downloader's
    /// claimed oid. This guards against a downloader implementation that silently forgets the
    /// tokenizer (e.g. a future bug in `HuggingFaceWhisperDownloader`'s tokenizer-repo fetch)
    /// promoting a model that would still hit WhisperKit's live-fetch fallback on first activate.
    func testDownloadRejectsWhenTokenizerFileMissingFromDownloaderManifest() async throws {
        let configData = Data("{\"key\":\"value\"}".utf8)
        downloader.filesToWrite = [
            .init(relativePath: "config.json", data: configData, oid: TestOID.gitBlobSHA1(configData))
        ]

        await XCTAssertThrowsErrorAsync(try await store.download(.tinyEn, progress: { _ in })) { error in
            XCTAssertEqual(error as? WhisperModelStoreError, .missingTokenizer)
        }

        XCTAssertFalse(store.presence(of: .tinyEn))
        let modelDirectory = tempDirectory.appendingPathComponent(WhisperModelID.tinyEn.rawValue, isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: modelDirectory.path))
    }

    /// `presence(of:)` is deliberately generic over the manifest's contents (it just re-checks
    /// every listed path still exists), but this pins down the specific scenario this task cares
    /// about: a model whose `.mlmodelc` bundle is intact but whose tokenizer is gone (or was never
    /// part of the manifest) must never report as downloaded, because WhisperKit's local tokenizer
    /// search would then miss and fall back to a live fetch.
    func testPresenceFalseWhenModelPresentButTokenizerMissing() throws {
        let modelDirectory = tempDirectory.appendingPathComponent(WhisperModelID.tinyEn.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        try Data("config".utf8).write(to: modelDirectory.appendingPathComponent("config.json"))
        // tokenizer.json deliberately not written to disk.

        let manifestListingTokenizer = try JSONEncoder().encode(["config.json", "tokenizer.json"])
        try manifestListingTokenizer.write(to: modelDirectory.appendingPathComponent(".verified"))

        XCTAssertFalse(store.presence(of: .tinyEn))

        // Once tokenizer.json actually lands too, presence flips true.
        try Data("{}".utf8).write(to: modelDirectory.appendingPathComponent("tokenizer.json"))
        XCTAssertTrue(store.presence(of: .tinyEn))
    }

    /// The per-file checksum verification loop is already generic over every file the downloader
    /// reports -- this pins down that a corrupted/mismatched tokenizer file is rejected exactly
    /// like a corrupted model weight file, not treated as some lesser, ignorable sidecar.
    func testTokenizerFileChecksumMismatchRejectsWholeDownload() async throws {
        let configData = Data("{\"key\":\"value\"}".utf8)
        let tokenizerData = Data("{\"tokenizer\":\"data\"}".utf8)
        downloader.filesToWrite = [
            .init(relativePath: "config.json", data: configData, oid: TestOID.gitBlobSHA1(configData)),
            // Wrong oid: doesn't match tokenizerData's real blob sha1.
            .init(relativePath: "tokenizer.json", data: tokenizerData, oid: .gitBlobSHA1(String(repeating: "0", count: 40))),
        ]

        await XCTAssertThrowsErrorAsync(try await store.download(.tinyEn, progress: { _ in })) { error in
            XCTAssertEqual(error as? WhisperModelStoreError, .checksumMismatch)
        }

        XCTAssertFalse(store.presence(of: .tinyEn))
        let modelDirectory = tempDirectory.appendingPathComponent(WhisperModelID.tinyEn.rawValue, isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: modelDirectory.path))
    }

    func testFileChecksumMismatchRejectsAndLeavesNotDownloaded() async throws {
        let configData = Data("{\"key\":\"value\"}".utf8)
        let weightData = Data(repeating: 0xAB, count: 256)
        downloader.filesToWrite = [
            .init(relativePath: "config.json", data: configData, oid: TestOID.gitBlobSHA1(configData)),
            // Wrong oid: doesn't match weightData's real sha256.
            .init(
                relativePath: "AudioEncoder.mlmodelc/weights/weight.bin",
                data: weightData,
                oid: .sha256(String(repeating: "0", count: 64))
            ),
        ]

        await XCTAssertThrowsErrorAsync(try await store.download(.tinyEn, progress: { _ in })) { error in
            XCTAssertEqual(error as? WhisperModelStoreError, .checksumMismatch)
        }

        XCTAssertFalse(store.presence(of: .tinyEn))
        let modelDirectory = tempDirectory.appendingPathComponent(WhisperModelID.tinyEn.rawValue, isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: modelDirectory.path))
    }

    func testInterruptedDownloadNeverBecomesSelectable() async throws {
        let partialData = Data(repeating: 0x01, count: 16)
        downloader.partialFileBeforeThrow = .init(
            relativePath: "AudioEncoder.mlmodelc/weights/weight.bin",
            data: partialData,
            oid: TestOID.sha256(partialData)
        )
        downloader.errorToThrow = FakeDownloaderError.simulatedInterruption

        await XCTAssertThrowsErrorAsync(try await store.download(.tinyEn, progress: { _ in })) { error in
            XCTAssertTrue(error is FakeDownloaderError)
        }

        XCTAssertFalse(store.presence(of: .tinyEn))
        let modelDirectory = tempDirectory.appendingPathComponent(WhisperModelID.tinyEn.rawValue, isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: modelDirectory.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: modelDirectory.appendingPathComponent("AudioEncoder.mlmodelc/weights/weight.bin").path
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: modelDirectory.appendingPathComponent(".verified").path))
    }

    func testRemoveDeletesAndRediscoversAsNotDownloaded() async throws {
        let configData = Data("{\"key\":\"value\"}".utf8)
        let tokenizerData = Data("{\"tokenizer\":\"data\"}".utf8)
        downloader.filesToWrite = [
            .init(relativePath: "config.json", data: configData, oid: TestOID.gitBlobSHA1(configData)),
            .init(relativePath: "tokenizer.json", data: tokenizerData, oid: TestOID.gitBlobSHA1(tokenizerData)),
        ]
        try await store.download(.tinyEn, progress: { _ in })
        XCTAssertTrue(store.presence(of: .tinyEn))

        try await store.remove(.tinyEn)

        XCTAssertFalse(store.presence(of: .tinyEn))
        let modelDirectory = tempDirectory.appendingPathComponent(WhisperModelID.tinyEn.rawValue, isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: modelDirectory.path))
    }
}

/// `XCTAssertThrowsError` has no async overload in this SDK version; this small helper awaits the
/// throwing expression first so async `store.download` calls can still assert on the thrown error.
func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error to be thrown", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
