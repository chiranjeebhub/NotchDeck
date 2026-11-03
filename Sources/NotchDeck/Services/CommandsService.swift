import AppKit
import Foundation

/// A command typed in a terminal, reported by NotchDeck's shell integration.
struct ShellCommand: Identifiable, Equatable {
    let id: String
    let shellPID: pid_t
    let directory: String
    let command: String
    let terminal: TerminalInfo
    let startedAt: Date
    var endedAt: Date?
    var exitStatus: Int32?

    var duration: TimeInterval? { endedAt.map { $0.timeIntervalSince(startedAt) } }
    var succeeded: Bool { exitStatus == 0 }

    /// The first line, without leading environment assignments being treated specially.
    var title: String { AgentText.firstLine(command) }

    var shortDirectory: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return directory.hasPrefix(home) ? "~" + directory.dropFirst(home.count) : directory
    }

    /// The program name, skipping `sudo`, `time` and `VAR=value` prefixes.
    var program: String {
        let words = command.split(whereSeparator: \.isWhitespace).map(String.init)
        return words.first { !$0.contains("=") && !["sudo", "time", "command", "exec", "nohup"].contains($0) } ?? ""
    }
}

/// Long-running shell commands: what's running now and how recent ones finished.
@MainActor
final class CommandsService: ObservableObject {
    static let shared = CommandsService()

    /// Commands running for a few seconds or more, newest first.
    @Published private(set) var running: [ShellCommand] = []
    /// Long commands that finished, newest first.
    @Published private(set) var recent: [ShellCommand] = []
    @Published private(set) var flash: NotchFlash?
    @Published private(set) var hasReceivedCommands = false

    private var active: [String: ShellCommand] = [:]
    /// How long each command took last time, for the progress bar.
    private var lastDurations: [String: TimeInterval] = [:]
    private var watcher: DirectoryWatcher?
    private var timer: Timer?
    private var flashTask: Task<Void, Never>?

    /// A command shows up as running once it has run this long.
    static let runningThreshold: TimeInterval = 3
    private static let recentLimit = 8

    /// Full-screen and interactive programs aren't "long commands".
    private static let interactivePrograms: Set<String> = [
        "vim", "nvim", "vi", "nano", "emacs", "micro", "hx", "less", "more", "man", "top", "htop", "btop", "btm",
        "ssh", "mosh", "tmux", "screen", "zellij", "claude", "codex", "aider", "gemini", "cursor-agent",
        "lazygit", "tig", "fzf", "ranger", "yazi", "k9s", "watch", "tail", "ncdu", "fg", "bg", "exit", "clear",
    ]
    /// REPLs and shells count only when they run something (`python train.py`), not on their own.
    private static let replPrograms: Set<String> = [
        "node", "python", "python3", "bun", "deno", "irb", "pry", "ipython", "bpython", "psql", "mysql",
        "sqlite3", "redis-cli", "mongosh", "zsh", "bash", "fish", "sh",
    ]

    static func isInteractive(_ command: ShellCommand) -> Bool {
        let program = command.program
        if interactivePrograms.contains(program) { return true }
        return replPrograms.contains(program) && command.command.trimmingCharacters(in: .whitespaces) == program
    }

    func start() {
        HookPaths.createDirectories()
        HookPaths.removeStaleFiles(in: HookPaths.commands, olderThan: 60)
        watcher = DirectoryWatcher(url: HookPaths.commands) { [weak self] in self?.drain() }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        drain()
    }

    func lastDuration(of command: ShellCommand) -> TimeInterval? {
        lastDurations[command.command]
    }

    func rerun(_ command: ShellCommand) {
        TerminalControl.run(command.command, in: command.directory, terminal: command.terminal)
    }

    func focus(_ command: ShellCommand) {
        TerminalControl.focus(command.terminal)
    }

    func clearRecent() {
        recent = []
    }

    /// Dev servers and watchers run until you stop them, so the closed notch leaves them out.
    static func isOpenEnded(_ command: ShellCommand) -> Bool {
        let text = " " + command.command.lowercased() + " "
        let patterns = [" dev ", " dev:", " serve", " start ", " watch", "--watch", " runserver", " preview ",
                        " up ", "tail -f", "log stream", " storybook", " expo start", " ngrok", " http-server",
                        " live-server", " jupyter", " -w "]
        if patterns.contains(where: text.contains) { return true }
        return text.contains(" compose up ") && !text.contains(" -d")
    }

    // MARK: - Events

    private func tick() {
        drain()
        // Drop commands whose shell went away (the terminal tab was closed mid-command).
        let gone = active.values.filter { kill($0.shellPID, 0) != 0 && errno == ESRCH }
        for command in gone { active[command.id] = nil }
        publishRunning()
    }

    private func drain() {
        let files = HookPaths.files(in: HookPaths.commands, extensions: ["start", "end"])
        guard !files.isEmpty else { return }
        // Starts before ends, so a command that finished between two reads still pairs up.
        let ordered = files.sorted { a, b in
            a.url.pathExtension != b.url.pathExtension ? a.url.pathExtension == "start" : a.date < b.date
        }
        for file in ordered {
            let lines = ((try? String(contentsOf: file.url, encoding: .utf8)) ?? "").components(separatedBy: "\n")
            try? FileManager.default.removeItem(at: file.url)
            let id = file.url.deletingPathExtension().lastPathComponent
            if file.url.pathExtension == "start" {
                started(id: id, lines: lines, at: file.date)
            } else {
                ended(id: id, lines: lines, at: file.date)
            }
        }
        hasReceivedCommands = true
        publishRunning()
    }

    private func started(id: String, lines: [String], at date: Date) {
        guard lines.count >= 7, lines[0] == "start", let pid = pid_t(lines[1]) else { return }
        let command = lines[6...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let terminal = TerminalInfo(tty: TerminalInfo.normalizedTTY(lines[3]),
                                    bundleID: lines[5].isEmpty ? nil : lines[5],
                                    termProgram: lines[4].isEmpty ? nil : lines[4])
        let shellCommand = ShellCommand(id: id, shellPID: pid, directory: lines[2], command: command,
                                        terminal: terminal, startedAt: date)
        guard !command.isEmpty, !Self.isInteractive(shellCommand) else { return }
        // A shell runs one command at a time; a new one means the previous one is over.
        for other in active.values where other.shellPID == pid { active[other.id] = nil }
        active[id] = shellCommand
    }

    private func ended(id: String, lines: [String], at date: Date) {
        guard var command = active.removeValue(forKey: id) else { return }
        command.endedAt = date
        command.exitStatus = lines.count > 1 ? Int32(lines[1].trimmingCharacters(in: .whitespaces)) : nil
        guard let duration = command.duration, duration >= AppSettings.commandsMinimumSeconds else { return }

        lastDurations[command.command] = duration
        if lastDurations.count > 100 { lastDurations.removeAll() }
        recent.insert(command, at: 0)
        if recent.count > Self.recentLimit { recent.removeLast(recent.count - Self.recentLimit) }

        showFlash(NotchFlash(source: .command, title: command.program.isEmpty ? command.title : command.program,
                             succeeded: command.succeeded,
                             detail: command.succeeded ? DurationFormat.short(duration) : "exit \(command.exitStatus ?? 1)",
                             list: .commands))
        if AppSettings.commandsPlaySound {
            NSSound(named: command.succeeded ? "Glass" : "Basso")?.play()
        }
    }

    private func publishRunning() {
        let now = Date.now
        let visible = active.values
            .filter { now.timeIntervalSince($0.startedAt) >= Self.runningThreshold }
            .sorted { $0.startedAt > $1.startedAt }
        if visible != running { running = visible }
    }

    private func showFlash(_ flash: NotchFlash) {
        self.flash = flash
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.flash = nil
        }
    }
}
