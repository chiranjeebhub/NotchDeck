import AppKit

/// Brings a terminal tab forward, or types a command into it, for agents and long commands.
/// Terminal and iTerm can target the exact tab by its tty; other apps are just brought forward.
enum TerminalControl {
    static func focus(_ terminal: TerminalInfo) {
        if terminal.supportsTabControl, let tty = terminal.tty {
            runAppleScript(terminal.resolvedBundleID == "com.googlecode.iterm2" ? iTermScript(typing: false)
                                                                                 : terminalScript(typing: false),
                           arguments: [tty])
        } else {
            activate(bundleID: terminal.resolvedBundleID ?? "com.apple.Terminal")
        }
    }

    /// Runs `command` in `directory`: in the same tab when the terminal allows it, otherwise in a new Terminal window.
    static func run(_ command: String, in directory: String, terminal: TerminalInfo) {
        let line = "cd \(shellQuoted(directory)) && \(command)"
        if terminal.supportsTabControl, let tty = terminal.tty {
            runAppleScript(terminal.resolvedBundleID == "com.googlecode.iterm2" ? iTermScript(typing: true)
                                                                                 : terminalScript(typing: true),
                           arguments: [tty, line])
        } else {
            runAppleScript("""
            on run argv
                tell application "Terminal"
                    do script (item 1 of argv)
                    activate
                end tell
            end run
            """, arguments: [line])
        }
    }

    static func activate(bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func terminalScript(typing: Bool) -> String {
        """
        on run argv
            set targetTTY to "/dev/" & (item 1 of argv)
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is targetTTY then
                            set selected of t to true
                            set index of w to 1
                            \(typing ? "do script (item 2 of argv) in t" : "")
                        end if
                    end repeat
                end repeat
                activate
            end tell
        end run
        """
    }

    private static func iTermScript(typing: Bool) -> String {
        """
        on run argv
            set targetTTY to "/dev/" & (item 1 of argv)
            tell application "iTerm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is targetTTY then
                                select w
                                select t
                                select s
                                \(typing ? "tell s to write text (item 2 of argv)" : "")
                            end if
                        end repeat
                    end repeat
                end repeat
                activate
            end tell
        end run
        """
    }

    /// osascript in the background, so a slow or refused Automation prompt never blocks the notch.
    private static func runAppleScript(_ source: String, arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            NSLog("NotchDeck: osascript failed: \(error)")
        }
    }
}

/// Calls `onChange` on the main thread when files are added to or removed from a directory.
final class DirectoryWatcher {
    private var source: DispatchSourceFileSystemObject?

    init(url: URL, onChange: @escaping @MainActor () -> Void) {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { onChange() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    deinit {
        source?.cancel()
    }
}
