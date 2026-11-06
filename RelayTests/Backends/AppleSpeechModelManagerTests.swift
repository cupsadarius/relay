import XCTest

@testable import Relay

final class AppleSpeechModelManagerTests: XCTestCase {
    func testBackendIDAndSingleAlwaysDownloadedModel() async {
        let manager = SingleModelManager.appleSpeech

        XCTAssertEqual(manager.backendID, .appleSpeech)

        let models = await manager.models()

        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models[0].descriptor.id, "apple-on-device")
        XCTAssertEqual(models[0].capabilities, [.select])
        XCTAssertEqual(models[0].installState, .downloaded)
        XCTAssertTrue(models[0].isSelected)
    }

    func testDownloadIsNoOpSuccess() async throws {
        let manager = SingleModelManager.appleSpeech
        try await manager.downloadModel("apple-on-device", progress: { _ in })
    }

    func testSelectIsNoOpSuccessForTheOneModel() async throws {
        let manager = SingleModelManager.appleSpeech
        try await manager.selectModel("apple-on-device")
    }

    func testRemoveIsNotSupported() async {
        let manager = SingleModelManager.appleSpeech

        do {
            try await manager.removeModel("apple-on-device")
            XCTFail("Expected removeNotSupported")
        } catch let error as SpeechModelManagerError {
            XCTAssertEqual(error, .removeNotSupported)
        } catch {
            XCTFail("expected SpeechModelManagerError, got \(error)")
        }
    }

    func testUnknownModelIdThrows() async {
        let manager = SingleModelManager.appleSpeech

        do {
            try await manager.downloadModel("whisper-large", progress: { _ in })
            XCTFail("Expected unknownModel")
        } catch let error as SpeechModelManagerError {
            XCTAssertEqual(error, .unknownModel("whisper-large"))
        } catch {
            XCTFail("expected SpeechModelManagerError, got \(error)")
        }

        do {
            try await manager.selectModel("whisper-large")
            XCTFail("Expected unknownModel")
        } catch let error as SpeechModelManagerError {
            XCTAssertEqual(error, .unknownModel("whisper-large"))
        } catch {
            XCTFail("expected SpeechModelManagerError, got \(error)")
        }

        do {
            try await manager.removeModel("whisper-large")
            XCTFail("Expected unknownModel")
        } catch let error as SpeechModelManagerError {
            XCTAssertEqual(error, .unknownModel("whisper-large"))
        } catch {
            XCTFail("expected SpeechModelManagerError, got \(error)")
        }
    }
}
