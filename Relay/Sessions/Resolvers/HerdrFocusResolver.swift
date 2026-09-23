import Foundation

struct HerdrFocusResolver: FocusResolver {
    let id = "herdr"
    let herdr: any HerdrQuerying
    let hostOwnership: any HerdrHostOwnershipChecking

    func supports(_ session: AgentSession) -> Bool {
        session.terminalContext.herdrSocketPath != nil && session.terminalContext.herdrPaneID != nil
    }

    func resolve(session: AgentSession, context: FocusContext) async -> FocusDecision {
        guard let frontmostPID = context.frontmostApplication?.pid,
              let socket = session.terminalContext.herdrSocketPath,
              let producingPane = session.terminalContext.herdrPaneID else {
            return .unknown(resolverID: id, reason: "missing frontmost app or Herdr identifiers")
        }
        guard let processSnapshot = context.processSnapshot else {
            return .unknown(resolverID: id, reason: "process snapshot unavailable")
        }
        guard await hostOwnership.frontmostAppOwnsClient(
            frontmostPID: frontmostPID,
            socketPath: socket,
            processSnapshot: processSnapshot
        ) else {
            return .notFocused(resolverID: id, reason: "frontmost app does not own a client for this Herdr socket")
        }
        do {
            let current = try await herdr.currentPane(socketPath: socket)
            guard current.paneID == producingPane else {
                return .notFocused(resolverID: id, reason: "Herdr active focused pane differs from producing pane")
            }
            if let nativeSession = current.agentSession,
               nativeSession.value != session.id.providerSessionID {
                return .notFocused(resolverID: id, reason: "Herdr focused pane belongs to a different native agent session")
            }
            return .focused(resolverID: id, reason: "frontmost Herdr client and active pane match producing session")
        } catch {
            return .unknown(resolverID: id, reason: "Herdr focus query failed")
        }
    }
}
