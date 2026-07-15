import Foundation

struct Meeting: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let location: String?
    let meetingLink: String?
    let isAllDay: Bool
    let source: MeetingSource
    let attendees: [String]
    let isRecurring: Bool
    let calendarName: String
}

enum MeetingSource: String, Hashable, Sendable, CaseIterable {
    case googleCalendar = "Google Calendar"
    case spacemail = "Spacemail"
}

struct CalendarCredentials: Codable, Sendable {
    let provider: String
    let username: String?
    let password: String?
    let accessToken: String?
    let refreshToken: String?
    let tokenExpiry: Date?
    let clientId: String?
    let clientSecret: String?
}

struct MeetingDateGroup: Identifiable {
    let id: Date
    let title: String
    let meetings: [Meeting]

    init(date: Date, meetings: [Meeting]) {
        self.id = Calendar.current.startOfDay(for: date)
        self.meetings = meetings
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMM d"
        self.title = formatter.string(from: date)
    }

    /// Groups meetings by start-of-day and sorts chronologically.
    static func groups(from meetings: [Meeting]) -> [MeetingDateGroup] {
        let grouped = Dictionary(grouping: meetings) { Calendar.current.startOfDay(for: $0.startDate) }
        return grouped
            .map { MeetingDateGroup(date: $0.key, meetings: $0.value) }
            .sorted { $0.id < $1.id }
    }
}

enum MeetingFormat {
    static func timeRange(_ meeting: Meeting) -> String {
        if meeting.isAllDay { return "All day" }
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return "\(f.string(from: meeting.startDate)) – \(f.string(from: meeting.endDate))"
    }

    /// True while the meeting has not fully ended (in progress or still upcoming).
    static func isRelevant(_ meeting: Meeting, now: Date = Date()) -> Bool {
        meeting.endDate > now
    }

    /// Next meeting for the menu bar: soonest start among not-yet-ended events.
    static func nextMeeting(from meetings: [Meeting], now: Date = Date()) -> Meeting? {
        meetings
            .filter { isRelevant($0, now: now) }
            .sorted { $0.startDate < $1.startDate }
            .first
    }

    /// Compact start time for the menu bar (no title).
    /// Examples: `Now`, `4:30 PM`, `Tomorrow 10:30 AM`, `Wed 10:30 AM`
    static func menuBarTime(for meeting: Meeting, now: Date = Date()) -> String {
        if meeting.isAllDay {
            let calendar = Calendar.current
            if calendar.isDateInToday(meeting.startDate) { return "All day" }
            if calendar.isDateInTomorrow(meeting.startDate) { return "Tomorrow all day" }
            let f = DateFormatter()
            f.dateFormat = "EEE"
            return "\(f.string(from: meeting.startDate)) all day"
        }

        if meeting.startDate <= now, meeting.endDate > now {
            return "Now"
        }

        let calendar = Calendar.current
        let clock = DateFormatter()
        clock.dateFormat = "h:mm a"
        let time = clock.string(from: meeting.startDate)

        if calendar.isDateInToday(meeting.startDate) {
            return time
        }
        if calendar.isDateInTomorrow(meeting.startDate) {
            return "Tomorrow \(time)"
        }
        let day = DateFormatter()
        day.dateFormat = "EEE"
        return "\(day.string(from: meeting.startDate)) \(time)"
    }

    /// Short relative label for menu bar / chips. Only "Now" when currently in progress.
    static func relativeTime(for meeting: Meeting, now: Date = Date()) -> String {
        relativeTime(start: meeting.startDate, end: meeting.endDate, now: now)
    }

    static func relativeTime(start: Date, end: Date, now: Date = Date()) -> String {
        // In progress (started, not finished).
        if start <= now, end > now {
            return "Now"
        }
        // Already over — should not appear as "next", but be safe.
        if end <= now {
            return "Done"
        }

        let calendar = Calendar.current
        let seconds = start.timeIntervalSince(now)
        let minutes = Int((seconds / 60.0).rounded(.down))

        if minutes < 1 {
            return "Now"
        }
        if minutes < 60 {
            return "In \(minutes)m"
        }
        if calendar.isDateInToday(start) {
            let hours = minutes / 60
            return hours == 1 ? "In 1h" : "In \(hours)h"
        }
        if calendar.isDateInTomorrow(start) {
            let f = DateFormatter()
            f.dateFormat = "h:mm a"
            return "Tomorrow \(f.string(from: start))"
        }

        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: start)).day ?? 0
        if days > 1, days < 7 {
            let f = DateFormatter()
            f.dateFormat = "EEE h:mm a"
            return f.string(from: start)
        }

        let f = DateFormatter()
        f.dateFormat = "M/d h:mm a"
        return f.string(from: start)
    }

    /// Legacy helper used by tests — start-only; prefers upcoming wording.
    static func relativeTime(_ date: Date, now: Date = Date()) -> String {
        relativeTime(start: date, end: date.addingTimeInterval(3600), now: now)
    }

    /// Meeting overlaps a calendar day (`[dayStart, dayEnd)`).
    static func overlapsDay(_ meeting: Meeting, dayStart: Date, dayEnd: Date) -> Bool {
        meeting.startDate < dayEnd && meeting.endDate > dayStart
    }
}
