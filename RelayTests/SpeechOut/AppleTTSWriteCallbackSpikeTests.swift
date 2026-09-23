import AVFoundation
import XCTest

/// Real-`AVSpeechSynthesizer` smoke test. Also prints which thread delivers `write` buffers
/// (recorded in the cleanup-4 plan's execution notes). Skips when no system voice is installed.
@MainActor
final class AppleTTSWriteCallbackSpikeTests: XCTestCase {
    func testRealWriteDeliversBuffersThenAnEmptyTerminator() async throws {
        guard !AVSpeechSynthesisVoice.speechVoices().isEmpty else {
            throw XCTSkip("No system speech voices installed")
        }
        let synthesizer = AVSpeechSynthesizer()
        let probe = WriteCallbackProbe()
        let ended = expectation(description: "a zero-length buffer ends the write")
        // Apple may deliver more than one zero-length buffer; only the first matters.
        ended.assertForOverFulfill = false

        // `@Sendable` so Swift 6 does not infer this closure as main-actor isolated: if Apple
        // calls it off the main thread, an inferred-isolated closure would trap.
        synthesizer.write(AVSpeechUtterance(string: "Relay.")) { @Sendable buffer in
            let isMainThread = Thread.isMainThread
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            probe.record(isMainThread: isMainThread, frameLength: Int(pcm.frameLength))
            if pcm.frameLength == 0 { ended.fulfill() }
        }

        await fulfillment(of: [ended], timeout: 20)
        let summary = probe.summary
        print("SPIKE apple-tts-write-callback: \(summary)")
        XCTAssertGreaterThan(summary.nonEmptyBuffers, 0)
    }
}

private final class WriteCallbackProbe: @unchecked Sendable {
    struct Summary: CustomStringConvertible {
        var mainThreadCallbacks = 0
        var backgroundCallbacks = 0
        var nonEmptyBuffers = 0

        var description: String {
            "main=\(mainThreadCallbacks) background=\(backgroundCallbacks) nonEmptyBuffers=\(nonEmptyBuffers)"
        }
    }

    private let lock = NSLock()
    private var storage = Summary()

    func record(isMainThread: Bool, frameLength: Int) {
        lock.withLock {
            if isMainThread { storage.mainThreadCallbacks += 1 } else { storage.backgroundCallbacks += 1 }
            if frameLength > 0 { storage.nonEmptyBuffers += 1 }
        }
    }

    var summary: Summary { lock.withLock { storage } }
}
