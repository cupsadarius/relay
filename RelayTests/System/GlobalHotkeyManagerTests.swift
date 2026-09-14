import XCTest
@testable import Relay

final class GlobalHotkeyManagerTests: XCTestCase {
    func testChordEmitsPressedAndReleasedPhases() {
        var matcher = HotkeyMatcher(definitions: [
            .readSelection: .chord(keyCode: 15, modifiers: [.option]),
        ])

        XCTAssertEqual(
            matcher.match(.keyDown(keyCode: 15, modifiers: [.option], isRepeat: false)),
            [.init(action: .readSelection, phase: .pressed)]
        )
        XCTAssertEqual(
            matcher.match(.keyUp(keyCode: 15, modifiers: [.option])),
            [.init(action: .readSelection, phase: .released)]
        )
    }

    func testChordRequiresExactConfiguredModifiers() {
        var matcher = HotkeyMatcher(definitions: [
            .readSelection: .chord(keyCode: 15, modifiers: [.option]),
        ])

        XCTAssertTrue(
            matcher.match(.keyDown(
                keyCode: 15,
                modifiers: [.option, .shift],
                isRepeat: false
            )).isEmpty
        )
    }

    func testRepeatedKeyDownIsDebounced() {
        var matcher = HotkeyMatcher(definitions: [
            .readSelection: .chord(keyCode: 15, modifiers: [.option]),
        ])

        _ = matcher.match(.keyDown(keyCode: 15, modifiers: [.option], isRepeat: false))

        XCTAssertTrue(
            matcher.match(.keyDown(keyCode: 15, modifiers: [.option], isRepeat: true)).isEmpty
        )
    }

    func testFunctionOnlyEmitsOnceForPressAndReleaseTransitions() {
        var matcher = HotkeyMatcher(definitions: [
            .dictate: .modifierOnly(.function),
        ])

        XCTAssertEqual(
            matcher.match(.flagsChanged(modifiers: [.function])),
            [.init(action: .dictate, phase: .pressed)]
        )
        XCTAssertTrue(matcher.match(.flagsChanged(modifiers: [.function])).isEmpty)
        XCTAssertEqual(
            matcher.match(.flagsChanged(modifiers: [])),
            [.init(action: .dictate, phase: .released)]
        )
        XCTAssertTrue(matcher.match(.flagsChanged(modifiers: [])).isEmpty)
    }

    func testFunctionOnlyDoesNotFireWhenCombinedWithAnotherModifier() {
        var matcher = HotkeyMatcher(definitions: [
            .dictate: .modifierOnly(.function),
        ])

        XCTAssertTrue(
            matcher.match(.flagsChanged(modifiers: [.function, .control])).isEmpty
        )
        XCTAssertTrue(matcher.match(.flagsChanged(modifiers: [.control])).isEmpty)
        XCTAssertTrue(matcher.match(.flagsChanged(modifiers: [])).isEmpty)
    }

    func testFunctionReleaseStillEmitsIfAnotherModifierWasAddedAfterPress() {
        var matcher = HotkeyMatcher(definitions: [
            .dictate: .modifierOnly(.function),
        ])

        _ = matcher.match(.flagsChanged(modifiers: [.function]))
        XCTAssertTrue(
            matcher.match(.flagsChanged(modifiers: [.function, .shift])).isEmpty
        )
        XCTAssertEqual(
            matcher.match(.flagsChanged(modifiers: [.shift])),
            [.init(action: .dictate, phase: .released)]
        )
    }

    func testUnmatchedEventsEmitNothing() {
        var matcher = HotkeyMatcher(definitions: [
            .readSelection: .chord(keyCode: 15, modifiers: [.option]),
        ])

        XCTAssertTrue(
            matcher.match(.keyDown(keyCode: 16, modifiers: [.option], isRepeat: false)).isEmpty
        )
        XCTAssertTrue(matcher.match(.flagsChanged(modifiers: [.shift])).isEmpty)
    }

    func testDuplicateDefinitionsEmitEachActionInStableOrder() {
        var matcher = HotkeyMatcher(definitions: [
            .readSelection: .chord(keyCode: 15, modifiers: [.option]),
            .replayLast: .chord(keyCode: 15, modifiers: [.option]),
        ])

        XCTAssertEqual(
            matcher.match(.keyDown(keyCode: 15, modifiers: [.option], isRepeat: false)),
            [
                .init(action: .readSelection, phase: .pressed),
                .init(action: .replayLast, phase: .pressed),
            ]
        )
    }
}
