import AppKit
import Combine
import SwiftUI

/// Owns the notch panel for one screen and decides when it opens and closes.
///
/// The panel is always as large as the open notch but ignores the mouse while closed, so it
/// never blocks the menu bar. Hover and file drags are detected with event monitors instead.
@MainActor
final class NotchWindowController {
    private let screen: NSScreen
    private let panel: NotchPanel
    let viewModel: NotchViewModel

    private var monitors: [Any] = []
    private var pendingAction: NotchViewModel.Status?
    private var pendingTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var dragChangeCount = NSPasteboard(name: .drag).changeCount
    private var isDraggingFile = false

    private static let shadowPadding: CGFloat = 24
    private static let hoverOpenDelay: Duration = .milliseconds(120)
    private static let closeDelay: Duration = .milliseconds(300)

    init(screen: NSScreen) {
        self.screen = screen
        viewModel = NotchViewModel(screen: screen)

        let ear = viewModel.earRadius(isOpen: true)
        let width = viewModel.openSize.width + ear * 2 + Self.shadowPadding * 2
        let height = viewModel.openSize.height + Self.shadowPadding
        panel = NotchPanel(contentRect: NotchGeometry.topCenteredRect(width: width, height: height, on: screen))
        panel.contentView = NotchHostingView(rootView: NotchRootView(viewModel: viewModel))
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()

        installMonitors()
    }

    func tearDown() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        pendingTask?.cancel()
        pollTask?.cancel()
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
    }

    private var openHitRect: CGRect {
        let ear = viewModel.earRadius(isOpen: true)
        return NotchGeometry
            .topCenteredRect(width: viewModel.openSize.width + ear * 2, height: viewModel.openSize.height, on: screen)
            .insetBy(dx: -12, dy: -12)
    }

    // MARK: - Mouse tracking

    private func installMonitors() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let type = event.type
            MainActor.assumeIsolated { self?.handle(type) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let type = event.type
            MainActor.assumeIsolated { self?.handle(type) }
            return event
        }) {
            monitors.append(local)
        }
    }

    private func handle(_ type: NSEvent.EventType) {
        switch type {
        case .leftMouseDown:
            dragChangeCount = NSPasteboard(name: .drag).changeCount
            isDraggingFile = false
        case .leftMouseDragged:
            if !isDraggingFile {
                let pasteboard = NSPasteboard(name: .drag)
                if pasteboard.changeCount != dragChangeCount,
                   pasteboard.types?.contains(.fileURL) == true {
                    isDraggingFile = true
                }
            }
        case .leftMouseUp:
            isDraggingFile = false
        default:
            break
        }
        evaluate(NSEvent.mouseLocation)
    }

    private func evaluate(_ location: NSPoint) {
        switch viewModel.status {
        case .closed:
            if closedHitRect.contains(location) {
                schedule(.open, after: isDraggingFile ? .zero : Self.hoverOpenDelay)
            } else if pendingAction == .open {
                cancelPending()
            }
        case .open:
            if openHitRect.contains(location) || viewModel.isDropTargeted {
                if pendingAction == .closed { cancelPending() }
            } else {
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

        // Mouse-moved events stop arriving in some states (e.g. over our own non-key panel),
        // so poll the cursor while open to make sure we close reliably.
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                guard let self, self.viewModel.status == .open else { return }
                self.evaluate(NSEvent.mouseLocation)
            }
        }
    }

    private func close() {
        guard viewModel.status == .open else { return }
        pollTask?.cancel()
        viewModel.status = .closed
        viewModel.isDropTargeted = false
        panel.ignoresMouseEvents = true
    }
}
