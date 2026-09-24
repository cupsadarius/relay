import Synchronization
import XCTest

@testable import Relay

@MainActor
final class AppleFoundationCleanupModelManagerTests: XCTestCase {
    private let selection = LockedValue<CleanupModelID?>(nil)

    private func makeManager(_ apple: FakeAppleCleanup, locale: Locale = Locale(identifier: "en_US")) -> AppleFoundationCleanupModelManager {
        let selection = selection
        return AppleFoundationCleanupModelManager(
            backend: apple,
            selectedModel: { selection.withLock { $0 } },
            setSelectedModel: { id in selection.withLock { $0 = id } },
            locale: { locale }
        )
    }

    func testAvailableModelIsBuiltInSelectableAndUsable() async throws {
        let statuses = await makeManager(FakeAppleCleanup()).models()
        let status = try XCTUnwrap(statuses.first)
        XCTAssertEqual(statuses.count, 1)
        XCTAssertEqual(status.id, "apple.system-language-model")
        XCTAssertEqual(status.descriptor.displayName, "Apple Intelligence")
        XCTAssertEqual(status.descriptor.detail, "Built in")
        XCTAssertEqual(status.capabilities, [.select])
        XCTAssertEqual(status.installState, .downloaded)
        XCTAssertEqual(status.usability, .usable)
        XCTAssertFalse(status.isSelected)
    }

    func testUnavailableReasonsBecomeUnusableRows() async {
        let reasons: [(AppleUnavailability, String)] = [
            (.appleIntelligenceNotEnabled, "Apple Intelligence is off"),
            (.deviceNotEligible, "Not supported on this Mac"),
            (.modelNotReady, "Apple model is not ready yet"),
            (.unknown, "Apple model is unavailable"),
        ]
        for (reason, text) in reasons {
            let statuses = await makeManager(FakeAppleCleanup(availability: .unavailable(reason))).models()
            XCTAssertEqual(statuses.first?.usability, .unusable(reason: text))
        }
    }

    func testNonEnglishLocaleShowsTheEnglishOnlyDetail() async {
        let french = await makeManager(FakeAppleCleanup(), locale: Locale(identifier: "fr_FR")).models()
        XCTAssertEqual(french.first?.descriptor.detail, "Built in · English only in this version")
        let unsupported = await makeManager(FakeAppleCleanup(supportsLocale: false)).models()
        XCTAssertEqual(unsupported.first?.descriptor.detail, "Built in · English only in this version")
    }

    func testSelectWritesTheGlobalSelectionOnlyWhenAvailable() async throws {
        try await makeManager(FakeAppleCleanup()).selectModel("apple.system-language-model")
        XCTAssertEqual(selection.withLock { $0 }, .appleSystem)
        let statuses = await makeManager(FakeAppleCleanup()).models()
        XCTAssertEqual(statuses.first?.isSelected, true)

        selection.withLock { $0 = nil }
        do {
            try await makeManager(FakeAppleCleanup(availability: .unavailable(.modelNotReady))).selectModel("apple.system-language-model")
            XCTFail("expected unavailable")
        } catch {
            XCTAssertEqual(error as? CleanupModelManagerError, .unavailable)
        }
        XCTAssertNil(selection.withLock { $0 })
    }

    func testDownloadAndRemoveAreNotSupported() async {
        let manager = makeManager(FakeAppleCleanup())
        let operations: [() async throws -> Void] = [
            { try await manager.removeModel("apple.system-language-model") },
            { try await manager.downloadModel("apple.system-language-model") { _ in } },
        ]
        for operation in operations {
            do {
                try await operation()
                XCTFail("expected notSupported")
            } catch {
                XCTAssertEqual(error as? CleanupModelManagerError, .notSupported)
            }
        }
    }

    func testUnknownIDs() async {
        do {
            try await makeManager(FakeAppleCleanup()).selectModel("mlx.qwen3-0.6b-4bit")
            XCTFail("expected unknownModel")
        } catch {
            XCTAssertEqual(error as? CleanupModelManagerError, .unknownModel("mlx.qwen3-0.6b-4bit"))
        }
    }
}
