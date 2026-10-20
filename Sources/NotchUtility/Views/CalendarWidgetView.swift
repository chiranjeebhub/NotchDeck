import SwiftUI

struct CalendarWidgetView: View {
    enum Mode: String { case day, month }

    @ObservedObject private var calendar = CalendarService.shared
    @AppStorage("calendarMode") private var mode = Mode.day
    @State private var selectedDay = Date.now
    @State private var displayedMonth = Date.now

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if calendar.authorization == .notDetermined {
                Spacer(minLength: 0)
                Button("Allow Calendar Access") { calendar.requestAccess() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Spacer(minLength: 0)
            } else if !calendar.hasAccess {
                Text("Calendar access is off.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.6))
                Button("Open Privacy Settings") { CalendarService.openPrivacySettings() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Spacer(minLength: 0)
            } else if mode == .day {
                DayEventsView(day: selectedDay, events: calendar.events(on: selectedDay))
            } else {
                MonthGridView(month: displayedMonth, selectedDay: selectedDay,
                              counts: calendar.eventCounts(inMonthOf: displayedMonth)) { day in
                    selectedDay = day
                    mode = .day
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            // Right after launch (or a rebuild) macOS can report "not determined" for a moment
            // before the real status, so check again shortly instead of showing the Allow button.
            calendar.reload()
            guard !calendar.hasAccess else { return }
            try? await Task.sleep(for: .seconds(1))
            calendar.reload()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 4) {
            NavArrow(systemImage: "chevron.left") { step(by: -1) }
            Group {
                if mode == .day {
                    Text(selectedDay, format: .dateTime.weekday(.wide))
                        .font(.system(size: 13, weight: .semibold))
                    Text(selectedDay, format: .dateTime.day().month(.abbreviated))
                        .font(.system(size: 13))
                        .foregroundStyle(Color.white.opacity(0.5))
                } else {
                    Text(displayedMonth, format: .dateTime.month(.wide))
                        .font(.system(size: 13, weight: .semibold))
                    Text(displayedMonth, format: .dateTime.year())
                        .font(.system(size: 13))
                        .foregroundStyle(Color.white.opacity(0.5))
                }
            }
            .lineLimit(1)
            NavArrow(systemImage: "chevron.right") { step(by: 1) }

            if !isShowingToday {
                Button("Today") {
                    selectedDay = .now
                    displayedMonth = .now
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.7))
                .padding(.leading, 4)
            }

            Spacer(minLength: 6)

            SegmentedToggle(options: ["Day", "Month"], selection: Binding(
                get: { mode == .day ? 0 : 1 },
                set: { index in
                    mode = index == 0 ? .day : .month
                    if mode == .month { displayedMonth = selectedDay }
                }
            ))
        }
        .frame(height: 22)
    }

    private var isShowingToday: Bool {
        let calendar = Calendar.current
        return mode == .day
            ? calendar.isDateInToday(selectedDay)
            : calendar.isDate(displayedMonth, equalTo: .now, toGranularity: .month)
    }

    private func step(by amount: Int) {
        let calendar = Calendar.current
        if mode == .day {
            selectedDay = calendar.date(byAdding: .day, value: amount, to: selectedDay) ?? selectedDay
        } else {
            displayedMonth = calendar.date(byAdding: .month, value: amount, to: displayedMonth) ?? displayedMonth
        }
    }
}

struct NavArrow: View {
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.55))
                .frame(width: 16, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct DayEventsView: View {
    let day: Date
    let events: [CalendarEvent]

    var body: some View {
        if events.isEmpty {
            Text(Calendar.current.isDateInToday(day) ? "No more events today" : "No events")
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.5))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(events) { event in
                        EventRow(event: event)
                    }
                }
            }
        }
    }
}

/// A compact month: today in red, the selected day outlined, dots for days with events.
struct MonthGridView: View {
    let month: Date
    let selectedDay: Date
    let counts: [Int: Int]
    let onSelect: (Date) -> Void

    private let calendar = Calendar.current
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    /// Day numbers for the grid, with nil for the blanks before the 1st.
    private var cells: [Int?] {
        guard let interval = calendar.dateInterval(of: .month, for: month),
              let days = calendar.range(of: .day, in: .month, for: month) else { return [] }
        let leading = (calendar.component(.weekday, from: interval.start) - calendar.firstWeekday + 7) % 7
        return Array(repeating: nil, count: leading) + days.map { Optional($0) }
    }

    private func date(for day: Int) -> Date? {
        var components = calendar.dateComponents([.year, .month], from: month)
        components.day = day
        return calendar.date(from: components)
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 1) {
            ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.4))
                    .frame(height: 13)
            }
            ForEach(Array(cells.enumerated()), id: \.offset) { _, day in
                if let day, let date = date(for: day) {
                    DayCell(
                        day: day,
                        isToday: calendar.isDateInToday(date),
                        isSelected: calendar.isDate(date, inSameDayAs: selectedDay),
                        eventCount: counts[day] ?? 0
                    ) {
                        onSelect(date)
                    }
                } else {
                    Color.clear.frame(height: 20)
                }
            }
        }
    }
}

struct DayCell: View {
    let day: Int
    let isToday: Bool
    let isSelected: Bool
    let eventCount: Int
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottom) {
                Text(String(day))
                    .font(.system(size: 11, weight: isToday ? .bold : .medium).monospacedDigit())
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if eventCount > 0 {
                    HStack(spacing: 2) {
                        ForEach(0..<min(eventCount, 3), id: \.self) { _ in
                            Circle()
                                .fill(isToday ? Color.white : Color(red: 0.38, green: 0.65, blue: 0.98))
                                .frame(width: 3, height: 3)
                        }
                    }
                    .padding(.bottom, 1.5)
                }
            }
            .frame(height: 20)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isToday ? Color.red : Color.white.opacity(isHovering ? 0.1 : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.white.opacity(isSelected && !isToday ? 0.5 : 0), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

struct EventRow: View {
    let event: CalendarEvent

    var body: some View {
        HStack(spacing: 8) {
            Capsule()
                .fill(Color(nsColor: event.color))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(timeText)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(event.isOngoing ? 0.8 : 0.5))
            }
            Spacer(minLength: 4)
            if let meeting = event.meeting {
                Button {
                    NSWorkspace.shared.open(meeting.url)
                } label: {
                    Label("Join", systemImage: "video.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.blue))
                }
                .buttonStyle(.plain)
                .help("Join on \(meeting.provider)")
            }
        }
        .frame(height: 30)
    }

    private var timeText: String {
        if event.isAllDay { return "All day" }
        let start = event.start.formatted(date: .omitted, time: .shortened)
        let end = event.end.formatted(date: .omitted, time: .shortened)
        return event.isOngoing ? "Now · until \(end)" : "\(start) – \(end)"
    }
}
