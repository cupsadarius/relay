import Synchronization
import XCTest

@testable import Relay

/// A scriptable `AppleCleanupEngine`.
final class FakeAppleEngine: AppleCleanupEngine {
    private let state = Mutex((availability: AppleCleanupAvailability.available, prewarms: [String]()))
    private let handler: @Sendable (CleanupRequest) async throws -> String

    init(handler: @escaping @Sendable (CleanupRequest) async throws -> String = { $0.input }) { self.handler = handler }

    var prewarms: [String] { state.withLock { $0.prewarms } }
    func setAvailability(_ value: AppleCleanupAvailability) { state.withLock { $0.availability = value } }

    func availability() -> AppleCleanupAvailability { state.withLock { $0.availability } }
    func supportsLocale(_ locale: Locale) -> Bool { locale.language.languageCode == .english }
    func prewarm(instructions: String) { state.withLock { $0.prewarms.append(instructions) } }
    func respond(_ request: CleanupRequest) async throws -> String { try await handler(request) }
}

@MainActor
final class AppleCleanupRuntimeTests: XCTestCase {
    private let request = CleanupRequest(modelID: .appleSystem, instructions: "I", input: "hi", maxOutputTokens: 32)

    func testForwardsAvailabilityLocaleAndPrewarm() {
        let engine = FakeAppleEngine()
        let runtime = AppleCleanupRuntime(engine: engine, slot: CleanupGenerationSlot())
        XCTAssertEqual(runtime.availability(), .available)
        XCTAssertTrue(runtime.supportsLocale(Locale(identifier: "en_GB")))
        runtime.prewarm(instructions: "I")
        XCTAssertEqual(engine.prewarms, ["I"])
    }

    func testGenerationGoesThroughTheSharedSlot() async throws {
        let operation = ManualOperation(cooperative: true)
        let slot = CleanupGenerationSlot()
        let runtime = AppleCleanupRuntime(engine: FakeAppleEngine(handler: { _ in try await operation.run() }), slot: slot)
        let first = Task { try await runtime.generate(self.request, priority: .production) }
        await eventually { operation.startCount == 1 }

        do {
            _ = try await runtime.generate(request, priority: .production)
            XCTFail("expected busy")
        } catch {
            XCTAssertEqual(error as? CleanupSlotError, .busy)
        }
        operation.finish(.success("Hi."))
        let output = try await first.value
        XCTAssertEqual(output, "Hi.")
    }
}
