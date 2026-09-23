import XCTest
@testable import Relay

/// SAFETY: every test in this file points `HelperInstaller` at a unique temporary directory
/// created in `setUp` and removed in `tearDown`. No test may construct `HelperInstaller()` with
/// its default argument, and no test may read or write the real `~/Library/Application Support`.
final class HelperInstallerTests: XCTestCase {
    private var tempDirectory: URL!
    private var sourceHelperURL: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        sourceHelperURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-RelayHook")
    }

    override func tearDown() {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        if let sourceHelperURL {
            try? FileManager.default.removeItem(at: sourceHelperURL)
        }
        tempDirectory = nil
        sourceHelperURL = nil
        super.tearDown()
    }

    private func writeSourceHelper(contents: String = "#!/bin/sh\necho hi\n") throws {
        try contents.data(using: .utf8)!.write(to: sourceHelperURL)
    }

    private var expectedStableURL: URL {
        tempDirectory.appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("RelayHook", isDirectory: false)
    }

    private func posixPermissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func testCopiesBundledHelperToStablePathAtomically() throws {
        try writeSourceHelper()
        let installer = HelperInstaller(baseDirectory: tempDirectory)

        try installer.installBundledHelper(from: sourceHelperURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedStableURL.path))
        XCTAssertEqual(try posixPermissions(at: expectedStableURL), 0o755)
        let installedContents = try String(contentsOf: expectedStableURL, encoding: .utf8)
        XCTAssertEqual(installedContents, "#!/bin/sh\necho hi\n")

        // A second install (simulating a rebuilt/updated bundled helper) replaces the file
        // idempotently rather than failing or leaving stray temp files behind.
        try writeSourceHelper(contents: "#!/bin/sh\necho updated\n")
        try installer.installBundledHelper(from: sourceHelperURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedStableURL.path))
        XCTAssertEqual(try posixPermissions(at: expectedStableURL), 0o755)
        let updatedContents = try String(contentsOf: expectedStableURL, encoding: .utf8)
        XCTAssertEqual(updatedContents, "#!/bin/sh\necho updated\n")

        let binDirectoryContents = try FileManager.default.contentsOfDirectory(
            at: expectedStableURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(binDirectoryContents.map(\.lastPathComponent), ["RelayHook"])
    }

    func testStableHelperURLPointsUnderThisBuildsSupportDirectory() {
        let resolved = HelperInstaller.stableHelperURL()
        XCTAssertEqual(resolved, RelayPaths.supportDirectory().appendingPathComponent("bin/RelayHook"))
        XCTAssertTrue(resolved.path.contains("/Library/Application Support/Relay"))
    }

    func testBinDirectoryIsCreatedWithRestrictedPermissions() throws {
        try writeSourceHelper()
        let installer = HelperInstaller(baseDirectory: tempDirectory)

        try installer.installBundledHelper(from: sourceHelperURL)

        let binDirectory = expectedStableURL.deletingLastPathComponent()
        XCTAssertEqual(try posixPermissions(at: binDirectory), 0o700)
    }
}
