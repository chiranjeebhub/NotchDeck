import AppKit

/// A TCP port some local process is listening on.
struct ListeningPort: Identifiable, Hashable, Sendable {
    let port: Int
    let pid: Int32
    let command: String
    let address: String
    /// The process's working directory, which for dev servers is usually the project folder.
    var directory: String?
    /// Process CPU in percent and resident memory in bytes, from `ps`.
    var cpu: Double?
    var memory: UInt64?

    var id: String { "\(pid):\(port)" }

    enum Kind { case web, database, other }

    static let databaseKeywords = [
        "postgres", "mysql", "maria", "mongo", "redis", "memcached", "clickhouse",
        "elastic", "opensearch", "rabbitmq", "kafka", "cockroach", "influx", "couchdb",
    ]
    private static let otherCommands: Set<String> = ["adb", "com.docker.backend", "vpnkit-bridge", "ssh"]
    private static let webCommands = [
        "node", "bun", "deno", "python", "ruby", "php", "java", "go", "rails", "puma", "uvicorn",
        "gunicorn", "next", "vite", "dotnet", "beam.smp", "hugo", "caddy", "nginx", "httpd",
    ]

    /// Best guess at what kind of server this is, used for colour and whether Open makes sense.
    var kind: Kind {
        let name = command.lowercased()
        if Self.databaseKeywords.contains(where: { name.contains($0) }) { return .database }
        if Self.otherCommands.contains(name) { return .other }
        if Self.webCommands.contains(where: { name == $0 || name.hasPrefix($0) }) { return .web }
        let devRanges = [3000...3999, 4000...4999, 5000...5999, 8000...8999, 9000...9999]
        return devRanges.contains { $0.contains(port) } ? .web : .other
    }

    var isLocalOnly: Bool {
        ["127.0.0.1", "[::1]", "localhost"].contains(address)
    }

    /// The working directory with the home folder shortened to ~.
    var shortDirectory: String? {
        guard let directory, directory != "/" else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return directory.hasPrefix(home) ? "~" + directory.dropFirst(home.count) : directory
    }
    var projectName: String? {
        guard let directory, directory != "/" else { return nil }
        return URL(fileURLWithPath: directory).lastPathComponent
    }
    var url: URL { URL(string: "http://localhost:\(port)")! }
}

/// Lists listening TCP ports with `lsof` and kills their processes.
@MainActor
final class PortsService: ObservableObject {
    static let shared = PortsService()

    @Published private(set) var ports: [ListeningPort] = []
    @Published private(set) var hasLoaded = false

    private var monitorTask: Task<Void, Never>?
    private var watchers = 0

    /// macOS services that listen on ports but aren't anything you'd want to open or kill.
    private static let systemCommands: Set<String> = [
        "ControlCenter", "rapportd", "sharingd", "identityservicesd", "remoted", "launchd",
        "AirPlayXPCHelper", "WiFiAgent", "UserEventAgent", "Spotify",
    ]

    func visiblePorts(showAll: Bool) -> [ListeningPort] {
        guard !showAll else { return ports }
        // Hide system services and ephemeral ports (49152+), which are rarely dev servers.
        return ports.filter { !Self.systemCommands.contains($0.command) && $0.port < 49152 }
    }

    /// Refreshes every few seconds while at least one view is watching.
    func startMonitoring() {
        watchers += 1
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func stopMonitoring() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        monitorTask?.cancel()
        monitorTask = nil
    }

    func refresh() async {
        let scanned = await Task.detached(priority: .utility) { PortScanner.scan() }.value
        if scanned != ports { ports = scanned }
        hasLoaded = true
    }

    func open(_ port: ListeningPort) {
        NSWorkspace.shared.open(port.url)
    }

    func copyURL(_ port: ListeningPort) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(port.url.absoluteString, forType: .string)
    }

    /// Asks the process to quit (SIGTERM). Only processes owned by the user can be killed.
    func kill(_ port: ListeningPort) {
        if Darwin.kill(port.pid, SIGTERM) != 0 {
            NSSound.beep()
        }
        ports.removeAll { $0.pid == port.pid }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            await self?.refresh()
        }
    }
}

enum PortScanner {
    static func scan() -> [ListeningPort] {
        // -F output: one field per line, prefixed by p (pid), c (command), n (name, e.g. "*:3000").
        guard let output = run(["+c", "0", "-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcn"]) else { return [] }

        var ports: [ListeningPort] = []
        var seen = Set<String>()
        var pid: Int32 = 0
        var command = ""
        for line in output.split(separator: "\n") {
            guard let field = line.first else { continue }
            let value = String(line.dropFirst())
            switch field {
            case "p":
                pid = Int32(value) ?? 0
            case "c":
                command = value
            case "n":
                guard let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]) else { continue }
                let address = String(value[..<colon])
                // IPv4 and IPv6 listeners for the same port show up separately.
                guard seen.insert("\(pid):\(port)").inserted else { continue }
                ports.append(ListeningPort(port: port, pid: pid, command: command, address: address))
            default:
                break
            }
        }

        let pids = Set(ports.map(\.pid))
        let directories = workingDirectories(of: pids)
        let usage = resourceUsage(of: pids)
        for index in ports.indices {
            let pid = ports[index].pid
            ports[index].directory = directories[pid]
            ports[index].cpu = usage[pid]?.cpu
            ports[index].memory = usage[pid]?.memory
        }
        return ports.sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
    }

    private static func workingDirectories(of pids: Set<Int32>) -> [Int32: String] {
        guard !pids.isEmpty,
              let output = run(["-a", "-d", "cwd", "-p", pids.map(String.init).joined(separator: ","), "-Fn"]) else { return [:] }
        var result: [Int32: String] = [:]
        var pid: Int32 = 0
        for line in output.split(separator: "\n") {
            if line.hasPrefix("p") {
                pid = Int32(line.dropFirst()) ?? 0
            } else if line.hasPrefix("n") {
                result[pid] = String(line.dropFirst())
            }
        }
        return result
    }

    private static func resourceUsage(of pids: Set<Int32>) -> [Int32: (cpu: Double, memory: UInt64)] {
        guard !pids.isEmpty,
              let output = run(["-o", "pid=,%cpu=,rss=", "-p", pids.map(String.init).joined(separator: ",")],
                               executable: "/bin/ps") else { return [:] }
        var result: [Int32: (cpu: Double, memory: UInt64)] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count == 3, let pid = Int32(fields[0]), let cpu = Double(fields[1]),
                  let rssKB = UInt64(fields[2]) else { continue }
            result[pid] = (cpu, rssKB * 1024)
        }
        return result
    }

    private static func run(_ arguments: [String], executable: String = "/usr/sbin/lsof") -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
