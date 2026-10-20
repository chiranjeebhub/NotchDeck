import AppKit
import Darwin

struct MemoryUsage: Equatable {
    var app: UInt64
    var wired: UInt64
    var compressed: UInt64
    var total: UInt64

    var used: UInt64 { app + wired + compressed }
}

struct DockerContainer: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    /// Compose service name, if the container belongs to a Compose project.
    let service: String?
    let project: String?
    let image: String
    let isRunning: Bool
    let status: String
    let hostPort: Int?
    var cpu: String?
    var memory: String?

    var displayName: String { service ?? name }
    var isDatabase: Bool {
        let image = image.lowercased()
        return ListeningPort.databaseKeywords.contains { image.contains($0) }
    }
    var url: URL? { hostPort.flatMap { URL(string: "http://localhost:\($0)") } }
}

enum DockerState: Equatable {
    case unknown
    case notInstalled
    case notRunning
    case running([DockerContainer])

    var containers: [DockerContainer] {
        if case .running(let containers) = self { return containers }
        return []
    }
}

/// CPU, memory and Docker status for the Dev tab.
@MainActor
final class SystemStatsService: ObservableObject {
    static let shared = SystemStatsService()

    @Published private(set) var cpuUsage: Double = 0
    /// The last minute of CPU samples, oldest first, in percent.
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var memory = MemoryUsage(app: 0, wired: 0, compressed: 0, total: ProcessInfo.processInfo.physicalMemory)
    @Published private(set) var docker: DockerState = .unknown
    @Published private(set) var network = NetworkRate()
    /// Recent download rate in bytes per second, oldest first.
    @Published private(set) var networkHistory: [Double] = []
    @Published private(set) var disk: DiskUsage?
    @Published private(set) var battery: BatteryStatus?
    @Published private(set) var gpu: Double?
    @Published private(set) var processes: [TopProcess] = []

    let coreCount = ProcessInfo.processInfo.activeProcessorCount

    private var previousTicks: [UInt32]?
    private var samplingTask: Task<Void, Never>?
    private var watchers = 0
    private var isRefreshingDocker = false
    private var isRefreshingProcesses = false
    private var previousCounters: [String: (rx: UInt32, tx: UInt32)]?
    private var previousCountersDate = Date.now

    private static let sampleInterval: Duration = .seconds(2)
    private static let historyLength = 30
    /// Docker is slower to query, so it refreshes every few CPU samples.
    private static let dockerEvery = 3
    private static let diskEvery = 15

    /// CPU and memory are sampled all the time (it is cheap), so the CPU graph already has a
    /// minute of history when the Dev tab opens. Docker is only queried while the tab is visible.
    func startSampling() {
        guard samplingTask == nil else { return }
        samplingTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                self.sampleCPU()
                self.sampleNetwork()
                if self.watchers > 0 {
                    self.sampleVisibleStats(tick: tick)
                    tick += 1
                }
                try? await Task.sleep(for: Self.sampleInterval)
            }
        }
    }

    func startMonitoring() {
        watchers += 1
        guard watchers == 1 else { return }
        sampleVisibleStats(tick: 0)
    }

    func stopMonitoring() {
        watchers = max(0, watchers - 1)
    }

    /// Stats that are only shown on the Dev tab, sampled while it is visible.
    private func sampleVisibleStats(tick: Int) {
        sampleMemory()
        let slots = AppSettings.devStatSlots
        if slots.contains(.gpu) {
            let value = SystemMetrics.gpuUtilization()
            if value != gpu { gpu = value }
        }
        if slots.contains(.battery) {
            let value = SystemMetrics.battery()
            if value != battery { battery = value }
        }
        if slots.contains(.disk), tick % Self.diskEvery == 0 {
            let value = SystemMetrics.disk()
            if value != disk { disk = value }
        }
        if AppSettings.wantsDocker, tick % Self.dockerEvery == 0 { refreshDocker() }
        if AppSettings.wantsProcesses { refreshProcesses() }
    }

    // MARK: - CPU, memory and network

    private func sampleCPU() {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }
        // user, system, idle, nice
        let ticks = [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]
        defer { previousTicks = ticks }
        guard let previous = previousTicks else { return }
        // Tick counters are 32-bit and can wrap, hence the wrapping subtraction.
        let delta = zip(ticks, previous).map { Double($0 &- $1) }
        let busy = delta[0] + delta[1] + delta[3]
        let total = busy + delta[2]
        guard total > 0 else { return }
        cpuUsage = busy / total * 100
        cpuHistory.append(cpuUsage)
        if cpuHistory.count > Self.historyLength { cpuHistory.removeFirst(cpuHistory.count - Self.historyLength) }
    }

    private func sampleMemory() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }
        let page = UInt64(getpagesize())
        // Same breakdown as Activity Monitor's "Memory Used".
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let next = MemoryUsage(
            app: (internalPages > purgeable ? internalPages - purgeable : 0) * page,
            wired: UInt64(stats.wire_count) * page,
            compressed: UInt64(stats.compressor_page_count) * page,
            total: ProcessInfo.processInfo.physicalMemory
        )
        if next != memory { memory = next }
    }

    private func sampleNetwork() {
        let counters = SystemMetrics.interfaceCounters()
        let now = Date.now
        defer {
            previousCounters = counters
            previousCountersDate = now
        }
        guard let previous = previousCounters else { return }
        let seconds = now.timeIntervalSince(previousCountersDate)
        guard seconds > 0 else { return }
        var received: UInt64 = 0
        var sent: UInt64 = 0
        for (name, value) in counters {
            guard let old = previous[name] else { continue }
            received += UInt64(value.rx &- old.rx)
            sent += UInt64(value.tx &- old.tx)
        }
        network = NetworkRate(download: Double(received) / seconds, upload: Double(sent) / seconds)
        networkHistory.append(network.download)
        if networkHistory.count > Self.historyLength { networkHistory.removeFirst(networkHistory.count - Self.historyLength) }
    }

    // MARK: - Processes

    func refreshProcesses() {
        guard !isRefreshingProcesses else { return }
        isRefreshingProcesses = true
        Task { [weak self] in
            let list = await Task.detached(priority: .utility) { SystemMetrics.topProcesses() }.value
            guard let self else { return }
            self.isRefreshingProcesses = false
            if list != self.processes { self.processes = list }
        }
    }

    /// Asks the process to quit (SIGTERM), then refreshes the list.
    func quit(_ process: TopProcess) {
        Darwin.kill(process.pid, SIGTERM)
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            self?.refreshProcesses()
        }
    }

    // MARK: - Docker

    func refreshDocker() {
        guard !isRefreshingDocker else { return }
        isRefreshingDocker = true
        Task { [weak self] in
            let state = await Task.detached(priority: .utility) { DockerCLI.state() }.value
            guard let self else { return }
            self.isRefreshingDocker = false
            if state != self.docker { self.docker = state }
        }
    }

    func start(_ container: DockerContainer) {
        runDocker(["start", container.id])
    }

    func stop(_ container: DockerContainer) {
        runDocker(["stop", container.id])
    }

    /// Opens a Terminal window following the container's logs.
    func showLogs(_ container: DockerContainer) {
        guard let docker = DockerCLI.path else { return }
        let script = "#!/bin/zsh\nexec '\(docker)' logs -f --tail 200 '\(container.id)'\n"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotchUtility-logs-\(container.id).command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)
        } catch {
            NSSound.beep()
        }
    }

    private func runDocker(_ arguments: [String]) {
        Task { [weak self] in
            _ = await Task.detached(priority: .userInitiated) { DockerCLI.run(arguments) }.value
            self?.refreshDocker()
        }
    }
}

/// Thin wrapper around the `docker` command line tool.
enum DockerCLI {
    static let path: String? = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/usr/local/bin/docker",
            "/opt/homebrew/bin/docker",
            "\(home)/.docker/bin/docker",
            "\(home)/.orbstack/bin/docker",
            "/Applications/Docker.app/Contents/Resources/bin/docker",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    static func state() -> DockerState {
        guard path != nil else { return .notInstalled }
        let list = run(["ps", "-a", "--format", "{{json .}}"])
        guard list.status == 0 else { return .notRunning }

        var containers: [DockerContainer] = []
        for line in list.output.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let labels = parseLabels(object["Labels"] as? String ?? "")
            containers.append(DockerContainer(
                id: object["ID"] as? String ?? "",
                name: object["Names"] as? String ?? "",
                service: labels["com.docker.compose.service"],
                project: labels["com.docker.compose.project"],
                image: object["Image"] as? String ?? "",
                isRunning: (object["State"] as? String) == "running",
                status: object["Status"] as? String ?? "",
                hostPort: firstHostPort(object["Ports"] as? String ?? "")
            ))
        }

        if containers.contains(where: \.isRunning) {
            let stats = run(["stats", "--no-stream", "--format", "{{.ID}}\t{{.CPUPerc}}\t{{.MemUsage}}"])
            var byID: [String: (String, String)] = [:]
            for line in stats.output.split(separator: "\n") {
                let fields = line.split(separator: "\t").map(String.init)
                guard fields.count == 3 else { continue }
                let memory = fields[2].components(separatedBy: " / ").first ?? fields[2]
                byID[fields[0]] = (fields[1], tidyUnits(memory))
            }
            for index in containers.indices {
                if let stat = byID[containers[index].id] {
                    containers[index].cpu = stat.0
                    containers[index].memory = stat.1
                }
            }
        }

        // Running first, then grouped by project.
        containers.sort {
            if $0.isRunning != $1.isRunning { return $0.isRunning }
            return ($0.project ?? "~", $0.displayName) < ($1.project ?? "~", $1.displayName)
        }
        return .running(containers)
    }

    @discardableResult
    static func run(_ arguments: [String]) -> (status: Int32, output: String) {
        guard let path else { return (-1, "") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        // Credential helpers and plugins live next to the CLI.
        var environment = ProcessInfo.processInfo.environment
        let directory = (path as NSString).deletingLastPathComponent
        environment["PATH"] = "\(directory):/usr/local/bin:/opt/homebrew/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return (-1, "")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private static func parseLabels(_ text: String) -> [String: String] {
        var labels: [String: String] = [:]
        for pair in text.split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { labels[parts[0]] = parts[1] }
        }
        return labels
    }

    /// "0.0.0.0:8080->80/tcp, :::8080->80/tcp" → 8080
    private static func firstHostPort(_ ports: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: #":(\d+)->"#),
              let match = regex.firstMatch(in: ports, range: NSRange(ports.startIndex..., in: ports)),
              let range = Range(match.range(at: 1), in: ports) else { return nil }
        return Int(ports[range])
    }

    private static func tidyUnits(_ value: String) -> String {
        value.replacingOccurrences(of: "GiB", with: " GB")
            .replacingOccurrences(of: "MiB", with: " MB")
            .replacingOccurrences(of: "KiB", with: " KB")
    }
}
