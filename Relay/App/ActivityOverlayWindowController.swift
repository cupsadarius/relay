import CoreGraphics
import Foundation
import AppKit

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
    /// Returns `nil` only if no screen exists at all.
    func screenForNewSession() -> ActivityOverlayScreen?

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
    func setFrame(origin: CGPoint, size: CGSize, animated: Bool)
    func setIgnoresMouseEvents(_ ignores: Bool)
    func orderFront() throws
    func orderOut()
}

/// Pure placement math: the panel sits centered above the bottom of the active display.
/// A `chromeInset` margin is added around the capsule so its own shadow/stroke aren't clipped
/// by the panel's bounds (the panel itself stays invisible/borderless).
enum ActivityOverlayPlacement {
    static let chromeInset: CGFloat = 24

    static func origin(capsuleSize: CGSize, visibleFrame: CGRect) -> CGPoint {
        CGPoint(
            x: visibleFrame.midX - capsuleSize.width / 2,
            y: visibleFrame.minY + 28
        )
    }

    static func panelFrame(capsuleSize: CGSize, visibleFrame: CGRect) -> CGRect {
        let capsuleOrigin = origin(capsuleSize: capsuleSize, visibleFrame: visibleFrame)
        return CGRect(origin: capsuleOrigin, size: capsuleSize).insetBy(dx: -chromeInset, dy: -chromeInset)
    }
}

/// Pure policy for hosting the activity capsule: which display to pin to, where to place it,
/// and when to show or hide it. Failures are isolated here and never propagate to callers.
/// Host calls (`setFrame`/`setIgnoresMouseEvents`/`orderFront`/`setContent`) are only made when
/// the value they'd apply has actually changed, so rapid same-session updates (e.g. mic level
/// ticks) don't repeatedly disturb the hosted SwiftUI content or the window server.
@MainActor
final class ActivityOverlayWindowController: ActivityOverlayPresenting {
    private let model: ActivityOverlayModel
    private let host: any ActivityOverlayPanelHosting
    private let screens: any ActivityOverlayScreenProviding
    private let diagnostics: DiagnosticsRecorder?
    private let onAction: @MainActor (ActivityOverlayAction) async -> Void

    private var pinnedSessionID: UUID?
    private var pinnedScreen: ActivityOverlayScreen?
    private var lastCapsuleSize: CGSize?
    private var lastAppliedStyle: ActivityOverlayStyle?
    private var lastPanelOrigin: CGPoint?
    private var lastPanelSize: CGSize?
    private var lastIgnoresMouse: Bool?
    private var isPanelVisible = false
    private var hasReportedFailure = false
    private var screenParametersObservation: NotificationObservation?

    init(
        model: ActivityOverlayModel,
        host: any ActivityOverlayPanelHosting,
        screens: any ActivityOverlayScreenProviding,
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

    func update(state: ActivityOverlayState, style: ActivityOverlayStyle) {
        guard !state.isHidden, let sessionID = state.sessionID else {
            hide()
            return
        }

        guard style != .off else {
            // Hide the panel but keep any existing pinned session/screen so switching back to a
            // visible style mid-session reuses it. Never pin a screen or record a failure here:
            // a missing screen doesn't matter when nothing should be shown anyway.
            orderOut()
            return
        }

        if pinnedSessionID != sessionID {
            guard let screen = screens.screenForNewSession() else {
                recordFailure()
                return
            }
            pinnedSessionID = sessionID
            pinnedScreen = screen
        }
        guard let screen = pinnedScreen else { return }

        guard let presentation = ActivityOverlayPresentation.make(state: state, style: style, reduceMotion: false) else {
            orderOut()
            return
        }

        show(capsuleSize: presentation.size, style: style, on: screen)
    }

    /// Re-applies the pinned screen's current geometry. Called after the active display's
    /// parameters change (resolution, arrangement, etc.); falls back to a fresh screen pick
    /// if the pinned screen has disappeared. Does nothing while the panel isn't shown.
    func relayoutForScreenChange() {
        guard isPanelVisible, let previousScreen = pinnedScreen, let capsuleSize = lastCapsuleSize else { return }
        guard let refreshed = screens.screen(withID: previousScreen.id) ?? screens.screenForNewSession() else {
            recordFailure()
            return
        }
        pinnedScreen = refreshed
        applyFrame(capsuleSize: capsuleSize, visibleFrame: refreshed.visibleFrame)
        recordShowSucceeded()
    }

    private func show(capsuleSize: CGSize, style: ActivityOverlayStyle, on screen: ActivityOverlayScreen) {
        do {
            try host.createIfNeeded()
            if lastAppliedStyle != style {
                host.setContent(model: model, style: style, onAction: onAction)
                lastAppliedStyle = style
            }
            lastCapsuleSize = capsuleSize
            applyFrame(capsuleSize: capsuleSize, visibleFrame: screen.visibleFrame)

            let ignoresMouse = style != .interactive
            if lastIgnoresMouse != ignoresMouse {
                host.setIgnoresMouseEvents(ignoresMouse)
                lastIgnoresMouse = ignoresMouse
            }

            if !isPanelVisible {
                try host.orderFront()
                isPanelVisible = true
            }
            recordShowSucceeded()
        } catch {
            // `isPanelVisible` is only set to `true` once `orderFront` succeeds above, so a
            // throw here leaves it `false` and the next update retries showing the panel.
            recordFailure()
        }
    }

    private func applyFrame(capsuleSize: CGSize, visibleFrame: CGRect) {
        let frame = ActivityOverlayPlacement.panelFrame(capsuleSize: capsuleSize, visibleFrame: visibleFrame)
        guard lastPanelOrigin != frame.origin || lastPanelSize != frame.size else { return }
        // Animate resizes once the panel is already positioned; the very first placement (no
        // previous frame recorded yet) snaps directly into place instead of animating in from a
        // meaningless prior frame - the SwiftUI scale/opacity transition already covers that
        // first appearance. `panelFrame` keeps the panel's bottom edge and horizontal center
        // fixed for any capsule size, and linear interpolation between two frames that both
        // satisfy a linear invariant (fixed midX, fixed minY) preserves that invariant at every
        // intermediate frame too, so an animated resize never drifts off that anchor mid-flight.
        let animated = lastPanelOrigin != nil
        host.setFrame(origin: frame.origin, size: frame.size, animated: animated)
        lastPanelOrigin = frame.origin
        lastPanelSize = frame.size
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
        lastCapsuleSize = nil
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
        screenParametersObservation = NotificationObservation(
            name: NSApplication.didChangeScreenParametersNotification
        ) { [weak self] in
            self?.relayoutForScreenChange()
        }
    }
}
