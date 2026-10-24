import SwiftUI

extension AIProvider {
    var color: Color {
        switch self {
        case .claude: Color(red: 0.88, green: 0.54, blue: 0.43)
        case .codex: Color(red: 0.90, green: 0.91, blue: 0.92)
        }
    }

    var systemImage: String {
        switch self {
        case .claude: "asterisk"
        case .codex: "chevron.left.forwardslash.chevron.right"
        }
    }
}

enum AIColors {
    static let amber = Color(red: 0.96, green: 0.62, blue: 0.04)
}

extension UsageLimit.Pace {
    var label: String {
        switch self {
        case .plenty: "plenty left"
        case .onPace: "on pace"
        case .behind: "behind pace"
        case .usedUp: "used up"
        }
    }

    var color: Color {
        switch self {
        case .plenty: Color.white.opacity(0.5)
        case .onPace: DevColors.web
        case .behind, .usedUp: AIColors.amber
        }
    }
}

/// "Resets in 3h 38m · at 2:50 PM" and friends.
enum ResetFormat {
    static func countdown(to date: Date, now: Date) -> String {
        let minutes = max(Int(date.timeIntervalSince(now) / 60), 0)
        let days = minutes / 1440
        let hours = (minutes % 1440) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes % 60)m" }
        return "\(minutes)m"
    }

    static func clock(_ date: Date, now: Date) -> String {
        if Calendar.current.isDate(date, inSameDayAs: now) {
            return "at " + date.formatted(date: .omitted, time: .shortened)
        }
        if date.timeIntervalSince(now) < 6 * 86400 {
            return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    static func long(_ limit: UsageLimit, now: Date) -> String {
        guard let resetsAt = limit.resetsAt else { return "Fresh window" }
        return "Resets in \(countdown(to: resetsAt, now: now)) · \(clock(resetsAt, now: now))"
    }

    static func short(_ limit: UsageLimit, now: Date) -> String {
        guard let resetsAt = limit.resetsAt else { return "Fresh window" }
        return "Resets in \(countdown(to: resetsAt, now: now))"
    }

    /// "as of 2h ago" when the numbers are old enough to matter, otherwise nil.
    static func age(of usage: AIProviderUsage, now: Date) -> String? {
        let minutes = Int(now.timeIntervalSince(usage.asOf) / 60)
        guard minutes >= 10 else { return nil }
        if minutes < 60 { return "as of \(minutes)m ago" }
        if minutes < 1440 { return "as of \(minutes / 60)h ago" }
        return "as of \(minutes / 1440)d ago"
    }

    static func message(for state: AIProviderState) -> String? {
        switch state {
        case .loading: "Checking…"
        case .notInstalled: "Not installed on this Mac"
        case .needsSignIn(let text), .failed(let text): text
        case .ready: nil
        }
    }
}

/// Filled with what's left, in the provider's colour. The white tick is where you'd be
/// if you spread your usage evenly over the window: fill past the tick means you're fine.
struct UsageBar: View {
    let remaining: Double
    let expected: Double?
    let color: Color

    private func fraction(_ value: Double) -> CGFloat { CGFloat(min(max(value / 100, 0), 1)) }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.1))
                Capsule().fill(color)
                    .frame(width: geometry.size.width * fraction(remaining))
                if let expected {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.white)
                        .frame(width: 2, height: geometry.size.height + 8)
                        .offset(x: geometry.size.width * fraction(expected) - 1)
                }
            }
        }
    }
}

/// Starts and stops AIUsageService while the view is on screen.
private struct AIUsageMonitoring: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onAppear { AIUsageService.shared.startMonitoring() }
            .onDisappear { AIUsageService.shared.stopMonitoring() }
    }
}

extension View {
    func monitorsAIUsage() -> some View { modifier(AIUsageMonitoring()) }
}

// MARK: - Dev list

/// The Dev tab's "AI limits" list: a header per provider, then a row per limit.
struct AILimitsListView: View {
    @ObservedObject private var ai = AIUsageService.shared
    @Binding var listHeight: CGFloat
    // Read so the list redraws when a provider is turned on or off.
    @AppStorage(AppSettings.aiShowClaudeKey) private var showClaude = true
    @AppStorage(AppSettings.aiShowCodexKey) private var showCodex = true

    var body: some View {
        Group {
            if ai.enabledProviders.isEmpty {
                EmptyListView(systemImage: "sparkles", text: "Claude and Codex are turned off in Settings → AI limits")
                    .onAppear { listHeight = 90 }
            } else {
                ScrollView(showsIndicators: false) {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(ai.enabledProviders) { provider in
                                section(provider, now: context.date)
                            }
                        }
                    }
                    .background(HeightReader(height: $listHeight))
                }
            }
        }
        .monitorsAIUsage()
    }

    @ViewBuilder
    private func section(_ provider: AIProvider, now: Date) -> some View {
        let state = ai.state(for: provider)
        AIProviderHeader(provider: provider, plan: state.usage?.plan)
            .padding(.horizontal, 10)
            .padding(.top, 4)
        if let usage = state.usage {
            let age = ResetFormat.age(of: usage, now: now)
            VStack(spacing: 0) {
                ForEach(Array(usage.limits.enumerated()), id: \.element.id) { index, limit in
                    AILimitRow(provider: provider, limit: limit, age: age, now: now, showsDivider: index > 0)
                }
            }
        } else if let message = ResetFormat.message(for: state) {
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.55))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
    }
}

/// "✳ CLAUDE · MAX"
struct AIProviderHeader: View {
    let provider: AIProvider
    let plan: String?

    var body: some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(provider.color)
                .frame(width: 15, height: 15)
                .overlay {
                    Image(systemName: provider.systemImage)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.black.opacity(0.8))
                }
            Text(([provider.name] + (plan.map { [$0] } ?? [])).joined(separator: " · ").uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(Color.white.opacity(0.55))
        }
    }
}

struct AILimitRow: View {
    let provider: AIProvider
    let limit: UsageLimit
    let age: String?
    let now: Date
    let showsDivider: Bool

    var body: some View {
        let pace = limit.pace(at: now)
        DevRowLayout(
            dotColor: provider.color,
            port: String(format: "%.0f%%", limit.remaining.rounded(.down)),
            title: limit.title,
            tag: limit.tag,
            details: ([ResetFormat.long(limit, now: now)] + (age.map { [$0] } ?? [])).joined(separator: " · "),
            usage: nil,
            help: "\(provider.name) \(limit.title): \(Int(limit.remaining))% left",
            showsDivider: showsDivider,
            dimmed: pace == .usedUp
        ) {
            UsageBar(remaining: limit.remaining, expected: limit.expectedRemaining(at: now), color: provider.color)
                .frame(width: 180, height: 5)
            Text(pace.label)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(pace.color)
                .frame(width: 80, alignment: .trailing)
        }
    }
}

// MARK: - Stats strip

/// Stats strip slot: Claude's 5-hour session, with the weekly limit underneath.
struct ClaudeStatColumn: View {
    @ObservedObject private var ai = AIUsageService.shared
    @AppStorage(AppSettings.aiShowClaudeKey) private var showClaude = true

    var body: some View {
        StatColumn(label: "Claude", detail: "Session") {
            if !showClaude {
                PlaceholderValue(text: "Turned off")
            } else if let limits = ai.claude.usage?.limits,
                      let session = limits.first(where: { $0.id == "claude.five_hour" }) ?? limits.first {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    VStack(alignment: .leading, spacing: 0) {
                        BigValue(value: String(format: "%.0f", session.remaining.rounded(.down)), unit: "% left")
                        UsageBar(remaining: session.remaining,
                                 expected: session.expectedRemaining(at: context.date),
                                 color: AIProvider.claude.color)
                            .frame(height: 5)
                            .padding(.top, 6)
                        Text(legend(session: session, weekly: limits.first { $0.id == "claude.seven_day" && $0 != session }, now: context.date))
                            .font(.system(size: 9.5))
                            .foregroundStyle(Color.white.opacity(0.45))
                            .lineLimit(1)
                            .padding(.top, 3)
                    }
                }
            } else {
                PlaceholderValue(text: placeholder)
                    .lineLimit(1)
                    .help(ResetFormat.message(for: ai.claude) ?? "")
            }
        }
        .monitorsAIUsage()
    }

    private var placeholder: String {
        switch ai.claude {
        case .loading: "Checking…"
        case .notInstalled: "Not installed"
        case .needsSignIn: "Not signed in"
        case .failed: "Unavailable"
        case .ready: "No limits"
        }
    }

    private func legend(session: UsageLimit, weekly: UsageLimit?, now: Date) -> String {
        var parts = [ResetFormat.short(session, now: now)]
        if let weekly { parts.append("Weekly \(Int(weekly.remaining.rounded(.down)))%") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Home widget

/// Home widget: every limit as a name, what's left, a bar and the reset time.
struct AILimitsWidgetView: View {
    @ObservedObject private var ai = AIUsageService.shared
    @AppStorage(AppSettings.aiShowClaudeKey) private var showClaude = true
    @AppStorage(AppSettings.aiShowCodexKey) private var showCodex = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AI limits")
                .font(.system(size: 13, weight: .semibold))
            if ai.enabledProviders.isEmpty {
                message("Turn on Claude or Codex in Settings → AI limits.")
            } else {
                ScrollView(showsIndicators: false) {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(ai.enabledProviders) { provider in
                                rows(provider, now: context.date)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .monitorsAIUsage()
    }

    @ViewBuilder
    private func rows(_ provider: AIProvider, now: Date) -> some View {
        let state = ai.state(for: provider)
        if let usage = state.usage {
            ForEach(usage.limits) { limit in
                row(provider, limit, now: now)
            }
        } else if let text = ResetFormat.message(for: state) {
            message("\(provider.name): \(text)")
        }
    }

    private func row(_ provider: AIProvider, _ limit: UsageLimit, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(provider.color).frame(width: 7, height: 7)
                Text("\(provider.name) \(limit.title.prefix(1).lowercased() + limit.title.dropFirst())")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 6)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(String(format: "%.0f%%", limit.remaining.rounded(.down)))
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                    Text("left")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.white.opacity(0.45))
                }
            }
            UsageBar(remaining: limit.remaining, expected: limit.expectedRemaining(at: now), color: provider.color)
                .frame(height: 4)
            Text(ResetFormat.short(limit, now: now))
                .font(.system(size: 9.5))
                .foregroundStyle(Color.white.opacity(0.45))
        }
        .padding(.top, 2)
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Color.white.opacity(0.55))
            .fixedSize(horizontal: false, vertical: true)
    }
}
