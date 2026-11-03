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

        /// The setting that shows or hides this tab.
        var visibilityKey: String {
            switch self {
            case .home: AppSettings.showHomeTabKey
            case .tray: AppSettings.showTrayTabKey
            case .dev: AppSettings.showDevTabKey
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

    /// Tabs turned on in Settings, in the chosen order. The Tray stays reachable while a file is dragged over the notch.
    static func visibleTabs(includingTray: Bool = false) -> [Tab] {
        let defaults = UserDefaults.standard
        let tabs = AppSettings.tabOrder.filter { tab in
            (tab == .tray && includingTray) || defaults.bool(forKey: tab.visibilityKey)
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
        // The notch opens on the first tab until you pick another one.
        tab = Self.visibleTabs().first ?? .home
    }

    /// Height of the top row of the open notch, which sits beside the camera housing.
    var headerHeight: CGFloat { max(notchSize.height, 30) }

    /// Radius of the concave corners that blend the notch into the top edge.
    func earRadius(isOpen: Bool) -> CGFloat {
        isOpen ? 14 : (hasNotch ? 6 : 3)
    }

    /// Width of each side of the closed notch while it shows an agent or a command.
    static let activitySideWidth: CGFloat = 108

    /// What the closed notch shows beside the camera: an agent that needs you first, then a
    /// short "finished" note, then a running command, then music.
    func closedActivity(isPlaying: Bool) -> ClosedActivity? {
        guard hasNotch else { return nil }
        let agents = AgentsService.shared
        let commands = CommandsService.shared
        if AppSettings.closedShowsAgents, let session = agents.waitingSession {
            return .agentWaiting(session)
        }
        if AppSettings.closedShowsCommands, let flash = commands.flash { return .flash(flash) }
        if AppSettings.closedShowsAgents, let flash = agents.flash { return .flash(flash) }
        if AppSettings.closedShowsCommands {
            let running = commands.running.filter { !CommandsService.isOpenEnded($0) }
            if let first = running.first { return .command(first, others: running.count - 1) }
        }
        if isPlaying && AppSettings.showLiveActivity { return .music }
        return nil
    }

    func closedSize(isPlaying: Bool) -> CGSize {
        closedSize(for: closedActivity(isPlaying: isPlaying))
    }

    func closedSize(for activity: ClosedActivity?) -> CGSize {
        switch activity {
        case nil:
            return notchSize
        case .music?:
            return CGSize(width: notchSize.width + notchSize.height * 2, height: notchSize.height)
        case .some:
            return CGSize(width: notchSize.width + Self.activitySideWidth * 2, height: notchSize.height)
        }
    }

    /// When opening on an agent that needs you (or something that just finished), show it.
    func focus(on activity: ClosedActivity?) {
        guard let list = activity?.list, Self.visibleTabs().contains(.dev) else { return }
        UserDefaults.standard.set(list.rawValue, forKey: DevView.sectionKey)
        tab = .dev
    }
}
