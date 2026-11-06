import Foundation

/// Focus for agents inside Rex blocks. Agents run under the Rex server, not the Rex app, so the
/// generic process-ancestry check can never match them.
// razor: Rex has no API for the session the app shows, so every Rex session whose own focused
// block is the agent's counts; the coordinator breaks ties by latest prompt. Use the API once Rex ships one.
struct RexFocusResolver: FocusResolver {
    static let appBundlePrefix = "com.superlogical.rex"

    let id = "rex"
    let rex: any RexQuerying

    func supports(_ session: AgentSession) -> Bool {
        session.terminalContext.rexSessionID != nil && session.terminalContext.rexBlockID != nil
    }

    func resolve(session: AgentSession, context: FocusContext) async -> FocusDecision {
        let terminal = session.terminalContext
        guard let sessionID = terminal.rexSessionID, let block = terminal.rexBlockID else {
            return .unknown(resolverID: id, reason: "missing Rex identifiers")
        }
        guard context.frontmostApplication?.bundleIdentifier?.hasPrefix(Self.appBundlePrefix) == true else {
            return .notFocused(resolverID: id, reason: "Rex is not the frontmost application")
        }
        do {
            let focused = try await rex.focusedBlockID(server: terminal.rexServer, sessionID: sessionID)
            return focused == block
                ? .focused(resolverID: id, reason: "producing block is focused in its Rex session")
                : .notFocused(resolverID: id, reason: "another block is focused in this Rex session")
        } catch {
            return .unknown(resolverID: id, reason: "Rex focus query failed")
        }
    }
}

protocol RexQuerying: Sendable {
    /// The focused block of the session's active window, or `nil` when it has none.
    func focusedBlockID(server: String?, sessionID: String) async throws -> String?
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

    func focusedBlockID(server: String?, sessionID: String) async throws -> String? {
        guard let executable else { throw QueryError.notInstalled }
        let input = try JSONSerialization.data(withJSONObject: ["session_id": sessionID])
        var arguments = server.map { ["-S", $0] } ?? []
        arguments += ["--autostart=false", "--timeout", "1s", "api", "call", "session.view", String(decoding: input, as: UTF8.self)]
        let result = try await runner.run(executable: executable, arguments: arguments, timeout: 2, maxOutputBytes: 1 << 20)
        guard result.terminationStatus == 0 else { throw QueryError.failed }
        return try Self.focusedBlockID(inSessionView: result.stdout)
    }

    static func focusedBlockID(inSessionView data: Data) throws -> String? {
        struct Window: Decodable {
            let windowID: String
            let focusedBlockID: String?
            enum CodingKeys: String, CodingKey {
                case windowID = "window_id"
                case focusedBlockID = "focused_block_id"
            }
        }
        struct View: Decodable {
            let activeWindowID: String?
            let windows: [Window]?
            enum CodingKeys: String, CodingKey {
                case activeWindowID = "active_window_id"
                case windows
            }
        }
        let view = try JSONDecoder().decode(View.self, from: data)
        return view.windows?.first { $0.windowID == view.activeWindowID }?.focusedBlockID
    }
}
