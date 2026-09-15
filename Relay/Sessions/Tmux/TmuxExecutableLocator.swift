import Foundation

struct TmuxExecutableLocator: Sendable {
    let candidates = [
        "/opt/homebrew/bin/tmux",
        "/usr/local/bin/tmux",
        "/opt/local/bin/tmux",
        "/usr/bin/tmux"
    ]

    func locate(fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)) -> String? {
        candidates.first(where: fileExists)
    }
}
