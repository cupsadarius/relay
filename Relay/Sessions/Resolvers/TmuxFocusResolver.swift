import Foundation

struct TmuxFocusResolver: FocusResolver {
    let id = "tmux"
    let runner: any TmuxCommandRunning
    let processTrees: any ProcessTreeReading

    func supports(_ session: AgentSession) -> Bool {
        session.terminalContext.tmuxSocketPath != nil && session.terminalContext.tmuxPaneID != nil
    }

    func resolve(session: AgentSession, context: FocusContext) async -> FocusDecision {
        guard let frontmostPID = context.frontmostApplication?.pid,
              let socket = session.terminalContext.tmuxSocketPath,
              let producingPane = session.terminalContext.tmuxPaneID else {
            return .unknown(resolverID: id, reason: "missing frontmost app or tmux identifiers")
        }
        do {
            let clients = try await runner.listClients(socketPath: socket)
            var frontmostClients: [TmuxClientListing] = []
            for client in clients {
                if try await processTrees.ancestry(from: client.pid).contains(frontmostPID) {
                    frontmostClients.append(client)
                }
            }
            guard frontmostClients.count == 1, let client = frontmostClients.first else {
                return frontmostClients.isEmpty
                    ? .notFocused(resolverID: id, reason: "no client for this tmux server belongs to frontmost application")
                    : .unknown(resolverID: id, reason: "multiple tmux clients belong to the same frontmost application")
            }
            let activePane = try await runner.activePane(socketPath: socket, clientName: client.name)
            return activePane == producingPane
                ? .focused(resolverID: id, reason: "frontmost tmux client active pane matches producing pane")
                : .notFocused(resolverID: id, reason: "frontmost tmux client is focused on a different pane")
        } catch {
            return .unknown(resolverID: id, reason: "tmux focus query failed")
        }
    }
}
