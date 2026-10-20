import AppKit

@main
@MainActor
enum NotchDeckMain {
    static let delegate = AppDelegate()

    static func main() {
        // Writing to the Now Playing helper's pipe after it exits must not kill the app.
        signal(SIGPIPE, SIG_IGN)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        app.run()
    }
}
