import AppKit
import Combine
import SwiftUI

/// Owns the notch panel for one screen and decides when it opens and closes.
///
/// The panel is always as large as the open notch but ignores the mouse while closed, so it
/// never blocks the menu bar. Hover and file drags are detected by polling the cursor instead.
@MainActor
final class NotchWindowController {
    let screen: NSScreen
    private let panel: NotchPanel
    let viewModel: NotchViewModel

    private var pendingAction: NotchViewModel.Status?
    private var pendingTask: Task<Void, Never>?
    private var trackingTask: Task<Void, Never>?
    private var wasMouseDown = false
    /// Set by the click monitor, so quick clicks between two polls are not missed.
    private var clickedSinceLastTick = false
    private var clickMonitor: Any?
    private var dragChangeCount = NSPasteboard(name: .drag).changeCount
    private var isDraggingFile = false
    /// Set when opened from the menu, so the notch stays open until the cursor has visited it.
    private var staysOpenUntilHovered = false

    private static let shadowPadding: CGFloat = 24
    /// The cursor's y equals the screen's maxY when pushed against the top edge, and
    /// `CGRect.contains` excludes the max edge, so hit rects extend slightly past it.
    private static let topEdgeSlop: CGFloat = 4
    private static let dragActivationHeight: CGFloat = 160
    private static let closeDelay: Duration = .milliseconds(300)

    init(screen: NSScreen) {
        self.screen = screen
        viewModel = NotchViewModel(screen: screen)

        let ear = viewModel.earRadius(isOpen: true)
        let width = viewModel.maxOpenSize.width + ear * 2 + Self.shadowPadding * 2
        let height = viewModel.maxOpenSize.height + Self.shadowPadding
        panel = NotchPanel(contentRect: NotchGeometry.topCenteredRect(width: width, height: height, on: screen))
        panel.contentView = NotchHostingView(rootView: NotchRootView(viewModel: viewModel))
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()

        startTracking()
    }

    func tearDown() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        pendingTask?.cancel()
        trackingTask?.cancel()
        panel.orderOut(nil)
        panel.close()
    }

    // MARK: - Hit areas

    private var closedHitRect: CGRect {
        let isPlaying = NowPlayingService.shared.nowPlaying?.isPlaying ?? false
        let size = viewModel.closedSize(isPlaying: isPlaying)
        let ear = viewModel.earRadius(isOpen: false)
        let height = viewModel.hasNotch ? size.height : NotchGeometry.menuBarHeight(for: screen)
        return NotchGeometry.topCenteredRect(width: size.width + ear * 2 + 16, height: height + 2, on: screen)
            .insetBy(dx: 0, dy: -Self.topEdgeSlop)
    }

    /// While a file is being dragged, the notch opens as soon as the cursor comes near it, well
    /// below the top edge. Reaching the edge itself makes macOS open Mission Control instead.
    private var dragActivationRect: CGRect {
        let ear = viewModel.earRadius(isOpen: true)
        return NotchGeometry
            .topCenteredRect(width: viewModel.openSize.width + ear * 2, height: Self.dragActivationHeight, on: screen)
            .insetBy(dx: 0, dy: -Self.topEdgeSlop)
    }

    private var openHitRect: CGRect {
        let ear = viewModel.earRadius(isOpen: true)
        return NotchGeometry
            .topCenteredRect(width: viewModel.openSize.width + ear * 2, height: viewModel.openSize.height, on: screen)
            .insetBy(dx: -12, dy: -12)
    }

    // MARK: - Mouse tracking

    /// Polls the cursor and mouse button instead of relying on event monitors: global
    /// mouse-moved events are not delivered reliably (for example while the cursor rests
    /// against the top edge, or during drags from other apps).
    private func startTracking() {
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            MainActor.assumeIsolated { self?.clickedSinceLastTick = true }
        }
        trackingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.tick()
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func tick() {
        let isMouseDown = NSEvent.pressedMouseButtons & 1 != 0
        let clicked = clickedSinceLastTick || (isMouseDown && !wasMouseDown)
        clickedSinceLastTick = false
        let pasteboard = NSPasteboard(name: .drag)
        if isMouseDown && !wasMouseDown {
            dragChangeCount = pasteboard.changeCount
        }
        if !isMouseDown {
            isDraggingFile = false
        } else if !isDraggingFile,
                  pasteboard.changeCount != dragChangeCount,
                  pasteboard.types?.contains(.fileURL) == true {
            isDraggingFile = true
        }
        wasMouseDown = isMouseDown
        evaluate(NSEvent.mouseLocation, clicked: clicked)
    }

    private func evaluate(_ location: NSPoint, clicked: Bool) {
        switch viewModel.status {
        case .closed:
            if isDraggingFile && dragActivationRect.contains(location) {
                schedule(.open, after: .zero)
            } else if closedHitRect.contains(location) {
                if AppSettings.openOnClick {
                    if clicked { schedule(.open, after: .zero) }
                } else {
                    schedule(.open, after: .milliseconds(Int(AppSettings.hoverDelay * 1000)))
                }
            } else if pendingAction == .open {
                cancelPending()
            }
        case .open:
            if openHitRect.contains(location) || viewModel.isDropTargeted {
                staysOpenUntilHovered = false
                if pendingAction == .closed { cancelPending() }
            } else if !staysOpenUntilHovered {
                schedule(.closed, after: Self.closeDelay)
            }
        }
    }

    private func schedule(_ action: NotchViewModel.Status, after delay: Duration) {
        guard pendingAction != action else { return }
        cancelPending()
        pendingAction = action
        pendingTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            self.pendingAction = nil
            if action == .open { self.open() } else { self.close() }
        }
    }

    private func cancelPending() {
        pendingTask?.cancel()
        pendingTask = nil
        pendingAction = nil
    }

    // MARK: - Open / close

    /// Opens the notch from the menu bar item. It stays open until the cursor has visited it and left.
    func showFromMenu() {
        cancelPending()
        open()
        staysOpenUntilHovered = true
    }

    private func open() {
        guard viewModel.status == .closed else { return }
        if isDraggingFile { viewModel.tab = .tray }
        viewModel.status = .open
        panel.ignoresMouseEvents = false
        if AppSettings.hapticFeedback {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        NowPlayingService.shared.refreshAll()
        CalendarService.shared.reload()
    }

    /// Closes the notch right away, e.g. when Settings opens.
    func dismiss() {
        cancelPending()
        close()
    }

    private func close() {
        guard viewModel.status == .open else { return }
        staysOpenUntilHovered = false
        viewModel.status = .closed
        viewModel.isDropTargeted = false
        panel.ignoresMouseEvents = true
        // After typing in a widget (Notes), hand the keyboard back to the app underneath, so
        // keystrokes don't keep going to the hidden text view. Ordering the panel out and back
        // in gives up key status without activating anything.
        if panel.isKeyWindow, panel.firstResponder is NSTextView {
            panel.makeFirstResponder(nil)
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
    }
}
