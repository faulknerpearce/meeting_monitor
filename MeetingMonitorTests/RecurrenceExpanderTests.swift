@testable import MeetingMonitor
import XCTest

final class RecurrenceExpanderTests: XCTestCase {
    private let calendar = TestSupport.denverCalendar

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        TestSupport.date(year, month, day, hour, minute)
    }

    /// Expands the VEVENTs (all in America/Denver) into meetings overlapping the window.
    private func expand(_ events: [String]..., from: Date, to: Date) -> [Meeting] {
        let ical = events.reduce(into: ["BEGIN:VCALENDAR"]) { lines, event in
            lines += ["BEGIN:VEVENT"] + event + ["END:VEVENT"]
        } + ["END:VCALENDAR"]
        let parsed = ICalendarParser.events(in: ical.joined(separator: "\r\n"))
        return RecurrenceExpander.meetings(from: parsed, idPrefix: "t", source: .spacemail, from: from, to: to)
    }

    private func series(start: String, rule: String, extra: [String] = []) -> [String] {
        ["UID:series", "DTSTART;TZID=America/Denver:\(start)", "DURATION:PT30M", "SUMMARY:Series", "RRULE:\(rule)"] + extra
    }

    private func days(_ meetings: [Meeting]) -> [String] {
        meetings.map {
            let parts = calendar.dateComponents([.month, .day, .hour, .minute], from: $0.startDate)
            return String(format: "%02d-%02d %02d:%02d", parts.month!, parts.day!, parts.hour!, parts.minute!)
        }
    }

    func testWeeklyByDay() {
        let meetings = expand(series(start: "20260706T100000", rule: "FREQ=WEEKLY;BYDAY=MO"), from: date(2026, 7, 1), to: date(2026, 8, 1))
        XCTAssertEqual(days(meetings), ["07-06 10:00", "07-13 10:00", "07-20 10:00", "07-27 10:00"])
        XCTAssertEqual(Set(meetings.map(\.id)).count, 4)
        XCTAssertTrue(meetings.allSatisfy { $0.endDate.timeIntervalSince($0.startDate) == 1800 })
    }

    func testUntilDateIsInclusive() {
        let meetings = expand(
            series(start: "20260706T100000", rule: "FREQ=WEEKLY;UNTIL=20260713"),
            from: date(2026, 7, 1),
            to: date(2026, 8, 1)
        )
        XCTAssertEqual(days(meetings), ["07-06 10:00", "07-13 10:00"])
    }

    func testUntilDateTimeIsInclusive() {
        // 16:00Z is 10:00 in Denver (MDT).
        let meetings = expand(
            series(start: "20260706T100000", rule: "FREQ=WEEKLY;UNTIL=20260713T160000Z"),
            from: date(2026, 7, 1),
            to: date(2026, 8, 1)
        )
        XCTAssertEqual(days(meetings), ["07-06 10:00", "07-13 10:00"])
    }

    func testCount() {
        let meetings = expand(series(start: "20260706T100000", rule: "FREQ=WEEKLY;COUNT=3"), from: date(2026, 7, 1), to: date(2026, 8, 1))
        XCTAssertEqual(days(meetings), ["07-06 10:00", "07-13 10:00", "07-20 10:00"])
    }

    func testCountIsMeasuredFromSeriesStartNotWindow() {
        let meetings = expand(series(start: "20260706T100000", rule: "FREQ=DAILY;COUNT=10"), from: date(2026, 7, 14), to: date(2026, 8, 1))
        XCTAssertEqual(days(meetings), ["07-14 10:00", "07-15 10:00"])
    }

    func testExdate() {
        let meetings = expand(
            series(start: "20260706T100000", rule: "FREQ=WEEKLY", extra: ["EXDATE;TZID=America/Denver:20260713T100000"]),
            from: date(2026, 7, 1),
            to: date(2026, 8, 1)
        )
        XCTAssertEqual(days(meetings), ["07-06 10:00", "07-20 10:00", "07-27 10:00"])
    }

    func testLongRunningDailySeriesStillExpands() {
        let meetings = expand(series(start: "20240101T100000", rule: "FREQ=DAILY"), from: date(2026, 7, 13), to: date(2026, 7, 16))
        XCTAssertEqual(days(meetings), ["07-13 10:00", "07-14 10:00", "07-15 10:00"])
    }

    func testBiweeklyMultipleDaysFollowsWeekStart() {
        let meetings = expand(
            series(start: "20260708T100000", rule: "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE"),
            from: date(2026, 7, 1),
            to: date(2026, 7, 25)
        )
        XCTAssertEqual(days(meetings), ["07-08 10:00", "07-20 10:00", "07-22 10:00"])
    }

    func testMonthlyNthWeekday() {
        let second = expand(series(start: "20260113T100000", rule: "FREQ=MONTHLY;BYDAY=2TU"), from: date(2026, 2, 1), to: date(2026, 4, 1))
        XCTAssertEqual(days(second), ["02-10 10:00", "03-10 10:00"])

        let last = expand(series(start: "20260130T100000", rule: "FREQ=MONTHLY;BYDAY=-1FR"), from: date(2026, 7, 1), to: date(2026, 8, 1))
        XCTAssertEqual(days(last), ["07-31 10:00"])
    }

    func testMonthlyOnThe31stSkipsShortMonths() {
        let meetings = expand(series(start: "20260131T100000", rule: "FREQ=MONTHLY"), from: date(2026, 1, 1), to: date(2026, 6, 1))
        XCTAssertEqual(days(meetings), ["01-31 10:00", "03-31 10:00", "05-31 10:00"])
    }

    func testMonthlyByMonthDayNegative() {
        let meetings = expand(
            series(start: "20260130T100000", rule: "FREQ=MONTHLY;BYMONTHDAY=-1"),
            from: date(2026, 2, 1),
            to: date(2026, 4, 1)
        )
        XCTAssertEqual(days(meetings), ["02-28 10:00", "03-31 10:00"])
    }

    func testYearlyByMonthNthWeekday() {
        // US Thanksgiving: fourth Thursday of November.
        let meetings = expand(
            series(start: "20251127T120000", rule: "FREQ=YEARLY;BYMONTH=11;BYDAY=4TH"),
            from: date(2026, 1, 1),
            to: date(2027, 1, 1)
        )
        XCTAssertEqual(days(meetings), ["11-26 12:00"])
    }

    func testWallClockTimeIsKeptAcrossDST() {
        // DST ends in Denver on 2026-11-01.
        let meetings = expand(series(start: "20261019T100000", rule: "FREQ=WEEKLY"), from: date(2026, 10, 25), to: date(2026, 11, 8))
        XCTAssertEqual(days(meetings), ["10-26 10:00", "11-02 10:00"])
    }

    func testRecurrenceIDOverrideReplacesOccurrence() {
        let original = series(start: "20260706T100000", rule: "FREQ=WEEKLY")
        let moved = [
            "UID:series",
            "RECURRENCE-ID;TZID=America/Denver:20260713T100000",
            "DTSTART;TZID=America/Denver:20260713T140000",
            "DURATION:PT30M",
            "SUMMARY:Moved",
        ]
        let meetings = expand(original, moved, from: date(2026, 7, 1), to: date(2026, 7, 21))
        XCTAssertEqual(days(meetings), ["07-06 10:00", "07-13 14:00", "07-20 10:00"])
        XCTAssertEqual(meetings[1].title, "Moved")
    }

    func testAllDaySeries() {
        let event = ["UID:ad", "DTSTART;VALUE=DATE:20260706", "SUMMARY:Gym", "RRULE:FREQ=WEEKLY;COUNT=2"]
        let meetings = expand(event, from: date(2026, 7, 1), to: date(2026, 8, 1))
        XCTAssertEqual(meetings.count, 2)
        XCTAssertTrue(meetings.allSatisfy(\.isAllDay))
        let local = Calendar.current
        XCTAssertTrue(meetings.allSatisfy { local.dateComponents([.day], from: $0.startDate, to: $0.endDate).day == 1 })
    }

    func testUnsupportedRuleShowsSeriesStartOnly() {
        XCTAssertNil(RecurrenceRule("FREQ=MONTHLY;BYDAY=MO,TU;BYSETPOS=-1"))
        let meetings = expand(
            series(start: "20260706T100000", rule: "FREQ=MONTHLY;BYSETPOS=-1"),
            from: date(2026, 7, 1),
            to: date(2026, 9, 1)
        )
        XCTAssertEqual(days(meetings), ["07-06 10:00"])
    }

    func testRuleParsing() throws {
        let rule = try XCTUnwrap(RecurrenceRule("FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE;WKST=SU"))
        XCTAssertEqual(rule.frequency, .weekly)
        XCTAssertEqual(rule.interval, 2)
        XCTAssertEqual(rule.byDay.map(\.weekday), [2, 4])
        XCTAssertEqual(rule.weekStart, 1)
        XCTAssertNil(RecurrenceRule("INTERVAL=2"))
        XCTAssertNil(RecurrenceRule("FREQ=WEEKLY;BYDAY=2MO"))
    }
}
