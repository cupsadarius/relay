import Foundation

struct GenericTerminalFocusResolver: FocusResolver {
    let id = "generic-terminal"

    func supports(_ session: AgentSession) -> Bool {
        Self.isDirect(session)
    }

    func resolve(session: AgentSession, context: FocusContext) async -> FocusDecision {
        guard let frontmostPID = context.frontmostApplication?.pid else {
            return .unknown(resolverID: id, reason: "no frontmost application")
        }
        guard session.processAncestry.contains(frontmostPID) else {
            return .notFocused(resolverID: id, reason: "frontmost application is outside producing process ancestry")
        }

        let directCandidates = context.sessions.filter {
            Self.isDirect($0) && $0.processAncestry.contains(frontmostPID)
        }
        guard directCandidates.count == 1, directCandidates[0].id == session.id else {
            return .unknown(resolverID: id, reason: "multiple direct agent sessions share the frontmost terminal process")
        }
        return .focused(resolverID: id, reason: "single direct session belongs to frontmost process ancestry")
    }

    /// Not inside a multiplexer pane, whose own resolver owns focus.
    private static func isDirect(_ session: AgentSession) -> Bool {
        let terminal = session.terminalContext
        return terminal.tmuxPaneID == nil && terminal.herdrPaneID == nil && terminal.rexBlockID == nil
    }
}
