import Foundation

struct TerminalContext: Equatable, Sendable {
    let termProgram: String?
    let tmuxSocketPath: String?
    let tmuxPaneID: String?
    let herdrSocketPath: String?
    let herdrPaneID: String?

    init(event: AgentResponseEvent) {
        termProgram = event.environment["TERM_PROGRAM"]
        tmuxSocketPath = event.environment["TMUX"]?.split(separator: ",", maxSplits: 1).first.map(String.init)
        tmuxPaneID = event.environment["TMUX_PANE"]
        herdrSocketPath = event.environment["HERDR_SOCKET_PATH"]
        herdrPaneID = event.environment["HERDR_PANE_ID"] ?? event.environment["HERDR_ACTIVE_PANE_ID"]
    }
}
