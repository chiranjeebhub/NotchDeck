import AppKit
import Foundation

enum AgentKind: String, Equatable {
    case claude, codex

    var name: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }
}

/// A permission prompt from Claude Code that can be answered from the notch.
struct PermissionRequest: Equatable {
    let id: String
    /// "Wants to run a command".
    let summary: String
    /// The command, file or URL it is about.
    let detail: String?
    /// False once the request has gone back to the terminal (nobody answered in time).
    var canAnswer: Bool
}

/// One Claude Code or Codex session and what it's doing now.
struct AgentSession: Identifiable, Equatable {
    enum Status: Int, Comparable {
        // Sort order in the list: what needs you first.
        case waiting, working, ready, done

        static func < (a: Status, b: Status) -> Bool { a.rawValue < b.rawValue }
    }

    let id: String
    let kind: AgentKind
    var directory: String
    var status: Status
    var detail: String
    var request: PermissionRequest?
    var terminal = TerminalInfo()
    var turnStartedAt: Date?
    var finishedAt: Date?
    var updatedAt: Date

    var projectName: String {
        let name = (directory as NSString).lastPathComponent
        return name.isEmpty ? kind.name : name
    }

    var shortDirectory: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return directory.hasPrefix(home) ? "~" + directory.dropFirst(home.count) : directory
    }
}

/// A short-lived "finished" note in the closed notch, for an agent or a long command.
struct NotchFlash: Equatable, Identifiable {
    enum Source: Equatable {
        case agent(AgentKind)
        case command
    }

    let id = UUID()
    let source: Source
    let title: String
    let succeeded: Bool
    /// "1m 12s" or "3 failed"-style detail on the right.
    let detail: String
    /// What the notch should open to when clicked.
    let list: DevList
}

/// Claude Code sessions (from NotchDeck's hooks) and Codex sessions (from its session logs).
@MainActor
final class AgentsService: ObservableObject {
    static let shared = AgentsService()

    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var flash: NotchFlash?
    @Published private(set) var claudeConnected = false

    private var claude: [String: AgentSession] = [:]
    private var codex: [String: AgentSession] = [:]
    private var watcher: DirectoryWatcher?
    private var timer: Timer?
    private var flashTask: Task<Void, Never>?
    private var codexFiles: [String: CodexFileState] = [:]

    /// Finished sessions stay in the list this long.
    private static let doneLifetime: TimeInterval = 30 * 60
    /// A session that has gone quiet this long is dropped.
    private static let staleLifetime: TimeInterval = 60 * 60

    var waitingSession: AgentSession? { sessions.first { $0.status == .waiting } }
    var waitingCount: Int { sessions.filter { $0.status == .waiting }.count }

    func start() {
        HookPaths.createDirectories()
        HookPaths.removeStaleFiles(in: HookPaths.agentEvents, olderThan: 10 * 60)
        HookPaths.removeStaleFiles(in: HookPaths.agentReplies, olderThan: 10 * 60)
        watcher = DirectoryWatcher(url: HookPaths.agentEvents) { [weak self] in self?.drainEvents() }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = 1
        refreshConnection()
        drainEvents()
        tick()
    }

    func refreshConnection() {
        claudeConnected = ClaudeHookInstaller.isInstalled
    }

    private func tick() {
        // The watcher can miss an event while a file is being renamed into place.
        drainEvents()
        scanCodex()
        prune()
    }

    // MARK: - Actions

    /// Answers a permission request from the notch.
    func answer(_ session: AgentSession, allow: Bool) {
        guard let request = session.request, request.canAnswer else { return }
        writeReply(allow ? "allow" : "deny", to: request.id)
        update(session.id) { session in
            session.request = nil
            session.status = .working
            session.detail = allow ? "Approved" : "Denied, continuing"
        }
    }

    /// Sends a waiting request back to the terminal and brings that terminal forward.
    func openTerminal(_ session: AgentSession) {
        if let request = session.request, request.canAnswer {
            writeReply("ask", to: request.id)
            update(session.id) { session in
                session.request?.canAnswer = false
                session.detail = "Waiting for you in \(session.terminal.appName)"
            }
        }
        TerminalControl.focus(session.terminal)
    }

    func dismiss(_ session: AgentSession) {
        claude[session.id] = nil
        codex[session.id] = nil
        publish()
    }

    private func writeReply(_ decision: String, to requestID: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: ["decision": decision]) else { return }
        HookPaths.writeAtomically(data, to: HookPaths.agentReplies.appendingPathComponent("\(requestID).json"))
    }

    private func update(_ id: String, _ change: (inout AgentSession) -> Void) {
        if var session = claude[id] {
            change(&session)
            claude[id] = session
        } else if var session = codex[id] {
            change(&session)
            codex[id] = session
        }
        publish()
    }

    // MARK: - Claude Code events

    private func drainEvents() {
        let files = HookPaths.files(in: HookPaths.agentEvents, extensions: ["json"])
        guard !files.isEmpty else { return }
        var events: [[String: Any]] = []
        for file in files {
            if let data = try? Data(contentsOf: file.url),
               let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                events.append(event)
            }
            try? FileManager.default.removeItem(at: file.url)
        }
        // Status hooks run in the background and can arrive out of order.
        events.sort { ($0["time"] as? Double ?? 0) < ($1["time"] as? Double ?? 0) }
        events.forEach(applyClaude)
        if !claudeConnected { refreshConnection() }
        publish()
    }

    private func applyClaude(_ event: [String: Any]) {
        guard let name = event["event"] as? String,
              let input = event["input"] as? [String: Any],
              let sessionID = input["session_id"] as? String, !sessionID.isEmpty else { return }
        let time = (event["time"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? .now

        if name == "SessionEnd" {
            claude[sessionID] = nil
            return
        }
        var session = claude[sessionID] ?? AgentSession(
            id: sessionID, kind: .claude, directory: input["cwd"] as? String ?? "",
            status: .ready, detail: "Ready", updatedAt: time
        )
        let previous = session.status
        if let cwd = input["cwd"] as? String, !cwd.isEmpty { session.directory = cwd }
        if let tty = TerminalInfo.normalizedTTY(event["tty"] as? String) { session.terminal.tty = tty }
        if let bundleID = event["bundleID"] as? String, !bundleID.isEmpty { session.terminal.bundleID = bundleID }
        if let program = event["termProgram"] as? String, !program.isEmpty { session.terminal.termProgram = program }
        session.updatedAt = time

        let tool = input["tool_name"] as? String ?? ""
        let toolInput = input["tool_input"] as? [String: Any] ?? [:]

        switch name {
        case "SessionStart":
            if session.status != .working { session.status = .ready; session.detail = "Ready" }
        case "UserPromptSubmit":
            session.status = .working
            session.detail = "Thinking"
            session.request = nil
            session.turnStartedAt = time
        case "PreToolUse":
            // A tool event after a permission request means it was answered (maybe in the terminal).
            session.request = nil
            session.status = .working
            session.detail = AgentText.describe(tool: tool, input: toolInput).summary
            if session.turnStartedAt == nil { session.turnStartedAt = time }
        case "PostToolUse":
            session.request = nil
            session.status = .working
        case "PermissionRequest":
            let description = AgentText.describePermission(tool: tool, input: toolInput)
            let canAnswer = event["wantsReply"] as? Bool ?? false
            session.status = .waiting
            session.request = PermissionRequest(id: event["id"] as? String ?? "", summary: description.summary,
                                                detail: description.detail, canAnswer: canAnswer)
            session.detail = canAnswer ? description.summary : "Waiting for you in \(session.terminal.appName)"
        case "NotchDeckReleased":
            if session.request?.id == event["requestID"] as? String {
                session.request?.canAnswer = false
                session.detail = "Waiting for you in \(session.terminal.appName)"
            }
        case "Notification":
            let type = input["notification_type"] as? String ?? ""
            let message = input["message"] as? String ?? ""
            if type == "permission_prompt" || (type.isEmpty && message.localizedCaseInsensitiveContains("permission")) {
                if session.request?.canAnswer != true {
                    session.status = .waiting
                    session.detail = "Waiting for permission in \(session.terminal.appName)"
                }
            } else if ["elicitation_dialog", "elicitation_url_dialog", "agent_needs_input"].contains(type) {
                session.status = .waiting
                session.detail = message.isEmpty ? "Has a question for you" : AgentText.firstLine(message)
            } else if type == "idle_prompt", session.status == .working {
                session.status = .done
                session.finishedAt = time
                session.detail = "Waiting for your next prompt"
            }
        case "Stop":
            session.status = .done
            session.request = nil
            session.finishedAt = time
            let last = (input["last_assistant_message"] as? String).map(AgentText.firstLine) ?? ""
            session.detail = last.isEmpty ? "Finished" : last
        default:
            break
        }

        if previous == .working, session.status == .done {
            let duration = session.turnStartedAt.map { time.timeIntervalSince($0) }
            showFlash(NotchFlash(source: .agent(.claude), title: session.projectName, succeeded: true,
                                 detail: duration.map(DurationFormat.short) ?? "done", list: .agents))
        }
        if session.status == .done { session.turnStartedAt = nil }
        claude[sessionID] = session
    }

    // MARK: - Codex

    private struct CodexFileState {
        var modified: Date
        var session: AgentSession?
    }

    /// Codex records each session in ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl as it goes.
    /// Only today's and yesterday's folders are looked at, and a file is only re-read when it changes.
    private func scanCodex() {
        guard AppSettings.showsCodexSessions else {
            if !codex.isEmpty { codex = [:]; publish() }
            return
        }
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions", isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        let calendar = Calendar.current
        let now = Date.now
        var seen = Set<String>()
        var changed = false
        for dayOffset in [0, -1] {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: now) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            let folder = root.appendingPathComponent(String(format: "%04d/%02d/%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0))
            for file in HookPaths.files(in: folder, extensions: ["jsonl"]) {
                guard now.timeIntervalSince(file.date) < Self.doneLifetime else { continue }
                let path = file.url.path
                seen.insert(path)
                if codexFiles[path]?.modified == file.date { continue }
                let previous = codexFiles[path]?.session
                var session = CodexLog.read(file.url, modified: file.date)
                if var current = session, let previous {
                    current.terminal = previous.terminal
                    session = current
                    if previous.status == .working, current.status == .done {
                        let duration = previous.turnStartedAt.map { file.date.timeIntervalSince($0) }
                        showFlash(NotchFlash(source: .agent(.codex), title: current.projectName, succeeded: true,
                                             detail: duration.map(DurationFormat.short) ?? "done", list: .agents))
                    }
                }
                codexFiles[path] = CodexFileState(modified: file.date, session: session)
                changed = true
            }
        }
        for path in codexFiles.keys.filter({ !seen.contains($0) }) {
            codexFiles[path] = nil
            changed = true
        }
        var sessions: [String: AgentSession] = [:]
        for state in codexFiles.values {
            guard var session = state.session else { continue }
            // Codex doesn't log that it stopped working when it is interrupted or killed.
            if session.status == .working, now.timeIntervalSince(session.updatedAt) > 10 * 60 {
                session.status = .done
                session.detail = "No activity for a while"
            }
            sessions[session.id] = session
        }
        if changed || sessions != codex {
            codex = sessions
            publish()
        }
    }

    // MARK: - Housekeeping

    private func prune() {
        let now = Date.now
        let before = claude.count
        claude = claude.filter { _, session in
            switch session.status {
            case .done: return now.timeIntervalSince(session.finishedAt ?? session.updatedAt) < Self.doneLifetime
            case .waiting: return now.timeIntervalSince(session.updatedAt) < Self.staleLifetime * 4
            case .working, .ready: return now.timeIntervalSince(session.updatedAt) < Self.staleLifetime
            }
        }
        if claude.count != before { publish() }
    }

    private func publish() {
        let all = Array(claude.values) + Array(codex.values)
        let sorted = all.sorted { a, b in
            a.status != b.status ? a.status < b.status : a.updatedAt > b.updatedAt
        }
        if sorted != sessions { sessions = sorted }
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

/// Short, readable descriptions of what an agent is doing.
enum AgentText {
    static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 120 ? String(trimmed.prefix(119)) + "…" : trimmed
    }

    private static func fileName(_ input: [String: Any], _ key: String = "file_path") -> String? {
        (input[key] as? String).map { ($0 as NSString).lastPathComponent }
    }

    /// What a tool call is doing, like "Editing login.tsx", plus the command or path it is about.
    static func describe(tool: String, input: [String: Any]) -> (summary: String, detail: String?) {
        switch tool {
        case "Bash":
            let command = (input["command"] as? String).map(firstLine)
            return (command.map { "Running \($0)" } ?? "Running a command", input["command"] as? String)
        case "Edit", "MultiEdit", "Write":
            return ("Editing \(fileName(input) ?? "a file")", input["file_path"] as? String)
        case "NotebookEdit":
            return ("Editing \(fileName(input, "notebook_path") ?? "a notebook")", input["notebook_path"] as? String)
        case "Read":
            return ("Reading \(fileName(input) ?? "a file")", input["file_path"] as? String)
        case "Grep", "Glob":
            return ("Searching the code", input["pattern"] as? String)
        case "WebFetch":
            return ("Reading a web page", input["url"] as? String)
        case "WebSearch":
            return ("Searching the web", input["query"] as? String)
        case "Task", "Agent":
            return ("Running a subagent", input["description"] as? String)
        case "TodoWrite":
            return ("Updating its to-do list", nil)
        default:
            if tool.hasPrefix("mcp__") {
                let parts = tool.components(separatedBy: "__")
                return ("Using \(parts.count > 1 ? parts[1] : tool)", parts.last)
            }
            return (tool.isEmpty ? "Working" : "Using \(tool)", nil)
        }
    }

    static func describePermission(tool: String, input: [String: Any]) -> (summary: String, detail: String?) {
        switch tool {
        case "Bash":
            return ("Wants to run a command", input["command"] as? String)
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            let name = fileName(input) ?? fileName(input, "notebook_path") ?? "a file"
            return ("Wants to edit \(name)", (input["file_path"] ?? input["notebook_path"]) as? String)
        case "WebFetch":
            return ("Wants to open a web page", input["url"] as? String)
        case "WebSearch":
            return ("Wants to search the web", input["query"] as? String)
        default:
            let described = describe(tool: tool, input: input)
            let name = tool.hasPrefix("mcp__") ? described.summary.replacingOccurrences(of: "Using ", with: "") : tool
            return ("Wants to use \(name.isEmpty ? "a tool" : name)", described.detail)
        }
    }
}

/// Reads the state of one Codex session from its log: the folder from the first line, and the
/// latest task event from the end of the file.
enum CodexLog {
    private static let tailBytes = 64 * 1024

    static func read(_ url: URL, modified: Date) -> AgentSession? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        // session_meta comes first: { "type": "session_meta", "payload": { "id", "cwd", ... } }
        let head = (try? handle.read(upToCount: 16 * 1024)) ?? Data()
        guard let firstLine = head.split(separator: UInt8(ascii: "\n"), maxSplits: 1).first,
              let meta = (try? JSONSerialization.jsonObject(with: Data(firstLine))) as? [String: Any],
              meta["type"] as? String == "session_meta",
              let payload = meta["payload"] as? [String: Any] else { return nil }
        let id = payload["id"] as? String ?? payload["session_id"] as? String ?? url.lastPathComponent
        let directory = payload["cwd"] as? String ?? ""

        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0)
        let tail = (try? handle.readToEnd()) ?? Data()

        var status: AgentSession.Status?
        var detail = ""
        var startedAt: Date?
        var lastMessage: String?
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        func timestamp(_ object: [String: Any]) -> Date? {
            (object["timestamp"] as? String).flatMap { formatter.date(from: $0) }
        }

        scan: for line in tail.split(separator: UInt8(ascii: "\n")).reversed() {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  object["type"] as? String == "event_msg",
                  let event = object["payload"] as? [String: Any],
                  let type = event["type"] as? String else { continue }
            if type == "agent_message", lastMessage == nil {
                lastMessage = (event["message"] as? String).map(AgentText.firstLine)
            }
            if status != nil {
                // Found the latest state; keep going back only to find when that task started.
                if type == "task_started" {
                    startedAt = timestamp(object)
                    break scan
                }
                continue
            }
            switch type {
            case "task_complete", "turn_aborted":
                status = .done
                detail = type == "turn_aborted" ? "Stopped" : "Finished"
            case "exec_approval_request", "apply_patch_approval_request", "request_user_input":
                status = .waiting
                detail = type == "apply_patch_approval_request" ? "Wants to edit files" : "Wants to run a command"
            case "task_started":
                status = .working
                detail = "Working"
                startedAt = timestamp(object)
                break scan
            default:
                break
            }
        }
        guard let status else { return nil }
        if status == .done, let lastMessage, !lastMessage.isEmpty { detail = lastMessage }
        if status == .waiting { detail += " in the terminal" }
        return AgentSession(id: "codex-\(id)", kind: .codex, directory: directory, status: status, detail: detail,
                            turnStartedAt: status == .done ? startedAt : startedAt ?? modified,
                            finishedAt: status == .done ? modified : nil, updatedAt: modified)
    }
}

enum DurationFormat {
    /// "42s", "1m 12s", "1h 5m".
    static func short(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(total % 60)s" }
        return "\(total / 3600)h \(total % 3600 / 60)m"
    }

    /// "0:42", "12:05", "1:02:03" for a running timer.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total < 3600 { return String(format: "%d:%02d", total / 60, total % 60) }
        return String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
    }

    /// "just now", "2m ago", "1h ago".
    static func ago(_ date: Date, now: Date = .now) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 45 { return "just now" }
        if seconds < 3600 { return "\(max(1, seconds / 60))m ago" }
        return "\(seconds / 3600)h ago"
    }
}
