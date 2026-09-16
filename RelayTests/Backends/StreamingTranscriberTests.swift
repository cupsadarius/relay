import XCTest
@testable import Relay

@MainActor
final class StreamingTranscriberTests: XCTestCase {
    func testTickLoopCallsTranscribeRepeatedlyAtTheConfiguredIntervalAndForwardsResultText() async throws {
        let recorder = CallRecorder()
        let transcriber = StreamingTranscriber(
            tickInterval: .milliseconds(20),
            transcribe: { audio in
                await recorder.record(audio)
                return Transcript(text: "hello", backendID: "fake")
            },
            onInterimText: { text in
                Task { await recorder.recordInterim(text) }
            }
        )

        await transcriber.start()
        await transcriber.appendSamples([0.1, 0.2, 0.3])
        try await Task.sleep(for: .milliseconds(90))
        await transcriber.stop()

        let count = await recorder.callCount
        XCTAssertGreaterThanOrEqual(count, 2)
        let interimTexts = await recorder.interimTexts
        XCTAssertEqual(interimTexts, Array(repeating: "hello", count: interimTexts.count))
        XCTAssertFalse(interimTexts.isEmpty)
    }

    func testDebounceNeverAllowsMoreThanOneTranscriptionInFlightAtOnce() async throws {
        let recorder = CallRecorder()
        let gate = Gate()
        let transcriber = StreamingTranscriber(
            tickInterval: .milliseconds(15),
            transcribe: { audio in
                await recorder.beginCall()
                await gate.waitUntilOpened()
                await recorder.endCall()
                return Transcript(text: "x", backendID: "fake")
            },
            onInterimText: { _ in }
        )

        await transcriber.start()
        await transcriber.appendSamples([0.1])
        // Several tick intervals elapse while the first transcription is deliberately still in
        // flight; debounce means none of them should start a second, overlapping call.
        try await Task.sleep(for: .milliseconds(80))
        let maxConcurrent = await recorder.maxConcurrent
        await gate.open()
        try await Task.sleep(for: .milliseconds(30))
        await transcriber.stop()

        XCTAssertEqual(maxConcurrent, 1)
    }

    func testAppendSamplesTrimsToTheMostRecentMaxWindowSamples() async throws {
        let recorder = CallRecorder()
        let transcriber = StreamingTranscriber(
            tickInterval: .milliseconds(15),
            maxWindowSamples: 5,
            transcribe: { audio in
                await recorder.record(audio)
                return Transcript(text: "x", backendID: "fake")
            },
            onInterimText: { _ in }
        )

        await transcriber.start()
        await transcriber.appendSamples([1, 2, 3])
        await transcriber.appendSamples([4, 5, 6, 7])
        try await Task.sleep(for: .milliseconds(40))
        await transcriber.stop()

        let audios = await recorder.receivedAudios
        XCTAssertFalse(audios.isEmpty)
        for audio in audios {
            XCTAssertLessThanOrEqual(audio.samples.count, 5)
        }
        XCTAssertEqual(audios.last?.samples, [3, 4, 5, 6, 7])
    }

    func testStopCancelsTheTickLoopSoNoFurtherTranscriptionsHappen() async throws {
        let recorder = CallRecorder()
        let transcriber = StreamingTranscriber(
            tickInterval: .milliseconds(15),
            transcribe: { audio in
                await recorder.record(audio)
                return Transcript(text: "hi", backendID: "fake")
            },
            onInterimText: { _ in }
        )

        await transcriber.start()
        await transcriber.appendSamples([0.1])
        try await Task.sleep(for: .milliseconds(40))
        await transcriber.stop()
        let countAtStop = await recorder.callCount

        try await Task.sleep(for: .milliseconds(60))
        let countAfterWaiting = await recorder.callCount

        XCTAssertEqual(countAtStop, countAfterWaiting)
    }

    func testTickIsSkippedWhenNoSamplesHaveBeenAppendedYet() async throws {
        let recorder = CallRecorder()
        let transcriber = StreamingTranscriber(
            tickInterval: .milliseconds(15),
            transcribe: { audio in
                await recorder.record(audio)
                return Transcript(text: "x", backendID: "fake")
            },
            onInterimText: { _ in }
        )

        await transcriber.start()
        try await Task.sleep(for: .milliseconds(50))
        await transcriber.stop()

        let count = await recorder.callCount
        XCTAssertEqual(count, 0)
    }
}

private actor CallRecorder {
    private(set) var callCount = 0
    private(set) var concurrentCount = 0
    private(set) var maxConcurrent = 0
    private(set) var receivedAudios: [AudioInput] = []
    private(set) var interimTexts: [String] = []

    func record(_ audio: AudioInput) {
        callCount += 1
        receivedAudios.append(audio)
    }

    func beginCall() {
        callCount += 1
        concurrentCount += 1
        maxConcurrent = max(maxConcurrent, concurrentCount)
    }

    func endCall() {
        concurrentCount -= 1
    }

    func recordInterim(_ text: String) {
        interimTexts.append(text)
    }
}

private actor Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func waitUntilOpened() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
