import XCTest
@testable import Relay

@MainActor
final class ActivityOverlayWindowControllerTests: XCTestCase {
    func testPlacementCentersAboveVisibleFrameBottom() {
        let frame = CGRect(x: 100, y: 50, width: 1_200, height: 800)
        XCTAssertEqual(
            ActivityOverlayPlacement.origin(panelSize: .init(width: 282, height: 62), visibleFrame: frame),
            CGPoint(x: 559, y: 78)
        )
    }

    func testSessionPinsChosenDisplayUntilHidden() {
        let screens = FakeOverlayScreens(first: .left, then: .right)
        let host = FakeOverlayPanelHost()
        let presenter = ActivityOverlayWindowController(host: host, screens: screens)
        let id = UUID()
        presenter.update(state: .listening(sessionID: id, startedAt: .now, level: 0), style: .interactive)
        presenter.update(state: .processing(sessionID: id, startedAt: .now), style: .interactive)
        XCTAssertEqual(host.positionedScreens, [.left, .left])
    }

    func testOffAndHiddenOrderPanelOutWithoutCreatingIt() {
        let host = FakeOverlayPanelHost()
        let presenter = ActivityOverlayWindowController(host: host, screens: FakeOverlayScreens())
        presenter.update(state: .hidden, style: .interactive)
        presenter.update(state: .speaking(sessionID: UUID(), startedAt: .now), style: .off)
        XCTAssertEqual(host.createCount, 0)
    }

    func testDifferentSessionsPickANewDisplay() {
        let screens = FakeOverlayScreens(first: .left, then: .right)
        let host = FakeOverlayPanelHost()
        let presenter = ActivityOverlayWindowController(host: host, screens: screens)

        presenter.update(state: .listening(sessionID: UUID(), startedAt: .now, level: 0), style: .interactive)
        presenter.update(state: .hidden, style: .interactive)
        presenter.update(state: .listening(sessionID: UUID(), startedAt: .now, level: 0), style: .interactive)

        XCTAssertEqual(host.positionedScreens, [.left, .right])
        XCTAssertEqual(host.orderOutCount, 1)
    }

    func testHostCreationFailureRecordsOverlayFailedOnceAndDoesNotThrow() {
        let host = FakeOverlayPanelHost()
        host.createError = FakeOverlayHostError.boom
        let diagnostics = DiagnosticsRecorder()
        let presenter = ActivityOverlayWindowController(
            host: host,
            screens: FakeOverlayScreens(),
            diagnostics: diagnostics
        )

        presenter.update(state: .listening(sessionID: UUID(), startedAt: .now, level: 0), style: .interactive)

        XCTAssertEqual(diagnostics.entries.map(\.event), [.overlayFailed])
        XCTAssertEqual(host.positionedScreens, [])
    }

    func testHostShowFailureRecordsOverlayFailedOnceAndDoesNotThrow() {
        let host = FakeOverlayPanelHost()
        host.orderFrontError = FakeOverlayHostError.boom
        let diagnostics = DiagnosticsRecorder()
        let presenter = ActivityOverlayWindowController(
            host: host,
            screens: FakeOverlayScreens(),
            diagnostics: diagnostics
        )

        presenter.update(state: .speaking(sessionID: UUID(), startedAt: .now), style: .interactive)

        XCTAssertEqual(diagnostics.entries.map(\.event), [.overlayFailed])
    }

    func testMinimalStyleIgnoresMouseEventsWhileInteractiveAllowsThem() {
        let host = FakeOverlayPanelHost()
        let presenter = ActivityOverlayWindowController(host: host, screens: FakeOverlayScreens())

        presenter.update(state: .listening(sessionID: UUID(), startedAt: .now, level: 0), style: .minimal)
        presenter.update(state: .processing(sessionID: UUID(), startedAt: .now), style: .interactive)

        XCTAssertEqual(host.ignoresMouseEventsValues, [true, false])
    }

    func testContentIsAppliedOnceUntilStyleChanges() {
        let host = FakeOverlayPanelHost()
        let presenter = ActivityOverlayWindowController(host: host, screens: FakeOverlayScreens())
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
        let presenter = ActivityOverlayWindowController(host: host, screens: screens)
        let session = UUID()

        presenter.update(state: .listening(sessionID: session, startedAt: .now, level: 0), style: .interactive)
        presenter.update(state: .processing(sessionID: session, startedAt: .now), style: .off)
        presenter.update(state: .processing(sessionID: session, startedAt: .now), style: .interactive)

        XCTAssertEqual(host.positionedScreens, [.left, .left])
    }

    func testConsecutiveFailuresRecordOverlayFailedOnceUntilAShowSucceeds() {
        let host = FakeOverlayPanelHost()
        host.orderFrontError = FakeOverlayHostError.boom
        let diagnostics = DiagnosticsRecorder()
        let presenter = ActivityOverlayWindowController(host: host, screens: FakeOverlayScreens(), diagnostics: diagnostics)
        let session = UUID()

        presenter.update(state: .listening(sessionID: session, startedAt: .now, level: 0), style: .interactive)
        presenter.update(state: .listening(sessionID: session, startedAt: .now, level: 0.5), style: .interactive)
        XCTAssertEqual(diagnostics.entries.map(\.event), [.overlayFailed])

        host.orderFrontError = nil
        presenter.update(state: .processing(sessionID: session, startedAt: .now), style: .interactive)
        XCTAssertEqual(diagnostics.entries.map(\.event), [.overlayFailed])

        host.orderFrontError = FakeOverlayHostError.boom
        presenter.update(state: .speaking(sessionID: session, startedAt: .now), style: .interactive)
        XCTAssertEqual(diagnostics.entries.map(\.event), [.overlayFailed, .overlayFailed])
    }

    func testRelayoutRepositionsUsingRefreshedFrameForSameScreen() {
        let host = FakeOverlayPanelHost()
        let updatedLeft = ActivityOverlayScreen(
            id: ActivityOverlayScreen.left.id,
            visibleFrame: CGRect(x: 0, y: 0, width: 2_000, height: 1_200)
        )
        let screens = FakeRelayoutScreens(newSessionScreens: [.left], refreshedScreen: updatedLeft)
        let presenter = ActivityOverlayWindowController(host: host, screens: screens)
        presenter.update(state: .listening(sessionID: UUID(), startedAt: .now, level: 0), style: .interactive)

        presenter.relayoutForScreenChange()

        let expectedOrigin = ActivityOverlayPlacement.origin(
            panelSize: CGSize(width: 282, height: 62),
            visibleFrame: updatedLeft.visibleFrame
        )
        XCTAssertEqual(host.frames.last?.origin, expectedOrigin)
        XCTAssertEqual(host.positionedScreens.last, updatedLeft)
    }

    func testRelayoutFallsBackToNewSessionScreenWhenPinnedScreenDisappears() {
        let host = FakeOverlayPanelHost()
        let screens = FakeRelayoutScreens(newSessionScreens: [.left, .right], refreshedScreen: nil)
        let presenter = ActivityOverlayWindowController(host: host, screens: screens)
        presenter.update(state: .listening(sessionID: UUID(), startedAt: .now, level: 0), style: .interactive)

        presenter.relayoutForScreenChange()

        XCTAssertEqual(host.positionedScreens.last, .right)
    }

    func testRelayoutDoesNothingWhenHidden() {
        let host = FakeOverlayPanelHost()
        let screens = FakeRelayoutScreens(newSessionScreens: [], refreshedScreen: .right)
        let presenter = ActivityOverlayWindowController(host: host, screens: screens)

        presenter.relayoutForScreenChange()

        XCTAssertTrue(host.frames.isEmpty)
        XCTAssertTrue(host.positionedScreens.isEmpty)
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

    func screenForNewSession() -> ActivityOverlayScreen {
        next.isEmpty ? fallback : next.removeFirst()
    }

    func screen(withID id: ActivityOverlayScreen.ID) -> ActivityOverlayScreen? {
        [ActivityOverlayScreen.left, .right].first { $0.id == id }
    }
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

    func screenForNewSession() -> ActivityOverlayScreen {
        newSessionScreens.removeFirst()
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
    private(set) var positionedScreens: [ActivityOverlayScreen] = []
    private(set) var frames: [(origin: CGPoint, size: CGSize)] = []
    private(set) var ignoresMouseEventsValues: [Bool] = []
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

    func setFrame(origin: CGPoint, size: CGSize) {
        frames.append((origin, size))
    }

    func setIgnoresMouseEvents(_ ignores: Bool) {
        ignoresMouseEventsValues.append(ignores)
    }

    func orderFront(on screen: ActivityOverlayScreen) throws {
        if let orderFrontError { throw orderFrontError }
        positionedScreens.append(screen)
    }

    func orderOut() {
        orderOutCount += 1
    }
}
