import XCTest
@testable import Relay

final class GlobalHotkeyManagerTests: XCTestCase {
    func testPermissionFailureExplainsAccessibilityAndListenOnlyAlternative() {
        XCTAssertEqual(
            GlobalHotkeyManager.permissionFailureMessage,
            "Global hotkeys need Accessibility permission. Enable Relay in System Settings > Privacy & Security > Accessibility, then retry in Diagnostics. Input Monitoring is an alternative for listen-only access."
        )
    }

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

    func testDoubleTappedModifierEmitsPressedOnSecondTapAndReleasedOnItsRelease() {
        var uptime: TimeInterval = 0
        var matcher = HotkeyMatcher(definitions: [.dictate: .doubleTapModifier(.control)], uptime: { uptime })
        XCTAssertTrue(matcher.match(.flagsChanged(modifiers: [.control])).isEmpty)
        uptime = 0.1; XCTAssertTrue(matcher.match(.flagsChanged(modifiers: [])).isEmpty)
        uptime = 0.2
        XCTAssertEqual(matcher.match(.flagsChanged(modifiers: [.control])), [.init(action: .dictate, phase: .pressed)])
        uptime = 0.25
        XCTAssertEqual(matcher.match(.flagsChanged(modifiers: [])), [.init(action: .dictate, phase: .released)])
    }

    func testEachConfiguredDoubleTapModifierRoutesToItsAction() {
        let cases: [(HotkeyModifier, HotkeyAction)] = [
            (.control, .dictate), (.option, .readSelection), (.shift, .stopSpeech),
            (.command, .replayLast), (.function, .toggleAutoRead),
        ]
        for (modifier, action) in cases {
            var uptime: TimeInterval = 0
            var matcher = HotkeyMatcher(definitions: [action: .doubleTapModifier(modifier)], uptime: { uptime })
            XCTAssertTrue(matcher.match(.flagsChanged(modifiers: [modifier])).isEmpty)
            uptime = 0.1; XCTAssertTrue(matcher.match(.flagsChanged(modifiers: [])).isEmpty)
            uptime = 0.2
            XCTAssertEqual(matcher.match(.flagsChanged(modifiers: [modifier])), [.init(action: action, phase: .pressed)])
        }
    }

    func testDifferentDoubleTapModifiersRouteToDifferentActions() {
        var uptime: TimeInterval = 0
        var matcher = HotkeyMatcher(definitions: [
            .dictate: .doubleTapModifier(.control),
            .readSelection: .doubleTapModifier(.option),
        ], uptime: { uptime })
        XCTAssertTrue(matcher.match(.flagsChanged(modifiers: [.option])).isEmpty)
        uptime = 0.1; XCTAssertTrue(matcher.match(.flagsChanged(modifiers: [])).isEmpty)
        uptime = 0.2
        XCTAssertEqual(matcher.match(.flagsChanged(modifiers: [.option])), [.init(action: .readSelection, phase: .pressed)])
    }

    func testControlChordCancelsPendingDoubleControlRecognition() {
        var matcher = HotkeyMatcher(definitions: [
            .dictate: .doubleTapModifier(.control),
            .readSelection: .chord(keyCode: 15, modifiers: [.control]),
        ])

        XCTAssertTrue(matcher.match(.flagsChanged(modifiers: [.control])).isEmpty)
        XCTAssertEqual(
            matcher.match(.keyDown(keyCode: 15, modifiers: [.control], isRepeat: false)),
            [.init(action: .readSelection, phase: .pressed)]
        )
        XCTAssertEqual(
            matcher.match(.keyUp(keyCode: 15, modifiers: [.control])),
            [.init(action: .readSelection, phase: .released)]
        )
        XCTAssertTrue(matcher.match(.flagsChanged(modifiers: [])).isEmpty)
    }

    func testModifierHeldLongerThanWindowDoesNotArmGesture() {
        var uptime: TimeInterval = 0
        var matcher = HotkeyMatcher(definitions: [.dictate: .doubleTapModifier(.control)], uptime: { uptime })
        XCTAssertTrue(matcher.match(.flagsChanged(modifiers: [.control])).isEmpty)
        uptime = 0.36; XCTAssertTrue(matcher.match(.flagsChanged(modifiers: [])).isEmpty)
        uptime = 0.4; XCTAssertTrue(matcher.match(.flagsChanged(modifiers: [.control])).isEmpty)
    }

    func testAdditionalModifierCancelsPendingDoubleControlRecognition() {
        var matcher = HotkeyMatcher(definitions: [.dictate: .doubleTapModifier(.control)])

        XCTAssertTrue(matcher.match(.flagsChanged(modifiers: [.control])).isEmpty)
        XCTAssertTrue(matcher.match(.flagsChanged(modifiers: [.control, .shift])).isEmpty)
        XCTAssertTrue(matcher.match(.flagsChanged(modifiers: [])).isEmpty)
        XCTAssertTrue(matcher.match(.flagsChanged(modifiers: [.control])).isEmpty)
    }

    func testSingleQuickControlTapDoesNotTriggerDictation() {
        var matcher = HotkeyMatcher(definitions: [.dictate: .doubleTapModifier(.control)])

        XCTAssertTrue(matcher.match(.flagsChanged(modifiers: [.control])).isEmpty)
        XCTAssertTrue(matcher.match(.flagsChanged(modifiers: [])).isEmpty)
    }

    func testInterTapGapLongerThanWindowDoesNotTriggerDictation() {
        var uptime: TimeInterval = 0
        var matcher = HotkeyMatcher(definitions: [.dictate: .doubleTapModifier(.control)], uptime: { uptime })

        XCTAssertTrue(matcher.match(.flagsChanged(modifiers: [.control])).isEmpty)
        uptime = 0.1
        XCTAssertTrue(matcher.match(.flagsChanged(modifiers: [])).isEmpty)
        uptime = 0.46
        XCTAssertTrue(matcher.match(.flagsChanged(modifiers: [.control])).isEmpty)
    }

    func testDoubleControlAtExactWindowBoundaryTriggersDictation() {
        var uptime: TimeInterval = 0
        var matcher = HotkeyMatcher(definitions: [.dictate: .doubleTapModifier(.control)], uptime: { uptime })

        XCTAssertTrue(matcher.match(.flagsChanged(modifiers: [.control])).isEmpty)
        uptime = 0.1
        XCTAssertTrue(matcher.match(.flagsChanged(modifiers: [])).isEmpty)
        uptime = 0.45
        XCTAssertEqual(
            matcher.match(.flagsChanged(modifiers: [.control])),
            [.init(action: .dictate, phase: .pressed)]
        )
    }

    func testOrdinaryKeyCancelsPendingDoubleControlRecognition() {
        var matcher = HotkeyMatcher(definitions: [.dictate: .doubleTapModifier(.control)])

        XCTAssertTrue(matcher.match(.flagsChanged(modifiers: [.control])).isEmpty)
        XCTAssertTrue(matcher.match(.keyDown(keyCode: 0, modifiers: [.control], isRepeat: false)).isEmpty)
        XCTAssertTrue(matcher.match(.keyUp(keyCode: 0, modifiers: [.control])).isEmpty)
        XCTAssertTrue(matcher.match(.flagsChanged(modifiers: [])).isEmpty)
        XCTAssertTrue(matcher.match(.flagsChanged(modifiers: [.control])).isEmpty)
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

    func testDuplicateDefinitionsEmitOnlyTheFirstActionInStableOrder() {
        var matcher = HotkeyMatcher(definitions: [
            .readSelection: .chord(keyCode: 15, modifiers: [.option]),
            .replayLast: .chord(keyCode: 15, modifiers: [.option]),
        ])

        XCTAssertEqual(
            matcher.match(.keyDown(keyCode: 15, modifiers: [.option], isRepeat: false)),
            [
                .init(action: .readSelection, phase: .pressed),
            ]
        )
    }
}
