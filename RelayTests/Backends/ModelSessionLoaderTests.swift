import XCTest
@testable import Relay

/// Pins the single-flight load rules every FluidAudio engine shares. These are the same semantics
/// `FluidAudioParakeetEngineTests`/`FluidAudioKokoroEngineTests`/`FluidAudioPocketTTSEngineTests`
/// used to pin once per engine.
final class ModelSessionLoaderTests: XCTestCase {
    func testLocalLoadThatFailsValidationThrowsModelsNotDownloadedWithoutLoading() async {
        let probe = LoaderProbe()
        await probe.setPresent(false)
        let loader = makeLoader(probe)

        await assertLoad(loader, allowDownload: false, throws: .notDownloaded)

        let localCalls = await probe.localCalls
        let downloadCalls = await probe.downloadCalls
        XCTAssertEqual(localCalls, 0)
        XCTAssertEqual(downloadCalls, 0)
        let session = await loader.session
        XCTAssertNil(session)
    }

    func testLocalLoadValidatesThenLoadsAndExposesTheSession() async throws {
        let probe = LoaderProbe()
        let loader = makeLoader(probe)

        try await loader.load(allowDownload: false, progress: { _ in })

        let session = await loader.session
        XCTAssertEqual(session, "local-1")
        let validateCalls = await probe.validateCalls
        XCTAssertEqual(validateCalls, 1)
    }

    func testLoadIsANoOpOnceASessionIsLoaded() async throws {
        let probe = LoaderProbe()
        let loader = makeLoader(probe)

        try await loader.load(allowDownload: false, progress: { _ in })
        try await loader.load(allowDownload: false, progress: { _ in })
        try await loader.load(allowDownload: true, progress: { _ in })

        let validateCalls = await probe.validateCalls
        let localCalls = await probe.localCalls
        let downloadCalls = await probe.downloadCalls
        XCTAssertEqual(validateCalls, 1)
        XCTAssertEqual(localCalls, 1)
        XCTAssertEqual(downloadCalls, 0)
    }

    func testConcurrentLocalLoadsShareOneUnderlyingLoad() async throws {
        let probe = LoaderProbe()
        await probe.gateLocalLoads()
        let loader = makeLoader(probe)

        let first = Task { try await loader.load(allowDownload: false, progress: { _ in }) }
        let second = Task { try await loader.load(allowDownload: false, progress: { _ in }) }
        await waitUntil { await probe.localCalls == 1 }
        await settle()
        let callsWhileGated = await probe.localCalls

        await probe.openLocalGate()
        try await first.value
        try await second.value

        XCTAssertEqual(callsWhileGated, 1)
        let finalCalls = await probe.localCalls
        XCTAssertEqual(finalCalls, 1)
    }

    func testConcurrentDownloadsShareOneUnderlyingDownload() async throws {
        let probe = LoaderProbe()
        await probe.gateDownloads()
        let loader = makeLoader(probe)

        let first = Task { try await loader.load(allowDownload: true, progress: { _ in }) }
        let second = Task { try await loader.load(allowDownload: true, progress: { _ in }) }
        await waitUntil { await probe.downloadCalls == 1 }
        await settle()

        await probe.openDownloadGate()
        try await first.value
        try await second.value

        let downloadCalls = await probe.downloadCalls
        XCTAssertEqual(downloadCalls, 1)
    }

    func testDownloadSkipsValidationAndForwardsProgress() async throws {
        let probe = LoaderProbe()
        let loader = makeLoader(probe)
        let recorder = ProgressRecorder()

        try await loader.load(allowDownload: true, progress: { recorder.record($0) })

        XCTAssertEqual(recorder.values, [0.5, 1.0])
        let validateCalls = await probe.validateCalls
        XCTAssertEqual(validateCalls, 0)
        let session = await loader.session
        XCTAssertEqual(session, "download-1")
    }

    func testLoadFailureIsMappedAndClearsTheValidationCacheSoARetryRevalidates() async throws {
        let probe = LoaderProbe()
        await probe.setLocalError(LoaderTestError.boom)
        let loader = makeLoader(probe)

        await assertLoad(loader, allowDownload: false, throws: .mapped)

        await probe.setLocalError(nil)
        try await loader.load(allowDownload: false, progress: { _ in })

        let validateCalls = await probe.validateCalls
        let localCalls = await probe.localCalls
        XCTAssertEqual(validateCalls, 2, "a failed load must not leave a trusted positive validation behind")
        XCTAssertEqual(localCalls, 2)
    }

    func testValidationErrorsPropagateUnmapped() async {
        let probe = LoaderProbe()
        await probe.setValidateError(LoaderTestError.boom)
        let loader = makeLoader(probe)

        await assertLoad(loader, allowDownload: false, throws: .boom)
        let localCalls = await probe.localCalls
        XCTAssertEqual(localCalls, 0)
    }

    func testCancellationIsNotMappedAndKeepsTheValidationCache() async throws {
        let probe = LoaderProbe()
        await probe.setLocalError(CancellationError())
        let loader = makeLoader(probe)

        do {
            try await loader.load(allowDownload: false, progress: { _ in })
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // expected
        }

        await probe.setLocalError(nil)
        try await loader.load(allowDownload: false, progress: { _ in })
        let validateCalls = await probe.validateCalls
        XCTAssertEqual(validateCalls, 1, "cancellation says nothing about on-disk state")
    }

    func testLocalCallerFailsFastWhileAnUnvalidatedDownloadIsRunning() async throws {
        let probe = LoaderProbe()
        await probe.gateDownloads()
        let loader = makeLoader(probe)

        let download = Task { try await loader.load(allowDownload: true, progress: { _ in }) }
        await waitUntil { await probe.downloadCalls == 1 }

        await assertLoad(loader, allowDownload: false, throws: .notDownloaded)
        let validateCalls = await probe.validateCalls
        XCTAssertEqual(validateCalls, 0)

        await probe.openDownloadGate()
        try await download.value
    }

    func testLocalCallerJoinsARunningDownloadWhenPresenceIsAlreadyValidated() async throws {
        let probe = LoaderProbe()
        await probe.gateDownloads()
        let loader = makeLoader(probe, validatedModelsPresent: true)

        let download = Task { try await loader.load(allowDownload: true, progress: { _ in }) }
        await waitUntil { await probe.downloadCalls == 1 }
        let local = Task { try await loader.load(allowDownload: false, progress: { _ in }) }
        await settle()

        await probe.openDownloadGate()
        try await download.value
        try await local.value

        let localCalls = await probe.localCalls
        XCTAssertEqual(localCalls, 0)
        let session = await loader.session
        XCTAssertEqual(session, "download-1")
    }

    func testDownloadCallerWaitsForARunningLocalLoadThenDownloadsIfItFailed() async throws {
        let probe = LoaderProbe()
        await probe.gateLocalLoads()
        await probe.setLocalError(LoaderTestError.boom)
        let loader = makeLoader(probe)

        let local = Task { try await loader.load(allowDownload: false, progress: { _ in }) }
        await waitUntil { await probe.localCalls == 1 }
        let download = Task { try await loader.load(allowDownload: true, progress: { _ in }) }
        await settle()
        let downloadsWhileLocalRuns = await probe.downloadCalls

        await probe.openLocalGate()
        try await download.value
        do {
            try await local.value
            XCTFail("The local load itself still fails")
        } catch {
            XCTAssertEqual(error as? LoaderTestError, .mapped)
        }

        XCTAssertEqual(downloadsWhileLocalRuns, 0)
        let session = await loader.session
        XCTAssertEqual(session, "download-1")
    }

    func testTwoDownloadCallersWaitingOnAFailedLocalLoadStartOnlyOneDownload() async throws {
        let probe = LoaderProbe()
        await probe.gateLocalLoads()
        await probe.setLocalError(LoaderTestError.boom)
        let loader = makeLoader(probe)

        let local = Task { try? await loader.load(allowDownload: false, progress: { _ in }) }
        await waitUntil { await probe.localCalls == 1 }
        let firstDownload = Task { try await loader.load(allowDownload: true, progress: { _ in }) }
        let secondDownload = Task { try await loader.load(allowDownload: true, progress: { _ in }) }
        await settle()

        await probe.openLocalGate()
        _ = await local.value
        try await firstDownload.value
        try await secondDownload.value

        let downloadCalls = await probe.downloadCalls
        XCTAssertEqual(downloadCalls, 1, "the second waiter must join the first waiter's download")
    }

    func testDownloadCallerReusesTheSessionARunningLocalLoadProduced() async throws {
        let probe = LoaderProbe()
        await probe.gateLocalLoads()
        let loader = makeLoader(probe)

        let local = Task { try await loader.load(allowDownload: false, progress: { _ in }) }
        await waitUntil { await probe.localCalls == 1 }
        let download = Task { try await loader.load(allowDownload: true, progress: { _ in }) }
        await settle()

        await probe.openLocalGate()
        try await local.value
        try await download.value

        let downloadCalls = await probe.downloadCalls
        XCTAssertEqual(downloadCalls, 0)
        let session = await loader.session
        XCTAssertEqual(session, "local-1")
    }

    func testResetDropsTheSessionAndForgetsValidation() async throws {
        let probe = LoaderProbe()
        let loader = makeLoader(probe)
        try await loader.load(allowDownload: false, progress: { _ in })

        await loader.reset()

        let sessionAfterReset = await loader.session
        XCTAssertNil(sessionAfterReset)
        try await loader.load(allowDownload: false, progress: { _ in })
        let validateCalls = await probe.validateCalls
        XCTAssertEqual(validateCalls, 2)
    }

    func testResetWaitsForAnInFlightLoadAndLeavesNoSession() async throws {
        let probe = LoaderProbe()
        await probe.gateLocalLoads()
        let loader = makeLoader(probe)
        let local = Task { try? await loader.load(allowDownload: false, progress: { _ in }) }
        await waitUntil { await probe.localCalls == 1 }

        let reset = Task { await loader.reset() }
        await settle()
        await probe.openLocalGate()
        await reset.value
        _ = await local.value

        let session = await loader.session
        XCTAssertNil(session, "a load that finishes during reset must not resurrect the session")
    }

    func testUnloadDropsTheSessionButKeepsValidation() async throws {
        let probe = LoaderProbe()
        let loader = makeLoader(probe)
        try await loader.load(allowDownload: false, progress: { _ in })

        await loader.unload()

        let sessionAfterUnload = await loader.session
        XCTAssertNil(sessionAfterUnload)
        try await loader.load(allowDownload: false, progress: { _ in })
        let validateCalls = await probe.validateCalls
        let localCalls = await probe.localCalls
        XCTAssertEqual(validateCalls, 1)
        XCTAssertEqual(localCalls, 2)
    }

    func testInitialValidationSkipsTheFirstCheck() async throws {
        let probe = LoaderProbe()
        let loader = makeLoader(probe, validatedModelsPresent: true)

        try await loader.load(allowDownload: false, progress: { _ in })

        let validateCalls = await probe.validateCalls
        XCTAssertEqual(validateCalls, 0)
    }

    // MARK: - Helpers

    private func makeLoader(_ probe: LoaderProbe, validatedModelsPresent: Bool = false) -> ModelSessionLoader<String> {
        ModelSessionLoader(
            validatedModelsPresent: validatedModelsPresent,
            modelsNotDownloaded: { LoaderTestError.notDownloaded },
            mapLoadFailure: { _ in LoaderTestError.mapped },
            validateLocal: { try await probe.validate() },
            loadLocal: { try await probe.loadLocal() },
            downloadAndLoad: { progress in try await probe.download(progress: progress) }
        )
    }

    private func assertLoad(
        _ loader: ModelSessionLoader<String>,
        allowDownload: Bool,
        throws expected: LoaderTestError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await loader.load(allowDownload: allowDownload, progress: { _ in })
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? LoaderTestError, expected, file: file, line: line)
        }
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    private func waitUntil(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () async -> Bool
    ) async {
        for _ in 0..<10_000 {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("Condition never became true", file: file, line: line)
    }
}

private enum LoaderTestError: Error, Equatable {
    case notDownloaded
    case mapped
    case boom
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []
    func record(_ value: Double) { lock.withLock { storage.append(value) } }
    var values: [Double] { lock.withLock { storage } }
}

private actor LoaderProbe {
    private(set) var validateCalls = 0
    private(set) var localCalls = 0
    private(set) var downloadCalls = 0
    private var present = true
    private var validateError: (any Error)?
    private var localError: (any Error)?
    private var gateLocal = false
    private var gateDownload = false
    private var localGate: CheckedContinuation<Void, Never>?
    private var downloadGate: CheckedContinuation<Void, Never>?

    func setPresent(_ value: Bool) { present = value }
    func setValidateError(_ error: (any Error)?) { validateError = error }
    func setLocalError(_ error: (any Error)?) { localError = error }
    func gateLocalLoads() { gateLocal = true }
    func gateDownloads() { gateDownload = true }

    func openLocalGate() {
        gateLocal = false
        localGate?.resume()
        localGate = nil
    }

    func openDownloadGate() {
        gateDownload = false
        downloadGate?.resume()
        downloadGate = nil
    }

    func validate() throws -> Bool {
        validateCalls += 1
        if let validateError { throw validateError }
        return present
    }

    func loadLocal() async throws -> String {
        localCalls += 1
        if gateLocal {
            await withCheckedContinuation { localGate = $0 }
        }
        if let localError { throw localError }
        return "local-\(localCalls)"
    }

    func download(progress: @Sendable (Double) -> Void) async throws -> String {
        downloadCalls += 1
        progress(0.5)
        if gateDownload {
            await withCheckedContinuation { downloadGate = $0 }
        }
        progress(1.0)
        return "download-\(downloadCalls)"
    }
}
