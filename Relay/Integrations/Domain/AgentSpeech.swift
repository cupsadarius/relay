import Foundation

extension AgentProvider {
    /// The `SpeechSource` attributed to speech produced from this agent's responses.
    var speechSource: SpeechSource {
        switch self {
        case .claudeCode: .claudeCode
        case .codex: .codex
        }
    }
}

extension AgentResponseEvent {
    var sessionID: AgentSessionID {
        AgentSessionID(provider: provider, providerSessionID: providerSessionID)
    }

    /// The single place an agent response becomes a `SpeechRequest`: source from the provider,
    /// session ID from `AgentSessionID.qualifiedName`. `text` is the already-preprocessed text.
    func speechRequest(text: String, mode: SpeechMode) -> SpeechRequest {
        SpeechRequest(text: text, source: provider.speechSource, mode: mode, sessionID: sessionID.qualifiedName)
    }
}
