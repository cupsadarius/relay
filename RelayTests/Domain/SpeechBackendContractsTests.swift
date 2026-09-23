import XCTest
@testable import Relay

final class SpeechBackendContractsTests: XCTestCase {
    func testBackendErrorFallbackClassification() {
        XCTAssertTrue(SpeechBackendError.unavailable("x").isFallbackWorthy)
        XCTAssertTrue(SpeechBackendError.modelNotDownloaded.isFallbackWorthy)
        XCTAssertTrue(SpeechBackendError.initializationFailed("x").isFallbackWorthy)
        XCTAssertTrue(SpeechBackendError.unsupportedOS.isFallbackWorthy)
        XCTAssertTrue(SpeechBackendError.unsupportedHardware.isFallbackWorthy)
        XCTAssertTrue(SpeechBackendError.inferenceFailed("x").isFallbackWorthy)
        XCTAssertTrue(SpeechBackendError.resourceExhausted.isFallbackWorthy)
        XCTAssertFalse(SpeechBackendError.permissionDenied.isFallbackWorthy)
        XCTAssertFalse(SpeechBackendError.noUsableAudio.isFallbackWorthy)
        XCTAssertFalse(SpeechBackendError.invalidInput.isFallbackWorthy)
    }
}
