import XCTest
@testable import Relay

@MainActor
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

    /// A slightly long first press must not be charged against the double-tap window: only the
    /// release→second-press gap matters, so a hold well past the old (0.35s) window still arms
    /// the gesture as long as the following gap is within the window.
    func testModifierHeldLongerThanWindowStillArmsGestureIfGapIsWithinWindow() {
        var uptime: TimeInterval = 0
        var matcher = HotkeyMatcher(definitions: [.dictate: .doubleTapModifier(.control)], uptime: { uptime })
        XCTAssertTrue(matcher.match(.flagsChanged(modifiers: [.control])).isEmpty)
        uptime = 0.9; XCTAssertTrue(matcher.match(.flagsChanged(modifiers: [])).isEmpty)
        uptime = 1.0
        XCTAssertEqual(
            matcher.match(.flagsChanged(modifiers: [.control])),
            [.init(action: .dictate, phase: .pressed)]
        )
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
        uptime = 0.61
        XCTAssertTrue(matcher.match(.flagsChanged(modifiers: [.control])).isEmpty)
    }

    func testDoubleControlAtExactWindowBoundaryTriggersDictation() {
        var uptime: TimeInterval = 0
        var matcher = HotkeyMatcher(definitions: [.dictate: .doubleTapModifier(.control)], uptime: { uptime })

        XCTAssertTrue(matcher.match(.flagsChanged(modifiers: [.control])).isEmpty)
        uptime = 0.1
        XCTAssertTrue(matcher.match(.flagsChanged(modifiers: [])).isEmpty)
        uptime = 0.6
        XCTAssertEqual(
            matcher.match(.flagsChanged(modifiers: [.control])),
            [.init(action: .dictate, phase: .pressed)]
        )
    }

    /// A duplicate/no-op `flagsChanged` (same modifier set as the previous event) must not cancel
    /// a pending double-tap gesture — common with Fn/external keyboards that resend the current
    /// modifier state without an actual change.
    func testDuplicateFlagsChangedDuringWindowDoesNotCancelPendingDoubleTap() {
        var uptime: TimeInterval = 0
        var matcher = HotkeyMatcher(definitions: [.dictate: .doubleTapModifier(.control)], uptime: { uptime })

        XCTAssertTrue(matcher.match(.flagsChanged(modifiers: [.control])).isEmpty)
        // Duplicate no-op event while tap 1 is still held.
        XCTAssertTrue(matcher.match(.flagsChanged(modifiers: [.control])).isEmpty)

        uptime = 0.1
        XCTAssertTrue(matcher.match(.flagsChanged(modifiers: [])).isEmpty)
        // Duplicate no-op event while awaiting the second press.
        XCTAssertTrue(matcher.match(.flagsChanged(modifiers: [])).isEmpty)

        uptime = 0.2
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
