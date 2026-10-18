@testable import MeetingMonitor
import XCTest

final class ICalendarParserTests: XCTestCase {
    func testFixtureSample() throws {
        let ical = try XCTUnwrap(TestSupport.fixtureRoot()["ical_sample"] as? String)
        let events = ICalendarParser.events(in: ical)

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].uid, "spacemail-uid-42@spacemail.com")
        XCTAssertEqual(events[0].title, "Design Review")
        XCTAssertEqual(events[0].meetingLink?.absoluteString, "https://zoom.us/j/123456789")
        XCTAssertFalse(events[0].isAllDay)
        XCTAssertEqual(events[0].end.timeIntervalSince(events[0].start.date), 3600)

        XCTAssertEqual(events[1].title, "Focus Day")
        XCTAssertTrue(events[1].isAllDay)
    }

    func testCRLFAndFoldedLines() {
        let ical = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:fold\r\nDTSTART:20260713T150000Z\r\n"
            + "SUMMARY:A very long\r\n  title\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
        let events = ICalendarParser.events(in: ical)
        XCTAssertEqual(events.map(\.title), ["A very long title"])
    }

    func testNestedAlarmDoesNotOverrideEventProperties() {
        let ical = TestSupport.calendar([
            "UID:u1",
            "DTSTART:20260713T150000Z",
            "DTEND:20260713T160000Z",
            "SUMMARY:Planning",
            "DESCRIPTION:Join https://zoom.us/j/123456789 please",
            "BEGIN:VALARM",
            "ACTION:DISPLAY",
            "DESCRIPTION:Reminder",
            "SUMMARY:Alarm summary",
            "TRIGGER:-PT10M",
            "END:VALARM",
        ])
        let event = ICalendarParser.events(in: ical).first
        XCTAssertEqual(event?.title, "Planning")
        XCTAssertEqual(event?.meetingLink?.absoluteString, "https://zoom.us/j/123456789")
    }

    func testCancelledEventIsDropped() {
        let ical = TestSupport.calendar(
            ["UID:a", "DTSTART:20260713T150000Z", "SUMMARY:Kept"],
            ["UID:b", "DTSTART:20260713T160000Z", "SUMMARY:Gone", "STATUS:CANCELLED"]
        )
        XCTAssertEqual(ICalendarParser.events(in: ical).map(\.title), ["Kept"])
    }

    func testTextEscapesAreDecoded() {
        let ical = TestSupport.calendar([
            "UID:esc",
            "DTSTART:20260713T150000Z",
            #"SUMMARY:Team sync\, planning\; Q3"#,
            #"LOCATION:Room 1\nFloor 2"#,
        ])
        let event = ICalendarParser.events(in: ical).first
        XCTAssertEqual(event?.title, "Team sync, planning; Q3")
        XCTAssertEqual(event?.location, "Room 1\nFloor 2")
    }

    func testMissingSummaryUsesPlaceholder() {
        let ical = TestSupport.calendar(["UID:x", "DTSTART:20260713T150000Z"])
        XCTAssertEqual(ICalendarParser.events(in: ical).first?.title, Meeting.untitled)
    }

    func testAllDayWithoutEndLastsOneDay() throws {
        let ical = TestSupport.calendar(["UID:k", "DTSTART;VALUE=DATE:20260713", "SUMMARY:No end"])
        let event = try XCTUnwrap(ICalendarParser.events(in: ical).first)
        XCTAssertTrue(event.isAllDay)
        XCTAssertEqual(Calendar.current.dateComponents([.day], from: event.start.date, to: event.end).day, 1)
    }

    func testDurationAndTimeZone() throws {
        let ical = TestSupport.calendar([
            "UID:d",
            "DTSTART;TZID=America/Denver:20260713T090000",
            "DURATION:PT1H30M",
            "SUMMARY:Denver",
        ])
        let event = try XCTUnwrap(ICalendarParser.events(in: ical).first)
        XCTAssertEqual(event.start.date, TestSupport.date(2026, 7, 13, 9))
        XCTAssertEqual(event.end.timeIntervalSince(event.start.date), 5400)
    }

    func testQuotedParameterContainingColon() {
        let ical = TestSupport.calendar([
            "UID:q",
            "DTSTART:20260713T150000Z",
            #"ORGANIZER;CN="Doe: Jane":mailto:jane@example.com"#,
            "SUMMARY:Quoted",
        ])
        XCTAssertEqual(ICalendarParser.events(in: ical).first?.title, "Quoted")
    }

    func testParseDateTimeForms() {
        let utc = ICalendarParser.parseDateTime("20260713T150000Z")
        XCTAssertEqual(utc?.date, Date(timeIntervalSince1970: 1_783_954_800))
        XCTAssertEqual(utc?.isDateOnly, false)

        let allDay = ICalendarParser.parseDateTime("20260716")
        XCTAssertEqual(allDay?.isDateOnly, true)

        XCTAssertNil(ICalendarParser.parseDateTime("20261340"))
        XCTAssertNil(ICalendarParser.parseDateTime("20260231"))
        XCTAssertNil(ICalendarParser.parseDateTime("garbage"))
    }

    func testParseDuration() throws {
        let mixed = try XCTUnwrap(ICalendarParser.parseDuration("P1DT2H"))
        XCTAssertEqual(mixed.days, 1)
        XCTAssertEqual(mixed.seconds, 7200)
        XCTAssertEqual(ICalendarParser.parseDuration("P2W")?.days, 14)
        XCTAssertNil(ICalendarParser.parseDuration("PT0S"))
        XCTAssertNil(ICalendarParser.parseDuration("1H"))
    }
}
