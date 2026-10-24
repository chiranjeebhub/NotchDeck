import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [NotchWindowController] = []
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var lastShowOnAllDisplays = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppSettings.migrateFromNotchUtility()
        AppSettings.registerDefaults()
        lastShowOnAllDisplays = AppSettings.showOnAllDisplays

        setUpStatusItem()
        NowPlayingService.shared.start()
        CalendarService.shared.start()
        SystemStatsService.shared.startSampling()
        UpdaterService.shared.start()
        rebuildNotches()

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        center.addObserver(self, selector: #selector(defaultsChanged), name: UserDefaults.didChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(openSettings(_:)), name: .openSettings, object: nil)
    }

    // MARK: - Notch windows

    private func rebuildNotches() {
        controllers.forEach { $0.tearDown() }
        let screens = AppSettings.showOnAllDisplays
            ? NSScreen.screens
            : [NotchGeometry.preferredScreen()].compactMap { $0 }
        controllers = screens.map { NotchWindowController(screen: $0) }
    }

    @objc private func screensChanged() {
        rebuildNotches()
    }

    @objc private func defaultsChanged() {
        let showAll = AppSettings.showOnAllDisplays
        if showAll != lastShowOnAllDisplays {
            lastShowOnAllDisplays = showAll
            rebuildNotches()
        }
        NowPlayingService.shared.updateActivePlayer()
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "menubar.rectangle", accessibilityDescription: "NotchDeck")

        let menu = NSMenu()
        menu.addItem(withTitle: "Open Notch", action: #selector(openNotch), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",").target = self
        if UpdaterService.shared.isAvailable {
            menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit NotchDeck", action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
        statusItem = item
    }

    @objc private func openNotch() {
        let screen = NotchGeometry.preferredScreen()
        (controllers.first { $0.screen == screen } ?? controllers.first)?.showFromMenu()
    }

    /// Opens Settings, on a specific page when the notification carries a `SettingsPage`.
    @objc private func openSettings(_ sender: Any?) {
        if let page = (sender as? Notification)?.object as? SettingsPage {
            SettingsNavigation.shared.page = page
        }
        // The open notch floats above normal windows and would cover the top of Settings.
        controllers.forEach { $0.dismiss() }

        let window = settingsWindow ?? makeSettingsWindow()
        settingsWindow = window
        if window.isMiniaturized { window.deminiaturize(nil) }
        // Show it on the screen the pointer is on, not wherever it was first created.
        if !window.isVisible, let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) {
            let visible = screen.visibleFrame
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2))
        }
        // NotchDeck is a menu bar app, so a plain activate() request can be refused while another
        // app is in front; ask firmly, and order the window front regardless.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func makeSettingsWindow() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
        window.title = "NotchDeck Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        // A toolbar gives the sidebar its full-height, unified look.
        window.toolbar = NSToolbar(identifier: "Settings")
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 760, height: 540))
        window.isReleasedWhenClosed = false
        // Open on the current Space, including over a full-screen app, instead of jumping back
        // to the Space the window was first shown on.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        return window
    }

    @objc private func checkForUpdates() {
        UpdaterService.shared.checkForUpdates()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
