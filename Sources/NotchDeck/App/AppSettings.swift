import Foundation

/// UserDefaults keys shared by `@AppStorage` in the settings UI and by the services.
enum AppSettings {
    static let preferredPlayerKey = "preferredPlayer"
    static let showOnAllDisplaysKey = "showOnAllDisplays"
    static let hapticFeedbackKey = "hapticFeedback"
    static let openOnClickKey = "openOnClick"
    static let hoverDelayKey = "hoverDelay"
    static let devShowAllPortsKey = "devShowAllPorts"

    // Appearance
    static let showLiveActivityKey = "showLiveActivity"
    static let showTabLabelsKey = "showTabLabels"

    // Tabs
    static let showHomeTabKey = "showHomeTab"
    static let showTrayTabKey = "showTrayTab"
    static let showDevTabKey = "showDevTab"

    // Home
    static let homeLeftWidgetKey = "homeLeftWidget"
    static let homeRightWidgetKey = "homeRightWidget"
    static let homeNotesKey = "homeNotes"
    static let calendarModeKey = "calendarMode"
    /// Newline-separated identifiers of calendars the Calendar widget leaves out.
    static let hiddenCalendarsKey = "hiddenCalendars"

    // Tray
    static let trayShowAirDropKey = "trayShowAirDrop"
    static let trayCopyFilesKey = "trayCopyFiles"

    // Dev
    /// Comma-separated `StatKind` raw values, one per slot of the stats strip.
    static let devStatSlotsKey = "devStatSlots"
    /// Comma-separated `DevList` raw values in display order; a leading "-" means turned off.
    static let devListsKey = "devLists"
    static let devShowUsageKey = "devShowUsage"
    static let devConfirmStopKey = "devConfirmStop"

    // AI limits
    static let aiShowClaudeKey = "aiShowClaude"
    static let aiShowCodexKey = "aiShowCodex"
    /// Show how much of each limit is used (true) or how much is left (false).
    static let aiShowUsedKey = "aiShowUsed"

    /// The app was called NotchUtility before; carry its settings and tray over once.
    static func migrateFromNotchUtility() {
        let defaults = UserDefaults.standard
        let marker = "migratedFromNotchUtility"
        guard !defaults.bool(forKey: marker) else { return }
        defaults.set(true, forKey: marker)
        guard let old = UserDefaults(suiteName: "com.chiranjeebhub.NotchUtility")?
            .persistentDomain(forName: "com.chiranjeebhub.NotchUtility") else { return }
        for (key, value) in old where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            preferredPlayerKey: "auto",
            showOnAllDisplaysKey: true,
            hapticFeedbackKey: true,
            openOnClickKey: false,
            hoverDelayKey: 0.15,
            devShowAllPortsKey: false,
            showLiveActivityKey: true,
            showTabLabelsKey: true,
            showHomeTabKey: true,
            showTrayTabKey: true,
            showDevTabKey: true,
            homeLeftWidgetKey: HomeWidget.nowPlaying.rawValue,
            homeRightWidgetKey: HomeWidget.calendar.rawValue,
            calendarModeKey: "day",
            hiddenCalendarsKey: "",
            trayShowAirDropKey: true,
            trayCopyFilesKey: false,
            devStatSlotsKey: StatKind.encode(StatKind.defaultSlots),
            devListsKey: DevListOrder.defaultValue.encoded,
            devShowUsageKey: true,
            devConfirmStopKey: true,
            aiShowClaudeKey: true,
            aiShowCodexKey: true,
            aiShowUsedKey: true,
        ])
    }

    private static var defaults: UserDefaults { .standard }

    static var showOnAllDisplays: Bool { defaults.bool(forKey: showOnAllDisplaysKey) }
    static var hapticFeedback: Bool { defaults.bool(forKey: hapticFeedbackKey) }
    static var openOnClick: Bool { defaults.bool(forKey: openOnClickKey) }
    /// Seconds the cursor must rest on the notch before it opens (hover mode).
    static var hoverDelay: Double { defaults.double(forKey: hoverDelayKey) }
    static var preferredPlayer: String { defaults.string(forKey: preferredPlayerKey) ?? "auto" }
    static var showLiveActivity: Bool { defaults.bool(forKey: showLiveActivityKey) }
    static var trayCopyFiles: Bool { defaults.bool(forKey: trayCopyFilesKey) }
    static var devStatSlots: [StatKind] { StatKind.slots(from: defaults.string(forKey: devStatSlotsKey) ?? "") }
    static var devLists: DevListOrder { DevListOrder(defaults.string(forKey: devListsKey) ?? "") }
    static var hiddenCalendars: Set<String> { parseIDs(defaults.string(forKey: hiddenCalendarsKey) ?? "") }

    /// Docker is only queried when something on the Dev tab shows it.
    static var wantsDocker: Bool { devStatSlots.contains(.docker) || devLists.isEnabled(.containers) }
    static var wantsProcesses: Bool { devLists.isEnabled(.processes) }

    static func aiProviderKey(_ provider: AIProvider) -> String {
        switch provider {
        case .claude: aiShowClaudeKey
        case .codex: aiShowCodexKey
        }
    }

    static func isAIProviderEnabled(_ provider: AIProvider) -> Bool {
        defaults.bool(forKey: aiProviderKey(provider))
    }

    static func parseIDs(_ text: String) -> Set<String> {
        Set(text.split(separator: "\n").map(String.init))
    }

    static func encodeIDs(_ ids: Set<String>) -> String {
        ids.sorted().joined(separator: "\n")
    }
}

/// What a slot in the Dev tab's stats strip shows.
enum StatKind: String, CaseIterable, Identifiable {
    case cpu, memory, docker, network, disk, battery, gpu, uptime, claude, none

    static let slotCount = 3
    static let defaultSlots: [StatKind] = [.cpu, .memory, .docker]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .docker: "Docker"
        case .network: "Network"
        case .disk: "Disk space"
        case .battery: "Battery"
        case .gpu: "GPU"
        case .uptime: "Uptime"
        case .claude: "Claude limit"
        case .none: "None"
        }
    }

    var systemImage: String {
        switch self {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .docker: "shippingbox"
        case .network: "arrow.up.arrow.down"
        case .disk: "internaldrive"
        case .battery: "battery.75percent"
        case .gpu: "square.stack.3d.up"
        case .uptime: "clock"
        case .claude: "sparkles"
        case .none: "minus"
        }
    }

    /// Always `slotCount` entries; unknown or missing values become `.none`.
    static func slots(from text: String) -> [StatKind] {
        let parsed = text.split(separator: ",").map { StatKind(rawValue: String($0)) ?? .none }
        return (0..<slotCount).map { $0 < parsed.count ? parsed[$0] : .none }
    }

    static func encode(_ slots: [StatKind]) -> String {
        slots.map(\.rawValue).joined(separator: ",")
    }
}

/// The lists the Dev tab can show under the stats strip.
enum DevList: String, CaseIterable, Identifiable {
    case servers, containers, processes, ai

    var id: String { rawValue }

    var title: String {
        switch self {
        case .servers: "Local servers"
        case .containers: "Docker containers"
        case .processes: "Top processes"
        case .ai: "AI limits"
        }
    }

    var shortTitle: String {
        switch self {
        case .servers: "Servers"
        case .containers: "Containers"
        case .processes: "Processes"
        case .ai: "AI limits"
        }
    }

    var subtitle: String {
        switch self {
        case .servers: "Ports your apps are listening on"
        case .containers: "Hidden automatically when Docker isn't running"
        case .processes: "The 5 busiest apps by CPU"
        case .ai: "What's left of your Claude and Codex limits"
        }
    }
}

/// Order and on/off state of the Dev tab's lists.
struct DevListOrder: Equatable {
    struct Entry: Equatable {
        var list: DevList
        var isEnabled: Bool
    }

    var entries: [Entry]

    static let defaultValue = DevListOrder(entries: [
        Entry(list: .servers, isEnabled: true),
        Entry(list: .containers, isEnabled: true),
        Entry(list: .processes, isEnabled: false),
        Entry(list: .ai, isEnabled: true),
    ])

    init(entries: [Entry]) {
        self.entries = entries
    }

    init(_ text: String) {
        var entries: [Entry] = []
        for token in text.split(separator: ",") {
            let isEnabled = !token.hasPrefix("-")
            guard let list = DevList(rawValue: String(token.drop { $0 == "-" })),
                  !entries.contains(where: { $0.list == list }) else { continue }
            entries.append(Entry(list: list, isEnabled: isEnabled))
        }
        // Lists added in later versions show up at the end, on or off as they are by default.
        for list in DevList.allCases where !entries.contains(where: { $0.list == list }) {
            let isEnabled = Self.defaultValue.entries.first { $0.list == list }?.isEnabled ?? false
            entries.append(Entry(list: list, isEnabled: isEnabled))
        }
        self.entries = entries
    }

    var encoded: String {
        entries.map { ($0.isEnabled ? "" : "-") + $0.list.rawValue }.joined(separator: ",")
    }

    var enabled: [DevList] { entries.filter(\.isEnabled).map(\.list) }

    func isEnabled(_ list: DevList) -> Bool { enabled.contains(list) }
}

/// Widgets that can fill the left or right side of the Home tab.
enum HomeWidget: String, CaseIterable, Identifiable {
    case nowPlaying, calendar, notes, aiLimits, none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nowPlaying: "Now Playing"
        case .calendar: "Calendar"
        case .notes: "Notes"
        case .aiLimits: "AI limits"
        case .none: "Nothing"
        }
    }

    var systemImage: String {
        switch self {
        case .nowPlaying: "music.note"
        case .calendar: "calendar"
        case .notes: "note.text"
        case .aiLimits: "sparkles"
        case .none: "minus"
        }
    }
}

extension Notification.Name {
    static let openSettings = Notification.Name("NotchDeck.openSettings")
}
