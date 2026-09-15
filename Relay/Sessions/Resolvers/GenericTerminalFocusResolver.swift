import Foundation

struct GenericTerminalFocusResolver: FocusResolver {
    let id = "generic-terminal"

    func supports(_ session: AgentSession) -> Bool {
        session.terminalContext.tmuxPaneID == nil && session.terminalContext.herdrPaneID == nil
    }

    func resolve(session: AgentSession, context: FocusContext) async -> FocusDecision {
        guard let frontmostPID = context.frontmostApplication?.pid else {
            return .unknown(resolverID: id, reason: "no frontmost application")
        }
        guard session.processAncestry.contains(frontmostPID) else {
            return .notFocused(resolverID: id, reason: "frontmost application is outside producing process ancestry")
        }

        let directCandidates = context.sessions.filter {
            $0.terminalContext.tmuxPaneID == nil &&
            $0.terminalContext.herdrPaneID == nil &&
            $0.processAncestry.contains(frontmostPID)
        }
        guard directCandidates.count == 1, directCandidates[0].id == session.id else {
            return .unknown(resolverID: id, reason: "multiple direct agent sessions share the frontmost terminal process")
        }
        return .focused(resolverID: id, reason: "single direct session belongs to frontmost process ancestry")
    }
}
