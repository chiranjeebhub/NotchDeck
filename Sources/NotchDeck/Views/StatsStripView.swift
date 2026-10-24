import SwiftUI

/// Up to three stats across the top of the Dev tab, chosen in Settings → Dev.
struct StatsStripView: View {
    @ObservedObject private var stats = SystemStatsService.shared
    @AppStorage(AppSettings.devStatSlotsKey) private var slotsText = StatKind.encode(StatKind.defaultSlots)

    static let height: CGFloat = 72

    private var slots: [StatKind] { StatKind.slots(from: slotsText).filter { $0 != .none } }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(slots.enumerated()), id: \.offset) { index, kind in
                if index > 0 { divider }
                column(for: kind)
                    .padding(.leading, index == 0 ? 4 : 0)
            }
        }
        .frame(height: Self.height)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(width: 1)
    }

    @ViewBuilder
    private func column(for kind: StatKind) -> some View {
        switch kind {
        case .cpu: cpuColumn
        case .memory: memoryColumn
        case .docker: dockerColumn
        case .network: networkColumn
        case .disk: diskColumn
        case .battery: batteryColumn
        case .gpu: gpuColumn
        case .uptime: uptimeColumn
        case .claude: ClaudeStatColumn()
        case .none: EmptyView()
        }
    }

    private var cpuColumn: some View {
        StatColumn(label: "CPU", detail: "\(stats.coreCount) cores") {
            BigValue(value: String(format: "%.0f", stats.cpuUsage), unit: "%")
            Sparkline(values: stats.cpuHistory)
                .frame(height: 24)
                .padding(.top, 2)
        }
    }

    private var memoryColumn: some View {
        StatColumn(label: "Memory", detail: ByteFormat.string(stats.memory.total)) {
            BigValue(value: ByteFormat.gigabytes(stats.memory.used), unit: "GB used")
            MemoryMeter(memory: stats.memory)
                .frame(height: 5)
                .padding(.top, 6)
            Text("App \(ByteFormat.gigabytes(stats.memory.app)) · Wired \(ByteFormat.gigabytes(stats.memory.wired)) · Compr. \(ByteFormat.gigabytes(stats.memory.compressed)) GB")
                .font(.system(size: 9.5))
                .foregroundStyle(Color.white.opacity(0.45))
                .lineLimit(1)
                .padding(.top, 3)
        }
    }

    private var networkColumn: some View {
        StatColumn(label: "Network", detail: nil) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                RateValue(symbol: "arrow.down", bytesPerSecond: stats.network.download)
                RateValue(symbol: "arrow.up", bytesPerSecond: stats.network.upload)
            }
            .padding(.top, 2)
            Sparkline(values: stats.networkHistory, ceiling: nil, minimumSpan: 50_000)
                .frame(height: 24)
                .padding(.top, 2)
        }
    }

    private var diskColumn: some View {
        StatColumn(label: "Disk", detail: stats.disk.map { ByteFormat.disk($0.total) }) {
            if let disk = stats.disk {
                BigValue(value: ByteFormat.disk(disk.free), unit: "free")
                ProgressMeter(fraction: Double(disk.used) / Double(max(disk.total, 1)), color: DevColors.database)
                    .frame(height: 5)
                    .padding(.top, 6)
            } else {
                PlaceholderValue(text: "Checking…")
            }
        }
    }

    private var batteryColumn: some View {
        StatColumn(label: "Battery", detail: stats.battery.map { $0.isCharging ? "Charging" : $0.isOnPower ? "On power" : "On battery" }) {
            if let battery = stats.battery {
                BigValue(value: String(battery.percent), unit: batteryDetail(battery))
                ProgressMeter(fraction: Double(battery.percent) / 100,
                              color: battery.percent <= 20 && !battery.isOnPower ? .red : DevColors.web)
                    .frame(height: 5)
                    .padding(.top, 6)
            } else {
                PlaceholderValue(text: "No battery")
            }
        }
    }

    private func batteryDetail(_ battery: BatteryStatus) -> String {
        guard !battery.isOnPower, let minutes = battery.minutesLeft else { return "%" }
        return "% · \(minutes / 60)h \(minutes % 60)m left"
    }

    private var gpuColumn: some View {
        StatColumn(label: "GPU", detail: nil) {
            if let gpu = stats.gpu {
                BigValue(value: String(format: "%.0f", gpu), unit: "%")
                ProgressMeter(fraction: gpu / 100, color: Color(red: 0.65, green: 0.55, blue: 0.98))
                    .frame(height: 5)
                    .padding(.top, 6)
            } else {
                PlaceholderValue(text: "Not available")
            }
        }
    }

    private var uptimeColumn: some View {
        StatColumn(label: "Uptime", detail: nil) {
            if let boot = SystemMetrics.bootDate {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    let minutes = max(Int(context.date.timeIntervalSince(boot) / 60), 0)
                    let days = minutes / 1440
                    let hours = (minutes % 1440) / 60
                    BigValue(value: days > 0 ? "\(days)d \(hours)h" : "\(hours)h \(minutes % 60)m", unit: "")
                }
                Text("Since \(boot.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .lineLimit(1)
                    .padding(.top, 6)
            } else {
                PlaceholderValue(text: "Unknown")
            }
        }
    }

    @ViewBuilder
    private var dockerColumn: some View {
        switch stats.docker {
        case .running(let containers):
            let running = containers.filter(\.isRunning).count
            StatColumn(label: "Docker", detail: nil) {
                BigValue(value: String(running), unit: "of \(containers.count) running")
                HStack(spacing: 10) {
                    StatusPill(color: DevColors.web, text: "\(running) up")
                    StatusPill(color: DevColors.other, text: "\(containers.count - running) stopped")
                }
                .padding(.top, 6)
            }
        case .notRunning, .notInstalled, .unknown:
            StatColumn(label: "Docker", detail: nil) {
                PlaceholderValue(text: stats.docker == .notInstalled ? "Not installed" : stats.docker == .unknown ? "Checking…" : "Not running")
                if stats.docker == .notRunning {
                    Button("Start Docker") {
                        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.docker.docker") {
                            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(DevColors.database)
                    .padding(.top, 4)
                }
            }
        }
    }
}

struct PlaceholderValue: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.6))
            .padding(.top, 6)
    }
}

/// "↓ 2.1 MB/s" with the number large and the unit small.
struct RateValue: View {
    let symbol: String
    let bytesPerSecond: Double

    var body: some View {
        let parts = ByteFormat.rate(bytesPerSecond)
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.5))
            Text(parts.value)
                .font(.system(size: 20, weight: .medium).monospacedDigit())
            Text(parts.unit)
                .font(.system(size: 10.5))
                .foregroundStyle(Color.white.opacity(0.45))
        }
        .lineLimit(1)
    }
}

/// A thin filled bar, for disk, battery and GPU.
struct ProgressMeter: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            Capsule()
                .fill(color)
                .frame(width: geometry.size.width * min(max(fraction, 0), 1))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Capsule().fill(Color.white.opacity(0.1)))
        }
    }
}

struct StatColumn<Content: View>: View {
    let label: String
    let detail: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(label.uppercased())
                Spacer()
                if let detail { Text(detail.uppercased()) }
            }
            .font(.system(size: 9.5, weight: .semibold))
            .kerning(0.6)
            .foregroundStyle(Color.white.opacity(0.45))
            content()
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct BigValue: View {
    let value: String
    let unit: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(value)
                .font(.system(size: 22, weight: .medium).monospacedDigit())
            Text(unit)
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.45))
                .lineLimit(1)
        }
        .padding(.top, 2)
    }
}

struct StatusPill: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.7))
        }
    }
}

/// Filled line chart of recent values, such as CPU usage.
struct Sparkline: View {
    let values: [Double]
    /// Highest value the scale can reach (100 for percentages), or nil for no limit.
    var ceiling: Double? = 100
    /// Smallest range the scale covers, so noise doesn't fill the whole height.
    var minimumSpan: Double = 10

    var body: some View {
        GeometryReader { geometry in
            let points = points(in: geometry.size)
            ZStack {
                if points.count > 1 {
                    Path { path in
                        path.move(to: CGPoint(x: points[0].x, y: geometry.size.height))
                        points.forEach { path.addLine(to: $0) }
                        path.addLine(to: CGPoint(x: points[points.count - 1].x, y: geometry.size.height))
                        path.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [DevColors.web.opacity(0.4), DevColors.web.opacity(0)],
                                         startPoint: .top, endPoint: .bottom))
                    Path { path in
                        path.move(to: points[0])
                        points.dropFirst().forEach { path.addLine(to: $0) }
                    }
                    .stroke(DevColors.web, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }

    /// The vertical scale follows the recent range, so small changes stay visible
    /// (a fixed 0–100% scale draws 18–25% as a flat line along the bottom).
    private func points(in size: CGSize) -> [CGPoint] {
        guard values.count > 1, let low = values.min(), let high = values.max() else { return [] }
        let padding = max((high - low) * 0.25, minimumSpan / 5)
        let bottom = max(low - padding, 0)
        let top = min(max(high + padding, bottom + minimumSpan), ceiling ?? .infinity)
        let span = max(top - bottom, 1)
        let step = size.width / CGFloat(values.count - 1)
        return values.enumerated().map { index, value in
            let fraction = (min(max(value, bottom), top) - bottom) / span
            return CGPoint(x: CGFloat(index) * step, y: size.height * (1 - CGFloat(fraction)))
        }
    }
}

/// Memory used, split into app (blue), wired (purple) and compressed (amber), out of total.
struct MemoryMeter: View {
    let memory: MemoryUsage

    var body: some View {
        GeometryReader { geometry in
            let total = max(Double(memory.total), 1)
            HStack(spacing: 0) {
                Rectangle().fill(DevColors.database)
                    .frame(width: geometry.size.width * Double(memory.app) / total)
                Rectangle().fill(Color(red: 0.65, green: 0.55, blue: 0.98))
                    .frame(width: geometry.size.width * Double(memory.wired) / total)
                Rectangle().fill(Color(red: 0.96, green: 0.62, blue: 0.04))
                    .frame(width: geometry.size.width * Double(memory.compressed) / total)
                Spacer(minLength: 0)
            }
            .background(Color.white.opacity(0.1))
            .clipShape(Capsule())
        }
    }
}
