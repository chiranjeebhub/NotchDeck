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

    /// Runs `command` in `directory`: in the same tab when the terminal allows it and that tab is
    /// back at its prompt, otherwise in a new window.
    static func run(_ command: String, in directory: String, terminal: TerminalInfo, shellPID: pid_t) {
        let line = "cd \(shellQuoted(directory)) && \(command)"
        let isITerm = terminal.resolvedBundleID == "com.googlecode.iterm2"
        // Typing into a tab that is busy (an editor, Claude Code, another build) would send the
        // command to that program instead, so check off the main thread first.
        DispatchQueue.global(qos: .userInitiated).async {
            if terminal.supportsTabControl, let tty = terminal.tty, isAtPrompt(shellPID: shellPID, tty: tty) {
                runAppleScript(isITerm ? iTermScript(typing: true) : terminalScript(typing: true), arguments: [tty, line])
            } else if isITerm {
                runAppleScript("""
                on run argv
                    tell application "iTerm2"
                        set newWindow to (create window with default profile)
                        tell current session of newWindow to write text (item 1 of argv)
                        activate
                    end tell
                end run
                """, arguments: [line])
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
    }

    /// True when the shell still runs on `tty` and nothing else has the terminal: its process
    /// group is the terminal's foreground group.
    static func isAtPrompt(shellPID: pid_t, tty: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "pgid=,tpgid=,tty=", "-p", "\(shellPID)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let parts = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count == 3, let pgid = Int32(parts[0]), let foreground = Int32(parts[1]) else { return false }
        // ps shows "ttys003" as "s003".
        return pgid == foreground && (tty == parts[2] || tty.hasSuffix(parts[2]))
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
