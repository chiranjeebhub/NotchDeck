import SwiftUI

extension AgentKind {
    var provider: AIProvider {
        switch self {
        case .claude: .claude
        case .codex: .codex
        }
    }
}

enum ActivityColors {
    static let working = Color(red: 0.48, green: 0.61, blue: 1)
    static let waiting = Color(red: 1, green: 0.62, blue: 0.26)
    static let success = Color(red: 0.24, green: 0.86, blue: 0.52)
    static let failure = Color(red: 1, green: 0.37, blue: 0.34)
}

/// The Claude or Codex mark used in rows and in the closed notch.
struct AgentGlyph: View {
    let kind: AgentKind
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(kind.provider.color)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: kind.provider.systemImage)
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.8))
            }
    }
}

/// A small spinning ring for things that are running.
struct SpinnerRing: View {
    var size: CGFloat = 12
    var color: Color = ActivityColors.working
    @State private var isSpinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.72)
            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(isSpinning ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: isSpinning)
            .onAppear { isSpinning = true }
    }
}

/// A glowing dot that pulses until whatever it marks is dealt with.
struct PulsingDot: View {
    var color: Color = ActivityColors.waiting
    @State private var isBright = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .shadow(color: color, radius: isBright ? 5 : 1)
            .opacity(isBright ? 1 : 0.45)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isBright)
            .onAppear { isBright = true }
    }
}

/// Small grey section title inside a Dev list ("RUNNING", "RECENT").
struct DevListSectionTitle: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 9.5, weight: .semibold))
            .kerning(0.6)
            .foregroundStyle(Color.white.opacity(0.45))
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Borderless row with a hairline divider, matching the other Dev lists.
struct ActivityRow<Leading: View, Content: View, Trailing: View>: View {
    let showsDivider: Bool
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let content: () -> Content
    @ViewBuilder let trailing: () -> Trailing
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            leading()
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2, content: content)
            Spacer(minLength: 8)
            HStack(spacing: 6, content: trailing)
        }
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

/// A setup message with a button, shown where a list has nothing yet.
struct SetupPromptView: View {
    let systemImage: String
    let text: String
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 20))
                .foregroundStyle(Color.white.opacity(0.4))
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.6))
                .multilineTextAlignment(.center)
            Button(buttonTitle, action: action)
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DevColors.database)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private enum RowButtons {
    static func terminal(_ app: String, action: @escaping () -> Void) -> some View {
        RowButton(title: app, systemImage: "arrow.up.forward.app",
                  foreground: Color.white.opacity(0.8), background: Color.white.opacity(0.07), action: action)
            .help("Show it in \(app)")
    }
}

// MARK: - Agents

struct AgentsListView: View {
    @ObservedObject private var agents = AgentsService.shared
    @Binding var listHeight: CGFloat

    var body: some View {
        if agents.sessions.isEmpty {
            Group {
                if agents.claudeConnected || !ClaudeHookInstaller.isClaudeInstalled {
                    EmptyListView(systemImage: "sparkles",
                                  text: "No agent sessions. Start Claude Code or Codex and they show up here.")
                } else {
                    SetupPromptView(systemImage: "sparkles",
                                    text: "See your Claude Code sessions here, and answer their permission prompts.",
                                    buttonTitle: "Connect Claude Code") {
                        ClaudeHookInstaller.install()
                        agents.refreshConnection()
                    }
                }
            }
            .onAppear { listHeight = 90 }
        } else {
            ScrollView(showsIndicators: false) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(spacing: 0) {
                        ForEach(Array(agents.sessions.enumerated()), id: \.element.id) { index, session in
                            AgentRow(session: session, now: context.date, showsDivider: index > 0)
                        }
                    }
                }
                .background(HeightReader(height: $listHeight))
            }
        }
    }
}

struct AgentRow: View {
    let session: AgentSession
    let now: Date
    let showsDivider: Bool

    private var statusColor: Color {
        switch session.status {
        case .waiting: ActivityColors.waiting
        case .working: ActivityColors.working
        case .done: ActivityColors.success
        case .ready: Color.white.opacity(0.5)
        }
    }

    private var statusWord: String {
        switch session.status {
        case .waiting: ""
        case .working: "Working"
        case .done: "Done"
        case .ready: "Ready"
        }
    }

    private var statusDetail: String {
        switch session.status {
        case .waiting:
            return session.detail
        case .working:
            let elapsed = session.turnStartedAt.map { DurationFormat.short(now.timeIntervalSince($0)) }
            return [session.detail, elapsed].compactMap { $0 }.joined(separator: " · ")
        case .done:
            return [session.detail, DurationFormat.ago(session.finishedAt ?? session.updatedAt, now: now)]
                .joined(separator: " · ")
        case .ready:
            return DurationFormat.ago(session.updatedAt, now: now)
        }
    }

    var body: some View {
        ActivityRow(showsDivider: showsDivider) {
            AgentGlyph(kind: session.kind)
        } content: {
            HStack(spacing: 6) {
                Text(session.projectName)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                Text(session.shortDirectory)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(0.4))
                    .lineLimit(1)
                    .truncationMode(.head)
                Text(session.kind.name)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(0.4))
                    .lineLimit(1)
                    .fixedSize()
            }
            HStack(spacing: 0) {
                if !statusWord.isEmpty {
                    Text(statusWord).foregroundStyle(statusColor)
                    Text(" · ").foregroundStyle(Color.white.opacity(0.45))
                }
                Text(statusDetail)
                    .foregroundStyle(session.status == .waiting ? statusColor : Color.white.opacity(0.45))
            }
            .font(.system(size: 10.5))
            .lineLimit(1)
            .truncationMode(.tail)
            if let request = session.request, request.canAnswer, let detail = request.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.06)))
                    .padding(.top, 3)
                    .help(detail)
            }
        } trailing: {
            if let request = session.request, request.canAnswer {
                RowButton(title: "Allow", systemImage: "checkmark", foreground: .black, background: ActivityColors.waiting) {
                    AgentsService.shared.answer(session, allow: true)
                }
                .help("Let \(session.kind.name) go ahead")
                RowButton(title: "Deny", systemImage: "xmark",
                          foreground: Color.white.opacity(0.8), background: Color.white.opacity(0.07)) {
                    AgentsService.shared.answer(session, allow: false)
                }
                .help("Tell \(session.kind.name) not to")
            }
            RowButtons.terminal(session.terminal.appName) {
                AgentsService.shared.openTerminal(session)
            }
        }
    }
}

// MARK: - Commands

struct CommandsListView: View {
    @ObservedObject private var commands = CommandsService.shared
    @Binding var listHeight: CGFloat
    @AppStorage(AppSettings.commandsMinimumSecondsKey) private var minimumSeconds = 10.0

    private var isShellConnected: Bool {
        commands.hasReceivedCommands || ShellIntegration.allCases.contains(where: \.isInstalled)
    }

    var body: some View {
        if commands.running.isEmpty && commands.recent.isEmpty {
            Group {
                if isShellConnected {
                    EmptyListView(systemImage: "terminal",
                                  text: "No long commands yet. Anything that runs \(Int(minimumSeconds))s or more shows up here.")
                } else {
                    SetupPromptView(systemImage: "terminal",
                                    text: "See builds and tests finish without watching the terminal.",
                                    buttonTitle: "Set Up Shell Integration") {
                        NotificationCenter.default.post(name: .openSettings, object: SettingsPage.dev)
                    }
                }
            }
            .onAppear { listHeight = 90 }
        } else {
            ScrollView(showsIndicators: false) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(spacing: 0) {
                        if !commands.running.isEmpty {
                            DevListSectionTitle(title: "Running")
                            ForEach(Array(commands.running.enumerated()), id: \.element.id) { index, command in
                                RunningCommandRow(command: command, now: context.date, showsDivider: index > 0)
                            }
                        }
                        if !commands.recent.isEmpty {
                            DevListSectionTitle(title: "Recent")
                                .padding(.top, commands.running.isEmpty ? 0 : 6)
                            ForEach(Array(commands.recent.enumerated()), id: \.element.id) { index, command in
                                FinishedCommandRow(command: command, now: context.date, showsDivider: index > 0)
                            }
                        }
                    }
                }
                .background(HeightReader(height: $listHeight))
            }
        }
    }
}

struct RunningCommandRow: View {
    let command: ShellCommand
    let now: Date
    let showsDivider: Bool

    private var elapsed: TimeInterval { now.timeIntervalSince(command.startedAt) }
    private var lastDuration: TimeInterval? { CommandsService.shared.lastDuration(of: command) }

    var body: some View {
        ActivityRow(showsDivider: showsDivider) {
            SpinnerRing(size: 14)
        } content: {
            Text(command.title)
                .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .help(command.command)
            Text(([command.shortDirectory, command.terminal.appName, "running \(DurationFormat.clock(elapsed))"]
                  + (lastDuration.map { ["last run took \(DurationFormat.clock($0))"] } ?? []))
                .joined(separator: " · "))
                .font(.system(size: 10.5))
                .foregroundStyle(Color.white.opacity(0.45))
                .lineLimit(1)
                .truncationMode(.middle)
            if let lastDuration, lastDuration > 0 {
                ProgressBar(fraction: min(elapsed / lastDuration, 0.97))
                    .frame(width: 200, height: 3)
                    .padding(.top, 3)
            }
        } trailing: {
            RowButtons.terminal(command.terminal.appName) {
                CommandsService.shared.focus(command)
            }
        }
    }
}

struct FinishedCommandRow: View {
    let command: ShellCommand
    let now: Date
    let showsDivider: Bool

    var body: some View {
        ActivityRow(showsDivider: showsDivider) {
            Image(systemName: command.succeeded ? "checkmark" : "xmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(command.succeeded ? ActivityColors.success : ActivityColors.failure)
        } content: {
            Text(command.title)
                .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .help(command.command)
            HStack(spacing: 0) {
                Text(command.shortDirectory + " · ")
                Text("exit \(command.exitStatus.map { String($0) } ?? "?")")
                    .foregroundStyle(command.succeeded ? Color.white.opacity(0.45) : ActivityColors.failure)
                Text(" · " + DurationFormat.ago(command.endedAt ?? now, now: now))
            }
            .font(.system(size: 10.5))
            .foregroundStyle(Color.white.opacity(0.45))
            .lineLimit(1)
            .truncationMode(.middle)
        } trailing: {
            Text(command.duration.map(DurationFormat.short) ?? "")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.55))
                .fixedSize()
            RowButton(title: "Re-run", systemImage: "arrow.clockwise",
                      foreground: Color.white.opacity(0.8), background: Color.white.opacity(0.07)) {
                CommandsService.shared.rerun(command)
            }
            .help(command.terminal.supportsTabControl ? "Run it again in the same tab, or in a new window if that tab is busy" : "Run it again in a new Terminal window")
            RowIconButton(systemImage: "arrow.up.forward.app", help: "Show it in \(command.terminal.appName)") {
                CommandsService.shared.focus(command)
            }
        }
    }
}

struct ProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.1))
                Capsule()
                    .fill(ActivityColors.working)
                    .frame(width: geometry.size.width * max(0, min(fraction, 1)))
            }
        }
    }
}

// MARK: - Closed notch

/// What the closed notch shows beside the camera, most important first.
enum ClosedActivity: Equatable {
    case agentWaiting(AgentSession)
    case flash(NotchFlash)
    case command(ShellCommand, others: Int)
    case music

    /// The Dev list the notch should open to, for things worth jumping to.
    var list: DevList? {
        switch self {
        case .agentWaiting: .agents
        case .flash(let flash): flash.list
        case .command, .music: nil
        }
    }
}

/// Status beside the camera for agents and commands. Music keeps its own `LiveActivityView`.
struct ClosedActivityView: View {
    let activity: ClosedActivity
    let sideWidth: CGFloat
    let height: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) { left }
                .frame(width: sideWidth, alignment: .leading)
            Spacer(minLength: 0)
            HStack(spacing: 6) { right }
                .frame(width: sideWidth, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .medium))
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private var left: some View {
        switch activity {
        case .agentWaiting(let session):
            AgentGlyph(kind: session.kind, size: 14)
            Text(session.projectName)
        case .flash(let flash):
            switch flash.source {
            case .agent(let kind): AgentGlyph(kind: kind, size: 14)
            case .command:
                Image(systemName: flash.succeeded ? "checkmark" : "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(flash.succeeded ? ActivityColors.success : ActivityColors.failure)
            }
            Text(flash.title)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
        case .command(let command, _):
            SpinnerRing(size: 11)
            Text(command.program.isEmpty ? command.title : command.program)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
        case .music:
            EmptyView()
        }
    }

    @ViewBuilder
    private var right: some View {
        switch activity {
        case .agentWaiting:
            Text("needs you")
                .foregroundStyle(ActivityColors.waiting)
            PulsingDot()
        case .flash(let flash):
            Text(flash.detail)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(flash.succeeded ? Color.white.opacity(0.6) : ActivityColors.failure)
        case .command(let command, let others):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(DurationFormat.clock(context.date.timeIntervalSince(command.startedAt))
                     + (others > 0 ? " +\(others)" : ""))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(ActivityColors.working)
            }
        case .music:
            EmptyView()
        }
    }
}
