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
        func value(_ key: TerminalEnvironmentKey) -> String? { event.environment[key.rawValue] }
        rexServer = value(.rexServer)
        rexSessionID = value(.rexSession)
        rexBlockID = value(.rexBlock)
        tmuxSocketPath = value(.tmux)?.split(separator: ",", maxSplits: 1).first.map(String.init)
        tmuxPaneID = value(.tmuxPane)
        herdrSocketPath = value(.herdrSocketPath)
        herdrPaneID = value(.herdrPaneID) ?? value(.herdrActivePaneID)
    }
}
