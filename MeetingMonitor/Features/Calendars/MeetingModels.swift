import Foundation

struct Meeting: Identifiable, Hashable, Sendable {
    /// Title shown for events that have no summary.
    static let untitled = "(No title)"

    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let location: String?
    let meetingLink: URL?
    let isAllDay: Bool
    let source: MeetingSource
}

enum MeetingSource: String, Hashable, Sendable, CaseIterable {
    case googleCalendar = "Google Calendar"
    case spacemail = "Spacemail"

    var displayName: String { rawValue }

    var shortName: String {
        switch self {
        case .googleCalendar: return "Google"
        case .spacemail: return "Spacemail"
        }
    }

    /// Single-letter badge for the menu bar.
    var badge: String {
        switch self {
        case .googleCalendar: return "G"
        case .spacemail: return "S"
        }
    }

    /// Key under which `CredentialStore` persists this source's credentials.
    var credentialKey: String {
        switch self {
        case .googleCalendar: return "google"
        case .spacemail: return "spacemail"
        }
    }
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

    func replacingAccessToken(_ accessToken: String?, expiry: Date?) -> CalendarCredentials {
        CalendarCredentials(
            provider: provider,
            username: username,
            password: password,
            accessToken: accessToken,
            refreshToken: refreshToken,
            tokenExpiry: expiry,
            clientId: clientId,
            clientSecret: clientSecret
        )
    }
}

/// Display formatting for meeting times. All functions take `now` and `calendar` so results
/// depend only on their inputs.
@MainActor
enum MeetingFormat {
    private static let clockFormatter = formatter(template: "jmm")
    private static let weekdayFormatter = formatter(template: "EEE")
    private static let weekdayClockFormatter = formatter(template: "EEEjmm")
    private static let dateClockFormatter = formatter(template: "Mdjmm")

    private static func formatter(template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }

    private static func string(_ formatter: DateFormatter, _ date: Date, _ calendar: Calendar) -> String {
        formatter.timeZone = calendar.timeZone
        return formatter.string(from: date)
    }

    /// Whole calendar days from `now`'s day to `date`'s day (0 = same day, 1 = tomorrow).
    private static func dayOffset(of date: Date, from now: Date, calendar: Calendar) -> Int {
        calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: date)
        ).day ?? 0
    }

    static func timeRange(_ meeting: Meeting, calendar: Calendar = .current) -> String {
        if meeting.isAllDay { return "All day" }
        return "\(string(clockFormatter, meeting.startDate, calendar)) – \(string(clockFormatter, meeting.endDate, calendar))"
    }

    /// True while the meeting has not fully ended (in progress or still upcoming).
    static func isRelevant(_ meeting: Meeting, now: Date = Date()) -> Bool {
        meeting.endDate > now
    }

    /// The meeting the menu bar points at: the soonest not-yet-ended timed meeting, or the soonest
    /// all-day event when no timed meeting remains.
    static func nextMeeting(from meetings: [Meeting], now: Date = Date()) -> Meeting? {
        let relevant = meetings
            .filter { isRelevant($0, now: now) }
            .sorted { $0.startDate < $1.startDate }
        return relevant.first { !$0.isAllDay } ?? relevant.first
    }

    /// Compact start time for the menu bar (no title).
    /// Examples: `Now`, `4:30 PM`, `Tomorrow 10:30 AM`, `Wed 10:30 AM`
    static func menuBarTime(for meeting: Meeting, now: Date = Date(), calendar: Calendar = .current) -> String {
        let offset = dayOffset(of: meeting.startDate, from: now, calendar: calendar)

        if meeting.isAllDay {
            if offset <= 0 { return "All day" }
            if offset == 1 { return "Tomorrow all day" }
            return "\(string(weekdayFormatter, meeting.startDate, calendar)) all day"
        }

        if meeting.startDate <= now, meeting.endDate > now {
            return "Now"
        }

        let time = string(clockFormatter, meeting.startDate, calendar)
        switch offset {
        case ...0: return time
        case 1: return "Tomorrow \(time)"
        default: return "\(string(weekdayFormatter, meeting.startDate, calendar)) \(time)"
        }
    }

    /// Short relative label for list rows. "Now" only while the meeting is in progress or about to start.
    static func relativeTime(for meeting: Meeting, now: Date = Date(), calendar: Calendar = .current) -> String {
        relativeTime(start: meeting.startDate, end: meeting.endDate, now: now, calendar: calendar)
    }

    static func relativeTime(start: Date, end: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if start <= now, end > now { return "Now" }
        if end <= now { return "Done" }

        let minutes = Int((start.timeIntervalSince(now) / 60.0).rounded(.down))
        if minutes < 1 { return "Now" }
        if minutes < 60 { return "In \(minutes)m" }

        switch dayOffset(of: start, from: now, calendar: calendar) {
        case ...0:
            let hours = minutes / 60
            return "In \(hours)h"
        case 1:
            return "Tomorrow \(string(clockFormatter, start, calendar))"
        case 2..<7:
            return string(weekdayClockFormatter, start, calendar)
        default:
            return string(dateClockFormatter, start, calendar)
        }
    }

    /// Meeting overlaps a calendar day (`[dayStart, dayEnd)`).
    static func overlapsDay(_ meeting: Meeting, dayStart: Date, dayEnd: Date) -> Bool {
        meeting.startDate < dayEnd && meeting.endDate > dayStart
    }
}
