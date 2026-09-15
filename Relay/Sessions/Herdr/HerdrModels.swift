import Foundation

struct HerdrAgentSession: Codable, Equatable, Sendable {
    let source: String
    let agent: String
    let kind: String
    let value: String
}

struct HerdrPaneInfo: Equatable, Sendable {
    let paneID: String
    let focused: Bool
    let agentSession: HerdrAgentSession?
}

struct HerdrPaneWire: Decodable {
    let paneID: String
    let focused: Bool
    let agentSession: HerdrAgentSession?
    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case focused
        case agentSession = "agent_session"
    }
}

struct HerdrPaneResult: Decodable { let type: String; let pane: HerdrPaneWire }
struct HerdrResponse: Decodable { let id: String; let result: HerdrPaneResult? }
