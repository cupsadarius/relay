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

        XCTAssertTrue(graph.sttRegistry["apple-speech"] is AppleSpeechBackend)
        XCTAssertTrue(graph.sttRegistry["parakeet"] is ParakeetBackend)
        XCTAssertTrue(graph.sttRegistry["whisper"] is WhisperBackend)
        XCTAssertEqual((graph.speechModelManagers["apple-speech"] as? SingleModelManager)?.backendID, "apple-speech")
        XCTAssertTrue(graph.speechModelManagers["parakeet"] is ParakeetModelManager)
        XCTAssertTrue(graph.speechModelManagers["whisper"] is WhisperModelManager)
    }

    func testRegistersConcreteTextToSpeechBackendsAndOnlyModelBackedManagers() {
        let graph = makeGraph()

        XCTAssertTrue(graph.ttsRegistry["pocket-tts"] is PocketTTSBackend)
        XCTAssertTrue(graph.ttsRegistry["kokoro"] is KokoroTTSBackend)
        XCTAssertTrue(graph.ttsRegistry["apple-tts"] is AppleTTSBackend)
        XCTAssertEqual((graph.ttsModelManagers["pocket-tts"] as? SingleModelManager)?.backendID, "pocket-tts")
        XCTAssertEqual((graph.ttsModelManagers["kokoro"] as? SingleModelManager)?.backendID, "kokoro")
        XCTAssertNil(graph.ttsModelManagers["apple-tts"])
    }

    func testRegistryKeysMatchTheIDsAppSettingsRecognizes() {
        let graph = makeGraph()

        XCTAssertEqual(Set(graph.sttRegistry.keys), AppSettings.knownSTTBackendIDs)
        XCTAssertEqual(Set(graph.ttsRegistry.keys), AppSettings.knownTTSBackendIDs)
    }
}
