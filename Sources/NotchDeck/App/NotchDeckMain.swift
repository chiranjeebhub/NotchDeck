import AppKit

@main
@MainActor
enum NotchDeckMain {
    static let delegate = AppDelegate()

    static func main() {
        // Run by Claude Code as a hook: hand the event to the running app and exit.
        if CommandLine.arguments.dropFirst().first == ClaudeHookCLI.argument {
            exit(ClaudeHookCLI.run())
        }
        // Writing to the Now Playing helper's pipe after it exits must not kill the app.
        signal(SIGPIPE, SIG_IGN)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        app.run()
    }
}
