import XCTest

@testable import Relay

@MainActor
final class WindowFocusCoordinatorTests: XCTestCase {
    func testExistingSettingsWindowActivatesRestoresAndFocusesWithoutPresenting() {
        let events = EventLog()
        let settings = FakeWindow(target: .settings, isMiniaturized: true, events: events)
        let presenter = FakeRelayWindowPresenter(events: events)
        let coordinator = makeCoordinator(events: events, finder: FakeWindowFinder(windows: [.settings: settings]), presenter: presenter)

        coordinator.openSettings()

        XCTAssertEqual(events.values, [.activated, .settingsRestored, .settingsFocused])
        XCTAssertEqual(presenter.settingsPresentationCount, 0)
    }

    func testAbsentDiagnosticsWindowPresentsOnceThenRestoresAndFocusesOnNextMainLoopTurn() {
        let events = EventLog()
        let finder = FakeWindowFinder(windows: [:])
        let presenter = FakeRelayWindowPresenter(events: events)
        let scheduler = FakeMainLoopScheduler(events: events)
        let coordinator = makeCoordinator(events: events, finder: finder, presenter: presenter, scheduler: scheduler)

        coordinator.openDiagnostics()

        XCTAssertEqual(events.values, [.activated, .diagnosticsPresented, .focusScheduled])
        XCTAssertEqual(presenter.diagnosticsPresentationCount, 1)

        finder.windows[.diagnostics] = FakeWindow(target: .diagnostics, isMiniaturized: true, events: events)
        scheduler.runNext()

        XCTAssertEqual(events.values, [.activated, .diagnosticsPresented, .focusScheduled, .activated, .diagnosticsRestored, .diagnosticsFocused])
        XCTAssertEqual(presenter.diagnosticsPresentationCount, 1)
    }

    /// First open activates the app around presenting (so the freshly created, untagged window
    /// comes forward immediately) and retries the focus lookup across bounded scheduler turns,
    /// since `RelayWindowTagger` may not have tagged the window by the first turn.
    func testAbsentSettingsWindowActivatesBeforePresentingAndRetriesFocusAcrossTurnsUntilTagged() {
        let events = EventLog()
        let finder = FakeWindowFinder(windows: [:])
        let presenter = FakeRelayWindowPresenter(events: events)
        let scheduler = FakeMainLoopScheduler(events: events)
        let coordinator = makeCoordinator(events: events, finder: finder, presenter: presenter, scheduler: scheduler)

        coordinator.openSettings()

        XCTAssertEqual(events.values, [.activated, .settingsPresented, .focusScheduled])
        XCTAssertEqual(presenter.settingsPresentationCount, 1)

        // First retry turn: the window still hasn't been tagged yet.
        scheduler.runNext()
        XCTAssertEqual(events.values, [.activated, .settingsPresented, .focusScheduled, .focusScheduled])

        // The window is tagged before the second retry turn runs.
        finder.windows[.settings] = FakeWindow(target: .settings, isMiniaturized: false, events: events)
        scheduler.runNext()

        XCTAssertEqual(
            events.values,
            [.activated, .settingsPresented, .focusScheduled, .focusScheduled, .activated, .settingsFocused]
        )
        XCTAssertEqual(presenter.settingsPresentationCount, 1)
    }

    /// The retry must be bounded: if the window never gets tagged, the coordinator gives up
    /// after a small, fixed number of attempts rather than scheduling forever.
    func testFocusRetryGivesUpAfterBoundedAttemptsWhenWindowNeverAppears() {
        let events = EventLog()
        let finder = FakeWindowFinder(windows: [:])
        let presenter = FakeRelayWindowPresenter(events: events)
        let scheduler = FakeMainLoopScheduler(events: events)
        let coordinator = makeCoordinator(events: events, finder: finder, presenter: presenter, scheduler: scheduler)

        coordinator.openSettings()
        scheduler.runNext()
        scheduler.runNext()
        scheduler.runNext()

        XCTAssertEqual(
            events.values,
            [.activated, .settingsPresented, .focusScheduled, .focusScheduled, .focusScheduled]
        )
        XCTAssertFalse(scheduler.hasPendingAction)
    }

    func testDeferredFocusSurvivesCoordinatorRelease() {
        let events = EventLog()
        let finder = FakeWindowFinder(windows: [:])
        let presenter = FakeRelayWindowPresenter(events: events)
        let scheduler = FakeMainLoopScheduler(events: events)
        var coordinator: WindowFocusCoordinator? = makeCoordinator(events: events, finder: finder, presenter: presenter, scheduler: scheduler)

        coordinator?.openDiagnostics()
        coordinator = nil
        finder.windows[.diagnostics] = FakeWindow(target: .diagnostics, isMiniaturized: true, events: events)

        scheduler.runNext()

        XCTAssertEqual(events.values, [.activated, .diagnosticsPresented, .focusScheduled, .activated, .diagnosticsRestored, .diagnosticsFocused])
    }

    func testExistingDiagnosticsWindowIsNotPresentedAgain() {
        let events = EventLog()
        let presenter = FakeRelayWindowPresenter(events: events)
        let coordinator = makeCoordinator(
            events: events,
            finder: FakeWindowFinder(windows: [.diagnostics: FakeWindow(target: .diagnostics, isMiniaturized: false, events: events)]),
            presenter: presenter
        )

        coordinator.openDiagnostics()

        XCTAssertEqual(presenter.diagnosticsPresentationCount, 0)
        XCTAssertEqual(events.values, [.activated, .diagnosticsFocused])
    }

    private func makeCoordinator(events: EventLog, finder: FakeWindowFinder, presenter: FakeRelayWindowPresenter, scheduler: FakeMainLoopScheduler? = nil)
        -> WindowFocusCoordinator
    {
        WindowFocusCoordinator(
            application: FakeApplicationActivator(events: events), windows: presenter, finder: finder,
            scheduler: scheduler ?? FakeMainLoopScheduler(events: events))
    }
}

@MainActor private final class EventLog { var values: [WindowFocusEvent] = [] }

private enum WindowFocusEvent: Equatable {
    case activated, settingsPresented, diagnosticsPresented, focusScheduled
    case settingsRestored, diagnosticsRestored, settingsFocused, diagnosticsFocused
}

@MainActor private final class FakeApplicationActivator: RelayApplicationActivating {
    private let events: EventLog
    init(events: EventLog) { self.events = events }
    func activate() { events.values.append(.activated) }
}

@MainActor private final class FakeRelayWindowPresenter: RelayWindowPresenting {
    private let events: EventLog
    private(set) var settingsPresentationCount = 0
    private(set) var diagnosticsPresentationCount = 0
    init(events: EventLog) { self.events = events }
    func presentSettings() { settingsPresentationCount += 1; events.values.append(.settingsPresented) }
    func presentDiagnostics() { diagnosticsPresentationCount += 1; events.values.append(.diagnosticsPresented) }
}

@MainActor private final class FakeWindowFinder: RelayWindowFinding {
    var windows: [RelayWindowTarget: any RelayWindowFocusing]
    init(windows: [RelayWindowTarget: any RelayWindowFocusing]) { self.windows = windows }
    func window(for target: RelayWindowTarget) -> (any RelayWindowFocusing)? { windows[target] }
}

@MainActor private final class FakeWindow: RelayWindowFocusing {
    let target: RelayWindowTarget
    var isMiniaturized: Bool
    private let events: EventLog
    init(target: RelayWindowTarget, isMiniaturized: Bool, events: EventLog) { self.target = target; self.isMiniaturized = isMiniaturized; self.events = events }
    func deminiaturize() { isMiniaturized = false; events.values.append(target == .settings ? .settingsRestored : .diagnosticsRestored) }
    func makeKeyAndOrderFront() { events.values.append(target == .settings ? .settingsFocused : .diagnosticsFocused) }
}

@MainActor private final class FakeMainLoopScheduler: RelayMainLoopScheduling {
    private let events: EventLog
    private var actions: [@MainActor @Sendable () -> Void] = []
    var hasPendingAction: Bool { !actions.isEmpty }
    init(events: EventLog) { self.events = events }
    func schedule(_ action: @escaping @MainActor @Sendable () -> Void) { events.values.append(.focusScheduled); actions.append(action) }
    func runNext() { actions.removeFirst()() }
}
