import AppKit
import SwiftUI

struct RelayWindowTagger: NSViewRepresentable {
    let target: RelayWindowTarget

    func makeNSView(context: Context) -> TaggedWindowView { TaggedWindowView(target: target) }
    func updateNSView(_ view: TaggedWindowView, context: Context) { view.target = target; view.tagWindow() }
}

final class TaggedWindowView: NSView {
    var target: RelayWindowTarget

    init(target: RelayWindowTarget) { self.target = target; super.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); tagWindow() }
    func tagWindow() { window?.identifier = target.identifier }
}
