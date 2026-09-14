import CoreGraphics
import XCTest
@testable import Relay

final class ActivityOverlayPresentationTests: XCTestCase {
    func testOffAlwaysMapsToHidden() {
        let state = ActivityOverlayState.speaking(sessionID: UUID(), startedAt: .now)

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
        XCTAssertNil(value?.action)
        XCTAssertEqual(value?.size, CGSize(width: 154, height: 40))
    }

    func testReduceMotionDisablesAnimatedWaveformsAndScale() {
        let value = ActivityOverlayPresentation.make(
            state: .speaking(sessionID: UUID(), startedAt: .now),
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
        XCTAssertEqual(value?.action, .cancelDictation(sessionID: id))
    }

    func testSpeakingMapsToStopWithVioletCyanAccent() {
        let id = UUID()
        let value = ActivityOverlayPresentation.make(
            state: .speaking(sessionID: id, startedAt: .now), style: .interactive, reduceMotion: false
        )

        XCTAssertEqual(value?.accent, .violetCyan)
        XCTAssertEqual(value?.action, .stopSpeech(sessionID: id))
        XCTAssertEqual(value?.actionAccessibilityLabel, "Stop speech")
    }

    func testListeningUsesRedAccent() {
        let value = ActivityOverlayPresentation.make(
            state: .listening(sessionID: UUID(), startedAt: .now, level: 0), style: .minimal, reduceMotion: false
        )

        XCTAssertEqual(value?.accent, .red)
    }

    func testErrorSanitizesWhitespaceAndUsesFallbackMessage() {
        let value = ActivityOverlayPresentation.make(
            state: .error(sessionID: UUID(), category: .unexpected, message: "  \n \t  "),
            style: .interactive,
            reduceMotion: false
        )

        XCTAssertEqual(value?.kind, .error)
        XCTAssertEqual(value?.accent, .error)
        XCTAssertEqual(value?.title, "Something went wrong")
    }

    func testSpeakingWaveformIsDeterministicForTimestamp() {
        let presentation = ActivityOverlayPresentation.make(
            state: .speaking(sessionID: UUID(), startedAt: .now), style: .minimal, reduceMotion: false
        )!
        let timestamp = Date(timeIntervalSinceReferenceDate: 42)

        XCTAssertEqual(presentation.waveformBars(at: timestamp), presentation.waveformBars(at: timestamp))
        XCTAssertEqual(presentation.waveformBars(at: timestamp).count, 5)
    }
}
