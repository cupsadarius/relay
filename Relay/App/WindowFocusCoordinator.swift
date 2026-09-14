import AppKit

enum RelayWindowTarget: Hashable {
    case settings
    case diagnostics

    var identifier: NSUserInterfaceItemIdentifier {
        switch self {
        case .settings: NSUserInterfaceItemIdentifier("dev.relaymac.Relay.settings")
        case .diagnostics: NSUserInterfaceItemIdentifier("dev.relaymac.Relay.diagnostics")
        }
    }
}

@MainActor protocol RelayApplicationActivating { func activate() }
@MainActor protocol RelayWindowPresenting { func presentSettings(); func presentDiagnostics() }
@MainActor protocol RelayWindowFocusing: AnyObject {
    var isMiniaturized: Bool { get }
    func deminiaturize()
    func makeKeyAndOrderFront()
}
@MainActor protocol RelayWindowFinding { func window(for target: RelayWindowTarget) -> (any RelayWindowFocusing)? }
@MainActor protocol RelayMainLoopScheduling { func schedule(_ action: @escaping @MainActor @Sendable () -> Void) }

@MainActor
final class WindowFocusCoordinator {
    private let application: any RelayApplicationActivating
    private let windows: any RelayWindowPresenting
    private let finder: any RelayWindowFinding
    private let scheduler: any RelayMainLoopScheduling

    init(application: any RelayApplicationActivating, windows: any RelayWindowPresenting, finder: any RelayWindowFinding, scheduler: any RelayMainLoopScheduling) {
        self.application = application
        self.windows = windows
        self.finder = finder
        self.scheduler = scheduler
    }

    func openSettings() { open(.settings) }
    func openDiagnostics() { open(.diagnostics) }

    private func open(_ target: RelayWindowTarget) {
        if let window = finder.window(for: target) {
            Self.focus(window, application: application)
            return
        }
        switch target {
        case .settings: windows.presentSettings()
        case .diagnostics: windows.presentDiagnostics()
        }
        let application = application
        let finder = finder
        scheduler.schedule {
            guard let window = finder.window(for: target) else { return }
            Self.focus(window, application: application)
        }
    }

    private static func focus(_ window: any RelayWindowFocusing, application: any RelayApplicationActivating) {
        application.activate()
        if window.isMiniaturized { window.deminiaturize() }
        window.makeKeyAndOrderFront()
    }
}

@MainActor struct RelayApplicationActivator: RelayApplicationActivating { func activate() { NSApplication.shared.activate() } }

@MainActor
struct RelayWindowActions: RelayWindowPresenting {
    private let openSettings: () -> Void
    private let openDiagnostics: () -> Void
    init(openSettings: @escaping () -> Void, openDiagnostics: @escaping () -> Void) { self.openSettings = openSettings; self.openDiagnostics = openDiagnostics }
    func presentSettings() { openSettings() }
    func presentDiagnostics() { openDiagnostics() }
}

@MainActor
struct RelayAppWindowFinder: RelayWindowFinding {
    func window(for target: RelayWindowTarget) -> (any RelayWindowFocusing)? {
        NSApplication.shared.windows.first { $0.identifier == target.identifier }.map(RelayAppKitWindow.init)
    }
}

@MainActor
final class RelayAppKitWindow: RelayWindowFocusing {
    private let window: NSWindow
    init(_ window: NSWindow) { self.window = window }
    var isMiniaturized: Bool { window.isMiniaturized }
    func deminiaturize() { window.deminiaturize(nil) }
    func makeKeyAndOrderFront() { window.makeKeyAndOrderFront(nil) }
}

@MainActor struct MainLoopScheduler: RelayMainLoopScheduling { func schedule(_ action: @escaping @MainActor @Sendable () -> Void) { DispatchQueue.main.async(execute: action) } }
