import XCTest

@testable import Relay

final class WhisperModelCatalogTests: XCTestCase {
    func testCatalogHasElevenModelsAndExcludesLargeV1() {
        XCTAssertEqual(WhisperModelID.allCases.count, 11)
        XCTAssertFalse(WhisperModelID.allCases.map(\.rawValue).contains("large-v1"))
    }

    func testEnglishOnlyFlagsAreCorrect() {
        XCTAssertTrue(WhisperModelCatalog.descriptor(for: .tinyEn).englishOnly)
        XCTAssertFalse(WhisperModelCatalog.descriptor(for: .turbo).englishOnly)
    }

    func testEveryModelHasNonEmptyArtifactAndPositiveSize() {
        for id in WhisperModelID.allCases {
            let d = WhisperModelCatalog.descriptor(for: id)
            XCTAssertFalse(d.runtimeArtifact.isEmpty)
            XCTAssertGreaterThan(d.approximateDiskBytes, 0)
        }
    }
}
