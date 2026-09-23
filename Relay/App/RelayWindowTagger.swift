import AppKit
import SwiftUI

struct RelayWindowTagger: NSViewRepresentable {
    let target: RelayWindowTarget
    /// When non-nil, forced onto the hosting window's title (Debug Settings window).
    var title: String? = nil

    func makeNSView(context: Context) -> TaggedWindowView { TaggedWindowView(target: target, title: title) }
    func updateNSView(_ view: TaggedWindowView, context: Context) {
        view.target = target
        view.title = title
        view.tagWindow()
    }
}

final class TaggedWindowView: NSView {
    var target: RelayWindowTarget
    var title: String?

    init(target: RelayWindowTarget, title: String? = nil) {
        self.target = target
        self.title = title
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); tagWindow() }
    func tagWindow() {
        window?.identifier = target.identifier
        if let title { window?.title = title }
    }
}
