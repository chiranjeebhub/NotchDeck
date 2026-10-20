import AppKit
import SwiftUI

/// Per-screen state of the notch: open/closed, selected tab and geometry.
@MainActor
final class NotchViewModel: ObservableObject {
    enum Status { case closed, open }

    enum Tab: String, CaseIterable {
        case nook, tray

        var title: String { self == .nook ? "Nook" : "Tray" }
        var systemImage: String { self == .nook ? "rectangle.3.group" : "tray" }
    }

    @Published var status: Status = .closed
    @Published var tab: Tab = .nook
    @Published var isDropTargeted = false

    let hasNotch: Bool
    /// Physical notch size, or the handle size on screens without a notch.
    let notchSize: CGSize
    /// Size of the expanded content area (without the concave "ears").
    let openSize = CGSize(width: 640, height: 230)

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
        hasNotch && isPlaying
    }

    func closedSize(isPlaying: Bool) -> CGSize {
        guard showsLiveActivity(isPlaying: isPlaying) else { return notchSize }
        return CGSize(width: notchSize.width + notchSize.height * 2, height: notchSize.height)
    }
}
