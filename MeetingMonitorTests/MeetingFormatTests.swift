@testable import MeetingMonitor
import XCTest

@MainActor
final class MeetingFormatTests: XCTestCase {
    private let calendar = TestSupport.denverCalendar
    private let noon = TestSupport.date(2026, 7, 13, 12)
    private let lateNight = TestSupport.date(2026, 7, 13, 23)

    private func relative(startOffset: TimeInterval, from now: Date, duration: TimeInterval = 3600) -> String {
        MeetingFormat.relativeTime(
            start: now.addingTimeInterval(startOffset),
            end: now.addingTimeInterval(startOffset + duration),
            now: now,
            calendar: calendar
        )
    }

    func testRelativeTimeNearTerm() {
        XCTAssertEqual(relative(startOffset: -60, from: noon), "Now")
        XCTAssertEqual(relative(startOffset: 5 * 60 + 30, from: noon), "In 5m")
        XCTAssertEqual(relative(startOffset: 90 * 60 + 30, from: noon), "In 1h")
        XCTAssertEqual(relative(startOffset: -7200, from: noon), "Done")
    }

    /// The day is taken from `now`, not the wall clock, so results do not depend on when tests run.
    func testRelativeTimeAcrossMidnightUsesNow() {
        XCTAssertTrue(relative(startOffset: 90 * 60 + 30, from: lateNight).hasPrefix("Tomorrow"))
        XCTAssertTrue(relative(startOffset: 26 * 3600, from: noon).hasPrefix("Tomorrow"))
        XCTAssertFalse(relative(startOffset: 26 * 3600, from: lateNight).hasPrefix("Tomorrow"))
    }

    func testNextMeetingSkipsEndedAndPrefersSoonest() {
        let ended = TestSupport.meeting(id: "ended", start: noon.addingTimeInterval(-7200), end: noon.addingTimeInterval(-3600))
        let tomorrow = TestSupport.meeting(id: "tmrw", start: noon.addingTimeInterval(26 * 3600), end: noon.addingTimeInterval(27 * 3600))
        let soon = TestSupport.meeting(id: "soon", start: noon.addingTimeInterval(1800), end: noon.addingTimeInterval(3600))
        XCTAssertEqual(MeetingFormat.nextMeeting(from: [ended, tomorrow, soon], now: noon)?.id, "soon")
    }

    func testNextMeetingPrefersTimedOverAllDay() {
        let dayStart = calendar.startOfDay(for: noon)
        let allDay = TestSupport.meeting(
            id: "birthday",
            start: dayStart,
            end: calendar.date(byAdding: .day, value: 1, to: dayStart)!,
            isAllDay: true
        )
        let standup = TestSupport.meeting(id: "standup", start: noon.addingTimeInterval(1800), end: noon.addingTimeInterval(3600))

        XCTAssertEqual(MeetingFormat.nextMeeting(from: [allDay, standup], now: noon)?.id, "standup")
        XCTAssertEqual(MeetingFormat.nextMeeting(from: [allDay], now: noon)?.id, "birthday")
    }

    func testMenuBarTime() {
        let inProgress = TestSupport.meeting(start: noon.addingTimeInterval(-60), end: noon.addingTimeInterval(600))
        XCTAssertEqual(MeetingFormat.menuBarTime(for: inProgress, now: noon, calendar: calendar), "Now")

        let laterToday = TestSupport.meeting(start: noon.addingTimeInterval(3 * 3600), end: noon.addingTimeInterval(4 * 3600))
        let today = MeetingFormat.menuBarTime(for: laterToday, now: noon, calendar: calendar)
        XCTAssertFalse(today.hasPrefix("Tomorrow"))
        XCTAssertFalse(today.isEmpty)

        let nextDay = TestSupport.meeting(start: noon.addingTimeInterval(24 * 3600), end: noon.addingTimeInterval(25 * 3600))
        XCTAssertTrue(MeetingFormat.menuBarTime(for: nextDay, now: noon, calendar: calendar).hasPrefix("Tomorrow "))

        let dayStart = calendar.startOfDay(for: noon)
        let allDay = TestSupport.meeting(start: dayStart, end: dayStart.addingTimeInterval(86400), isAllDay: true)
        XCTAssertEqual(MeetingFormat.menuBarTime(for: allDay, now: noon, calendar: calendar), "All day")
    }

    func testOverlapsDayIncludesSpanningEvents() {
        let dayStart = calendar.startOfDay(for: noon)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!
        let spanning = TestSupport.meeting(start: dayStart.addingTimeInterval(-3600), end: dayEnd.addingTimeInterval(3600), isAllDay: true)
        let outside = TestSupport.meeting(start: dayEnd.addingTimeInterval(3600), end: dayEnd.addingTimeInterval(7200))
        XCTAssertTrue(MeetingFormat.overlapsDay(spanning, dayStart: dayStart, dayEnd: dayEnd))
        XCTAssertFalse(MeetingFormat.overlapsDay(outside, dayStart: dayStart, dayEnd: dayEnd))
    }

    func testMenuBarLabelText() {
        XCTAssertEqual(MenuBarStatusRenderer.labelText(meetings: [], showSource: true, now: noon), "No meetings")

        let now = Date()
        let soon = TestSupport.meeting(start: now.addingTimeInterval(-60), end: now.addingTimeInterval(600), source: .spacemail)
        XCTAssertEqual(MenuBarStatusRenderer.labelText(meetings: [soon], showSource: true, now: now), "Next meeting · Now · S")
        XCTAssertEqual(MenuBarStatusRenderer.labelText(meetings: [soon], showSource: false, now: now), "Next meeting · Now")
    }

    func testMenuBarImageIsTemplate() {
        let image = MenuBarStatusRenderer.image(text: String(repeating: "x", count: 200))
        XCTAssertTrue(image.isTemplate)
        XCTAssertLessThanOrEqual(image.size.width, MenuBarStatusRenderer.maxWidth)
    }
}
