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

/// Events from every calendar in the Calendar app (including Google accounts added there).
@MainActor
final class CalendarService: NSObject, ObservableObject {
    static let shared = CalendarService()

    @Published private(set) var authorization = EKEventStore.authorizationStatus(for: .event)
    /// Bumped whenever the event store or the time of day changes, so views re-query.
    @Published private(set) var revision = 0

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
            reload()
        }
    }

    func reload() {
        authorization = EKEventStore.authorizationStatus(for: .event)
        revision += 1
    }

    /// Events on `day`, sorted by start time. For today, events that already ended are left out.
    func events(on day: Date) -> [CalendarEvent] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)
        guard hasAccess, let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        let isToday = calendar.isDateInToday(day)
        return fetch(from: start, to: end)
            .filter { !isToday || $0.endDate > .now }
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

    /// Number of events starting on each day (1...31) of the month containing `date`.
    func eventCounts(inMonthOf date: Date) -> [Int: Int] {
        let calendar = Calendar.current
        guard hasAccess, let month = calendar.dateInterval(of: .month, for: date) else { return [:] }
        var counts: [Int: Int] = [:]
        for event in fetch(from: month.start, to: month.end) {
            // Multi-day events count on each day they cover within the month.
            var day = max(calendar.startOfDay(for: event.startDate), month.start)
            let last = min(event.isAllDay ? event.endDate.addingTimeInterval(-1) : event.endDate, month.end.addingTimeInterval(-1))
            while day <= last {
                counts[calendar.component(.day, from: day), default: 0] += 1
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }
        return counts
    }

    private func fetch(from start: Date, to end: Date) -> [EKEvent] {
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
    }

    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }
}
