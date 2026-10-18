import Foundation
@testable import MeetingMonitor

enum TestSupport {
    static let denver = TimeZone(identifier: "America/Denver")!

    static var denverCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = denver
        return calendar
    }

    /// A wall-clock time in `calendar`'s zone.
    static func date(
        _ year: Int, _ month: Int, _ day: Int,
        _ hour: Int = 0, _ minute: Int = 0,
        calendar: Calendar = denverCalendar
    ) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    static func meeting(
        id: String = UUID().uuidString,
        title: String = "Meeting",
        start: Date,
        end: Date,
        isAllDay: Bool = false,
        source: MeetingSource = .googleCalendar,
        link: URL? = nil
    ) -> Meeting {
        Meeting(
            id: id,
            title: title,
            startDate: start,
            endDate: end,
            location: nil,
            meetingLink: link,
            isAllDay: isAllDay,
            source: source
        )
    }

    /// Wraps VEVENT body lines in a CRLF-delimited VCALENDAR.
    static func calendar(_ events: [String]...) -> String {
        var lines = ["BEGIN:VCALENDAR", "VERSION:2.0"]
        for event in events {
            lines += ["BEGIN:VEVENT"] + event + ["END:VEVENT"]
        }
        lines.append("END:VCALENDAR")
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    static func fixtureRoot() throws -> [String: Any] {
        let url = Bundle(for: BundleToken.self).url(forResource: "meetings_fixture", withExtension: "json")
            ?? URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/meetings_fixture.json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let root = object as? [String: Any] else {
            throw NSError(domain: "TestSupport", code: 1, userInfo: [NSLocalizedDescriptionKey: "bad fixture root"])
        }
        return root
    }

    private final class BundleToken {}
}
