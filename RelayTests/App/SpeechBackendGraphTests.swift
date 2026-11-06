import XCTest

@testable import Relay

/// Pins the production speech registries without building the rest of `makeProduction()`
/// (no UserDefaults, event tap, or socket).
@MainActor
final class SpeechBackendGraphTests: XCTestCase {
    private func makeGraph() -> SpeechBackendGraph {
        SpeechBackendGraph.make(
            whisperSelection: { nil }, setWhisperSelection: { _ in },
            parakeetSelection: { nil }, setParakeetSelection: { _ in }
        )
    }

    func testRegistersConcreteSpeechToTextBackendsAndManagers() {
        let graph = makeGraph()

        XCTAssertTrue(graph.sttRegistry[.appleSpeech] is AppleSpeechBackend)
        XCTAssertTrue(graph.sttRegistry[.parakeet] is ParakeetBackend)
        XCTAssertTrue(graph.sttRegistry[.whisper] is WhisperBackend)
        XCTAssertEqual((graph.speechModelManagers[.appleSpeech] as? SingleModelManager)?.backendID, .appleSpeech)
        XCTAssertTrue(graph.speechModelManagers[.parakeet] is ParakeetModelManager)
        XCTAssertTrue(graph.speechModelManagers[.whisper] is WhisperModelManager)
    }

    func testRegistersConcreteTextToSpeechBackendsAndOnlyModelBackedManagers() {
        let graph = makeGraph()

        XCTAssertTrue(graph.ttsRegistry[.pocketTTS] is PocketTTSBackend)
        XCTAssertTrue(graph.ttsRegistry[.kokoro] is KokoroTTSBackend)
        XCTAssertTrue(graph.ttsRegistry[.appleTTS] is AppleTTSBackend)
        XCTAssertEqual((graph.ttsModelManagers[.pocketTTS] as? SingleModelManager)?.backendID, .pocketTTS)
        XCTAssertEqual((graph.ttsModelManagers[.kokoro] as? SingleModelManager)?.backendID, .kokoro)
        XCTAssertNil(graph.ttsModelManagers[.appleTTS])
    }

    func testRegistryKeysCoverEveryBackendIDOfTheirDirection() {
        let graph = makeGraph()

        XCTAssertEqual(Set(graph.sttRegistry.keys), Set(BackendID.allSpeechToText))
        XCTAssertEqual(Set(graph.ttsRegistry.keys), Set(BackendID.allTextToSpeech))
    }
}
