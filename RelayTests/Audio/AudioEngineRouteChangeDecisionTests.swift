import XCTest

@testable import Relay

final class AudioEngineRouteChangeDecisionTests: XCTestCase {
    func testNotRunningIsAlwaysDisruptiveEvenWithAnUnchangedFormat() {
        XCTAssertTrue(
            AudioEngineRouteChangeDecision.isDisruptive(
                isEngineRunning: false,
                installedSampleRate: 48_000,
                installedChannelCount: 2,
                currentSampleRate: 48_000,
                currentChannelCount: 2
            ))
    }

    func testRunningWithAnUnchangedFormatIsNotDisruptive() {
        XCTAssertFalse(
            AudioEngineRouteChangeDecision.isDisruptive(
                isEngineRunning: true,
                installedSampleRate: 48_000,
                installedChannelCount: 2,
                currentSampleRate: 48_000,
                currentChannelCount: 2
            ))
    }

    func testRunningWithAChangedSampleRateIsDisruptive() {
        XCTAssertTrue(
            AudioEngineRouteChangeDecision.isDisruptive(
                isEngineRunning: true,
                installedSampleRate: 48_000,
                installedChannelCount: 2,
                currentSampleRate: 44_100,
                currentChannelCount: 2
            ))
    }

    func testRunningWithAChangedChannelCountIsDisruptive() {
        XCTAssertTrue(
            AudioEngineRouteChangeDecision.isDisruptive(
                isEngineRunning: true,
                installedSampleRate: 48_000,
                installedChannelCount: 2,
                currentSampleRate: 48_000,
                currentChannelCount: 1
            ))
    }
}
