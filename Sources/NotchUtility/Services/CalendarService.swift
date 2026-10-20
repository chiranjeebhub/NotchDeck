import AppKit
import EventKit

struct CalendarEvent: Identifiable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let color: NSColor
    let meeting: MeetingLink?

    var isOngoing: Bool { start <= .now && end > .now }
}

struct MeetingLink {
    let provider: String
    let url: URL

    private static let providers: [(name: String, pattern: String)] = [
        ("Meet", #"meet\.google\.com/"#),
        ("Zoom", #"zoom\.us/(j|my|w)/"#),
        ("Teams", #"teams\.(microsoft|live)\.com/"#),
        ("Webex", #"webex\.com/"#),
    ]

    private static let urlRegex = try! NSRegularExpression(pattern: #"https://[^\s<>"']+"#)

    /// Finds the first video-call link in the event's URL, location or notes.
    static func find(in event: EKEvent) -> MeetingLink? {
        let texts = [event.url?.absoluteString, event.location, event.notes].compactMap { $0 }
        for text in texts {
            let range = NSRange(text.startIndex..., in: text)
            for match in urlRegex.matches(in: text, range: range) {
                guard let swiftRange = Range(match.range, in: text) else { continue }
                let candidate = String(text[swiftRange])
                for provider in providers where candidate.range(of: provider.pattern, options: .regularExpression) != nil {
                    if let url = URL(string: candidate) { return MeetingLink(provider: provider.name, url: url) }
                }
            }
        }
        return nil
    }
}

/// Today's remaining events from every calendar in the Calendar app (including Google accounts added there).
@MainActor
final class CalendarService: NSObject, ObservableObject {
    static let shared = CalendarService()

    @Published private(set) var events: [CalendarEvent] = []
    @Published private(set) var authorization = EKEventStore.authorizationStatus(for: .event)

    private let store = EKEventStore()
    private var refreshTask: Task<Void, Never>?

    var hasAccess: Bool { authorization == .fullAccess }

    func start() {
        NotificationCenter.default.addObserver(self, selector: #selector(storeChanged), name: .EKEventStoreChanged, object: store)
        reload()
        // Drop finished events as the day goes on.
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                self?.reload()
            }
        }
    }

    @objc private func storeChanged() { reload() }

    func requestAccess() {
        Task {
            _ = try? await store.requestFullAccessToEvents()
            authorization = EKEventStore.authorizationStatus(for: .event)
            reload()
        }
    }

    func reload() {
        authorization = EKEventStore.authorizationStatus(for: .event)
        guard hasAccess else {
            events = []
            return
        }
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: .now)
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else { return }
        let predicate = store.predicateForEvents(withStart: startOfDay, end: endOfDay, calendars: nil)
        events = store.events(matching: predicate)
            .filter { $0.endDate > .now }
            .sorted { $0.startDate < $1.startDate }
            .map { event in
                CalendarEvent(
                    id: event.calendarItemIdentifier + "\(event.startDate.timeIntervalSince1970)",
                    title: event.title ?? "Untitled",
                    start: event.startDate,
                    end: event.endDate,
                    isAllDay: event.isAllDay,
                    color: event.calendar?.color ?? .systemBlue,
                    meeting: MeetingLink.find(in: event)
                )
            }
    }

    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }
}
