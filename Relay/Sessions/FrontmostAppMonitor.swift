import AppKit

struct FrontmostApplication: Equatable, Sendable {
    let pid: Int32
    let bundleIdentifier: String?
    let localizedName: String?
}

protocol FrontmostAppMonitoring: Sendable {
    func current() async -> FrontmostApplication?
}

struct FrontmostAppMonitor: FrontmostAppMonitoring {
    @MainActor
    func current() async -> FrontmostApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return FrontmostApplication(
            pid: app.processIdentifier,
            bundleIdentifier: app.bundleIdentifier,
            localizedName: app.localizedName
        )
    }
}
