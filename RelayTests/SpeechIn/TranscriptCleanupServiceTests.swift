import XCTest

@testable import Relay

@MainActor
final class TranscriptCleanupServiceTests: XCTestCase {
    private let english = Locale(identifier: "en_US")
    private let start = ContinuousClock.now

    private func makeService(
        enabled: Bool = true,
        selection: CleanupModelID? = .qwen3_0_6b,
        apple: FakeAppleCleanup = FakeAppleCleanup(),
        mlx: FakeMLXRuntime = FakeMLXRuntime(),
        sleeper: TestSleeper = TestSleeper(),
        locale: Locale? = nil,
        memoryPressure: (any MemoryPressureMonitoring)? = nil,
        diagnostics: DiagnosticsRecorder? = nil
    ) -> TranscriptCleanupService {
        let locale = locale ?? english
        let instant = start
        return TranscriptCleanupService(
            isEnabled: { enabled },
            selection: { selection },
            apple: apple,
            mlx: mlx,
            sleep: sleeper.sleepFunction,
            now: { instant },
            locale: { locale },
            memoryPressure: memoryPressure,
            diagnostics: diagnostics
        )
    }

    private func clean(_ service: TranscriptCleanupService, _ text: String) async throws -> (result: TranscriptCleanupResult, attempts: Int) {
        var attempts = 0
        let result = try await service.cleanForInsertion(text) { attempts += 1 }
        return (result, attempts)
    }

    // MARK: Not attempted

    func testDisabledIsNotAttemptedAndRecordsNothing() async throws {
        let diagnostics = DiagnosticsRecorder()
        let mlx = FakeMLXRuntime()
        let (result, attempts) = try await clean(makeService(enabled: false, mlx: mlx, diagnostics: diagnostics), "hello")
        XCTAssertEqual(result, .notAttempted("hello"))
        XCTAssertEqual(attempts, 0)
        XCTAssertTrue(diagnostics.entries.isEmpty)
        let requests = await mlx.generateRequests
        XCTAssertTrue(requests.isEmpty)
    }

    func testNoSelectionIsNotAttempted() async throws {
        let (result, attempts) = try await clean(makeService(selection: nil), "hello")
        XCTAssertEqual(result, .notAttempted("hello"))
        XCTAssertEqual(attempts, 0)
    }

    // MARK: Gates

    func testInputOverTheCapFallsBack() async throws {
        let text = String(repeating: "a ", count: 1_001)
        let (result, attempts) = try await clean(makeService(), text)
        XCTAssertEqual(result.outcome, .fellBack(.inputTooLong))
        XCTAssertEqual(result.text, text)
        XCTAssertEqual(attempts, 0)
    }

    func testNonEnglishLocaleFallsBackForBothEngines() async throws {
        for selection in [CleanupModelID.qwen3_0_6b, .appleSystem] {
            let (result, _) = try await clean(makeService(selection: selection, locale: Locale(identifier: "fr_FR")), "bonjour")
            XCTAssertEqual(result.outcome, .fellBack(.unsupportedLocale))
        }
    }

    func testAppleUnavailabilityFallsBackWithItsReason() async throws {
        for reason in [AppleUnavailability.deviceNotEligible, .appleIntelligenceNotEnabled, .modelNotReady, .unknown] {
            let apple = FakeAppleCleanup(availability: .unavailable(reason))
            let (result, attempts) = try await clean(makeService(selection: .appleSystem, apple: apple), "hello")
            XCTAssertEqual(result.outcome, .fellBack(.appleUnavailable(reason)))
            XCTAssertEqual(attempts, 0)
        }
    }

    func testAppleLocaleGate() async throws {
        let apple = FakeAppleCleanup(supportsLocale: false)
        let (result, _) = try await clean(makeService(selection: .appleSystem, apple: apple), "hello")
        XCTAssertEqual(result.outcome, .fellBack(.unsupportedLocale))
    }

    func testMLXNotDownloadedFallsBack() async throws {
        let (result, _) = try await clean(makeService(mlx: FakeMLXRuntime(present: [])), "hello")
        XCTAssertEqual(result.outcome, .fellBack(.modelNotDownloaded))
    }

    func testColdMLXFallsBackAndStartsABackgroundLoad() async throws {
        let mlx = FakeMLXRuntime(readiness: .notLoaded)
        let (result, attempts) = try await clean(makeService(mlx: mlx), "hello")
        XCTAssertEqual(result.outcome, .fellBack(.modelCold))
        XCTAssertEqual(attempts, 0)
        await eventually { await mlx.ensureLoadedCalls == [.qwen3_0_6b] }
    }

    func testLoadingMLXFallsBackWithoutAnotherLoad() async throws {
        let mlx = FakeMLXRuntime(readiness: .loading)
        let (result, _) = try await clean(makeService(mlx: mlx), "hello")
        XCTAssertEqual(result.outcome, .fellBack(.modelCold))
        let calls = await mlx.ensureLoadedCalls
        XCTAssertEqual(calls, [])
    }

    func testFailedLoadFallsBackAndRetriesTheLoad() async throws {
        let mlx = FakeMLXRuntime(readiness: .loadFailed)
        let (result, _) = try await clean(makeService(mlx: mlx), "hello")
        XCTAssertEqual(result.outcome, .fellBack(.loadFailed))
        await eventually { await mlx.ensureLoadedCalls == [.qwen3_0_6b] }
    }

    func testUnloadingMLXIsBusy() async throws {
        let (result, _) = try await clean(makeService(mlx: FakeMLXRuntime(readiness: .unloading)), "hello")
        XCTAssertEqual(result.outcome, .fellBack(.runtimeBusy))
    }

    // MARK: Generation

    func testRuntimeAndEngineErrorsMapToFallbackReasons() async throws {
        let cases: [(any Error, CleanupModelID, CleanupFallbackReason)] = [
            (CleanupSlotError.busy, .qwen3_0_6b, .runtimeBusy),
            (MLXCleanupRuntimeError.notLoaded, .qwen3_0_6b, .modelCold),
            (CleanupEngineError.generation(.refusal), .appleSystem, .generationFailed(.refusal)),
            (CleanupEngineError.generation(.rateLimited), .appleSystem, .generationFailed(.rateLimited)),
            (CleanupTestError(), .qwen3_0_6b, .generationFailed(.mlxEngine)),
            (CleanupTestError(), .appleSystem, .generationFailed(.other)),
        ]
        for (error, model, reason) in cases {
            let failing: @Sendable (CleanupRequest, CleanupPriority) async throws -> String = { _, _ in throw error }
            let service = makeService(selection: model, apple: FakeAppleCleanup(handler: failing), mlx: FakeMLXRuntime(handler: failing))
            let (result, attempts) = try await clean(service, "hello")
            XCTAssertEqual(result.outcome, .fellBack(reason))
            XCTAssertEqual(result.text, "hello")
            XCTAssertEqual(attempts, 1)
        }
    }

    func testTimeoutReturnsTheInputAtTheDeadline() async throws {
        let sleeper = TestSleeper()
        let operation = ManualOperation(cooperative: false)
        let service = makeService(mlx: FakeMLXRuntime(handler: { _, _ in try await operation.run() }), sleeper: sleeper)
        let call = Task { try await service.cleanForInsertion("hello") {} }
        await eventually { operation.startCount == 1 && sleeper.pending(.milliseconds(2500)) == 1 }

        sleeper.fire(.milliseconds(2500))
        let result = try await call.value

        XCTAssertEqual(result.outcome, .fellBack(.timedOut))
        XCTAssertEqual(result.text, "hello")
        operation.finish(.success("late"))
    }

    func testCallerCancellationThrowsAndRecordsCancelled() async {
        let diagnostics = DiagnosticsRecorder()
        let operation = ManualOperation(cooperative: false)
        let service = makeService(mlx: FakeMLXRuntime(handler: { _, _ in try await operation.run() }), diagnostics: diagnostics)
        let call = Task { try await service.cleanForInsertion("hello") {} }
        await eventually { operation.startCount == 1 }

        call.cancel()

        do {
            _ = try await call.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(diagnostics.entries.last?.event, .dictationCleanup(.cancelled(model: .qwen3_0_6b)))
        operation.finish(.success("late"))
    }

    func testValidationRejectionFallsBack() async throws {
        let mlx = FakeMLXRuntime(handler: { _, _ in "Set the port to 3." })
        let (result, _) = try await clean(makeService(mlx: mlx), "set the port to 3, no, 4")
        XCTAssertEqual(result.outcome, .fellBack(.validationRejected(.literalMissing)))
        XCTAssertEqual(result.text, "set the port to 3, no, 4")
    }

    func testCleanedOutputIsReturnedWithDiagnostics() async throws {
        let diagnostics = DiagnosticsRecorder()
        let mlx = FakeMLXRuntime(handler: { _, _ in "  Set the port to 4.\n" })
        let (result, attempts) = try await clean(makeService(mlx: mlx, diagnostics: diagnostics), "set the port to 3, no, 4")
        XCTAssertEqual(result, TranscriptCleanupResult(text: "Set the port to 4.", modelID: .qwen3_0_6b, outcome: .cleaned, elapsed: .zero))
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(
            diagnostics.entries.map(\.event),
            [
                .dictationCleanup(.started(model: .qwen3_0_6b)),
                .dictationCleanup(.finished(model: .qwen3_0_6b, elapsed: .under250Milliseconds)),
            ]
        )
    }

    func testRequestUsesTheFixedPromptBudgetAndProductionPriority() async throws {
        let mlx = FakeMLXRuntime()
        _ = try await clean(makeService(mlx: mlx), "ship it")
        let requests = await mlx.generateRequests
        let priorities = await mlx.generatePriorities
        XCTAssertEqual(
            requests,
            [
                CleanupRequest(
                    modelID: .qwen3_0_6b, instructions: CleanupPrompt.instructions, input: "ship it",
                    maxOutputTokens: CleanupPrompt.maxOutputTokens(for: "ship it")
                )
            ]
        )
        XCTAssertEqual(priorities, [.production])
    }

    func testOnAttemptRunsBeforeGeneration() async throws {
        let log = OrderLog()
        let apple = FakeAppleCleanup(handler: { request, _ in
            log.append("generate")
            return request.input
        })
        _ = try await makeService(selection: .appleSystem, apple: apple).cleanForInsertion("ship it") { log.append("attempt") }
        XCTAssertEqual(log.values, ["attempt", "generate"])
    }

    // MARK: Prewarm

    func testPrewarmLoadsAndTouchesTheSelectedMLXModel() async {
        let mlx = FakeMLXRuntime(readiness: .notLoaded)
        makeService(mlx: mlx).prewarm()
        await eventually {
            let loads = await mlx.ensureLoadedCalls
            let touches = await mlx.touchCount
            return loads == [.qwen3_0_6b] && touches == 1
        }
    }

    func testPrewarmPrewarmsAnAvailableAppleModel() {
        let apple = FakeAppleCleanup()
        makeService(selection: .appleSystem, apple: apple).prewarm()
        XCTAssertEqual(apple.prewarmCount, 1)
    }

    func testPrewarmDoesNothingWhenDisabledUnavailableOrNotDownloaded() async {
        let mlx = FakeMLXRuntime(present: [])
        let apple = FakeAppleCleanup(availability: .unavailable(.modelNotReady))
        makeService(enabled: false, apple: apple).prewarm()
        makeService(selection: .appleSystem, apple: apple).prewarm()
        makeService(mlx: mlx).prewarm()
        XCTAssertEqual(apple.prewarmCount, 0)
        let calls = await mlx.ensureLoadedCalls
        XCTAssertEqual(calls, [])
    }

    // MARK: Diagnostics privacy

    func testDiagnosticsNeverIncludeTextOrLiterals() async throws {
        let diagnostics = DiagnosticsRecorder()
        let input = "deploy --secret-flag from src/secret.swift SECRET-PHRASE-42"
        let outputSentinel = "OUTPUT-SENTINEL-7 src/other-secret.swift"
        let secrets = ["--secret-flag", "src/secret.swift", "SECRET-PHRASE-42", "OUTPUT-SENTINEL-7", "src/other-secret.swift"]
        let echoOutput: @Sendable (CleanupRequest, CleanupPriority) async throws -> String = { _, _ in outputSentinel }
        let failing: @Sendable (CleanupRequest, CleanupPriority) async throws -> String = { _, _ in throw CleanupTestError() }

        let services: [TranscriptCleanupService] = [
            makeService(diagnostics: diagnostics), // cleaned (echo of input is valid)
            makeService(mlx: FakeMLXRuntime(handler: echoOutput), diagnostics: diagnostics), // validation rejected
            makeService(mlx: FakeMLXRuntime(present: []), diagnostics: diagnostics),
            makeService(mlx: FakeMLXRuntime(readiness: .notLoaded), diagnostics: diagnostics),
            makeService(mlx: FakeMLXRuntime(readiness: .loadFailed), diagnostics: diagnostics),
            makeService(mlx: FakeMLXRuntime(readiness: .unloading), diagnostics: diagnostics),
            makeService(mlx: FakeMLXRuntime(handler: failing), diagnostics: diagnostics),
            makeService(locale: Locale(identifier: "de_DE"), diagnostics: diagnostics),
            makeService(selection: .appleSystem, apple: FakeAppleCleanup(availability: .unavailable(.modelNotReady)), diagnostics: diagnostics),
            makeService(selection: .appleSystem, apple: FakeAppleCleanup(supportsLocale: false), diagnostics: diagnostics),
            makeService(selection: .appleSystem, apple: FakeAppleCleanup(handler: failing), diagnostics: diagnostics),
        ]
        for service in services {
            _ = try await service.cleanForInsertion(input) {}
        }
        _ = try await makeService(diagnostics: diagnostics).cleanForInsertion(input + String(repeating: " x", count: 1_000)) {}

        let sleeper = TestSleeper()
        let hanging = ManualOperation(cooperative: false)
        let timeoutService = makeService(mlx: FakeMLXRuntime(handler: { _, _ in try await hanging.run() }), sleeper: sleeper, diagnostics: diagnostics)
        let timeoutCall = Task { try await timeoutService.cleanForInsertion(input) {} }
        await eventually { sleeper.pending(.milliseconds(2500)) == 1 }
        sleeper.fire(.milliseconds(2500))
        _ = try await timeoutCall.value
        hanging.finish(.success(outputSentinel))

        let cancelled = ManualOperation(cooperative: false)
        let cancelService = makeService(mlx: FakeMLXRuntime(handler: { _, _ in try await cancelled.run() }), diagnostics: diagnostics)
        let cancelCall = Task { try await cancelService.cleanForInsertion(input) {} }
        await eventually { cancelled.startCount == 1 }
        cancelCall.cancel()
        _ = try? await cancelCall.value
        cancelled.finish(.success(outputSentinel))

        let text = diagnostics.copyText
        XCTAssertFalse(text.isEmpty)
        for secret in secrets {
            XCTAssertFalse(text.contains(secret), "diagnostics leaked a literal")
        }
    }

    func testMemoryPressureUnloadsTheRuntime() async {
        let pressure = FakeMemoryPressure()
        let mlx = FakeMLXRuntime()
        let service = makeService(mlx: mlx, memoryPressure: pressure)

        pressure.fire()

        await eventually { await mlx.unloadCauses == [.memoryPressure] }
        withExtendedLifetime(service) {}
    }

    func testRuntimeEventsBecomeStructuralDiagnostics() async {
        let diagnostics = DiagnosticsRecorder()
        let mlx = FakeMLXRuntime()
        let service = makeService(mlx: mlx, diagnostics: diagnostics)

        mlx.eventSink.yield(.loaded(.qwen3_0_6b, elapsed: .milliseconds(3200)))
        mlx.eventSink.yield(.unloaded(.qwen3_0_6b, cause: .idle))

        await eventually { diagnostics.entries.count == 2 }
        XCTAssertEqual(
            diagnostics.entries.map(\.event),
            [
                .dictationCleanup(.modelLoaded(model: .qwen3_0_6b, elapsed: .over2Point5Seconds)),
                .dictationCleanup(.modelUnloaded(model: .qwen3_0_6b, cause: .idle)),
            ]
        )
        withExtendedLifetime(service) {}
    }
}
