import Foundation

/// Installs the bundled `RelayHook` helper binary to a stable, app-bundle-independent
/// location under Application Support.
///
/// Both Claude Code's and Codex's hook configs store the helper's path verbatim as an
/// absolute string. Historically that path was `Bundle.main.bundleURL/Contents/Helpers/
/// RelayHook` — which changes (or stops existing) whenever the app is rebuilt, moved, or
/// DerivedData is cleared, silently breaking the hook without any error. Copying the
/// bundled helper here first means the installers can always point at ONE path that
/// outlives any particular app bundle.
///
/// Never logs the source or destination path; only structural facts (success/failure).
struct HelperInstaller {
    private static let helperBasename = "RelayHook"

    private let baseDirectory: URL

    /// - Parameter baseDirectory: Relay's own directory under Application Support (normally
    ///   `~/Library/Application Support/Relay`). Tests MUST inject a unique temporary
    ///   directory here rather than relying on the default, so the real
    ///   `~/Library/Application Support` is never read or written.
    init(baseDirectory: URL = HelperInstaller.defaultBaseDirectory()) {
        self.baseDirectory = baseDirectory
    }

    /// Relay's directory under the real `~/Library/Application Support`.
    static func defaultBaseDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Relay", isDirectory: true)
    }

    /// The stable, bundle-independent path Relay always installs `RelayHook` hook commands
    /// to: `~/Library/Application Support/Relay/bin/RelayHook`.
    static func stableHelperURL() -> URL {
        binDirectory(under: defaultBaseDirectory()).appendingPathComponent(helperBasename, isDirectory: false)
    }

    private static func binDirectory(under baseDirectory: URL) -> URL {
        baseDirectory.appendingPathComponent("bin", isDirectory: true)
    }

    private var binDirectory: URL {
        Self.binDirectory(under: baseDirectory)
    }

    /// Where THIS installer's `installBundledHelper` writes to — `<baseDirectory>/bin/
    /// RelayHook`. For an installer constructed with the default `baseDirectory`, this equals
    /// `HelperInstaller.stableHelperURL()`; exposed as an instance property (rather than only
    /// the static default) so a caller holding an injected installer — production code built
    /// around a non-default base directory, or a test — can verify the destination this
    /// SPECIFIC instance actually targets, instead of always the real default path.
    var installedHelperURL: URL {
        binDirectory.appendingPathComponent(Self.helperBasename, isDirectory: false)
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

        let temporaryURL = binDirectory.appendingPathComponent(".\(Self.helperBasename)-\(UUID().uuidString)")
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
