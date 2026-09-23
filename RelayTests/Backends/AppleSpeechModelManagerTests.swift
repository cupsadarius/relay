import XCTest

@testable import Relay

final class AppleSpeechModelManagerTests: XCTestCase {
    func testBackendIDAndSingleAlwaysDownloadedModel() async {
        let manager = AppleSpeechModelManager()

        XCTAssertEqual(manager.backendID, "apple-speech")

        let models = await manager.models()

        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models[0].descriptor.id, "apple-on-device")
        XCTAssertEqual(models[0].capabilities, [.select])
        XCTAssertEqual(models[0].installState, .downloaded)
        XCTAssertTrue(models[0].isSelected)
    }

    func testDownloadIsNoOpSuccess() async throws {
        let manager = AppleSpeechModelManager()
        try await manager.downloadModel("apple-on-device", progress: { _ in })
    }

    func testSelectIsNoOpSuccessForTheOneModel() async throws {
        let manager = AppleSpeechModelManager()
        try await manager.selectModel("apple-on-device")
    }

    func testRemoveIsNotSupported() async {
        let manager = AppleSpeechModelManager()

        do {
            try await manager.removeModel("apple-on-device")
            XCTFail("Expected removeNotSupported")
        } catch let error as AppleSpeechModelManagerError {
            XCTAssertEqual(error, .removeNotSupported)
        } catch {
            XCTFail("expected AppleSpeechModelManagerError, got \(error)")
        }
    }

    func testUnknownModelIdThrows() async {
        let manager = AppleSpeechModelManager()

        do {
            try await manager.downloadModel("whisper-large", progress: { _ in })
            XCTFail("Expected unknownModel")
        } catch let error as AppleSpeechModelManagerError {
            XCTAssertEqual(error, .unknownModel("whisper-large"))
        } catch {
            XCTFail("expected AppleSpeechModelManagerError, got \(error)")
        }

        do {
            try await manager.selectModel("whisper-large")
            XCTFail("Expected unknownModel")
        } catch let error as AppleSpeechModelManagerError {
            XCTAssertEqual(error, .unknownModel("whisper-large"))
        } catch {
            XCTFail("expected AppleSpeechModelManagerError, got \(error)")
        }

        do {
            try await manager.removeModel("whisper-large")
            XCTFail("Expected unknownModel")
        } catch let error as AppleSpeechModelManagerError {
            XCTAssertEqual(error, .unknownModel("whisper-large"))
        } catch {
            XCTFail("expected AppleSpeechModelManagerError, got \(error)")
        }
    }
}
