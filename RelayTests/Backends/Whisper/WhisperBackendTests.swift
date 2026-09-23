import Foundation
import XCTest

@testable import Relay

/// Writes a `.verified` marker (with an empty file manifest -- `WhisperModelStore.presence(of:)`
/// only re-checks paths *listed* in the manifest, so an empty one is trivially satisfied) so tests
/// can mark a model "present" without exercising the real download/verify flow at all.
private func markWhisperModelPresent(_ id: WhisperModelID, in cacheDirectory: URL) throws {
    let directory = cacheDirectory.appendingPathComponent(id.rawValue, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let markerURL = directory.appendingPathComponent(".verified")
    try JSONEncoder().encode([String]()).write(to: markerURL)
}

/// Maps a `WhisperModelID` to a deterministic fake folder URL for a `WhisperRuntime` under test --
/// mirrors `WhisperRuntimeTests`' own convention, which `FakeWhisperEngine.load` relies on to
/// recover the requested model id.
private func fakeRuntimeModelFolder(for id: WhisperModelID) -> URL {
    URL(fileURLWithPath: "/fake/whisper-backend-models/\(id.rawValue)", isDirectory: true)
}

final class WhisperBackendTests: XCTestCase {
    private var tempDirectory: URL!
    private var store: WhisperModelStore!
    private var log: FakeWhisperEventLog!
    private var engine: FakeWhisperEngine!
    private var runtime: WhisperRuntime!
    private var selected: WhisperModelID?
    private var backend: WhisperBackend!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperBackendTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        store = WhisperModelStore(cacheDirectory: tempDirectory, downloader: FakeWhisperDownloader())
        log = FakeWhisperEventLog()
        engine = FakeWhisperEngine(log: log)
        runtime = WhisperRuntime(engine: engine, modelFolder: fakeRuntimeModelFolder(for:))
        selected = nil

        backend = WhisperBackend(store: store, runtime: runtime, selectedModel: { [weak self] in self?.selected })
    }

    override func tearDown() {
        backend = nil
        runtime = nil
        engine = nil
        log = nil
        store = nil
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
        super.tearDown()
    }

    func testAvailabilityModelNotDownloadedWhenNothingSelected() async {
        selected = nil

        let availability = await backend.availability()

        XCTAssertEqual(availability, .modelNotDownloaded)
    }

    func testAvailabilityModelNotDownloadedWhenSelectedModelAbsent() async {
        selected = .baseEn

        let availability = await backend.availability()

        XCTAssertEqual(availability, .modelNotDownloaded)
    }

    func testAvailabilityAvailableWhenSelectedModelPresent() async throws {
        selected = .baseEn
        try markWhisperModelPresent(.baseEn, in: tempDirectory)

        let availability = await backend.availability()

        XCTAssertEqual(availability, .available)
    }

    func testTranscribeRejectsWrongSampleRate() async {
        selected = .baseEn
        try? markWhisperModelPresent(.baseEn, in: tempDirectory)

        do {
            _ = try await backend.transcribe(
                audio: AudioInput(samples: [0.1, 0.2], sampleRate: 44_100),
                options: STTOptions()
            )
            XCTFail("expected invalidInput")
        } catch {
            XCTAssertEqual(error as? SpeechBackendError, .invalidInput)
        }
    }

    func testTranscribeRejectsEmptyAudio() async {
        selected = .baseEn
        try? markWhisperModelPresent(.baseEn, in: tempDirectory)

        do {
            _ = try await backend.transcribe(
                audio: AudioInput(samples: [], sampleRate: 16_000),
                options: STTOptions()
            )
            XCTFail("expected noUsableAudio")
        } catch {
            XCTAssertEqual(error as? SpeechBackendError, .noUsableAudio)
        }
    }

    func testTranscribeReturnsRuntimeTextAsTranscript() async throws {
        selected = .baseEn
        try markWhisperModelPresent(.baseEn, in: tempDirectory)

        let transcript = try await backend.transcribe(
            audio: AudioInput(samples: [0.1, 0.2, 0.3], sampleRate: 16_000),
            options: STTOptions()
        )

        XCTAssertEqual(transcript.text, "fake transcript")
        XCTAssertEqual(transcript.backendID, "whisper")
    }

    func testLoadFailureMapsToInitializationFailedSoRouterCanFallThrough() async throws {
        selected = .baseEn
        try markWhisperModelPresent(.baseEn, in: tempDirectory)
        engine.errorToThrow = FakeWhisperEngineError.simulatedLoadFailure

        do {
            _ = try await backend.transcribe(
                audio: AudioInput(samples: [0.1, 0.2, 0.3], sampleRate: 16_000),
                options: STTOptions()
            )
            XCTFail("expected a fallback-worthy SpeechBackendError")
        } catch let error as SpeechBackendError {
            XCTAssertTrue(error.isFallbackWorthy)
        } catch {
            XCTFail("expected a SpeechBackendError, got \(error)")
        }
    }
}
