import Foundation
import Security

/// One rate limit of an AI tool, such as Claude's 5-hour session or Codex's weekly limit.
struct UsageLimit: Identifiable, Equatable, Codable {
    let id: String
    let title: String
    let tag: String?
    /// 0–100, how much of the limit is still available.
    let remaining: Double
    let resetsAt: Date?
    /// Length of the window the limit covers, used to work out the pace.
    let window: TimeInterval?

    /// How much would be left now if usage were spread evenly over the window (0–100).
    func expectedRemaining(at now: Date = .now) -> Double? {
        guard let resetsAt, let window, window > 0 else { return nil }
        let left = min(max(resetsAt.timeIntervalSince(now), 0), window)
        return left / window * 100
    }

    enum Pace: Equatable {
        case plenty, onPace, behind, usedUp
    }

    func pace(at now: Date = .now) -> Pace {
        if remaining <= 0.5 { return .usedUp }
        if remaining >= 95 { return .plenty }
        guard let expected = expectedRemaining(at: now) else { return .onPace }
        return remaining + 5 >= expected ? .onPace : .behind
    }
}

struct AIProviderUsage: Equatable, Codable {
    var plan: String?
    var limits: [UsageLimit]
    /// When the numbers were recorded. Codex only records them while you use it.
    var asOf: Date
}

enum AIProviderState: Equatable {
    case loading
    case notInstalled
    /// Signed out or the saved sign-in expired; the tool itself needs to be opened.
    case needsSignIn(String)
    case failed(String)
    case ready(AIProviderUsage)

    var usage: AIProviderUsage? {
        if case .ready(let usage) = self { return usage }
        return nil
    }
}

enum AIProvider: String, CaseIterable, Identifiable {
    case claude, codex

    var id: String { rawValue }

    var name: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }
}

/// Usage limits for Claude (Claude Code's sign-in) and Codex (its local session logs).
/// Only refreshes while something on screen shows it, since reading Claude's sign-in
/// asks for keychain access the first time.
@MainActor
final class AIUsageService: ObservableObject {
    static let shared = AIUsageService()

    @Published private(set) var claude: AIProviderState = .loading
    @Published private(set) var codex: AIProviderState = .loading
    @Published private(set) var lastRefresh: Date?

    private var watchers = 0
    private var refreshTask: Task<Void, Never>?
    private var isRefreshing = false

    private static let refreshInterval: Duration = .seconds(300)
    /// Opening the notch refreshes at most this often.
    private static let minimumGap: TimeInterval = 60

    func state(for provider: AIProvider) -> AIProviderState {
        switch provider {
        case .claude: claude
        case .codex: codex
        }
    }

    /// Providers turned on in Settings → AI limits.
    var enabledProviders: [AIProvider] {
        AIProvider.allCases.filter { AppSettings.isAIProviderEnabled($0) }
    }

    /// Every limit that's ready to show, with its provider.
    var visibleLimits: [(provider: AIProvider, limit: UsageLimit)] {
        enabledProviders.flatMap { provider in
            (state(for: provider).usage?.limits ?? []).map { (provider, $0) }
        }
    }

    func startMonitoring() {
        watchers += 1
        if let lastRefresh, Date.now.timeIntervalSince(lastRefresh) < Self.minimumGap {
            // Recently refreshed.
        } else {
            refresh()
        }
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.refreshInterval)
                self?.refresh()
            }
        }
    }

    func stopMonitoring() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        refreshTask?.cancel()
        refreshTask = nil
    }

    // Anthropic rate-limits the usage endpoint, so the last answer is kept on disk and
    // Claude is asked at most every few minutes, even across relaunches.
    private static let claudeCacheKey = "aiClaudeCache"
    private static let claudeNextFetchKey = "aiClaudeNextFetch"
    private static let claudeGap: TimeInterval = 300

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.claudeCacheKey),
           let usage = try? JSONDecoder().decode(AIProviderUsage.self, from: data) {
            claude = .ready(usage)
        }
    }

    private var claudeNextFetch: Date {
        get { UserDefaults.standard.object(forKey: Self.claudeNextFetchKey) as? Date ?? .distantPast }
        set { UserDefaults.standard.set(newValue, forKey: Self.claudeNextFetchKey) }
    }

    /// `force` (Refresh Now) skips the usual gap, but still waits out a rate limit.
    func refresh(force: Bool = false) {
        guard !isRefreshing else { return }
        isRefreshing = true
        let wantsClaude = AppSettings.isAIProviderEnabled(.claude)
            && (Date.now >= claudeNextFetch || (force && !claudeRateLimited))
        let wantsCodex = AppSettings.isAIProviderEnabled(.codex)
        Task { [weak self] in
            async let claudeResult: ClaudeUsage.Result? = wantsClaude ? ClaudeUsage.fetch() : nil
            async let codexState: AIProviderState? = wantsCodex
                ? Task.detached(priority: .utility) { CodexUsage.read() }.value
                : nil
            let (newClaude, newCodex) = await (claudeResult, codexState)
            guard let self else { return }
            if let newClaude { self.apply(newClaude) }
            if let newCodex, newCodex != self.codex { self.codex = newCodex }
            self.lastRefresh = .now
            self.isRefreshing = false
        }
    }

    /// Rate-limit waits are always longer than the usual gap, so a later next fetch means one is running.
    private var claudeRateLimited: Bool { claudeNextFetch.timeIntervalSinceNow > Self.claudeGap }

    private func apply(_ result: ClaudeUsage.Result) {
        switch result.state {
        case .ready(let usage):
            claudeNextFetch = .now.addingTimeInterval(Self.claudeGap)
            if let data = try? JSONEncoder().encode(usage) {
                UserDefaults.standard.set(data, forKey: Self.claudeCacheKey)
            }
            claude = result.state
        case .failed:
            claudeNextFetch = .now.addingTimeInterval(result.retryAfter ?? 120)
            // Keep showing the last numbers; their age is shown once they're old.
            if claude.usage == nil, claude != result.state { claude = result.state }
        default:
            claudeNextFetch = .now.addingTimeInterval(Self.claudeGap)
            UserDefaults.standard.removeObject(forKey: Self.claudeCacheKey)
            if claude != result.state { claude = result.state }
        }
    }
}

// MARK: - Claude

/// Reads the sign-in Claude Code keeps in the keychain and asks Anthropic's usage endpoint
/// (the one behind Claude Code's /usage) for the current limits. NotchDeck never refreshes
/// or changes the sign-in; if it has expired, using Claude Code renews it.
enum ClaudeUsage {
    private static let keychainService = "Claude Code-credentials"
    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    private struct Credentials {
        let accessToken: String
        let expiresAt: Date?
        let plan: String?
    }

    struct Result {
        let state: AIProviderState
        /// Set when Anthropic asked us to slow down.
        var retryAfter: TimeInterval?
    }

    static func fetch() async -> Result {
        let (state, retryAfter) = await request()
        return Result(state: state, retryAfter: retryAfter)
    }

    private static func request() async -> (AIProviderState, TimeInterval?) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude").path) else {
            return (.notInstalled, nil)
        }
        guard let credentials = await Task.detached(priority: .utility, operation: { readCredentials() }).value else {
            return (.needsSignIn("Sign in to Claude Code, then allow NotchDeck to read its sign-in."), nil)
        }
        if let expiresAt = credentials.expiresAt, expiresAt < .now {
            return (.needsSignIn("Claude Code's sign-in has expired. Open Claude Code to renew it."), nil)
        }

        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 || status == 403 {
                return (.needsSignIn("Claude Code's sign-in has expired. Open Claude Code to renew it."), nil)
            }
            if status == 429 {
                let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")
                let wait = max(header.flatMap(TimeInterval.init) ?? 900, 360)
                return (.failed("Claude is limiting how often usage can be checked. Trying again in \(Int(wait / 60)) min."), wait)
            }
            guard status == 200,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return (.failed("Claude usage isn't available right now (HTTP \(status))."), nil)
            }
            return (.ready(AIProviderUsage(plan: credentials.plan, limits: limits(from: object), asOf: .now)), nil)
        } catch {
            return (.failed("Couldn't reach Claude: \(error.localizedDescription)"), nil)
        }
    }

    /// `five_hour`, `seven_day` and `seven_day_<model>` entries, each `{utilization, resets_at}`.
    static func limits(from object: [String: Any]) -> [UsageLimit] {
        var limits: [UsageLimit] = []
        for key in object.keys.sorted(by: order) {
            guard let entry = object[key] as? [String: Any],
                  let utilization = (entry["utilization"] as? NSNumber)?.doubleValue else { continue }
            let resetsAt = (entry["resets_at"] as? String).flatMap(parseDate)
            let title: String
            var tag: String?
            let window: TimeInterval?
            switch key {
            case "five_hour":
                title = "Session"
                tag = "5-hour window"
                window = 5 * 3600
            case "seven_day":
                title = "Weekly"
                tag = "all models"
                window = 7 * 86400
            case let other where other.hasPrefix("seven_day_"):
                let model = other.dropFirst("seven_day_".count)
                    .split(separator: "_").map { $0.capitalized }.joined(separator: " ")
                title = "Weekly · \(model)"
                window = 7 * 86400
            default:
                continue
            }
            limits.append(UsageLimit(id: "claude.\(key)", title: title, tag: tag,
                                     remaining: max(0, min(100, 100 - utilization)),
                                     resetsAt: resetsAt, window: window))
        }
        return limits
    }

    /// Session first, then weekly, then per-model weekly limits.
    private static func order(_ a: String, _ b: String) -> Bool {
        func rank(_ key: String) -> Int {
            switch key {
            case "five_hour": 0
            case "seven_day": 1
            default: 2
            }
        }
        return (rank(a), a) < (rank(b), b)
    }

    private static func parseDate(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    /// The first read shows macOS's "allow access" prompt for Claude Code's keychain item.
    private static func readCredentials() -> Credentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        let expiresAt = (oauth["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        let plan = (oauth["subscriptionType"] as? String).map { $0.capitalized }
        return Credentials(accessToken: token, expiresAt: expiresAt, plan: plan)
    }
}

// MARK: - Codex

/// Codex writes its rate limits into the session logs under ~/.codex/sessions while you use it,
/// so the newest entry is the latest known state.
enum CodexUsage {
    /// How many of the newest session files to look through. Most sessions record no limits,
    /// so this goes back a long way; files without a "codex" limit are skipped with a byte search.
    private static let filesToScan = 2000
    private static let marker = Data("\"limit_id\":\"codex\"".utf8)

    static func read() -> AIProviderState {
        let sessions = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        guard FileManager.default.fileExists(atPath: sessions.path) else { return .notInstalled }

        for file in newestSessionFiles(in: sessions) {
            guard let usage = latestUsage(in: file) else { continue }
            // Newer Codex versions often log no limits; numbers older than the weekly window say nothing now.
            if Date.now.timeIntervalSince(usage.asOf) > 7 * 86400 {
                let date = usage.asOf.formatted(.dateTime.month(.abbreviated).day())
                return .failed("Codex hasn't recorded its limits since \(date).")
            }
            return .ready(usage)
        }
        return .failed("No usage recorded yet. Use Codex once and it will appear here.")
    }

    private static func newestSessionFiles(in directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return [] }
        var files: [(URL, Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            files.append((url, date))
        }
        return files.sorted { $0.1 > $1.1 }.prefix(filesToScan).map(\.0)
    }

    /// The last line in the file with a non-null "codex" rate limit.
    private static func latestUsage(in file: URL) -> AIProviderUsage? {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe),
              data.range(of: marker) != nil else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n").reversed()
        where line.contains("\"rate_limits\"") && !line.contains("\"rate_limits\":null") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            let payload = object["payload"] as? [String: Any] ?? object
            guard let limits = payload["rate_limits"] as? [String: Any],
                  (limits["limit_id"] as? String ?? "codex") == "codex" else { continue }
            let parsed = [("primary", limits["primary"]), ("secondary", limits["secondary"])].compactMap { key, value in
                (value as? [String: Any]).flatMap { limit(key: key, $0) }
            }
            guard !parsed.isEmpty else { continue }
            let timestamp = (object["timestamp"] as? String).flatMap { text -> Date? in
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
            }
            let asOf = timestamp
                ?? (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                ?? .now
            return AIProviderUsage(plan: (limits["plan_type"] as? String)?.capitalized, limits: parsed, asOf: asOf)
        }
        return nil
    }

    private static func limit(key: String, _ entry: [String: Any]) -> UsageLimit? {
        guard let used = (entry["used_percent"] as? NSNumber)?.doubleValue else { return nil }
        let minutes = (entry["window_minutes"] as? NSNumber)?.doubleValue
        var resetsAt = (entry["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        if resetsAt == nil, let seconds = (entry["resets_in_seconds"] as? NSNumber)?.doubleValue {
            resetsAt = Date.now.addingTimeInterval(seconds)
        }
        // Once the window has reset, nothing has been used in the new one yet.
        let hasReset = resetsAt.map { $0 < .now } ?? false
        let title: String
        var tag: String?
        switch minutes {
        case 10080?: title = "Weekly"
        case let value? where value < 1440:
            title = "Session"
            tag = "\(Int(value / 60))-hour window"
        case let value?: title = "\(Int(value / 1440))-day"
        case nil: title = key == "primary" ? "Session" : "Weekly"
        }
        return UsageLimit(id: "codex.\(key)", title: title, tag: tag,
                          remaining: hasReset ? 100 : max(0, min(100, 100 - used)),
                          resetsAt: hasReset ? nil : resetsAt,
                          window: minutes.map { $0 * 60 })
    }
}
