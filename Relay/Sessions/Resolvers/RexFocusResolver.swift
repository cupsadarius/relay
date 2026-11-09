import ApplicationServices
import Foundation

/// Focus for agents inside Rex blocks. Agents run under the Rex server, not the Rex app, so the
/// generic process-ancestry check can never match them.
// razor: Rex has no API for the session the app shows, so the Rex window title ("<tab> - <session
// label>") stands in for it; duplicate labels fall back to the latest-prompt tie-break. Use the API once Rex ships one.
struct RexFocusResolver: FocusResolver {
    static let appBundlePrefix = "com.superlogical.rex"

    let id = "rex"
    let rex: any RexQuerying
    /// The title of the given app's focused window, or `nil` when it cannot be read.
    let focusedWindowTitle: @Sendable (Int32) async -> String?

    init(
        rex: any RexQuerying,
        focusedWindowTitle: @escaping @Sendable (Int32) async -> String? = RexFocusResolver.accessibilityWindowTitle
    ) {
        self.rex = rex
        self.focusedWindowTitle = focusedWindowTitle
    }

    func supports(_ session: AgentSession) -> Bool {
        session.terminalContext.rexSessionID != nil && session.terminalContext.rexBlockID != nil
    }

    func resolve(session: AgentSession, context: FocusContext) async -> FocusDecision {
        let terminal = session.terminalContext
        guard let sessionID = terminal.rexSessionID, let block = terminal.rexBlockID else {
            return .unknown(resolverID: id, reason: "missing Rex identifiers")
        }
        guard let app = context.frontmostApplication, app.bundleIdentifier?.hasPrefix(Self.appBundlePrefix) == true else {
            return .notFocused(resolverID: id, reason: "Rex is not the frontmost application")
        }
        let view: RexSessionView
        do {
            view = try await rex.sessionView(server: terminal.rexServer, sessionID: sessionID)
        } catch {
            return .unknown(resolverID: id, reason: "Rex focus query failed")
        }
        if let label = view.label, !label.isEmpty, let title = await focusedWindowTitle(app.pid),
            title != label, !title.hasSuffix(" - \(label)")
        {
            return .notFocused(resolverID: id, reason: "Rex is showing another session")
        }
        return view.focusedBlockID == block
            ? .focused(resolverID: id, reason: "producing block is focused in its Rex session")
            : .notFocused(resolverID: id, reason: "another block is focused in this Rex session")
    }

    @Sendable static func accessibilityWindowTitle(pid: Int32) async -> String? {
        let app = AXUIElementCreateApplication(pid)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
            let window, CFGetTypeID(window) == AXUIElementGetTypeID()
        else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success
        else { return nil }
        return title as? String
    }
}

struct RexSessionView: Equatable, Sendable {
    let label: String?
    /// The focused block of the session's active window, or `nil` when it has none.
    let focusedBlockID: String?
}

protocol RexQuerying: Sendable {
    func sessionView(server: String?, sessionID: String) async throws -> RexSessionView
}

/// Asks the Rex server through the `rex` CLI (`session.view`).
struct RexClient: RexQuerying {
    enum QueryError: Error { case notInstalled, failed }

    let executable: URL?
    let runner: any ProcessRunning

    init(executable: URL? = RexClient.locate(), runner: any ProcessRunning = BoundedProcessRunner()) {
        self.executable = executable
        self.runner = runner
    }

    static func locate() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(
                "Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/rex"),
            URL(fileURLWithPath: "/usr/local/bin/rex"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func sessionView(server: String?, sessionID: String) async throws -> RexSessionView {
        guard let executable else { throw QueryError.notInstalled }
        let input = try JSONSerialization.data(withJSONObject: ["session_id": sessionID])
        var arguments = server.map { ["-S", $0] } ?? []
        arguments += ["--autostart=false", "--timeout", "1s", "api", "call", "session.view", String(decoding: input, as: UTF8.self)]
        let result = try await runner.run(executable: executable, arguments: arguments, timeout: 2, maxOutputBytes: 1 << 20)
        guard result.terminationStatus == 0 else { throw QueryError.failed }
        return try Self.sessionView(from: result.stdout)
    }

    static func sessionView(from data: Data) throws -> RexSessionView {
        struct Window: Decodable {
            let windowID: String
            let focusedBlockID: String?
            enum CodingKeys: String, CodingKey {
                case windowID = "window_id"
                case focusedBlockID = "focused_block_id"
            }
        }
        struct View: Decodable {
            let label: String?
            let activeWindowID: String?
            let windows: [Window]?
            enum CodingKeys: String, CodingKey {
                case label
                case activeWindowID = "active_window_id"
                case windows
            }
        }
        let view = try JSONDecoder().decode(View.self, from: data)
        return RexSessionView(
            label: view.label,
            focusedBlockID: view.windows?.first { $0.windowID == view.activeWindowID }?.focusedBlockID
        )
    }
}
