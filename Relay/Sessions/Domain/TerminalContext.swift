import Foundation

struct TerminalContext: Equatable, Sendable {
    let tmuxSocketPath: String?
    let tmuxPaneID: String?
    let herdrSocketPath: String?
    let herdrPaneID: String?
    let rexServer: String?
    let rexSessionID: String?
    let rexBlockID: String?

    init(event: AgentResponseEvent) {
        rexServer = event.environment["REX_SERVER"]
        rexSessionID = event.environment["REX_SESSION"]
        rexBlockID = event.environment["REX_BLOCK"]
        tmuxSocketPath = event.environment["TMUX"]?.split(separator: ",", maxSplits: 1).first.map(String.init)
        tmuxPaneID = event.environment["TMUX_PANE"]
        herdrSocketPath = event.environment["HERDR_SOCKET_PATH"]
        herdrPaneID = event.environment["HERDR_PANE_ID"] ?? event.environment["HERDR_ACTIVE_PANE_ID"]
    }
}
