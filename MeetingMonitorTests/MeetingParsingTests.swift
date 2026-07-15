import XCTest
@testable import MeetingMonitor

final class MeetingParsingTests: XCTestCase {
    // MARK: - Google

    func testParseGoogleEventsFromFixture() throws {
        let root = try fixtureRoot()
        guard let googleEvents = root["google_events"] else {
            return XCTFail("missing google_events")
        }
        let encoded = try JSONSerialization.data(withJSONObject: googleEvents)
        let meetings = try GoogleCalendarClient.parseEvents(data: encoded)

        XCTAssertEqual(meetings.count, 2, "Broken-date event should be skipped")
        XCTAssertEqual(meetings[0].id, "google_evt_standup_001")
        XCTAssertEqual(meetings[0].title, "Daily Standup")
        XCTAssertEqual(meetings[0].source, .googleCalendar)
        XCTAssertEqual(meetings[0].meetingLink, "https://meet.google.com/abc-defg-hij")
        XCTAssertFalse(meetings[0].isAllDay)
        XCTAssertEqual(meetings[0].attendees.count, 2)

        XCTAssertEqual(meetings[1].title, "Company Offsite")
        XCTAssertTrue(meetings[1].isAllDay)
    }

    func testParseGoogleEmptyItems() throws {
        let data = #"{"items":[]}"#.data(using: .utf8)!
        let meetings = try GoogleCalendarClient.parseEvents(data: data)
        XCTAssertTrue(meetings.isEmpty)
    }

    func testParseGoogleSkipsMissingSummary() throws {
        let data = #"{"items":[{"id":"x","start":{"dateTime":"2026-07-13T10:00:00Z"},"end":{"dateTime":"2026-07-13T11:00:00Z"}}]}"#.data(using: .utf8)!
        let meetings = try GoogleCalendarClient.parseEvents(data: data)
        XCTAssertTrue(meetings.isEmpty)
    }

    // MARK: - Spacemail / iCal

    func testParseICalStringUsesStableUID() throws {
        let ical = try fixtureString("ical_sample")
        let meetings = SpacemailCalDAVClient.parseICalString(ical, calendarName: "personal")

        XCTAssertEqual(meetings.count, 2)
        XCTAssertTrue(meetings[0].id.contains("spacemail-uid-42@spacemail.com"))
        XCTAssertEqual(meetings[0].title, "Design Review")
        XCTAssertEqual(meetings[0].source, .spacemail)
        XCTAssertEqual(meetings[0].meetingLink, "https://zoom.us/j/123456789")
        XCTAssertEqual(meetings[0].attendees.sorted(), ["carol@example.com", "dave@example.com"])
        XCTAssertFalse(meetings[0].isAllDay)

        XCTAssertEqual(meetings[1].title, "Focus Day")
        XCTAssertTrue(meetings[1].isAllDay)
        XCTAssertTrue(meetings[1].id.contains("allday-uid-99@spacemail.com"))
    }

    func testCalDAVTimeRangeFormat() {
        var components = DateComponents()
        components.year = 2026
        components.month = 7
        components.day = 13
        components.hour = 15
        components.minute = 0
        components.second = 0
        components.timeZone = TimeZone(secondsFromGMT: 0)
        let date = Calendar(identifier: .gregorian).date(from: components)!

        let formatted = SpacemailCalDAVClient.calDAVTimeRangeString(from: date)
        XCTAssertEqual(formatted, "20260713T150000Z")
        XCTAssertFalse(formatted.contains("-"))
        XCTAssertFalse(formatted.contains(":"))
    }

    func testParseICalDateUTCAndAllDay() {
        let utc = SpacemailCalDAVClient.parseDate("20260713T150000Z")
        XCTAssertNotNil(utc)

        let allDay = SpacemailCalDAVClient.parseDate("20260716")
        XCTAssertNotNil(allDay)
    }

    func testExpandWeeklyRRuleProducesTomorrowOccurrence() {
        // Master: Monday 2026-07-13 15:00 UTC, weekly — window covers following Monday.
        let masterStart = SpacemailCalDAVClient.parseDate("20260713T150000Z")!
        let masterEnd = masterStart.addingTimeInterval(3600)
        let master = Meeting(
            id: "spacemail_weekly_1_\(Int(masterStart.timeIntervalSince1970))",
            title: "Co Founder Sync",
            startDate: masterStart,
            endDate: masterEnd,
            location: nil,
            meetingLink: nil,
            isAllDay: false,
            source: .spacemail,
            attendees: [],
            isRecurring: true,
            calendarName: "personal"
        )
        // Seed recurrence metadata the way parse does.
        // Use public expand API via parseICalString so RecurrenceStore is populated.
        let ical = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        UID:weekly-cofounder@spacemail.com
        DTSTART:20260713T150000Z
        DTEND:20260713T160000Z
        RRULE:FREQ=WEEKLY;BYDAY=MO
        SUMMARY:Co Founder Sync
        END:VEVENT
        END:VCALENDAR
        """
        let parsed = SpacemailCalDAVClient.parseICalString(ical, calendarName: "personal")
        XCTAssertEqual(parsed.count, 1)
        XCTAssertTrue(parsed[0].isRecurring)

        let from = SpacemailCalDAVClient.parseDate("20260714T000000Z")! // Tue
        let to = SpacemailCalDAVClient.parseDate("20260722T000000Z")!   // next Wed
        let expanded = SpacemailCalDAVClient.expandRecurring(meetings: parsed, from: from, to: to)
        // Next Monday Jul 20 should appear; Jul 13 is before `from`.
        XCTAssertTrue(expanded.contains { $0.title == "Co Founder Sync" })
        XCTAssertTrue(
            expanded.contains {
                Calendar.current.isDate(
                    $0.startDate,
                    inSameDayAs: SpacemailCalDAVClient.parseDate("20260720T150000Z")!
                )
            },
            "Expected weekly occurrence on 2026-07-20, got \(expanded.map(\.startDate))"
        )
        _ = master
    }

    // MARK: - MeetingFormat

    func testMeetingFormatRelativeTime() {
        let now = Date()
        // In-progress (started, not finished) → Now
        XCTAssertEqual(
            MeetingFormat.relativeTime(
                start: now.addingTimeInterval(-60),
                end: now.addingTimeInterval(30 * 60),
                now: now
            ),
            "Now"
        )
        // Use mid-window offsets so minute-boundary rounding does not flake.
        XCTAssertEqual(
            MeetingFormat.relativeTime(
                start: now.addingTimeInterval(5 * 60 + 30),
                end: now.addingTimeInterval(65 * 60),
                now: now
            ),
            "In 5m"
        )
        XCTAssertEqual(
            MeetingFormat.relativeTime(
                start: now.addingTimeInterval(90 * 60 + 30),
                end: now.addingTimeInterval(150 * 60),
                now: now
            ),
            "In 1h"
        )
    }

    func testNextMeetingSkipsEndedAndPrefersSoonestUpcoming() {
        let now = Date()
        let ended = Meeting(
            id: "ended", title: "Old Sync",
            startDate: now.addingTimeInterval(-7200),
            endDate: now.addingTimeInterval(-3600),
            location: nil, meetingLink: nil, isAllDay: false, source: .googleCalendar,
            attendees: [], isRecurring: false, calendarName: "G"
        )
        let tomorrow = Meeting(
            id: "tmrw", title: "Co Founder Sync",
            startDate: now.addingTimeInterval(26 * 3600),
            endDate: now.addingTimeInterval(27 * 3600),
            location: nil, meetingLink: nil, isAllDay: false, source: .googleCalendar,
            attendees: [], isRecurring: false, calendarName: "G"
        )
        let soon = Meeting(
            id: "soon", title: "Standup",
            startDate: now.addingTimeInterval(30 * 60),
            endDate: now.addingTimeInterval(60 * 60),
            location: nil, meetingLink: nil, isAllDay: false, source: .spacemail,
            attendees: [], isRecurring: false, calendarName: "S"
        )
        let next = MeetingFormat.nextMeeting(from: [ended, tomorrow, soon], now: now)
        XCTAssertEqual(next?.id, "soon")
        XCTAssertEqual(MeetingFormat.relativeTime(for: tomorrow, now: now).hasPrefix("Tomorrow"), true)
    }

    func testOverlapsDayIncludesSpanningEvents() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let dayStart = cal.startOfDay(for: Date(timeIntervalSince1970: 1_720_000_000))
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart)!
        let spanning = Meeting(
            id: "span", title: "Offsite",
            startDate: dayStart.addingTimeInterval(-3600),
            endDate: dayEnd.addingTimeInterval(3600),
            location: nil, meetingLink: nil, isAllDay: true, source: .googleCalendar,
            attendees: [], isRecurring: false, calendarName: "G"
        )
        let outside = Meeting(
            id: "out", title: "Later",
            startDate: dayEnd.addingTimeInterval(3600),
            endDate: dayEnd.addingTimeInterval(7200),
            location: nil, meetingLink: nil, isAllDay: false, source: .googleCalendar,
            attendees: [], isRecurring: false, calendarName: "G"
        )
        XCTAssertTrue(MeetingFormat.overlapsDay(spanning, dayStart: dayStart, dayEnd: dayEnd))
        XCTAssertFalse(MeetingFormat.overlapsDay(outside, dayStart: dayStart, dayEnd: dayEnd))
    }

    func testMeetingDateGroups() {
        let day1 = Date(timeIntervalSince1970: 1_720_000_000)
        let day2 = day1.addingTimeInterval(86_400)
        let meetings = [
            Meeting(
                id: "a", title: "A", startDate: day1, endDate: day1.addingTimeInterval(3600),
                location: nil, meetingLink: nil, isAllDay: false, source: .googleCalendar,
                attendees: [], isRecurring: false, calendarName: "G"
            ),
            Meeting(
                id: "b", title: "B", startDate: day2, endDate: day2.addingTimeInterval(3600),
                location: nil, meetingLink: nil, isAllDay: false, source: .spacemail,
                attendees: [], isRecurring: false, calendarName: "S"
            ),
            Meeting(
                id: "c", title: "C", startDate: day1.addingTimeInterval(7200), endDate: day1.addingTimeInterval(10_800),
                location: nil, meetingLink: nil, isAllDay: false, source: .googleCalendar,
                attendees: [], isRecurring: false, calendarName: "G"
            ),
        ]
        let groups = MeetingDateGroup.groups(from: meetings)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].meetings.count, 2)
        XCTAssertEqual(groups[1].meetings.count, 1)
    }

    // MARK: - Helpers

    private func fixtureURL() -> URL {
        if let url = Bundle.main.url(forResource: "meetings_fixture", withExtension: "json") {
            return url
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("MeetingMonitor/Fixtures/meetings_fixture.json")
    }

    private func fixtureRoot() throws -> [String: Any] {
        let data = try Data(contentsOf: fixtureURL())
        let obj = try JSONSerialization.jsonObject(with: data)
        guard let dict = obj as? [String: Any] else {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "bad fixture root"])
        }
        return dict
    }

    private func fixtureString(_ key: String) throws -> String {
        let root = try fixtureRoot()
        guard let value = root[key] as? String else {
            throw NSError(domain: "test", code: 2, userInfo: [NSLocalizedDescriptionKey: "missing \(key)"])
        }
        return value
    }
}
