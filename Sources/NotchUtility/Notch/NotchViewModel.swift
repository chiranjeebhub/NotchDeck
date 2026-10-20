import AppKit
import SwiftUI

/// Per-screen state of the notch: open/closed, selected tab and geometry.
@MainActor
final class NotchViewModel: ObservableObject {
    enum Status { case closed, open }

    enum Tab: String, CaseIterable {
        case home, tray, dev

        var title: String {
            switch self {
            case .home: "Home"
            case .tray: "Tray"
            case .dev: "Dev"
            }
        }

        var systemImage: String {
            switch self {
            case .home: "rectangle.3.group"
            case .tray: "tray"
            case .dev: "terminal"
            }
        }
    }

    /// Tabs turned on in Settings. The Tray stays reachable while a file is dragged over the notch.
    static func visibleTabs(includingTray: Bool = false) -> [Tab] {
        let defaults = UserDefaults.standard
        let tabs = Tab.allCases.filter { tab in
            switch tab {
            case .home: defaults.bool(forKey: AppSettings.showHomeTabKey)
            case .tray: includingTray || defaults.bool(forKey: AppSettings.showTrayTabKey)
            case .dev: defaults.bool(forKey: AppSettings.showDevTabKey)
            }
        }
        return tabs.isEmpty ? [.home] : tabs
    }

    @Published var status: Status = .closed
    @Published var tab: Tab = .home
    @Published var isDropTargeted = false
    /// Height the current tab asks for (the Dev tab grows with its list), or nil for the default.
    @Published var preferredHeight: CGFloat?

    let hasNotch: Bool
    /// Physical notch size, or the handle size on screens without a notch.
    let notchSize: CGSize
    static let openWidth: CGFloat = 700
    static let openHeight: CGFloat = 230
    static let tallOpenHeight: CGFloat = 430

    /// Size of the expanded content area (without the concave "ears").
    var openSize: CGSize {
        let height = preferredHeight.map { min(max($0, Self.openHeight), Self.tallOpenHeight) } ?? Self.openHeight
        return CGSize(width: Self.openWidth, height: height)
    }
    /// The largest the open notch can get, which sizes its window.
    var maxOpenSize: CGSize { CGSize(width: Self.openWidth, height: Self.tallOpenHeight) }

    init(screen: NSScreen) {
        hasNotch = NotchGeometry.hasNotch(screen)
        notchSize = NotchGeometry.notchSize(for: screen)
    }

    /// Height of the top row of the open notch, which sits beside the camera housing.
    var headerHeight: CGFloat { max(notchSize.height, 30) }

    /// Radius of the concave corners that blend the notch into the top edge.
    func earRadius(isOpen: Bool) -> CGFloat {
        isOpen ? 14 : (hasNotch ? 6 : 3)
    }

    /// The closed shape widens to show album art and a level meter while music plays.
    func showsLiveActivity(isPlaying: Bool) -> Bool {
        hasNotch && isPlaying && AppSettings.showLiveActivity
    }

    func closedSize(isPlaying: Bool) -> CGSize {
        guard showsLiveActivity(isPlaying: isPlaying) else { return notchSize }
        return CGSize(width: notchSize.width + notchSize.height * 2, height: notchSize.height)
    }
}
