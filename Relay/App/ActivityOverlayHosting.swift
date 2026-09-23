import CoreGraphics
import Foundation

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
