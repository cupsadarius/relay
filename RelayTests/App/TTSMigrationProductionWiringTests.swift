import XCTest
@testable import Relay

@MainActor
final class TTSMigrationProductionWiringTests: XCTestCase {
    func testProductionUsesSpeechModelManagingForNeuralTTSBackends() {
        let runtime = RelayRuntime.makeProduction()

        XCTAssertTrue(runtime.speechOut.ttsModelManagers["kokoro"] is KokoroModelManager)
        XCTAssertTrue(runtime.speechOut.ttsModelManagers["pocket-tts"] is PocketTTSModelManager)
        XCTAssertNil(runtime.speechOut.ttsModelManagers["apple-tts"])
    }
}
