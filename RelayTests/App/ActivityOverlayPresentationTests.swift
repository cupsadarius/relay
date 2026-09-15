import CoreGraphics
import XCTest
@testable import Relay

final class ActivityOverlayPresentationTests: XCTestCase {
    func testOffAlwaysMapsToHidden() {
        let state = ActivityOverlayState.speaking(sessionID: UUID(), startedAt: .now, level: nil)

        XCTAssertNil(ActivityOverlayPresentation.make(state: state, style: .off, reduceMotion: false))
    }

    func testInteractiveListeningShowsCancelAndElapsedTime() {
        let id = UUID()
        let value = ActivityOverlayPresentation.make(
            state: .listening(sessionID: id, startedAt: .distantPast, level: 0.4),
            style: .interactive,
            reduceMotion: false
        )

        XCTAssertEqual(value?.title, "Listening")
        XCTAssertEqual(value?.subtitle, "Microphone")
        XCTAssertEqual(value?.action, .cancelDictation(sessionID: id))
        XCTAssertEqual(value?.actionAccessibilityLabel, "Cancel dictation")
        XCTAssertEqual(value?.size, CGSize(width: 282, height: 62))
    }

    func testMinimalHasNoTextOrControl() {
        let value = ActivityOverlayPresentation.make(
            state: .processing(sessionID: UUID(), startedAt: .now),
            style: .minimal,
            reduceMotion: false
        )

        XCTAssertNil(value?.title)
        XCTAssertNil(value?.subtitle)
        XCTAssertNil(value?.action)
        XCTAssertEqual(value?.size, CGSize(width: 154, height: 40))
    }

    func testReduceMotionDisablesAnimatedWaveformsAndScale() {
        let value = ActivityOverlayPresentation.make(
            state: .speaking(sessionID: UUID(), startedAt: .now, level: nil),
            style: .interactive,
            reduceMotion: true
        )

        XCTAssertFalse(value!.animatesWaveform)
        XCTAssertFalse(value!.usesScaleTransition)
    }

    func testProcessingMapsToCancelWithAmberAccent() {
        let id = UUID()
        let value = ActivityOverlayPresentation.make(
            state: .processing(sessionID: id, startedAt: .now), style: .interactive, reduceMotion: false
        )

        XCTAssertEqual(value?.accent, .amber)
        XCTAssertEqual(value?.subtitle, "Transcribing")
        XCTAssertEqual(value?.action, .cancelDictation(sessionID: id))
    }

    func testSpeakingMapsToStopWithVioletCyanAccent() {
        let id = UUID()
        let value = ActivityOverlayPresentation.make(
            state: .speaking(sessionID: id, startedAt: .now, level: nil), style: .interactive, reduceMotion: false
        )

        XCTAssertEqual(value?.accent, .violetCyan)
        XCTAssertEqual(value?.subtitle, "Speaking")
        XCTAssertEqual(value?.action, .stopSpeech(sessionID: id))
        XCTAssertEqual(value?.actionAccessibilityLabel, "Stop speech")
    }

    // MARK: - Backend name subtitle

    func testSubtitleUsesBackendNameWhenProvidedForListeningProcessingAndSpeaking() {
        let listening = ActivityOverlayPresentation.make(
            state: .listening(sessionID: UUID(), startedAt: .now, level: 0), style: .interactive, reduceMotion: false,
            backendName: "Apple Speech"
        )
        let processing = ActivityOverlayPresentation.make(
            state: .processing(sessionID: UUID(), startedAt: .now), style: .interactive, reduceMotion: false,
            backendName: "Apple Speech"
        )
        let speaking = ActivityOverlayPresentation.make(
            state: .speaking(sessionID: UUID(), startedAt: .now, level: nil), style: .interactive, reduceMotion: false,
            backendName: "Apple System Voice"
        )

        XCTAssertEqual(listening?.subtitle, "Apple Speech")
        XCTAssertEqual(processing?.subtitle, "Apple Speech")
        XCTAssertEqual(speaking?.subtitle, "Apple System Voice")
    }

    func testSubtitleFallsBackWhenNoBackendNameProvided() {
        let listening = ActivityOverlayPresentation.make(
            state: .listening(sessionID: UUID(), startedAt: .now, level: 0), style: .interactive, reduceMotion: false
        )
        let processing = ActivityOverlayPresentation.make(
            state: .processing(sessionID: UUID(), startedAt: .now), style: .interactive, reduceMotion: false
        )
        let speaking = ActivityOverlayPresentation.make(
            state: .speaking(sessionID: UUID(), startedAt: .now, level: nil), style: .interactive, reduceMotion: false
        )

        XCTAssertEqual(listening?.subtitle, "Microphone")
        XCTAssertEqual(processing?.subtitle, "Transcribing")
        XCTAssertEqual(speaking?.subtitle, "Speaking")
    }

    func testErrorSubtitleIsAlwaysTryAgainRegardlessOfBackendName() {
        let value = ActivityOverlayPresentation.make(
            state: .error(sessionID: UUID(), category: .speechPlayback, message: "boom"),
            style: .interactive, reduceMotion: false, backendName: "Apple System Voice"
        )

        XCTAssertEqual(value?.subtitle, "Try again")
    }

    // MARK: - Speaking waveform: live level vs synthetic curve

    func testSpeakingWithLevelUsesLevelDrivenBarsInsteadOfSyntheticCurve() {
        let presentation = ActivityOverlayPresentation.make(
            state: .speaking(sessionID: UUID(), startedAt: .now, level: 0.5), style: .minimal, reduceMotion: false
        )!

        XCTAssertEqual(presentation.speakingLevel, 0.5)
        let bars = presentation.speakingLevelBars()
        XCTAssertEqual(bars.count, 7)
        XCTAssertTrue(bars.allSatisfy { $0 == bars[0] })
    }

    func testSpeakingWithoutLevelHasNilSpeakingLevelAndEmptyLevelBars() {
        let presentation = ActivityOverlayPresentation.make(
            state: .speaking(sessionID: UUID(), startedAt: .now, level: nil), style: .minimal, reduceMotion: false
        )!

        XCTAssertNil(presentation.speakingLevel)
        XCTAssertEqual(presentation.speakingLevelBars(), [])
    }

    func testSpeakingLevelBarsIsEmptyForNonSpeakingStates() {
        let listening = ActivityOverlayPresentation.make(
            state: .listening(sessionID: UUID(), startedAt: .now, level: 0.5), style: .minimal, reduceMotion: false
        )!

        XCTAssertEqual(listening.speakingLevelBars(), [])
    }

    func testListeningUsesRedAccent() {
        let value = ActivityOverlayPresentation.make(
            state: .listening(sessionID: UUID(), startedAt: .now, level: 0), style: .minimal, reduceMotion: false
        )

        XCTAssertEqual(value?.accent, .red)
    }

    func testErrorRenderingUsesFixedCategoryCopyInsteadOfSensitiveMessage() {
        let cases: [(ActivityOverlayErrorCategory, String)] = [
            (.microphone, "Microphone unavailable"),
            (.speechRecognition, "Speech recognition unavailable"),
            (.noUsableAudio, "No usable audio detected"),
            (.speechPlayback, "Speech playback failed"),
            (.insertion, "Could not insert text"),
            (.unexpected, "Something went wrong"),
        ]

        for (category, expectedTitle) in cases {
            let sensitiveMessage = "https://internal.example/token=secret transcript: private identifier 123"
            let value = ActivityOverlayPresentation.make(
                state: .error(sessionID: UUID(), category: category, message: sensitiveMessage),
                style: .interactive,
                reduceMotion: false
            )

            XCTAssertEqual(value?.kind, .error)
            XCTAssertEqual(value?.accent, .error)
            XCTAssertEqual(value?.title, expectedTitle)
            XCTAssertEqual(value?.subtitle, "Try again")
            XCTAssertNil(value?.action)
            XCTAssertNil(value?.startedAt)
            XCTAssertFalse(value!.title!.contains("secret"))
        }
    }

    func testCornerRadiusMatchesStyle() {
        let minimal = ActivityOverlayPresentation.make(
            state: .processing(sessionID: UUID(), startedAt: .now), style: .minimal, reduceMotion: false
        )
        let interactive = ActivityOverlayPresentation.make(
            state: .processing(sessionID: UUID(), startedAt: .now), style: .interactive, reduceMotion: false
        )

        XCTAssertEqual(minimal?.cornerRadius, 22)
        XCTAssertEqual(interactive?.cornerRadius, 20)
    }

    func testLayoutMatchesStyle() {
        let minimal = ActivityOverlayPresentation.make(
            state: .processing(sessionID: UUID(), startedAt: .now), style: .minimal, reduceMotion: false
        )
        let interactive = ActivityOverlayPresentation.make(
            state: .processing(sessionID: UUID(), startedAt: .now), style: .interactive, reduceMotion: false
        )

        XCTAssertEqual(minimal?.layout, .minimal)
        XCTAssertEqual(interactive?.layout, .interactive)
    }

    func testWaveformRestHeightsHasSevenBars() {
        XCTAssertEqual(ActivityOverlayPresentation.waveformRestHeights, [8, 15, 23, 11, 23, 15, 8])
    }

    func testSpeakingWaveformIsDeterministicForTimestampAndHasSevenBars() {
        let presentation = ActivityOverlayPresentation.make(
            state: .speaking(sessionID: UUID(), startedAt: .now, level: nil), style: .minimal, reduceMotion: false
        )!
        let timestamp = Date(timeIntervalSinceReferenceDate: 42)

        XCTAssertEqual(presentation.waveformBars(at: timestamp), presentation.waveformBars(at: timestamp))
        XCTAssertEqual(presentation.waveformBars(at: timestamp).count, 7)
        for value in presentation.waveformBars(at: timestamp) {
            XCTAssertGreaterThanOrEqual(value, 0.34)
            XCTAssertLessThanOrEqual(value, 1.0)
        }
    }

    func testSpeakingWaveformBarsAreSymmetricAndVaryAcrossBars() {
        let presentation = ActivityOverlayPresentation.make(
            state: .speaking(sessionID: UUID(), startedAt: .now, level: nil), style: .minimal, reduceMotion: false
        )!
        let bars = presentation.waveformBars(at: Date(timeIntervalSinceReferenceDate: 42))

        XCTAssertEqual(bars[0], bars[6])
        XCTAssertEqual(bars[1], bars[5])
        XCTAssertEqual(bars[2], bars[4])
        XCTAssertNotEqual(bars[0], bars[3])
    }

    func testWaveformBarsIsEmptyForNonSpeakingStates() {
        let listening = ActivityOverlayPresentation.make(
            state: .listening(sessionID: UUID(), startedAt: .now, level: 0.5), style: .minimal, reduceMotion: false
        )!
        let processing = ActivityOverlayPresentation.make(
            state: .processing(sessionID: UUID(), startedAt: .now), style: .minimal, reduceMotion: false
        )!
        let error = ActivityOverlayPresentation.make(
            state: .error(sessionID: UUID(), category: .unexpected, message: ""), style: .minimal, reduceMotion: false
        )!

        XCTAssertEqual(listening.waveformBars(at: .now), [])
        XCTAssertEqual(processing.waveformBars(at: .now), [])
        XCTAssertEqual(error.waveformBars(at: .now), [])
    }

    func testListeningWaveformBarsHasSevenSymmetricMultipliers() {
        let value = ActivityOverlayPresentation.make(
            state: .listening(sessionID: UUID(), startedAt: .now, level: 0.5), style: .minimal, reduceMotion: false
        )!
        let bars = value.listeningWaveformBars()

        XCTAssertEqual(bars.count, 7)
        XCTAssertEqual(bars[0], bars[6])
        XCTAssertEqual(bars[1], bars[5])
        XCTAssertEqual(bars[2], bars[4])
        for value in bars {
            XCTAssertGreaterThanOrEqual(value, 0.34)
            XCTAssertLessThanOrEqual(value, 1.0)
        }
    }

    func testListeningWaveformBarsIsEmptyForNonListeningStates() {
        let speaking = ActivityOverlayPresentation.make(
            state: .speaking(sessionID: UUID(), startedAt: .now, level: nil), style: .minimal, reduceMotion: false
        )!

        XCTAssertEqual(speaking.listeningWaveformBars(), [])
    }

    func testListeningWaveformBarsAtFullLevelAreAllOneAndAtZeroAreAllFloor() {
        // `WaveformBars` renders each bar as `restHeight × scale`, so the shape lives entirely in
        // `waveformRestHeights`: the multiplier returned here must be identical across all seven
        // bars for level 1 to reproduce the rest heights exactly (scale 1.0) and level 0 to dim
        // every bar to the same 0.34 proportion, rather than re-applying the shape a second time.
        let full = ActivityOverlayPresentation.make(
            state: .listening(sessionID: UUID(), startedAt: .now, level: 1), style: .minimal, reduceMotion: false
        )!.listeningWaveformBars()
        let quiet = ActivityOverlayPresentation.make(
            state: .listening(sessionID: UUID(), startedAt: .now, level: 0), style: .minimal, reduceMotion: false
        )!.listeningWaveformBars()

        XCTAssertEqual(full.count, 7)
        XCTAssertEqual(quiet.count, 7)
        for value in full {
            XCTAssertEqual(value, 1.0, accuracy: 0.000001)
        }
        for value in quiet {
            XCTAssertEqual(value, 0.34, accuracy: 0.000001)
        }
    }

    func testListeningWaveformBarsReflectLevelEvenUnderReduceMotion() {
        let quiet = ActivityOverlayPresentation.make(
            state: .listening(sessionID: UUID(), startedAt: .now, level: 0), style: .minimal, reduceMotion: true
        )!
        let loud = ActivityOverlayPresentation.make(
            state: .listening(sessionID: UUID(), startedAt: .now, level: 1), style: .minimal, reduceMotion: true
        )!

        XCTAssertFalse(quiet.animatesWaveform)
        XCTAssertNotEqual(quiet.listeningWaveformBars(), loud.listeningWaveformBars())
    }

    func testElapsedTimeFormatsAsMinutesColonSeconds() {
        let start = Date(timeIntervalSinceReferenceDate: 0)

        XCTAssertEqual(
            ActivityOverlayPresentation.elapsedTime(since: start, now: start.addingTimeInterval(18)),
            "00:18"
        )
        XCTAssertEqual(
            ActivityOverlayPresentation.elapsedTime(since: start, now: start.addingTimeInterval(65)),
            "01:05"
        )
        XCTAssertEqual(
            ActivityOverlayPresentation.elapsedTime(since: start, now: start),
            "00:00"
        )
    }
}
