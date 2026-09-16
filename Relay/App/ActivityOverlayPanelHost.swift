import CoreGraphics
@preconcurrency import AppKit
import SwiftUI

/// Production screen lookup, backed by real `NSScreen`s.
@MainActor
final class SystemActivityOverlayScreens: ActivityOverlayScreenProviding {
    func screenForNewSession() -> ActivityOverlayScreen? {
        let mouseLocation = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        else { return nil }
        return Self.overlayScreen(for: screen)
    }

    func screen(withID id: ActivityOverlayScreen.ID) -> ActivityOverlayScreen? {
        NSScreen.screens.first { Self.identifier(for: $0) == id }.map(Self.overlayScreen(for:))
    }

    private static func overlayScreen(for screen: NSScreen) -> ActivityOverlayScreen {
        ActivityOverlayScreen(id: identifier(for: screen), visibleFrame: screen.visibleFrame)
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

/// Lets the Interactive capsule's cancel/stop button receive a click on first mouse-down even
/// though the panel never becomes key: without this override AppKit treats the first click on
/// an inactive window's view as "activate the window" and swallows it instead of delivering it.
@MainActor
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private enum ActivityOverlayHostError: Error {
    case panelNotCreated
}

/// Production `NSPanel` host for the activity capsule.
@MainActor
final class ActivityOverlayPanelHost: ActivityOverlayPanelHosting {
    private static let resizeAnimationDuration: TimeInterval = 0.18
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
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.level = .floating
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.animationBehavior = .none
        self.panel = panel
    }

    func setContent(
        model: ActivityOverlayModel,
        style: ActivityOverlayStyle,
        onAction: @escaping @MainActor (ActivityOverlayAction) async -> Void
    ) {
        guard let panel else { return }
        let content = ActivityOverlayView(model: model, style: style, onAction: onAction)
            .padding(ActivityOverlayPlacement.chromeInset)
        let hostingView = FirstMouseHostingView(rootView: content)
        hostingView.sizingOptions = []
        panel.contentView = hostingView
    }

    /// The very first placement of a session's panel calls this with `animated: false` (there is
    /// no meaningful prior frame to animate from); every later resize during that same session -
    /// e.g. the pill growing/shrinking as interim text arrives - animates smoothly instead of
    /// snapping.
    func setFrame(origin: CGPoint, size: CGSize, animated: Bool) {
        guard let panel else { return }
        let frame = CGRect(origin: origin, size: size)
        guard animated else {
            panel.setFrame(frame, display: false)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.resizeAnimationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    func setIgnoresMouseEvents(_ ignores: Bool) {
        panel?.ignoresMouseEvents = ignores
    }

    func orderFront() throws {
        guard let panel else { throw ActivityOverlayHostError.panelNotCreated }
        panel.orderFrontRegardless()
    }

    func orderOut() {
        panel?.orderOut(nil)
    }
}
