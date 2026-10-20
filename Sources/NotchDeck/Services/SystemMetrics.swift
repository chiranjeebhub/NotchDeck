import Darwin
import Foundation
import IOKit
import IOKit.ps

struct NetworkRate: Equatable {
    var download: Double = 0
    var upload: Double = 0
}

struct DiskUsage: Equatable {
    var free: Int64
    var total: Int64

    var used: Int64 { max(total - free, 0) }
}

struct BatteryStatus: Equatable {
    var percent: Int
    var isCharging: Bool
    var isOnPower: Bool
    /// Minutes until empty, when macOS has an estimate.
    var minutesLeft: Int?
}

struct TopProcess: Identifiable, Hashable, Sendable {
    let pid: Int32
    let name: String
    let cpu: Double
    let memory: UInt64

    var id: Int32 { pid }
}

/// One-shot readings for the optional stats. Each call is cheap except `topProcesses`, which runs `ps`.
enum SystemMetrics {
    /// Bytes received and sent per interface since boot. The counters are 32-bit and wrap.
    static func interfaceCounters() -> [String: (rx: UInt32, tx: UInt32)] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let start = first else { return [:] }
        defer { freeifaddrs(first) }
        var result: [String: (rx: UInt32, tx: UInt32)] = [:]
        for pointer in sequence(first: start, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
                  let data = entry.ifa_data else { continue }
            let name = String(cString: entry.ifa_name)
            // Wi-Fi/Ethernet and cellular only; VPN tunnels would count traffic twice.
            guard name.hasPrefix("en") || name.hasPrefix("pdp_ip") else { continue }
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            result[name] = (stats.ifi_ibytes, stats.ifi_obytes)
        }
        return result
    }

    static func disk() -> DiskUsage? {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let free = values.volumeAvailableCapacityForImportantUsage,
              let total = values.volumeTotalCapacity else { return nil }
        return DiskUsage(free: free, total: Int64(total))
    }

    /// nil on Macs without a battery.
    static func battery() -> BatteryStatus? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  (description["Type"] as? String) == "InternalBattery",
                  let current = description["Current Capacity"] as? Int,
                  let maximum = description["Max Capacity"] as? Int, maximum > 0 else { continue }
            let minutes = description["Time to Empty"] as? Int
            return BatteryStatus(
                percent: Int((Double(current) / Double(maximum) * 100).rounded()),
                isCharging: description["Is Charging"] as? Bool ?? false,
                isOnPower: (description["Power Source State"] as? String) == "AC Power",
                minutesLeft: minutes.flatMap { $0 > 0 ? $0 : nil }
            )
        }
        return nil
    }

    /// GPU busy percentage as reported by the graphics driver, if it reports one.
    static func gpuUtilization() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        var best: Double?
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let property = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0),
               let statistics = property.takeRetainedValue() as? [String: Any],
               let value = statistics["Device Utilization %"] as? NSNumber {
                best = max(best ?? 0, value.doubleValue)
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return best
    }

    static let bootDate: Date? = {
        var time = timeval()
        var size = MemoryLayout<timeval>.stride
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &time, &size, nil, 0) == 0, time.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(time.tv_sec))
    }()

    /// The busiest processes by CPU, like the top of Activity Monitor.
    static func topProcesses(limit: Int = 5) -> [TopProcess] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        // -c: command name only, -r: sort by CPU.
        process.arguments = ["-Aceo", "pid=,%cpu=,rss=,comm=", "-r"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var result: [TopProcess] = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard fields.count == 4, let pid = Int32(fields[0]), let cpu = Double(fields[1]),
                  let rss = UInt64(fields[2]), pid != ownPID, fields[3] != "ps" else { continue }
            result.append(TopProcess(pid: pid, name: String(fields[3]), cpu: cpu, memory: rss * 1024))
            if result.count == limit { break }
        }
        return result
    }
}
