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

    func testReportNamesWhatChanged() {
        XCTAssertEqual(
            AudioEngineRouteChangeDecision.report(
                isEngineRunning: false,
                installedSampleRate: 48_000, installedChannelCount: 2,
                currentSampleRate: 16_000, currentChannelCount: 1,
                inputDevice: "CMF Buds Pro 2", defaultInput: "CMF Buds Pro 2", defaultOutput: "CMF Buds Pro 2"
            ),
            "The audio input device changed: engine stopped; input 48 kHz 2 ch → 16 kHz 1 ch on CMF Buds Pro 2; default in CMF Buds Pro 2, out CMF Buds Pro 2."
        )
    }

    func testReportHandlesUnknownDevicesAndFractionalRates() {
        XCTAssertEqual(
            AudioEngineRouteChangeDecision.report(
                isEngineRunning: true,
                installedSampleRate: 44_100, installedChannelCount: 1,
                currentSampleRate: 48_000, currentChannelCount: 1,
                inputDevice: nil, defaultInput: nil, defaultOutput: "MacBook Pro Speakers"
            ),
            "The audio input device changed: engine running; input 44.1 kHz 1 ch → 48 kHz 1 ch on unknown device; default in unknown, out MacBook Pro Speakers."
        )
    }
}
