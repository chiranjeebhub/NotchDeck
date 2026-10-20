import AppKit

/// A TCP port some local process is listening on.
struct ListeningPort: Identifiable, Hashable, Sendable {
    let port: Int
    let pid: Int32
    let command: String
    let address: String
    /// The process's working directory, which for dev servers is usually the project folder.
    var directory: String?

    var id: String { "\(pid):\(port)" }
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

        let directories = workingDirectories(of: Set(ports.map(\.pid)))
        for index in ports.indices {
            ports[index].directory = directories[ports[index].pid]
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

    private static func run(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
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
