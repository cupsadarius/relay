import Foundation

/// Installs the bundled `RelayHook` helper binary to a stable, app-bundle-independent
/// location under Application Support. Hook configs store the helper's absolute path, and an
/// app-bundle path breaks silently whenever the app is rebuilt or moved.
///
/// Never logs the source or destination path; only structural facts (success/failure).
struct HelperInstaller {
    private let baseDirectory: URL

    /// - Parameter baseDirectory: this build's support directory. Tests MUST inject a unique
    ///   temporary directory, so the real `~/Library/Application Support` is never touched.
    init(baseDirectory: URL = RelayPaths.supportDirectory()) {
        self.baseDirectory = baseDirectory
    }

    /// Where this installer's `installBundledHelper` writes: `<baseDirectory>/bin/RelayHook`.
    var installedHelperURL: URL {
        RelayPaths.helperURL(inSupportDirectory: baseDirectory)
    }

    private var binDirectory: URL {
        installedHelperURL.deletingLastPathComponent()
    }

    /// Copies `bundledURL` to this installer's stable helper location.
    ///
    /// Creates the `bin` directory (mode `0o700`) if it doesn't exist yet, copies the
    /// source to a uniquely-named temporary file in that same directory, makes it
    /// executable (`0o755`), then atomically swaps it into place — so a concurrently
    /// running hook invocation never observes a partially written file. Idempotent:
    /// calling this again (e.g. after an app rebuild produces a new bundled helper) safely
    /// replaces whatever was installed before.
    func installBundledHelper(from bundledURL: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: binDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let temporaryURL = binDirectory.appendingPathComponent(".\(RelayPaths.helperBasename)-\(UUID().uuidString)")
        try fileManager.copyItem(at: bundledURL, to: temporaryURL)
        do {
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporaryURL.path)
            _ = try fileManager.replaceItemAt(installedHelperURL, withItemAt: temporaryURL)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }
}
