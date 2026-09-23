import SwiftUI

/// User-visible chrome that differs between the Release and Debug builds, so the two
/// side-by-side apps are distinguishable at a glance. Release values match the app as it
/// shipped before flavors existed. The activity overlay deliberately does not use this.
struct BuildFlavorPresentation: Equatable, Sendable {
    let menuBarTitle: String
    let menuBarSystemImage: String
    /// Short text shown next to the menu bar image; `nil` shows the image alone.
    let menuBarBadge: String?
    /// First line of the menu bar menu; `nil` shows no header.
    let menuHeader: String?
    /// Title forced onto the Settings window; `nil` leaves SwiftUI's default.
    let settingsWindowTitle: String?
    let quitTitle: String

    init(flavor: BuildFlavor) {
        let name = flavor.displayName
        menuBarTitle = name
        menuBarSystemImage = "waveform"
        quitTitle = "Quit \(name)"
        switch flavor {
        case .release:
            menuBarBadge = nil
            menuHeader = nil
            settingsWindowTitle = nil
        case .debug:
            menuBarBadge = "DEV"
            menuHeader = name
            settingsWindowTitle = "\(name) Settings"
        }
    }

    static var current: BuildFlavorPresentation { BuildFlavorPresentation(flavor: .current) }
}

/// The menu bar item's label. The SF Symbol renders as a template image and the badge text
/// uses the menu bar's own text colour, so both follow light/dark menu bar appearance.
struct MenuBarLabel: View {
    let presentation: BuildFlavorPresentation

    var body: some View {
        if let badge = presentation.menuBarBadge {
            HStack(spacing: 2) {
                Image(systemName: presentation.menuBarSystemImage)
                Text(badge)
                    .font(.system(size: 9, weight: .bold))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(presentation.menuBarTitle)
        } else {
            Image(systemName: presentation.menuBarSystemImage)
                .accessibilityLabel(presentation.menuBarTitle)
        }
    }
}
