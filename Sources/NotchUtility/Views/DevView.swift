import SwiftUI

/// Dev tab: system stats on top, then local servers or Docker containers.
struct DevView: View {
    enum DevSection: String { case servers, containers }

    @ObservedObject private var service = PortsService.shared
    @ObservedObject private var stats = SystemStatsService.shared
    @AppStorage(AppSettings.devShowAllPortsKey) private var showAll = false
    @AppStorage("devSection") private var section = DevSection.servers
    @AppStorage("devShowAllContainers") private var showAllContainers = false

    private var ports: [ListeningPort] { service.visiblePorts(showAll: showAll) }
    private var dockerAvailable: Bool {
        if case .running = stats.docker { return true }
        return false
    }
    private var containers: [DockerContainer] {
        let all = stats.docker.containers
        return showAllContainers ? all : all.filter(\.isRunning)
    }
    private var activeSection: DevSection { dockerAvailable ? section : .servers }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StatsStripView()

            HStack(spacing: 8) {
                SegmentedToggle(
                    options: dockerAvailable
                        ? ["Servers  \(ports.count)", "Containers  \(stats.docker.containers.count)"]
                        : ["Servers  \(ports.count)"],
                    selection: Binding(
                        get: { activeSection == .servers ? 0 : 1 },
                        set: { section = $0 == 0 ? .servers : .containers }
                    )
                )
                Spacer()
                if activeSection == .servers {
                    SegmentedToggle(options: ["Dev", "All ports"], selection: Binding(
                        get: { showAll ? 1 : 0 },
                        set: { showAll = $0 == 1 }
                    ))
                } else {
                    SegmentedToggle(options: ["Running", "All"], selection: Binding(
                        get: { showAllContainers ? 1 : 0 },
                        set: { showAllContainers = $0 == 1 }
                    ))
                }
                RowIconButton(systemImage: "arrow.clockwise", help: "Refresh") {
                    Task { await service.refresh() }
                    stats.refreshDocker()
                }
            }

            if activeSection == .servers {
                serverList
            } else {
                containerList
            }
        }
        .onAppear {
            service.startMonitoring()
            stats.startMonitoring()
        }
        .onDisappear {
            service.stopMonitoring()
            stats.stopMonitoring()
        }
    }

    @ViewBuilder
    private var serverList: some View {
        if ports.isEmpty {
            EmptyListView(systemImage: "network.slash",
                          text: service.hasLoaded ? "No local servers running" : "Looking for local servers…")
        } else {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(Array(ports.enumerated()), id: \.element.id) { index, port in
                        PortRow(port: port, showsDivider: index > 0)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var containerList: some View {
        if containers.isEmpty {
            EmptyListView(systemImage: "shippingbox",
                          text: showAllContainers ? "No containers" : "No running containers")
        } else {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(Array(containers.enumerated()), id: \.element.id) { index, container in
                        ContainerRow(container: container, showsDivider: index > 0)
                    }
                }
            }
        }
    }
}

struct EmptyListView: View {
    let systemImage: String
    let text: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 22))
                .foregroundStyle(Color.white.opacity(0.4))
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum DevColors {
    static let web = Color(red: 0.20, green: 0.83, blue: 0.60)
    static let database = Color(red: 0.38, green: 0.65, blue: 0.98)
    static let other = Color(white: 0.45)
}

enum ByteFormat {
    static func string(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    /// Gigabytes with one decimal, without the unit.
    static func gigabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / 1_073_741_824)
    }
}

/// Shared layout for server and container rows: dot + port, title + tag, details, usage, buttons.
struct DevRowLayout<Buttons: View>: View {
    let dotColor: Color
    let port: String
    let title: String
    let tag: String?
    let details: String
    let usage: String?
    let help: String
    let showsDivider: Bool
    var dimmed = false
    @ViewBuilder let buttons: () -> Buttons
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
                    .shadow(color: dimmed ? .clear : dotColor, radius: 4)
                Text(port)
                    .font(.system(size: 16, weight: .medium).monospacedDigit())
                    .foregroundStyle(Color.white.opacity(dimmed ? 0.7 : 1))
            }
            .frame(width: 74, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    if let tag {
                        Text(tag)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.6))
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.08)))
                    }
                }
                Text(details)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help(help)

            Spacer(minLength: 8)

            if let usage {
                Text(usage)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .lineLimit(1)
                    .fixedSize()
            }

            HStack(spacing: 6, content: buttons)
        }
        .opacity(dimmed ? 0.6 : 1)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(isHovering ? 0.07 : 0))
        )
        .overlay(alignment: .top) {
            if showsDivider && !isHovering {
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(height: 1)
                    .padding(.horizontal, 10)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}

/// Stop button that needs a second click ("Stop … ?") within three seconds.
struct ConfirmStopButton: View {
    let confirmTitle: String
    let help: String
    let action: () -> Void
    @State private var isConfirming = false

    var body: some View {
        RowButton(
            title: isConfirming ? confirmTitle : "Stop",
            systemImage: "stop.fill",
            foreground: isConfirming ? .white : Color(red: 0.99, green: 0.65, blue: 0.65),
            background: isConfirming ? Color.red : Color.white.opacity(0.07)
        ) {
            if isConfirming {
                isConfirming = false
                action()
            } else {
                isConfirming = true
            }
        }
        .help(help)
        .animation(.easeOut(duration: 0.15), value: isConfirming)
        .task(id: isConfirming) {
            guard isConfirming else { return }
            try? await Task.sleep(for: .seconds(3))
            isConfirming = false
        }
    }
}

/// Stop takes two clicks, so a list that shifts while refreshing can't stop the wrong server.
struct PortRow: View {
    let port: ListeningPort
    let showsDivider: Bool
    @State private var copied = false

    private var dotColor: Color {
        switch port.kind {
        case .web: DevColors.web
        case .database: DevColors.database
        case .other: DevColors.other
        }
    }

    private var tag: String? {
        switch port.kind {
        case .database: "database"
        case .web: port.projectName == nil ? nil : port.command
        case .other: nil
        }
    }

    private var details: String {
        var parts = [port.command, "pid \(port.pid)"]
        if port.kind == .web, let directory = port.shortDirectory {
            parts.append(directory)
        } else if port.isLocalOnly {
            parts.append("localhost only")
        }
        return parts.joined(separator: " · ")
    }

    private var usage: String? {
        guard let cpu = port.cpu, let memory = port.memory else { return nil }
        return String(format: "CPU %.0f%%", cpu) + " · " + ByteFormat.string(memory)
    }

    var body: some View {
        DevRowLayout(
            dotColor: dotColor,
            port: String(port.port),
            title: port.projectName ?? port.command,
            tag: tag,
            details: details,
            usage: usage,
            help: port.directory ?? port.command,
            showsDivider: showsDivider,
            dimmed: port.kind == .other
        ) {
            if port.kind == .web {
                RowButton(title: "Open", systemImage: "arrow.up.right.square",
                          foreground: Color(red: 0.75, green: 0.86, blue: 1), background: Color.blue.opacity(0.22)) {
                    PortsService.shared.open(port)
                }
                .help("Open \(port.url.absoluteString)")
            }
            RowIconButton(systemImage: copied ? "checkmark" : "doc.on.doc", help: "Copy \(port.url.absoluteString)") {
                PortsService.shared.copyURL(port)
                copied = true
            }
            .task(id: copied) {
                guard copied else { return }
                try? await Task.sleep(for: .seconds(1.2))
                copied = false
            }
            ConfirmStopButton(confirmTitle: "Stop server?", help: "Quit \(port.command) (pid \(port.pid))") {
                PortsService.shared.kill(port)
            }
        }
    }
}

struct ContainerRow: View {
    let container: DockerContainer
    let showsDivider: Bool

    private var dotColor: Color {
        guard container.isRunning else { return DevColors.other }
        return container.isDatabase ? DevColors.database : DevColors.web
    }

    private var usage: String? {
        guard container.isRunning, let cpu = container.cpu, let memory = container.memory else { return nil }
        return "CPU \(cpu) · \(memory)"
    }

    var body: some View {
        DevRowLayout(
            dotColor: dotColor,
            port: container.hostPort.map(String.init) ?? "—",
            title: container.displayName,
            tag: container.project,
            details: "\(container.image) · \(container.status)",
            usage: usage,
            help: "\(container.name) (\(container.id))",
            showsDivider: showsDivider,
            dimmed: !container.isRunning
        ) {
            if container.isRunning {
                if let url = container.url, !container.isDatabase {
                    RowButton(title: "Open", systemImage: "arrow.up.right.square",
                              foreground: Color(red: 0.75, green: 0.86, blue: 1), background: Color.blue.opacity(0.22)) {
                        NSWorkspace.shared.open(url)
                    }
                    .help("Open \(url.absoluteString)")
                }
                RowButton(title: "Logs", systemImage: "text.alignleft",
                          foreground: Color.white.opacity(0.8), background: Color.white.opacity(0.07)) {
                    SystemStatsService.shared.showLogs(container)
                }
                .help("Follow logs in Terminal")
                ConfirmStopButton(confirmTitle: "Stop container?", help: "docker stop \(container.name)") {
                    SystemStatsService.shared.stop(container)
                }
            } else {
                RowButton(title: "Start", systemImage: "play.fill",
                          foreground: Color(red: 0.53, green: 0.94, blue: 0.67), background: Color.white.opacity(0.07)) {
                    SystemStatsService.shared.start(container)
                }
                .help("docker start \(container.name)")
            }
        }
    }
}

/// Small labelled pill button used in the Dev rows.
struct RowButton: View {
    let title: String
    let systemImage: String
    let foreground: Color
    let background: Color
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(background)
                    .brightness(isHovering ? 0.08 : 0)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// Square icon-only button matching `RowButton`.
struct RowIconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.75))
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(isHovering ? 0.14 : 0.07))
                )
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
    }
}

/// Compact segmented control styled for the black notch.
struct SegmentedToggle: View {
    let options: [String]
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { index in
                Button {
                    selection = index
                } label: {
                    Text(options[index])
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Color.white.opacity(selection == index ? 1 : 0.6))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.white.opacity(selection == index ? 0.18 : 0))
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.08)))
    }
}
