import Foundation

/// Files that Claude Code hooks and the shell integration use to talk to the running app.
///
/// Everything goes through small files under Application Support, so the hooks never need a
/// network port and do nothing at all while NotchDeck isn't running:
/// - `AgentEvents/<id>.json`: one Claude Code hook event, written by `NotchDeck --claude-hook`.
/// - `AgentReplies/<id>.json`: the answer to a permission request, written by the app.
/// - `Commands/<id>.start` and `<id>.end`: a shell command starting and finishing.
/// - `notchdeck.pid`: present while the app runs.
enum HookPaths {
    static var support: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NotchDeck", isDirectory: true)
    }

    static var agentEvents: URL { support.appendingPathComponent("AgentEvents", isDirectory: true) }
    static var agentReplies: URL { support.appendingPathComponent("AgentReplies", isDirectory: true) }
    static var commands: URL { support.appendingPathComponent("Commands", isDirectory: true) }
    static var shell: URL { support.appendingPathComponent("Shell", isDirectory: true) }
    static var pidFile: URL { support.appendingPathComponent("notchdeck.pid") }

    static func createDirectories() {
        for directory in [agentEvents, agentReplies, commands, shell] {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    /// Writes `data` under a temporary name first, so a reader never sees half a file.
    static func writeAtomically(_ data: Data, to url: URL) {
        let temporary = url.deletingPathExtension().appendingPathExtension("tmp")
        do {
            try data.write(to: temporary)
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: temporary, to: url)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
        }
    }

    /// Files in `directory` with one of `extensions`, oldest first.
    static func files(in directory: URL, extensions: Set<String>) -> [(url: URL, date: Date)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        return urls
            .filter { extensions.contains($0.pathExtension) }
            .map { url in
                let date = (try? url.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .now
                return (url: url, date: date)
            }
            .sorted { $0.date < $1.date }
    }

    /// Removes files left behind while the app wasn't running.
    static func removeStaleFiles(in directory: URL, olderThan age: TimeInterval) {
        let cutoff = Date.now.addingTimeInterval(-age)
        for file in files(in: directory, extensions: ["json", "start", "end", "tmp"]) where file.date < cutoff {
            try? FileManager.default.removeItem(at: file.url)
        }
    }

    // MARK: - Running app

    static func writePID() {
        createDirectories()
        try? Data("\(ProcessInfo.processInfo.processIdentifier)".utf8).write(to: pidFile)
    }

    static func removePID() {
        try? FileManager.default.removeItem(at: pidFile)
    }

    /// The pid of the running app, if it is running.
    static func runningAppPID() -> pid_t? {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0, pid != getpid(), kill(pid, 0) == 0 else { return nil }
        return pid
    }
}

/// Where a command or agent session is running, so the notch can bring that window forward.
struct TerminalInfo: Equatable {
    /// "ttys003", without "/dev/".
    var tty: String?
    /// The bundle identifier of the app hosting the terminal (Terminal, iTerm, Warp, VS Code…).
    var bundleID: String?
    var termProgram: String?

    static func normalizedTTY(_ text: String?) -> String? {
        guard var text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              text != "??", text != "not a tty" else { return nil }
        if text.hasPrefix("/dev/") { text.removeFirst(5) }
        return text
    }

    var appName: String {
        switch bundleID {
        case "com.apple.Terminal": return "Terminal"
        case "com.googlecode.iterm2": return "iTerm"
        case "dev.warp.Warp-Stable", "dev.warp.Warp": return "Warp"
        case "com.mitchellh.ghostty": return "Ghostty"
        case "com.microsoft.VSCode": return "VS Code"
        case "com.todesktop.230313mzl4w4u92": return "Cursor"
        case "dev.zed.Zed": return "Zed"
        default: break
        }
        switch termProgram {
        case "Apple_Terminal": return "Terminal"
        case "iTerm.app": return "iTerm"
        case "WarpTerminal": return "Warp"
        case "ghostty": return "Ghostty"
        case "vscode": return "VS Code"
        case let program?: return program
        case nil: return "Terminal"
        }
    }

    /// Terminal and iTerm can select the exact tab by its tty and type into it.
    var supportsTabControl: Bool {
        tty != nil && (resolvedBundleID == "com.apple.Terminal" || resolvedBundleID == "com.googlecode.iterm2")
    }

    var resolvedBundleID: String? {
        if let bundleID { return bundleID }
        switch termProgram {
        case "Apple_Terminal": return "com.apple.Terminal"
        case "iTerm.app": return "com.googlecode.iterm2"
        case "WarpTerminal": return "dev.warp.Warp-Stable"
        case "ghostty": return "com.mitchellh.ghostty"
        case "vscode": return "com.microsoft.VSCode"
        default: return nil
        }
    }
}

// MARK: - Claude Code hook (command-line side)

/// `NotchDeck --claude-hook`, run by Claude Code for each hook event. It hands the event to
/// the running app, and for a permission request waits for an answer from the notch.
/// It never blocks Claude Code for long, and does nothing when the app isn't running.
enum ClaudeHookCLI {
    static let argument = "--claude-hook"

    static func run() -> Int32 {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard HookPaths.runningAppPID() != nil,
              let object = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any],
              let event = object["hook_event_name"] as? String else { return 0 }

        // This runs from inside NotchDeck.app, so the standard defaults are the app's settings.
        let defaults = UserDefaults.standard
        let approves = defaults.object(forKey: AppSettings.agentsApproveInNotchKey) as? Bool ?? true
        let wait = max(5, defaults.object(forKey: AppSettings.agentsApprovalWaitKey) as? Double ?? 30)
        let wantsReply = event == "PermissionRequest" && approves

        let id = UUID().uuidString
        let environment = ProcessInfo.processInfo.environment
        var message: [String: Any] = [
            "id": id,
            "agent": "claude",
            "event": event,
            "time": Date.now.timeIntervalSince1970,
            "wantsReply": wantsReply,
            "input": object,
        ]
        message["termProgram"] = environment["TERM_PROGRAM"]
        message["bundleID"] = environment["__CFBundleIdentifier"]
        // Tool events are frequent; the tty only needs looking up when a session starts or needs you.
        if !["PreToolUse", "PostToolUse"].contains(event) {
            message["tty"] = parentTTY()
        }
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return 0 }
        HookPaths.createDirectories()
        HookPaths.writeAtomically(data, to: HookPaths.agentEvents.appendingPathComponent("\(id).json"))

        guard wantsReply else { return 0 }
        let reply = waitForReply(id: id, timeout: wait)
        switch reply {
        case .some(let behavior) where behavior == "allow" || behavior == "deny":
            var decision: [String: Any] = ["behavior": behavior]
            if behavior == "deny" { decision["message"] = "Denied from NotchDeck." }
            let output: [String: Any] = [
                "hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision],
            ]
            if let json = try? JSONSerialization.data(withJSONObject: output) {
                FileHandle.standardOutput.write(json)
            }
        default:
            // No answer (or "Answer in Terminal"): say nothing, and Claude Code asks in the terminal.
            if reply == nil {
                let released: [String: Any] = ["id": UUID().uuidString, "agent": "claude", "event": "NotchDeckReleased",
                                               "time": Date.now.timeIntervalSince1970, "requestID": id,
                                               "input": ["session_id": object["session_id"] ?? ""]]
                if let data = try? JSONSerialization.data(withJSONObject: released) {
                    HookPaths.writeAtomically(data, to: HookPaths.agentEvents.appendingPathComponent("\(UUID().uuidString).json"))
                }
            }
        }
        return 0
    }

    /// "allow", "deny" or "ask", or nil when nobody answered in time.
    private static func waitForReply(id: String, timeout: Double) -> String? {
        let url = HookPaths.agentReplies.appendingPathComponent("\(id).json")
        let deadline = Date.now.addingTimeInterval(timeout)
        var checks = 0
        while Date.now < deadline {
            if let data = try? Data(contentsOf: url) {
                try? FileManager.default.removeItem(at: url)
                let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                return object?["decision"] as? String ?? "ask"
            }
            checks += 1
            // Stop waiting if the app quits.
            if checks % 20 == 0, HookPaths.runningAppPID() == nil { return "ask" }
            Thread.sleep(forTimeInterval: 0.15)
        }
        return nil
    }

    /// The terminal of the Claude Code process (hooks run through a shell, so look up the tree).
    private static func parentTTY() -> String? {
        var pid = getppid()
        for _ in 0..<3 where pid > 1 {
            let output = run("/bin/ps", ["-o", "tty=,ppid=", "-p", "\(pid)"])
            let parts = output.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count == 2 else { return nil }
            if let tty = TerminalInfo.normalizedTTY(parts[0]) { return tty }
            pid = pid_t(parts[1]) ?? 0
        }
        return nil
    }

    private static func run(_ path: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Claude Code hook (settings side)

/// Adds and removes NotchDeck's entries in ~/.claude/settings.json, leaving everything else alone.
enum ClaudeHookInstaller {
    static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                         "PermissionRequest", "Notification", "Stop", "SessionEnd"]

    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    static var isClaudeInstalled: Bool {
        FileManager.default.fileExists(atPath: settingsURL.deletingLastPathComponent().path)
    }

    static var command: String {
        let path = Bundle.main.executablePath ?? "/Applications/NotchDeck.app/Contents/MacOS/NotchDeck"
        return "\"\(path)\" \(ClaudeHookCLI.argument)"
    }

    private static func readSettings() -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsURL) else { return [:] }
        if data.isEmpty { return [:] }
        // nil means the file exists but isn't JSON we understand: leave it untouched.
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func isOurs(_ handler: Any) -> Bool {
        ((handler as? [String: Any])?["command"] as? String)?.contains(ClaudeHookCLI.argument) == true
    }

    /// The commands NotchDeck has registered, if any.
    static func installedCommands() -> Set<String> {
        guard let hooks = readSettings()?["hooks"] as? [String: Any] else { return [] }
        var commands = Set<String>()
        for case let groups as [[String: Any]] in hooks.values {
            for group in groups {
                for case let handler as [String: Any] in group["hooks"] as? [Any] ?? [] where isOurs(handler) {
                    if let command = handler["command"] as? String { commands.insert(command) }
                }
            }
        }
        return commands
    }

    static var isInstalled: Bool { !installedCommands().isEmpty }
    /// Installed, but pointing at a copy of the app that isn't this one (it was moved or reinstalled).
    static var needsUpdate: Bool {
        let commands = installedCommands()
        return !commands.isEmpty && commands != [command]
    }

    @discardableResult
    static func install() -> Bool {
        update(adding: true)
    }

    @discardableResult
    static func uninstall() -> Bool {
        update(adding: false)
    }

    private static func update(adding: Bool) -> Bool {
        guard var settings = readSettings() else { return false }
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        // Drop our old entries first, so installing twice or from a moved app never duplicates them.
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let cleaned: [[String: Any]] = groups.compactMap { group in
                guard let handlers = group["hooks"] as? [Any] else { return group }
                let kept = handlers.filter { !isOurs($0) }
                if kept.isEmpty { return nil }
                var group = group
                group["hooks"] = kept
                return group
            }
            if cleaned.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = cleaned }
        }

        if adding {
            for event in events {
                var handler: [String: Any] = ["type": "command", "command": command]
                if event == "PermissionRequest" {
                    // Waits for your answer in the notch; Claude Code's own limit is far longer.
                    handler["timeout"] = 300
                } else {
                    // Status updates never hold Claude Code up.
                    handler["async"] = true
                }
                var groups = hooks[event] as? [[String: Any]] ?? []
                groups.append(["hooks": [handler]])
                hooks[event] = groups
            }
        }
        if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = hooks }

        guard let data = try? JSONSerialization.data(withJSONObject: settings,
                                                     options: [.prettyPrinted, .withoutEscapingSlashes]) else { return false }
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Keep a copy of the file as it was before NotchDeck first changed it.
        let backup = settingsURL.appendingPathExtension("notchdeck-backup")
        if fileManager.fileExists(atPath: settingsURL.path), !fileManager.fileExists(atPath: backup.path) {
            try? fileManager.copyItem(at: settingsURL, to: backup)
        }
        do {
            try data.write(to: settingsURL, options: .atomic)
            return true
        } catch {
            NSLog("NotchDeck: couldn't update Claude Code settings: \(error)")
            return false
        }
    }
}

// MARK: - Shell integration

/// The zsh, bash and fish snippets that report commands to the notch, and the line that loads them.
enum ShellIntegration: String, CaseIterable, Identifiable {
    case zsh, bash, fish

    var id: String { rawValue }

    var scriptURL: URL { HookPaths.shell.appendingPathComponent("notchdeck.\(rawValue)") }

    /// The file the loader line goes into.
    var rcURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .zsh: return home.appendingPathComponent(".zshrc")
        case .bash: return home.appendingPathComponent(".bash_profile")
        case .fish: return home.appendingPathComponent(".config/fish/conf.d/notchdeck.fish")
        }
    }

    var rcDisplayPath: String {
        switch self {
        case .zsh: "~/.zshrc"
        case .bash: "~/.bash_profile"
        case .fish: "~/.config/fish/conf.d/notchdeck.fish"
        }
    }

    private static let marker = "NotchDeck/Shell/notchdeck."

    var loaderLine: String {
        let path = "$HOME/Library/Application Support/NotchDeck/Shell/notchdeck.\(rawValue)"
        switch self {
        case .zsh, .bash: return "[ -f \"\(path)\" ] && source \"\(path)\""
        case .fish: return "test -f \"\(path)\"; and source \"\(path)\""
        }
    }

    var isAvailable: Bool {
        switch self {
        case .zsh, .bash: true
        case .fish: ["/opt/homebrew/bin/fish", "/usr/local/bin/fish"].contains { FileManager.default.fileExists(atPath: $0) }
        }
    }

    var isInstalled: Bool {
        (try? String(contentsOf: rcURL, encoding: .utf8))?.contains(Self.marker) == true
    }

    @discardableResult
    func install() -> Bool {
        guard !isInstalled else { return true }
        let block = "\n# NotchDeck: show long-running commands in the notch\n\(loaderLine)\n"
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: rcURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: rcURL.path) {
                let handle = try FileHandle(forWritingTo: rcURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(block.utf8))
            } else {
                try Data(block.utf8).write(to: rcURL)
            }
            return true
        } catch {
            NSLog("NotchDeck: couldn't update \(rcDisplayPath): \(error)")
            return false
        }
    }

    @discardableResult
    func uninstall() -> Bool {
        guard let text = try? String(contentsOf: rcURL, encoding: .utf8) else { return false }
        if self == .fish {
            return (try? FileManager.default.removeItem(at: rcURL)) != nil
        }
        let lines = text.components(separatedBy: "\n")
        var kept: [String] = []
        for line in lines {
            if line.contains(Self.marker) {
                if kept.last == "# NotchDeck: show long-running commands in the notch" { kept.removeLast() }
                if kept.last == "" { kept.removeLast() }
                continue
            }
            kept.append(line)
        }
        do {
            try kept.joined(separator: "\n").write(to: rcURL, atomically: false, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    /// Writes the current scripts, so updates to NotchDeck update the shell side too.
    static func writeScripts() {
        HookPaths.createDirectories()
        for shell in allCases {
            try? Data(shell.script.utf8).write(to: shell.scriptURL)
        }
    }

    // Each command writes two tiny files with shell builtins only (no extra processes):
    //   <id>.start: start, shell pid, directory, tty, TERM_PROGRAM, terminal bundle id, command
    //   <id>.end:   end, exit status
    // The app uses the files' modification times as the start and end times.
    private var script: String {
        switch self {
        case .zsh:
            return #"""
            # NotchDeck shell integration for zsh. Written by NotchDeck; changes are overwritten.
            if [[ -o interactive && -z "$__notchdeck_loaded" ]]; then
              typeset -g __notchdeck_loaded=1
              typeset -g __notchdeck_dir="$HOME/Library/Application Support/NotchDeck/Commands"
              typeset -g __notchdeck_pid="$HOME/Library/Application Support/NotchDeck/notchdeck.pid"
              typeset -g __notchdeck_id=""
              typeset -gi __notchdeck_count=0

              __notchdeck_preexec() {
                [[ -e "$__notchdeck_pid" ]] || return 0
                (( __notchdeck_count++ ))
                __notchdeck_id="$$-$__notchdeck_count-$RANDOM"
                print -rl -- start "$$" "$PWD" "$TTY" "$TERM_PROGRAM" "$__CFBundleIdentifier" "$1" \
                  >| "$__notchdeck_dir/$__notchdeck_id.start" 2>/dev/null
              }

              __notchdeck_precmd() {
                local code=$?
                if [[ -n "$__notchdeck_id" ]]; then
                  print -rl -- end "$code" >| "$__notchdeck_dir/$__notchdeck_id.end" 2>/dev/null
                  __notchdeck_id=""
                fi
                return $code
              }

              autoload -Uz add-zsh-hook
              add-zsh-hook preexec __notchdeck_preexec
              # First in line, so it sees the command's exit status before other prompt hooks run.
              precmd_functions=(__notchdeck_precmd ${precmd_functions:#__notchdeck_precmd})
            fi
            """#
        case .bash:
            return #"""
            # NotchDeck shell integration for bash. Written by NotchDeck; changes are overwritten.
            if [[ $- == *i* && -z "$__notchdeck_loaded" ]] && [[ -z "$(trap -p DEBUG)" ]]; then
              __notchdeck_loaded=1
              __notchdeck_dir="$HOME/Library/Application Support/NotchDeck/Commands"
              __notchdeck_pid="$HOME/Library/Application Support/NotchDeck/notchdeck.pid"
              __notchdeck_tty="$(tty 2>/dev/null)"
              __notchdeck_id=""
              __notchdeck_ready=""
              __notchdeck_count=0

              __notchdeck_preexec() {
                [[ -n "$__notchdeck_ready" && -z "$COMP_LINE" ]] || return 0
                __notchdeck_ready=""
                [[ -e "$__notchdeck_pid" ]] || return 0
                __notchdeck_count=$((__notchdeck_count + 1))
                __notchdeck_id="$$-$__notchdeck_count-$RANDOM"
                printf 'start\n%s\n%s\n%s\n%s\n%s\n%s\n' "$$" "$PWD" "$__notchdeck_tty" "$TERM_PROGRAM" \
                  "$__CFBundleIdentifier" "$BASH_COMMAND" > "$__notchdeck_dir/$__notchdeck_id.start" 2>/dev/null
              }

              __notchdeck_precmd() {
                local code=$?
                if [[ -n "$__notchdeck_id" ]]; then
                  printf 'end\n%s\n' "$code" > "$__notchdeck_dir/$__notchdeck_id.end" 2>/dev/null
                  __notchdeck_id=""
                fi
                return $code
              }

              trap '__notchdeck_preexec' DEBUG
              PROMPT_COMMAND="__notchdeck_precmd${PROMPT_COMMAND:+; $PROMPT_COMMAND}; __notchdeck_ready=1"
            fi
            """#
        case .fish:
            return #"""
            # NotchDeck shell integration for fish. Written by NotchDeck; changes are overwritten.
            if status is-interactive; and not set -q __notchdeck_loaded
                set -g __notchdeck_loaded 1
                set -g __notchdeck_dir "$HOME/Library/Application Support/NotchDeck/Commands"
                set -g __notchdeck_pid "$HOME/Library/Application Support/NotchDeck/notchdeck.pid"
                set -g __notchdeck_tty (tty 2>/dev/null)
                set -g __notchdeck_id ""
                set -g __notchdeck_count 0

                function __notchdeck_preexec --on-event fish_preexec
                    test -e "$__notchdeck_pid"; or return 0
                    set -g __notchdeck_count (math $__notchdeck_count + 1)
                    set -g __notchdeck_id "$fish_pid-$__notchdeck_count-"(random)
                    printf 'start\n%s\n%s\n%s\n%s\n%s\n%s\n' "$fish_pid" "$PWD" "$__notchdeck_tty" "$TERM_PROGRAM" \
                        "$__CFBundleIdentifier" "$argv" > "$__notchdeck_dir/$__notchdeck_id.start" 2>/dev/null
                end

                function __notchdeck_postexec --on-event fish_postexec
                    set -l code $status
                    if test -n "$__notchdeck_id"
                        printf 'end\n%s\n' "$code" > "$__notchdeck_dir/$__notchdeck_id.end" 2>/dev/null
                        set -g __notchdeck_id ""
                    end
                end
            end
            """#
        }
    }
}
