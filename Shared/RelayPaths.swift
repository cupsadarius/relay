import Foundation

/// Filesystem locations Relay owns under `~/Library/Application Support`.
///
/// Per build (Release `Relay/`, Debug `Relay Debug/`): the socket, the single-instance lock
/// (always the socket's sibling), and the stable `bin/RelayHook`. Shared by every build:
/// `Relay/Models/` — multi-GB downloads are never duplicated.
///
/// Compiled into BOTH the `Relay` app target and the `RelayHook` helper target. Foundation-only.
enum RelayPaths {
    static let socketFileName = "relay.sock"
    static let helperBasename = "RelayHook"
    /// Shared state (models) always lives under the Release directory name.
    static let sharedDirectoryName = BuildFlavor.release.supportDirectoryName

    /// `~/Library/Application Support`. `home` is injectable for tests only.
    static func applicationSupportRoot(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
    }

    /// This build's own directory: `…/Relay` or `…/Relay Debug`.
    static func supportDirectory(
        flavor: BuildFlavor = .current,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        applicationSupportRoot(home: home).appendingPathComponent(flavor.supportDirectoryName, isDirectory: true)
    }

    /// The Unix-domain socket this build's app listens on.
    static func socketPath(
        flavor: BuildFlavor = .current,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        supportDirectory(flavor: flavor, home: home).appendingPathComponent(socketFileName, isDirectory: false).path
    }

    /// The stable, app-bundle-independent helper this build installs and points hooks at.
    static func stableHelperURL(
        flavor: BuildFlavor = .current,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        supportDirectory(flavor: flavor, home: home)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent(helperBasename, isDirectory: false)
    }

    /// `…/Relay/Models` for EVERY flavor.
    static func sharedModelsDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        applicationSupportRoot(home: home)
            .appendingPathComponent(sharedDirectoryName, isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    /// The Relay support directory a stable helper lives in, or `nil` when `path` is not
    /// `…/Application Support/<Relay*>/bin/RelayHook` (any flavor, including future ones).
    static func supportDirectory(ofStableHelperPath path: String) -> URL? {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let components = url.pathComponents
        guard components.count >= 4 else { return nil }
        let tail = Array(components.suffix(4))
        guard tail[3] == helperBasename,
              tail[2] == "bin",
              tail[1].hasPrefix(sharedDirectoryName),
              tail[0] == "Application Support" else { return nil }
        return url.deletingLastPathComponent().deletingLastPathComponent()
    }

    static func isStableHelperPath(_ path: String) -> Bool {
        supportDirectory(ofStableHelperPath: path) != nil
    }

    /// The socket `RelayHook` should connect to, derived from where the helper binary itself
    /// lives: `<support>/bin/RelayHook` -> `<support>/relay.sock`. Any other location (a legacy
    /// hook pointing into an app bundle) falls back to the Release socket. No build flags.
    static func socketPath(
        forHelperExecutablePath executablePath: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        guard let supportDirectory = supportDirectory(ofStableHelperPath: executablePath) else {
            return socketPath(flavor: .release, home: home)
        }
        return supportDirectory.appendingPathComponent(socketFileName, isDirectory: false).path
    }
}
