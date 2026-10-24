import SwiftUI

/// Dev tab: system stats on top, then local servers, Docker containers, top processes or AI limits.
/// What it shows is chosen in Settings → Dev.
struct DevView: View {
    @ObservedObject private var service = PortsService.shared
    @ObservedObject private var stats = SystemStatsService.shared
    @ObservedObject private var ai = AIUsageService.shared
    @AppStorage(AppSettings.devShowAllPortsKey) private var showAll = false
    @AppStorage("devSection") private var section = DevList.servers
    @AppStorage("devShowAllContainers") private var showAllContainers = false
    @AppStorage(AppSettings.devStatSlotsKey) private var slotsText = StatKind.encode(StatKind.defaultSlots)
    @AppStorage(AppSettings.devListsKey) private var listsText = DevListOrder.defaultValue.encoded
    /// Reports the height the tab needs, so the notch can shrink to fit a short list.
    private let onContentHeightChange: (CGFloat) -> Void
    @State private var topHeight: CGFloat = 0
    @State private var listHeight: CGFloat = 0

    private static let spacing: CGFloat = 10
    /// Height given to the "No local servers" message.
    private static let emptyListHeight: CGFloat = 90

    init(onContentHeightChange: @escaping (CGFloat) -> Void = { _ in }) {
        self.onContentHeightChange = onContentHeightChange
    }

    private var ports: [ListeningPort] { service.visiblePorts(showAll: showAll) }
    private var dockerAvailable: Bool {
        if case .running = stats.docker { return true }
        return false
    }
    private var containers: [DockerContainer] {
        let all = stats.docker.containers
        return showAllContainers ? all : all.filter(\.isRunning)
    }
    private var hasStats: Bool { StatKind.slots(from: slotsText).contains { $0 != .none } }
    /// Lists turned on in Settings, without Containers while Docker isn't running.
    private var lists: [DevList] {
        DevListOrder(listsText).enabled.filter { $0 != .containers || dockerAvailable }
    }
    private var activeList: DevList? { lists.contains(section) ? section : lists.first }

    private func count(of list: DevList) -> Int {
        switch list {
        case .servers: ports.count
        case .containers: stats.docker.containers.count
        case .processes: stats.processes.count
        case .ai: ai.visibleLimits.count
        }
    }

    /// "Servers  4"; AI limits leaves the count out until it has loaded.
    private func switcherTitle(_ list: DevList) -> String {
        let count = count(of: list)
        return list == .ai && count == 0 ? list.shortTitle : "\(list.shortTitle)  \(count)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            // Stats and the list switcher; measured to work out how tall the tab needs to be.
            VStack(alignment: .leading, spacing: Self.spacing) {
                if hasStats {
                    StatsStripView()
                }
                if let activeList {
                    listControls(activeList)
                }
            }
            .background(HeightReader(height: $topHeight))

            Group {
                switch activeList {
                case .servers: serverList
                case .containers: containerList
                case .processes: processList
                case .ai: AILimitsListView(listHeight: $listHeight)
                case nil:
                    if !hasStats { nothingToShow }
                }
            }
            // Never taller than the rows, so a short list leaves no empty space.
            .frame(maxHeight: activeList == nil && hasStats ? 0 : listHeight, alignment: .top)

            Spacer(minLength: 0)
        }
        .onChange(of: topHeight + listHeight, initial: true) { _, _ in
            reportHeight()
        }
        .onChange(of: activeList) { _, _ in
            reportHeight()
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

    private func reportHeight() {
        let list = activeList == nil && hasStats ? 0 : listHeight
        onContentHeightChange(topHeight + (list > 0 ? Self.spacing + list : 0))
    }

    private func listControls(_ activeList: DevList) -> some View {
        HStack(spacing: 8) {
            SegmentedToggle(
                options: lists.map(switcherTitle),
                selection: Binding(
                    get: { lists.firstIndex(of: activeList) ?? 0 },
                    set: { section = lists[$0] }
                )
            )
            Spacer()
            switch activeList {
            case .servers:
                SegmentedToggle(options: ["Dev", "All ports"], selection: Binding(
                    get: { showAll ? 1 : 0 },
                    set: { showAll = $0 == 1 }
                ))
            case .containers:
                SegmentedToggle(options: ["Running", "All"], selection: Binding(
                    get: { showAllContainers ? 1 : 0 },
                    set: { showAllContainers = $0 == 1 }
                ))
            case .processes, .ai:
                EmptyView()
            }
            RowIconButton(systemImage: "arrow.clockwise", help: "Refresh") {
                if activeList == .ai {
                    ai.refresh(force: true)
                } else {
                    Task { await service.refresh() }
                    stats.refreshDocker()
                    stats.refreshProcesses()
                }
            }
        }
    }

    private var nothingToShow: some View {
        VStack(spacing: 8) {
            Text("Nothing is turned on for the Dev tab.")
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.6))
            Button("Open Settings") {
                NotificationCenter.default.post(name: .openSettings, object: SettingsPage.dev)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(DevColors.database)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { listHeight = Self.emptyListHeight }
    }

    @ViewBuilder
    private var processList: some View {
        if stats.processes.isEmpty {
            EmptyListView(systemImage: "cpu", text: "Looking for busy apps…")
                .onAppear { listHeight = Self.emptyListHeight }
        } else {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(Array(stats.processes.enumerated()), id: \.element.id) { index, process in
                        ProcessRow(process: process, showsDivider: index > 0)
                    }
                }
                .background(HeightReader(height: $listHeight))
            }
        }
    }

    @ViewBuilder
    private var serverList: some View {
        if ports.isEmpty {
            EmptyListView(systemImage: "network.slash",
                          text: service.hasLoaded ? "No local servers running" : "Looking for local servers…")
                .onAppear { listHeight = Self.emptyListHeight }
        } else {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(Array(ports.enumerated()), id: \.element.id) { index, port in
                        PortRow(port: port, showsDivider: index > 0)
                    }
                }
                .background(HeightReader(height: $listHeight))
            }
        }
    }

    @ViewBuilder
    private var containerList: some View {
        if containers.isEmpty {
            EmptyListView(systemImage: "shippingbox",
                          text: showAllContainers ? "No containers" : "No running containers")
                .onAppear { listHeight = Self.emptyListHeight }
        } else {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(Array(containers.enumerated()), id: \.element.id) { index, container in
                        ContainerRow(container: container, showsDivider: index > 0)
                    }
                }
                .background(HeightReader(height: $listHeight))
            }
        }
    }
}

/// Writes the height of the view it is the background of into `height`.
struct HeightReader: View {
    @Binding var height: CGFloat

    var body: some View {
        GeometryReader { geometry in
            Color.clear
                .onAppear { height = geometry.size.height }
                .onChange(of: geometry.size.height) { _, newHeight in height = newHeight }
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

    /// Disk sizes use decimal units, like Finder.
    static func disk(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func rate(_ bytesPerSecond: Double) -> (value: String, unit: String) {
        switch bytesPerSecond {
        case ..<1_000: (String(format: "%.0f", bytesPerSecond), "B/s")
        case ..<1_000_000: (String(format: "%.0f", bytesPerSecond / 1_000), "KB/s")
        case ..<10_000_000: (String(format: "%.1f", bytesPerSecond / 1_000_000), "MB/s")
        default: (String(format: "%.0f", bytesPerSecond / 1_000_000), "MB/s")
        }
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

/// Stop button that needs a second click ("Stop … ?") within three seconds,
/// unless confirmation is turned off in Settings → Dev.
struct ConfirmStopButton: View {
    let confirmTitle: String
    let help: String
    let action: () -> Void
    @AppStorage(AppSettings.devConfirmStopKey) private var asksToConfirm = true
    @State private var isConfirming = false

    var body: some View {
        RowButton(
            title: isConfirming ? confirmTitle : "Stop",
            systemImage: "stop.fill",
            foreground: isConfirming ? .white : Color(red: 0.99, green: 0.65, blue: 0.65),
            background: isConfirming ? Color.red : Color.white.opacity(0.07)
        ) {
            if isConfirming || !asksToConfirm {
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
    @AppStorage(AppSettings.devShowUsageKey) private var showUsage = true
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
        guard showUsage, let cpu = port.cpu, let memory = port.memory else { return nil }
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
    @AppStorage(AppSettings.devShowUsageKey) private var showUsage = true

    private var dotColor: Color {
        guard container.isRunning else { return DevColors.other }
        return container.isDatabase ? DevColors.database : DevColors.web
    }

    private var usage: String? {
        guard showUsage, container.isRunning, let cpu = container.cpu, let memory = container.memory else { return nil }
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

struct ProcessRow: View {
    let process: TopProcess
    let showsDivider: Bool
    @AppStorage(AppSettings.devShowUsageKey) private var showUsage = true

    private var dotColor: Color {
        process.cpu >= 50 ? Color(red: 0.96, green: 0.62, blue: 0.04) : DevColors.web
    }

    var body: some View {
        DevRowLayout(
            dotColor: dotColor,
            port: String(format: "%.0f%%", process.cpu),
            title: process.name,
            tag: nil,
            details: "pid \(process.pid)",
            usage: showUsage ? ByteFormat.string(process.memory) : nil,
            help: "\(process.name) (pid \(process.pid))",
            showsDivider: showsDivider
        ) {
            ConfirmStopButton(confirmTitle: "Quit app?", help: "Quit \(process.name) (pid \(process.pid))") {
                SystemStatsService.shared.quit(process)
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
