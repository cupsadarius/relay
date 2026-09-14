import CoreGraphics
import Foundation
@preconcurrency import AppKit
import SwiftUI

/// The AppKit-independent seam AppModel binds `ActivityOverlayModel.setStateHandler` to.
@MainActor
protocol ActivityOverlayPresenting: AnyObject {
    func update(state: ActivityOverlayState, style: ActivityOverlayStyle)
}

/// A stable, testable stand-in for an `NSScreen`. Production code maps real screens onto this;
/// tests construct values directly so they never need a real `NSScreen`.
struct ActivityOverlayScreen: Equatable, Sendable {
    typealias ID = String

    let id: ID
    let visibleFrame: CGRect
}

/// Chooses and looks up displays without exposing `NSScreen` to policy code.
@MainActor
protocol ActivityOverlayScreenProviding {
    /// The screen a brand-new session should be pinned to: the screen under the mouse,
    /// falling back to the main screen, falling back to the first available screen.
    func screenForNewSession() -> ActivityOverlayScreen

    /// Looks up a previously chosen screen by its stable identifier, for relayout after the
    /// active display's parameters change. Returns `nil` if that screen has disappeared.
    func screen(withID id: ActivityOverlayScreen.ID) -> ActivityOverlayScreen?
}

/// The AppKit boundary for the overlay panel: creating it, moving it, and showing/hiding it.
/// Production wraps a real `NSPanel`; tests fake it to verify policy without AppKit.
@MainActor
protocol ActivityOverlayPanelHosting: AnyObject {
    func createIfNeeded() throws
    func setContent(
        model: ActivityOverlayModel,
        style: ActivityOverlayStyle,
        onAction: @escaping @MainActor (ActivityOverlayAction) async -> Void
    )
    func setFrame(origin: CGPoint, size: CGSize)
    func setIgnoresMouseEvents(_ ignores: Bool)
    func orderFront(on screen: ActivityOverlayScreen) throws
    func orderOut()
}

/// Pure placement math: the panel sits centered above the bottom of the active display.
enum ActivityOverlayPlacement {
    static func origin(panelSize: CGSize, visibleFrame: CGRect) -> CGPoint {
        CGPoint(
            x: visibleFrame.midX - panelSize.width / 2,
            y: visibleFrame.minY + 28
        )
    }
}

/// Pure policy for hosting the activity capsule: which display to pin to, where to place it,
/// and when to show or hide it. Failures are isolated here and never propagate to callers.
@MainActor
final class ActivityOverlayWindowController: ActivityOverlayPresenting {
    private let model: ActivityOverlayModel
    private let host: any ActivityOverlayPanelHosting
    private let screens: any ActivityOverlayScreenProviding
    private let diagnostics: DiagnosticsRecorder?
    private let onAction: @MainActor (ActivityOverlayAction) async -> Void

    private var pinnedSessionID: UUID?
    private var pinnedScreen: ActivityOverlayScreen?
    private var lastSize: CGSize?
    private var lastAppliedStyle: ActivityOverlayStyle?
    private var isPanelVisible = false
    private var hasReportedFailure = false
    private nonisolated(unsafe) var screenParametersObserver: NSObjectProtocol?

    init(
        model: ActivityOverlayModel = ActivityOverlayModel(),
        host: any ActivityOverlayPanelHosting,
        screens: any ActivityOverlayScreenProviding = SystemActivityOverlayScreens(),
        diagnostics: DiagnosticsRecorder? = nil,
        onAction: @escaping @MainActor (ActivityOverlayAction) async -> Void = { _ in }
    ) {
        self.model = model
        self.host = host
        self.screens = screens
        self.diagnostics = diagnostics
        self.onAction = onAction
        observeScreenParameterChanges()
    }

    deinit {
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
        }
    }

    func update(state: ActivityOverlayState, style: ActivityOverlayStyle) {
        guard !state.isHidden, let sessionID = state.sessionID else {
            hide()
            return
        }

        if pinnedSessionID != sessionID {
            pinnedSessionID = sessionID
            pinnedScreen = screens.screenForNewSession()
        }
        guard let screen = pinnedScreen else { return }

        guard let presentation = ActivityOverlayPresentation.make(state: state, style: style, reduceMotion: false) else {
            // Style is `.off` while a session is still active: hide the panel but keep the
            // pinned session/screen so switching back to a visible style mid-session reuses it.
            orderOut()
            return
        }

        show(size: presentation.size, style: style, on: screen)
    }

    /// Re-applies the pinned screen's current geometry. Called after the active display's
    /// parameters change (resolution, arrangement, etc.); falls back to a fresh screen pick
    /// if the pinned screen has disappeared. Does nothing while the panel isn't shown.
    func relayoutForScreenChange() {
        guard isPanelVisible, let previousScreen = pinnedScreen, let size = lastSize else { return }
        let refreshed = screens.screen(withID: previousScreen.id) ?? screens.screenForNewSession()
        pinnedScreen = refreshed
        do {
            host.setFrame(origin: ActivityOverlayPlacement.origin(panelSize: size, visibleFrame: refreshed.visibleFrame), size: size)
            try host.orderFront(on: refreshed)
            recordShowSucceeded()
        } catch {
            recordFailure()
        }
    }

    private func show(size: CGSize, style: ActivityOverlayStyle, on screen: ActivityOverlayScreen) {
        do {
            try host.createIfNeeded()
            if lastAppliedStyle != style {
                host.setContent(model: model, style: style, onAction: onAction)
                lastAppliedStyle = style
            }
            host.setFrame(origin: ActivityOverlayPlacement.origin(panelSize: size, visibleFrame: screen.visibleFrame), size: size)
            host.setIgnoresMouseEvents(style != .interactive)
            try host.orderFront(on: screen)
            isPanelVisible = true
            lastSize = size
            recordShowSucceeded()
        } catch {
            recordFailure()
        }
    }

    private func orderOut() {
        guard isPanelVisible else { return }
        isPanelVisible = false
        host.orderOut()
    }

    private func hide() {
        orderOut()
        pinnedSessionID = nil
        pinnedScreen = nil
        lastSize = nil
        hasReportedFailure = false
    }

    private func recordFailure() {
        guard !hasReportedFailure else { return }
        hasReportedFailure = true
        diagnostics?.record(.overlayFailed)
    }

    private func recordShowSucceeded() {
        hasReportedFailure = false
    }

    private func observeScreenParameterChanges() {
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.relayoutForScreenChange() }
        }
    }
}

/// Production screen lookup, backed by real `NSScreen`s.
@MainActor
final class SystemActivityOverlayScreens: ActivityOverlayScreenProviding {
    func screenForNewSession() -> ActivityOverlayScreen {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        return Self.overlayScreen(for: screen)
    }

    func screen(withID id: ActivityOverlayScreen.ID) -> ActivityOverlayScreen? {
        NSScreen.screens.first { Self.identifier(for: $0) == id }.map(Self.overlayScreen(for:))
    }

    private static func overlayScreen(for screen: NSScreen?) -> ActivityOverlayScreen {
        guard let screen else { return ActivityOverlayScreen(id: "unknown", visibleFrame: .zero) }
        return ActivityOverlayScreen(id: identifier(for: screen), visibleFrame: screen.visibleFrame)
    }

    private static func identifier(for screen: NSScreen) -> String {
        if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return number.stringValue
        }
        return String(describing: ObjectIdentifier(screen))
    }
}

/// A non-activating panel: it never becomes key or main, so showing it cannot steal focus
/// from whatever app the user is dictating or reading into.
@MainActor
private final class NonActivatingOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private enum ActivityOverlayHostError: Error {
    case panelNotCreated
}

/// Production `NSPanel` host for the activity capsule.
@MainActor
final class ActivityOverlayPanelHost: ActivityOverlayPanelHosting {
    private var panel: NonActivatingOverlayPanel?

    func createIfNeeded() throws {
        guard panel == nil else { return }
        let panel = NonActivatingOverlayPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.level = .floating
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        self.panel = panel
    }

    func setContent(
        model: ActivityOverlayModel,
        style: ActivityOverlayStyle,
        onAction: @escaping @MainActor (ActivityOverlayAction) async -> Void
    ) {
        guard let panel else { return }
        let hostingView = NSHostingView(rootView: ActivityOverlayView(model: model, style: style, onAction: onAction))
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        panel.contentView = hostingView
    }

    func setFrame(origin: CGPoint, size: CGSize) {
        panel?.setFrame(CGRect(origin: origin, size: size), display: true)
    }

    func setIgnoresMouseEvents(_ ignores: Bool) {
        panel?.ignoresMouseEvents = ignores
    }

    func orderFront(on screen: ActivityOverlayScreen) throws {
        guard let panel else { throw ActivityOverlayHostError.panelNotCreated }
        _ = screen
        panel.orderFrontRegardless()
    }

    func orderOut() {
        panel?.orderOut(nil)
    }
}
