import SwiftUI

/// CPU, memory and Docker summary across the top of the Dev tab.
struct StatsStripView: View {
    @ObservedObject private var stats = SystemStatsService.shared

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            StatColumn(label: "CPU", detail: "\(stats.coreCount) cores") {
                BigValue(value: String(format: "%.0f", stats.cpuUsage), unit: "%")
                Sparkline(values: stats.cpuHistory)
                    .frame(height: 24)
                    .padding(.top, 2)
            }
            .padding(.leading, 4)

            divider

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

            divider

            dockerColumn
        }
        .frame(height: 72)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(width: 1)
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
                Text(stats.docker == .notInstalled ? "Not installed" : stats.docker == .unknown ? "Checking…" : "Not running")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .padding(.top, 6)
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

/// Filled line chart of recent CPU usage (0–100%).
struct Sparkline: View {
    let values: [Double]

    var body: some View {
        GeometryReader { geometry in
            let points = Self.points(values, in: geometry.size)
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
    private static func points(_ values: [Double], in size: CGSize) -> [CGPoint] {
        guard values.count > 1, let low = values.min(), let high = values.max() else { return [] }
        let padding = max((high - low) * 0.25, 2)
        let bottom = max(low - padding, 0)
        let top = min(max(high + padding, bottom + 10), 100)
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
