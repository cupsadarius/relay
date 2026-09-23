import XCTest

@testable import Relay

/// Pins the production speech registries without building the rest of `makeProduction()`
/// (no UserDefaults, event tap, or socket).
@MainActor
final class SpeechBackendGraphTests: XCTestCase {
    private func makeGraph() -> SpeechBackendGraph {
        SpeechBackendGraph.make(whisperSelection: { nil }, setWhisperSelection: { _ in })
    }

    func testRegistersConcreteSpeechToTextBackendsAndManagers() {
        let graph = makeGraph()

        XCTAssertTrue(graph.sttRegistry["apple-speech"] is AppleSpeechBackend)
        XCTAssertTrue(graph.sttRegistry["parakeet"] is ParakeetBackend)
        XCTAssertTrue(graph.sttRegistry["whisper"] is WhisperBackend)
        XCTAssertTrue(graph.speechModelManagers["apple-speech"] is AppleSpeechModelManager)
        XCTAssertTrue(graph.speechModelManagers["parakeet"] is ParakeetModelManager)
        XCTAssertTrue(graph.speechModelManagers["whisper"] is WhisperModelManager)
    }

    func testRegistersConcreteTextToSpeechBackendsAndOnlyModelBackedManagers() {
        let graph = makeGraph()

        XCTAssertTrue(graph.ttsRegistry["pocket-tts"] is PocketTTSBackend)
        XCTAssertTrue(graph.ttsRegistry["kokoro"] is KokoroTTSBackend)
        XCTAssertTrue(graph.ttsRegistry["apple-tts"] is AppleTTSBackend)
        XCTAssertTrue(graph.ttsModelManagers["pocket-tts"] is PocketTTSModelManager)
        XCTAssertTrue(graph.ttsModelManagers["kokoro"] is KokoroModelManager)
        XCTAssertNil(graph.ttsModelManagers["apple-tts"])
    }

    func testRegistryKeysMatchTheIDsAppSettingsRecognizes() {
        let graph = makeGraph()

        XCTAssertEqual(Set(graph.sttRegistry.keys), AppSettings.knownSTTBackendIDs)
        XCTAssertEqual(Set(graph.ttsRegistry.keys), AppSettings.knownTTSBackendIDs)
    }
}
