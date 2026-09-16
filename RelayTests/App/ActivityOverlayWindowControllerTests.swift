import XCTest
@testable import Relay

@MainActor
final class ActivityOverlayWindowControllerTests: XCTestCase {
    func testPlacementCentersAboveVisibleFrameBottom() {
        let frame = CGRect(x: 100, y: 50, width: 1_200, height: 800)
        XCTAssertEqual(
            ActivityOverlayPlacement.origin(capsuleSize: .init(width: 282, height: 62), visibleFrame: frame),
            CGPoint(x: 559, y: 78)
        )
    }

    func testPanelFrameInsetsCapsuleRectByChromeInset() {
        let frame = CGRect(x: 100, y: 50, width: 1_200, height: 800)
        let capsuleSize = CGSize(width: 282, height: 62)
        let capsuleOrigin = ActivityOverlayPlacement.origin(capsuleSize: capsuleSize, visibleFrame: frame)
        let expected = CGRect(origin: capsuleOrigin, size: capsuleSize)
            .insetBy(dx: -ActivityOverlayPlacement.chromeInset, dy: -ActivityOverlayPlacement.chromeInset)

        XCTAssertEqual(ActivityOverlayPlacement.panelFrame(capsuleSize: capsuleSize, visibleFrame: frame), expected)
    }

    func testSessionPinsChosenDisplayUntilHidden() {
        let screens = FakeOverlayScreens(first: .left, then: .right)
        let host = FakeOverlayPanelHost()
        let presenter = makeController(model: ActivityOverlayModel(), host: host, screens: screens)
        let id = UUID()

        presenter.update(state: .listening(sessionID: id, startedAt: .now, level: 0), style: .interactive)
        presenter.update(state: .processing(sessionID: id, startedAt: .now), style: .interactive)

        // Geometry is unchanged between the two updates, so an idempotent controller only calls
        // `setFrame` once; if the session had been re-pinned to `.right`, a second, different
        // frame would appear here.
        let expectedFrame = ActivityOverlayPlacement.panelFrame(
            capsuleSize: CGSize(width: 282, height: 62),
            visibleFrame: ActivityOverlayScreen.left.visibleFrame
        )
        XCTAssertEqual(host.frames.map(\.origin), [expectedFrame.origin])
    }

    func testGrowingInterimTextRecentersHorizontallyAndAnchorsTheSameBottomEdgeAsThePanelGrowsTaller() {
        let host = FakeOverlayPanelHost()
        let presenter = makeController(model: ActivityOverlayModel(), host: host, screens: FakeOverlayScreens())
        let id = UUID()

        presenter.update(
            state: .listening(sessionID: id, startedAt: .now, level: 0, interimText: ""),
            style: .interactive
        )
        let longText = String(repeating: "word ", count: 200)
        presenter.update(
            state: .listening(sessionID: id, startedAt: .now, level: 0, interimText: longText),
            style: .interactive
        )

        XCTAssertEqual(host.frames.count, 2)
        let baseFrame = host.frames[0]
        let grownFrame = host.frames[1]

        // The panel grows to fit the wrapped interim text - never smaller than the base capsule.
        XCTAssertGreaterThan(grownFrame.size.height, baseFrame.size.height)
        XCTAssertGreaterThanOrEqual(grownFrame.size.width, baseFrame.size.width)

        // Anchored to the same bottom edge of the visible frame regardless of height: the pill
        // grows upward, away from the screen edge, rather than jumping or drifting off it.
        XCTAssertEqual(baseFrame.origin.y, grownFrame.origin.y, accuracy: 0.01)

        // Recentered horizontally around the same screen midpoint as the pill grows wider.
        let visibleFrame = ActivityOverlayScreen.left.visibleFrame
        let baseMidX = baseFrame.origin.x + baseFrame.size.width / 2
        let grownMidX = grownFrame.origin.x + grownFrame.size.width / 2
        XCTAssertEqual(baseMidX, visibleFrame.midX, accuracy: 0.01)
        XCTAssertEqual(grownMidX, visibleFrame.midX, accuracy: 0.01)
    }

    func testFirstPlacementIsNotAnimatedButLaterResizesAre() {
        let host = FakeOverlayPanelHost()
        let presenter = makeController(model: ActivityOverlayModel(), host: host, screens: FakeOverlayScreens())
        let id = UUID()

        presenter.update(
            state: .listening(sessionID: id, startedAt: .now, level: 0, interimText: ""),
            style: .interactive
        )
        let longText = String(repeating: "word ", count: 200)
        presenter.update(
            state: .listening(sessionID: id, startedAt: .now, level: 0, interimText: longText),
            style: .interactive
        )

        XCTAssertEqual(host.frames.count, 2)
        XCTAssertFalse(host.frames[0].animated)
        XCTAssertTrue(host.frames[1].animated)
    }

    func testOffAndHiddenNeverCreatePanel() {
        let host = FakeOverlayPanelHost()
        let presenter = makeController(model: ActivityOverlayModel(), host: host, screens: FakeOverlayScreens())

        presenter.update(state: .hidden, style: .interactive)
        presenter.update(state: .speaking(sessionID: UUID(), startedAt: .now, level: nil), style: .off)

        XCTAssertEqual(host.createCount, 0)
    }

    func testDifferentSessionsPickANewDisplay() {
        let screens = FakeOverlayScreens(first: .left, then: .right)
        let host = FakeOverlayPanelHost()
        let presenter = makeController(model: ActivityOverlayModel(), host: host, screens: screens)

        presenter.update(state: .listening(sessionID: UUID(), startedAt: .now, level: 0), style: .interactive)
        presenter.update(state: .hidden, style: .interactive)
        presenter.update(state: .listening(sessionID: UUID(), startedAt: .now, level: 0), style: .interactive)

        let leftFrame = ActivityOverlayPlacement.panelFrame(
            capsuleSize: CGSize(width: 282, height: 62),
            visibleFrame: ActivityOverlayScreen.left.visibleFrame
        )
        let rightFrame = ActivityOverlayPlacement.panelFrame(
            capsuleSize: CGSize(width: 282, height: 62),
            visibleFrame: ActivityOverlayScreen.right.visibleFrame
        )
        XCTAssertEqual(host.frames.map(\.origin), [leftFrame.origin, rightFrame.origin])
        XCTAssertEqual(host.orderOutCount, 1)
    }

    func testHostCreationFailureRecordsOverlayFailedOnceAndDoesNotThrow() {
        let host = FakeOverlayPanelHost()
        host.createError = FakeOverlayHostError.boom
        let diagnostics = DiagnosticsRecorder()
        let presenter = makeController(model: ActivityOverlayModel(), host: host, screens: FakeOverlayScreens(), diagnostics: diagnostics)

        presenter.update(state: .listening(sessionID: UUID(), startedAt: .now, level: 0), style: .interactive)

        XCTAssertEqual(diagnostics.entries.map(\.event), [.overlayFailed])
        XCTAssertTrue(host.frames.isEmpty)
    }

    func testHostShowFailureRecordsOverlayFailedOnceAndDoesNotThrow() {
        let host = FakeOverlayPanelHost()
        host.orderFrontError = FakeOverlayHostError.boom
        let diagnostics = DiagnosticsRecorder()
        let presenter = makeController(model: ActivityOverlayModel(), host: host, screens: FakeOverlayScreens(), diagnostics: diagnostics)

        presenter.update(state: .speaking(sessionID: UUID(), startedAt: .now, level: nil), style: .interactive)

        XCTAssertEqual(diagnostics.entries.map(\.event), [.overlayFailed])
    }

    func testMinimalStyleIgnoresMouseEventsWhileInteractiveAllowsThem() {
        let host = FakeOverlayPanelHost()
        let presenter = makeController(model: ActivityOverlayModel(), host: host, screens: FakeOverlayScreens())

        presenter.update(state: .listening(sessionID: UUID(), startedAt: .now, level: 0), style: .minimal)
        presenter.update(state: .processing(sessionID: UUID(), startedAt: .now), style: .interactive)

        XCTAssertEqual(host.ignoresMouseEventsValues, [true, false])
    }

    func testContentIsAppliedOnceUntilStyleChanges() {
        let host = FakeOverlayPanelHost()
        let presenter = makeController(model: ActivityOverlayModel(), host: host, screens: FakeOverlayScreens())
        let session = UUID()

        presenter.update(state: .listening(sessionID: session, startedAt: .now, level: 0), style: .interactive)
        presenter.update(state: .listening(sessionID: session, startedAt: .now, level: 0.5), style: .interactive)
        presenter.update(state: .processing(sessionID: session, startedAt: .now), style: .interactive)
        XCTAssertEqual(host.setContentCount, 1)

        presenter.update(state: .processing(sessionID: session, startedAt: .now), style: .minimal)
        XCTAssertEqual(host.setContentCount, 2)
    }

    func testOffStyleHidesPanelButKeepsPinUntilTrulyHidden() {
        let screens = FakeOverlayScreens(first: .left, then: .right)
        let host = FakeOverlayPanelHost()
        let presenter = makeController(model: ActivityOverlayModel(), host: host, screens: screens)
        let session = UUID()

        presenter.update(state: .listening(sessionID: session, startedAt: .now, level: 0), style: .interactive)
        presenter.update(state: .processing(sessionID: session, startedAt: .now), style: .off)
        presenter.update(state: .processing(sessionID: session, startedAt: .now), style: .interactive)

        // Only ever positioned on `.left`; if the pin had been dropped on the `.off` update, the
        // final show would have re-picked `.right` from the fake's scripted sequence.
        let expectedFrame = ActivityOverlayPlacement.panelFrame(
            capsuleSize: CGSize(width: 282, height: 62),
            visibleFrame: ActivityOverlayScreen.left.visibleFrame
        )
        XCTAssertEqual(host.frames.map(\.origin), [expectedFrame.origin])
        XCTAssertEqual(host.orderOutCount, 1)
        XCTAssertEqual(host.orderFrontCount, 2)
    }

    func testConsecutiveFailuresRecordOverlayFailedOnceUntilAShowSucceeds() {
        let host = FakeOverlayPanelHost()
        host.orderFrontError = FakeOverlayHostError.boom
        let diagnostics = DiagnosticsRecorder()
        let presenter = makeController(model: ActivityOverlayModel(), host: host, screens: FakeOverlayScreens(), diagnostics: diagnostics)
        let session = UUID()

        presenter.update(state: .listening(sessionID: session, startedAt: .now, level: 0), style: .interactive)
        presenter.update(state: .listening(sessionID: session, startedAt: .now, level: 0.5), style: .interactive)
        XCTAssertEqual(diagnostics.entries.map(\.event), [.overlayFailed])

        // Clearing the error lets the panel actually show, which resets the dedupe flag.
        host.orderFrontError = nil
        presenter.update(state: .processing(sessionID: session, startedAt: .now), style: .interactive)
        XCTAssertEqual(diagnostics.entries.map(\.event), [.overlayFailed])

        // Order the panel out (without fully hiding the session) so the next show attempts
        // `orderFront` again instead of skipping it as already-visible, then fail it again.
        presenter.update(state: .processing(sessionID: session, startedAt: .now), style: .off)
        host.orderFrontError = FakeOverlayHostError.boom
        presenter.update(state: .speaking(sessionID: session, startedAt: .now, level: nil), style: .interactive)
        XCTAssertEqual(diagnostics.entries.map(\.event), [.overlayFailed, .overlayFailed])
    }

    func testShowIsIdempotentAcrossRepeatedUpdatesWithUnchangedGeometry() {
        let host = FakeOverlayPanelHost()
        let presenter = makeController(model: ActivityOverlayModel(), host: host, screens: FakeOverlayScreens())
        let session = UUID()

        for level: Float in [0, 0.2, 0.4, 0.6, 0.8] {
            presenter.update(state: .listening(sessionID: session, startedAt: .now, level: level), style: .interactive)
        }

        XCTAssertEqual(host.frames.count, 1)
        XCTAssertEqual(host.orderFrontCount, 1)
        XCTAssertEqual(host.setContentCount, 1)
        XCTAssertEqual(host.ignoresMouseEventsValues.count, 1)
    }

    func testNilScreenForNewSessionRecordsOverlayFailedAndDoesNotShow() {
        let host = FakeOverlayPanelHost()
        let diagnostics = DiagnosticsRecorder()
        let presenter = makeController(model: ActivityOverlayModel(), host: host, screens: NilScreenProvider(), diagnostics: diagnostics)

        presenter.update(state: .listening(sessionID: UUID(), startedAt: .now, level: 0), style: .interactive)
        presenter.update(state: .listening(sessionID: UUID(), startedAt: .now, level: 0.5), style: .interactive)

        XCTAssertEqual(diagnostics.entries.map(\.event), [.overlayFailed])
        XCTAssertEqual(host.createCount, 0)
        XCTAssertTrue(host.frames.isEmpty)
    }

    func testPanelSizeMatchesStyle() {
        let host = FakeOverlayPanelHost()
        let presenter = makeController(model: ActivityOverlayModel(), host: host, screens: FakeOverlayScreens())
        let session = UUID()

        presenter.update(state: .listening(sessionID: session, startedAt: .now, level: 0), style: .minimal)
        let minimalExpected = ActivityOverlayPlacement.panelFrame(
            capsuleSize: CGSize(width: 154, height: 40),
            visibleFrame: ActivityOverlayScreen.left.visibleFrame
        )
        XCTAssertEqual(host.frames.last.map { CGRect(origin: $0.origin, size: $0.size) }, minimalExpected)

        presenter.update(state: .processing(sessionID: session, startedAt: .now), style: .interactive)
        let interactiveExpected = ActivityOverlayPlacement.panelFrame(
            capsuleSize: CGSize(width: 282, height: 62),
            visibleFrame: ActivityOverlayScreen.left.visibleFrame
        )
        XCTAssertEqual(host.frames.last.map { CGRect(origin: $0.origin, size: $0.size) }, interactiveExpected)
    }

    func testRelayoutRepositionsUsingRefreshedFrameForSameScreen() {
        let host = FakeOverlayPanelHost()
        let updatedLeft = ActivityOverlayScreen(
            id: ActivityOverlayScreen.left.id,
            visibleFrame: CGRect(x: 0, y: 0, width: 2_000, height: 1_200)
        )
        let screens = FakeRelayoutScreens(newSessionScreens: [.left], refreshedScreen: updatedLeft)
        let presenter = makeController(model: ActivityOverlayModel(), host: host, screens: screens)
        presenter.update(state: .listening(sessionID: UUID(), startedAt: .now, level: 0), style: .interactive)

        presenter.relayoutForScreenChange()

        let expected = ActivityOverlayPlacement.panelFrame(
            capsuleSize: CGSize(width: 282, height: 62),
            visibleFrame: updatedLeft.visibleFrame
        )
        XCTAssertEqual(host.frames.last.map { CGRect(origin: $0.origin, size: $0.size) }, expected)
    }

    func testRelayoutFallsBackToNewSessionScreenWhenPinnedScreenDisappears() {
        let host = FakeOverlayPanelHost()
        let screens = FakeRelayoutScreens(newSessionScreens: [.left, .right], refreshedScreen: nil)
        let presenter = makeController(model: ActivityOverlayModel(), host: host, screens: screens)
        presenter.update(state: .listening(sessionID: UUID(), startedAt: .now, level: 0), style: .interactive)

        presenter.relayoutForScreenChange()

        let expected = ActivityOverlayPlacement.panelFrame(
            capsuleSize: CGSize(width: 282, height: 62),
            visibleFrame: ActivityOverlayScreen.right.visibleFrame
        )
        XCTAssertEqual(host.frames.last.map { CGRect(origin: $0.origin, size: $0.size) }, expected)
    }

    func testRelayoutDoesNothingWhenHidden() {
        let host = FakeOverlayPanelHost()
        let screens = FakeRelayoutScreens(newSessionScreens: [], refreshedScreen: .right)
        let presenter = makeController(model: ActivityOverlayModel(), host: host, screens: screens)

        presenter.relayoutForScreenChange()

        XCTAssertTrue(host.frames.isEmpty)
        XCTAssertEqual(host.orderFrontCount, 0)
    }

    func testScreenParameterChangeNotificationTriggersRelayoutOnRefreshedFrame() async {
        let host = FakeOverlayPanelHost()
        let refreshedLeft = ActivityOverlayScreen(
            id: ActivityOverlayScreen.left.id,
            visibleFrame: CGRect(x: 0, y: 0, width: 2_000, height: 1_200)
        )
        let screens = FakeRelayoutScreens(newSessionScreens: [.left], refreshedScreen: refreshedLeft)
        let presenter = makeController(model: ActivityOverlayModel(), host: host, screens: screens)
        presenter.update(state: .listening(sessionID: UUID(), startedAt: .now, level: 0), style: .interactive)

        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        for _ in 0..<10 { await Task.yield() }

        let expected = ActivityOverlayPlacement.panelFrame(
            capsuleSize: CGSize(width: 282, height: 62),
            visibleFrame: refreshedLeft.visibleFrame
        )
        XCTAssertEqual(host.frames.last.map { CGRect(origin: $0.origin, size: $0.size) }, expected)
        withExtendedLifetime(presenter) {}
    }

    private func makeController(
        model: ActivityOverlayModel,
        host: any ActivityOverlayPanelHosting,
        screens: any ActivityOverlayScreenProviding,
        diagnostics: DiagnosticsRecorder? = nil
    ) -> ActivityOverlayWindowController {
        ActivityOverlayWindowController(model: model, host: host, screens: screens, diagnostics: diagnostics)
    }
}

private enum FakeOverlayHostError: Error {
    case boom
}

@MainActor
private final class FakeOverlayScreens: ActivityOverlayScreenProviding {
    private var next: [ActivityOverlayScreen]
    private let fallback: ActivityOverlayScreen

    init(first: ActivityOverlayScreen = .left, then: ActivityOverlayScreen = .left) {
        next = [first, then]
        fallback = then
    }

    func screenForNewSession() -> ActivityOverlayScreen? {
        next.isEmpty ? fallback : next.removeFirst()
    }

    func screen(withID id: ActivityOverlayScreen.ID) -> ActivityOverlayScreen? {
        [ActivityOverlayScreen.left, .right].first { $0.id == id }
    }
}

/// Always reports that no screen exists, to exercise the "screen pick failed" path.
@MainActor
private final class NilScreenProvider: ActivityOverlayScreenProviding {
    func screenForNewSession() -> ActivityOverlayScreen? { nil }
    func screen(withID id: ActivityOverlayScreen.ID) -> ActivityOverlayScreen? { nil }
}

/// A screen provider tailored to the relayout tests: `screenForNewSession()` hands out a
/// scripted sequence (the initial pin, then any fallback pick), while `screen(withID:)`
/// always returns the configured refreshed value (or `nil` to simulate a disappeared screen).
@MainActor
private final class FakeRelayoutScreens: ActivityOverlayScreenProviding {
    private var newSessionScreens: [ActivityOverlayScreen]
    private let refreshedScreen: ActivityOverlayScreen?

    init(newSessionScreens: [ActivityOverlayScreen], refreshedScreen: ActivityOverlayScreen?) {
        self.newSessionScreens = newSessionScreens
        self.refreshedScreen = refreshedScreen
    }

    func screenForNewSession() -> ActivityOverlayScreen? {
        newSessionScreens.isEmpty ? nil : newSessionScreens.removeFirst()
    }

    func screen(withID id: ActivityOverlayScreen.ID) -> ActivityOverlayScreen? {
        refreshedScreen
    }
}

extension ActivityOverlayScreen {
    static let left = ActivityOverlayScreen(id: "left", visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900))
    static let right = ActivityOverlayScreen(id: "right", visibleFrame: CGRect(x: 1_440, y: 0, width: 1_440, height: 900))
}

@MainActor
private final class FakeOverlayPanelHost: ActivityOverlayPanelHosting {
    private(set) var createCount = 0
    private(set) var setContentCount = 0
    private(set) var frames: [(origin: CGPoint, size: CGSize, animated: Bool)] = []
    private(set) var ignoresMouseEventsValues: [Bool] = []
    private(set) var orderFrontCount = 0
    private(set) var orderOutCount = 0
    var createError: Error?
    var orderFrontError: Error?

    func createIfNeeded() throws {
        if let createError { throw createError }
        createCount += 1
    }

    func setContent(
        model: ActivityOverlayModel,
        style: ActivityOverlayStyle,
        onAction: @escaping @MainActor (ActivityOverlayAction) async -> Void
    ) {
        setContentCount += 1
    }

    func setFrame(origin: CGPoint, size: CGSize, animated: Bool) {
        frames.append((origin, size, animated))
    }

    func setIgnoresMouseEvents(_ ignores: Bool) {
        ignoresMouseEventsValues.append(ignores)
    }

    func orderFront() throws {
        if let orderFrontError { throw orderFrontError }
        orderFrontCount += 1
    }

    func orderOut() {
        orderOutCount += 1
    }
}
