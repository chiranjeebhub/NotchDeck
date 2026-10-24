import EventKit
import ServiceManagement
import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, appearance, home, tray, dev, media, calendar, ai, permissions, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .home: "Home"
        case .tray: "Tray"
        case .dev: "Dev"
        case .media: "Media"
        case .calendar: "Calendar"
        case .ai: "AI usage"
        case .permissions: "Permissions"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape.fill"
        case .appearance: "paintbrush.fill"
        case .home: "rectangle.3.group.fill"
        case .tray: "tray.fill"
        case .dev: "terminal.fill"
        case .media: "music.note"
        case .calendar: "calendar"
        case .ai: "sparkles"
        case .permissions: "hand.raised.fill"
        case .about: "info"
        }
    }

    var tint: Color {
        switch self {
        case .general, .about: .gray
        case .appearance: .indigo
        case .home: .blue
        case .tray: .teal
        case .dev: .green
        case .media: .pink
        case .calendar: .red
        case .ai: .purple
        case .permissions: .orange
        }
    }

    /// Extra words the sidebar search matches.
    var keywords: String {
        switch self {
        case .general: "launch login displays haptic hover click delay open"
        case .appearance: "music closed notch live activity labels icons"
        case .home: "widgets layout now playing calendar notes left right"
        case .tray: "airdrop files copy drop"
        case .dev: "stats cpu memory docker network disk battery gpu uptime servers ports containers processes"
        case .media: "player spotify music fallback"
        case .calendar: "calendars day month events"
        case .ai: "claude codex usage limits quota session weekly anthropic openai"
        case .permissions: "privacy access automation calendar"
        case .about: "version github updates sparkle"
        }
    }

    static let sections: [(title: String?, pages: [SettingsPage])] = [
        (nil, [.general, .appearance]),
        ("Tabs", [.home, .tray, .dev]),
        ("System", [.media, .calendar, .ai, .permissions, .about]),
    ]
}

/// Which page the settings window shows; the notch can open it on a given page.
@MainActor
final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()
    @Published var page: SettingsPage? = .general
}

struct SettingsView: View {
    @ObservedObject private var navigation = SettingsNavigation.shared
    @State private var search = ""

    private func matches(_ page: SettingsPage) -> Bool {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return query.isEmpty || page.title.lowercased().contains(query) || page.keywords.contains(query)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $navigation.page) {
                ForEach(Array(SettingsPage.sections.enumerated()), id: \.offset) { _, section in
                    let pages = section.pages.filter(matches)
                    if !pages.isEmpty {
                        if let title = section.title {
                            Section(title) { rows(pages) }
                        } else {
                            Section { rows(pages) }
                        }
                    }
                }
            }
            .searchable(text: $search, placement: .sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 200, max: 240)
        } detail: {
            Group {
                switch navigation.page ?? .general {
                case .general: GeneralSettings()
                case .appearance: AppearanceSettings()
                case .home: HomeSettings()
                case .tray: TraySettings()
                case .dev: DevSettings()
                case .media: MediaSettings()
                case .calendar: CalendarSettings()
                case .ai: AILimitsSettings()
                case .permissions: PermissionsSettings()
                case .about: AboutSettings()
                }
            }
            .formStyle(.grouped)
            .navigationTitle((navigation.page ?? .general).title)
        }
        .frame(minWidth: 720, minHeight: 500)
    }

    private func rows(_ pages: [SettingsPage]) -> some View {
        ForEach(pages) { page in
            Label {
                Text(page.title)
            } icon: {
                SettingsIcon(page: page)
            }
            .tag(page)
        }
    }
}

/// System Settings–style tile: a white glyph centred in a coloured rounded square.
/// The glyph is sized explicitly, because the sidebar otherwise scales symbols to fill the tile.
private struct SettingsIcon: View {
    let page: SettingsPage

    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(page.tint.gradient)
            .frame(width: 20, height: 20)
            .overlay {
                Image(systemName: page.systemImage)
                    .resizable()
                    .scaledToFit()
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .frame(width: 12, height: 12)
            }
    }
}

/// Small grey explanation under a setting.
private struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @AppStorage(AppSettings.showOnAllDisplaysKey) private var showOnAllDisplays = true
    @AppStorage(AppSettings.hapticFeedbackKey) private var hapticFeedback = true
    @AppStorage(AppSettings.openOnClickKey) private var openOnClick = false
    @AppStorage(AppSettings.hoverDelayKey) private var hoverDelay = 0.15
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            NSLog("NotchDeck: launch at login failed: \(error)")
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Toggle("Show on all displays", isOn: $showOnAllDisplays)
                Toggle("Haptic feedback when opening", isOn: $hapticFeedback)
            }

            Section("Opening") {
                Picker("Open the notch", selection: $openOnClick) {
                    Text("On hover").tag(false)
                    Text("On click").tag(true)
                }
                .pickerStyle(.segmented)
                if !openOnClick {
                    LabeledContent("Hover delay") {
                        HStack {
                            Slider(value: $hoverDelay, in: 0...1, step: 0.05)
                                .frame(width: 160)
                            Text(hoverDelay, format: .number.precision(.fractionLength(2)))
                                .monospacedDigit()
                                .frame(width: 34, alignment: .trailing)
                            Text("s")
                        }
                    }
                }
                Caption("Dragging a file onto the notch always opens it.")
            }
        }
    }
}

// MARK: - Appearance

private struct AppearanceSettings: View {
    @AppStorage(AppSettings.showLiveActivityKey) private var showLiveActivity = true
    @AppStorage(AppSettings.showTabLabelsKey) private var showTabLabels = true
    @AppStorage(AppSettings.showHomeTabKey) private var showHome = true
    @AppStorage(AppSettings.showTrayTabKey) private var showTray = true
    @AppStorage(AppSettings.showDevTabKey) private var showDev = true

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $showLiveActivity) {
                    Text("Show music in the closed notch")
                    Caption("Album art and a level meter beside the camera while something plays.")
                }
                Toggle("Show tab names", isOn: $showTabLabels)
            }
            Section("Tabs") {
                Toggle("Home", isOn: $showHome)
                Toggle(isOn: $showTray) {
                    Text("Tray")
                    Caption("Dragging a file onto the notch still opens the Tray.")
                }
                Toggle("Dev", isOn: $showDev)
            }
        }
    }
}

// MARK: - Home

private struct HomeSettings: View {
    @AppStorage(AppSettings.showHomeTabKey) private var showHome = true
    @AppStorage(AppSettings.homeLeftWidgetKey) private var left = HomeWidget.nowPlaying
    @AppStorage(AppSettings.homeRightWidgetKey) private var right = HomeWidget.calendar
    @AppStorage(AppSettings.homeNotesKey) private var notes = ""

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $showHome) {
                    Text("Show Home tab")
                    Caption("Hide it entirely if you don't need it.")
                }
            }
            Section("Layout") {
                HStack(spacing: 10) {
                    WidgetSlot(title: "Left", widget: $left)
                    Button {
                        (left, right) = (right, left)
                    } label: {
                        Image(systemName: "arrow.left.arrow.right")
                    }
                    .buttonStyle(.borderless)
                    .help("Swap sides")
                    WidgetSlot(title: "Right", widget: $right)
                }
                .padding(.vertical, 4)
                Caption("Pick a widget for each side, or Nothing to give the other side the full width.")
            }
            Section("Notes") {
                LabeledContent("Saved text") {
                    Button("Clear Notes") { notes = "" }
                        .disabled(notes.isEmpty)
                }
            }
            Section {
                Caption("Calendar options are under Calendar, and the player under Media.")
            }
        }
    }
}

/// A dark card that previews a Home side and picks its widget.
private struct WidgetSlot: View {
    let title: String
    @Binding var widget: HomeWidget

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(Color.white.opacity(0.45))
            Label(widget.title, systemImage: widget.systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(widget == .none ? Color.white.opacity(0.4) : .white)
            Picker("", selection: $widget) {
                ForEach(HomeWidget.allCases) { option in
                    Label(option.title, systemImage: option.systemImage).tag(option)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black))
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Tray

private struct TraySettings: View {
    @AppStorage(AppSettings.showTrayTabKey) private var showTray = true
    @AppStorage(AppSettings.trayShowAirDropKey) private var showAirDrop = true
    @AppStorage(AppSettings.trayCopyFilesKey) private var copyFiles = false
    @ObservedObject private var tray = TrayStore.shared

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $showTray) {
                    Text("Show Tray tab")
                    Caption("Dragging a file onto the notch still opens the Tray.")
                }
                Toggle("Show AirDrop tile", isOn: $showAirDrop)
                Toggle(isOn: $copyFiles) {
                    Text("Copy dropped files into the tray")
                    Caption("Keeps them even if the original moves or is deleted. Copies are removed when you take them out of the tray.")
                }
            }
            Section {
                LabeledContent("Files in the tray") {
                    HStack {
                        Text("\(tray.items.count)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Button("Clear Tray") { tray.removeAll() }
                            .disabled(tray.items.isEmpty)
                    }
                }
            }
        }
    }
}

// MARK: - Dev

private struct DevSettings: View {
    @AppStorage(AppSettings.showDevTabKey) private var showDev = true
    @AppStorage(AppSettings.devStatSlotsKey) private var slotsText = StatKind.encode(StatKind.defaultSlots)
    @AppStorage(AppSettings.devListsKey) private var listsText = DevListOrder.defaultValue.encoded
    @AppStorage(AppSettings.devShowAllPortsKey) private var showAllPorts = false
    @AppStorage(AppSettings.devShowUsageKey) private var showUsage = true
    @AppStorage(AppSettings.devConfirmStopKey) private var confirmStop = true

    private var slots: Binding<[StatKind]> {
        Binding(get: { StatKind.slots(from: slotsText) }, set: { slotsText = StatKind.encode($0) })
    }

    private var lists: Binding<DevListOrder> {
        Binding(get: { DevListOrder(listsText) }, set: { listsText = $0.encoded })
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $showDev) {
                    Text("Show Dev tab")
                    Caption("Hide it entirely if you don't need it.")
                }
            }

            Section {
                HStack(spacing: 10) {
                    ForEach(0..<StatKind.slotCount, id: \.self) { index in
                        StatSlot(kind: slots[index])
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Stats strip")
            } footer: {
                Caption("Three slots across the top of the Dev tab. Choose None to leave one out.")
            }

            Section {
                ForEach(Array(lists.wrappedValue.entries.enumerated()), id: \.element.list) { index, entry in
                    HStack(spacing: 10) {
                        Toggle(isOn: lists.entries[index].isEnabled) {
                            Text(entry.list.title)
                            Caption(entry.list.subtitle)
                        }
                        Spacer()
                        Button {
                            lists.wrappedValue.entries.swapAt(index, index - 1)
                        } label: {
                            Image(systemName: "chevron.up")
                        }
                        .buttonStyle(.borderless)
                        .disabled(index == 0)
                        .help("Move up")
                        Button {
                            lists.wrappedValue.entries.swapAt(index, index + 1)
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .buttonStyle(.borderless)
                        .disabled(index == lists.wrappedValue.entries.count - 1)
                        .help("Move down")
                    }
                }
            } header: {
                Text("Lists")
            } footer: {
                Caption("Lists that are on appear as a switcher under the stats, in this order.")
            }

            Section("Local servers") {
                Toggle("Show macOS services and high ports", isOn: $showAllPorts)
                Toggle("Show CPU and memory on each row", isOn: $showUsage)
                Toggle("Stop asks for confirmation", isOn: $confirmStop)
            }
        }
    }
}

/// A dark card that previews one stats slot and picks what it shows.
private struct StatSlot: View {
    @Binding var kind: StatKind

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(kind.title, systemImage: kind.systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(kind == .none ? Color.white.opacity(0.4) : .white)
            Picker("", selection: $kind) {
                ForEach(StatKind.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black))
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Media

private struct MediaSettings: View {
    @AppStorage(AppSettings.preferredPlayerKey) private var preferredPlayer = "auto"
    @AppStorage(AppSettings.showLiveActivityKey) private var showLiveActivity = true

    var body: some View {
        Form {
            Section {
                Picker("Fallback player", selection: $preferredPlayer) {
                    Text("Automatic").tag("auto")
                    ForEach(MediaPlayer.allCases) { player in
                        Text(player.displayName).tag(player.rawValue)
                    }
                }
                Caption("The notch follows whatever macOS shows as Now Playing, including browsers and Podcasts. If that isn't available, it falls back to Spotify and Apple Music: Automatic follows whichever started playing most recently.")
                Toggle("Show music in the closed notch", isOn: $showLiveActivity)
            }
        }
    }
}

// MARK: - Calendar

private struct CalendarSettings: View {
    @ObservedObject private var calendarService = CalendarService.shared
    @AppStorage(AppSettings.calendarModeKey) private var mode = CalendarWidgetView.Mode.day
    @AppStorage(AppSettings.hiddenCalendarsKey) private var hiddenText = ""

    private var hidden: Set<String> { AppSettings.parseIDs(hiddenText) }

    private func isShown(_ calendar: EKCalendar) -> Binding<Bool> {
        Binding(
            get: { !hidden.contains(calendar.calendarIdentifier) },
            set: { shown in
                var ids = hidden
                if shown { ids.remove(calendar.calendarIdentifier) } else { ids.insert(calendar.calendarIdentifier) }
                hiddenText = AppSettings.encodeIDs(ids)
                calendarService.reload()
            }
        )
    }

    var body: some View {
        Form {
            Section {
                Picker("Default view", selection: $mode) {
                    Text("Day").tag(CalendarWidgetView.Mode.day)
                    Text("Month").tag(CalendarWidgetView.Mode.month)
                }
                .pickerStyle(.segmented)
            }

            if calendarService.hasAccess {
                let calendars = calendarService.allCalendars()
                let sources = Dictionary(grouping: calendars) { $0.source?.title ?? "Other" }
                ForEach(sources.keys.sorted(), id: \.self) { source in
                    Section(source) {
                        ForEach(sources[source] ?? [], id: \.calendarIdentifier) { calendar in
                            Toggle(isOn: isShown(calendar)) {
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(Color(nsColor: calendar.color))
                                        .frame(width: 9, height: 9)
                                    Text(calendar.title)
                                }
                            }
                        }
                    }
                }
            } else {
                Section("Calendars to show") {
                    LabeledContent("Calendar access is off") {
                        if calendarService.authorization == .notDetermined {
                            Button("Allow Access") { calendarService.requestAccess() }
                        } else {
                            Button("Open Privacy Settings") { CalendarService.openPrivacySettings() }
                        }
                    }
                }
            }
        }
        .onAppear { calendarService.reload() }
    }
}

// MARK: - AI limits

private struct AILimitsSettings: View {
    @ObservedObject private var ai = AIUsageService.shared
    @AppStorage(AppSettings.aiShowClaudeKey) private var showClaude = true
    @AppStorage(AppSettings.aiShowCodexKey) private var showCodex = true
    @AppStorage(AppSettings.aiShowUsedKey) private var showsUsed = true

    var body: some View {
        Form {
            Section {
                Picker("Show", selection: $showsUsed) {
                    Text("Used").tag(true)
                    Text("Left").tag(false)
                }
                .pickerStyle(.segmented)
                Caption(showsUsed ? "Numbers and bars show how much of each limit you've used, like \"25% used\"."
                                  : "Numbers and bars show how much of each limit is left, like \"75% left\".")
            }

            Section {
                Toggle(isOn: $showClaude) {
                    Text("Claude")
                    Caption("Uses Claude Code's sign-in to read your session and weekly limits. macOS asks once whether NotchDeck may read it: choose Always Allow.")
                }
                Toggle(isOn: $showCodex) {
                    Text("Codex")
                    Caption("Reads the limits Codex records on this Mac while you use it, so they can be a little behind.")
                }
            } header: {
                Text("Apps to show")
            } footer: {
                Caption("Turn off an app to hide it everywhere. Show your limits on the Dev tab (the AI limits list, or the Claude slot in the stats strip) or as a Home widget.")
            }

            Section("Status") {
                ForEach(AIProvider.allCases) { provider in
                    LabeledContent(provider.name) {
                        Text(status(provider))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
                LabeledContent("Last checked") {
                    HStack {
                        Text(ai.lastRefresh.map { $0.formatted(date: .omitted, time: .shortened) } ?? "Not yet")
                            .foregroundStyle(.secondary)
                        Button("Refresh Now") { ai.refresh(force: true) }
                            .disabled(!showClaude && !showCodex)
                    }
                }
            }
        }
        .onChange(of: showClaude) { _, on in if on { ai.refresh() } }
        .onChange(of: showCodex) { _, on in if on { ai.refresh() } }
    }

    private func status(_ provider: AIProvider) -> String {
        guard AppSettings.isAIProviderEnabled(provider) else { return "Off" }
        switch ai.state(for: provider) {
        case .loading: return "Not checked yet"
        case .ready(let usage):
            let plan = usage.plan.map { "\($0) plan · " } ?? ""
            let display = AIUsageDisplay(showsUsed: showsUsed)
            return plan + usage.limits.map { "\($0.title) \(display.number($0))% \(display.word)" }.joined(separator: ", ")
        case let other: return ResetFormat.message(for: other) ?? ""
        }
    }
}

// MARK: - Permissions

private struct PermissionsSettings: View {
    @ObservedObject private var calendarService = CalendarService.shared

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Button("Open Settings") { CalendarService.openPrivacySettings() }
                } label: {
                    Text("Calendar")
                    Caption(calendarService.hasAccess ? "Allowed" : "Not allowed. The Calendar widget needs it.")
                }
                LabeledContent {
                    Button("Open Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                } label: {
                    Text("Automation")
                    Caption("Lets the notch control Spotify and Music when macOS Now Playing isn't available.")
                }
            }
        }
        .onAppear { calendarService.reload() }
    }
}

// MARK: - About

private struct AboutSettings: View {
    @ObservedObject private var updater = UpdaterService.shared

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("NotchDeck")
                            .font(.title2.weight(.semibold))
                        Text("Version \(version)")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
                Link("Source code on GitHub", destination: URL(string: "https://github.com/chiranjeebhub/NotchDeck")!)
            }
            Section("Updates") {
                if updater.isAvailable {
                    Toggle("Check for updates automatically", isOn: Binding(
                        get: { updater.automaticallyChecks },
                        set: { updater.automaticallyChecks = $0 }
                    ))
                    LabeledContent("Updates") {
                        Button("Check Now") { updater.checkForUpdates() }
                    }
                } else {
                    Caption("This is a local build. Updates are available in the release downloaded from GitHub.")
                }
            }
        }
    }
}
