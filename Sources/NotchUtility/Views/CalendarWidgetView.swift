import SwiftUI

struct CalendarWidgetView: View {
    @ObservedObject private var calendar = CalendarService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Date.now, format: .dateTime.weekday(.wide))
                    .font(.system(size: 13, weight: .semibold))
                Text(Date.now, format: .dateTime.month(.abbreviated).day())
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(0.5))
            }

            if calendar.authorization == .notDetermined {
                Spacer(minLength: 0)
                Button("Allow Calendar Access") { calendar.requestAccess() }
                    .buttonStyle(.borderedProminent)
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
            } else if calendar.events.isEmpty {
                Spacer(minLength: 0)
                Text("No more events today")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(calendar.events) { event in
                            EventRow(event: event)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
