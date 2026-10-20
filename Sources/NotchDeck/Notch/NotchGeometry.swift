import AppKit

/// Measures the physical notch (or a stand-in handle on screens without one).
enum NotchGeometry {
    /// Width of the slim handle drawn on screens that have no notch.
    static let handleWidth: CGFloat = 180
    static let handleHeight: CGFloat = 5

    static func hasNotch(_ screen: NSScreen) -> Bool {
        screen.safeAreaInsets.top > 0 && screen.auxiliaryTopLeftArea != nil && screen.auxiliaryTopRightArea != nil
    }

    /// Size of the hardware notch, or of the handle when there is none.
    static func notchSize(for screen: NSScreen) -> CGSize {
        if hasNotch(screen),
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            return CGSize(width: screen.frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
        }
        return CGSize(width: handleWidth, height: handleHeight)
    }

    static func menuBarHeight(for screen: NSScreen) -> CGFloat {
        max(screen.frame.maxY - screen.visibleFrame.maxY, 24)
    }

    /// The built-in notched display if there is one, otherwise the primary display.
    static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first(where: hasNotch) ?? NSScreen.screens.first
    }

    /// A rect of the given size centred horizontally against the top edge of `screen`, in screen coordinates.
    static func topCenteredRect(width: CGFloat, height: CGFloat, on screen: NSScreen) -> CGRect {
        CGRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height)
    }
}
