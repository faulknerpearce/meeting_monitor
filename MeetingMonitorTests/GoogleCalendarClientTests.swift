@testable import MeetingMonitor
import XCTest

final class GoogleCalendarClientTests: XCTestCase {
    private func parse(_ json: String) throws -> [Meeting] {
        try GoogleCalendarClient.parseEvents(data: Data(json.utf8))
    }

    func testParseEventsFromFixture() throws {
        let root = try TestSupport.fixtureRoot()
        let encoded = try JSONSerialization.data(withJSONObject: XCTUnwrap(root["google_events"]))
        let meetings = try GoogleCalendarClient.parseEvents(data: encoded)

        XCTAssertEqual(meetings.count, 2, "Event without a start date should be skipped")
        XCTAssertEqual(meetings[0].id, "google_evt_standup_001")
        XCTAssertEqual(meetings[0].title, "Daily Standup")
        XCTAssertEqual(meetings[0].source, .googleCalendar)
        XCTAssertEqual(meetings[0].meetingLink?.absoluteString, "https://meet.google.com/abc-defg-hij")
        XCTAssertFalse(meetings[0].isAllDay)

        XCTAssertEqual(meetings[1].title, "Company Offsite")
        XCTAssertTrue(meetings[1].isAllDay)
        let calendar = Calendar.current
        XCTAssertEqual(
            calendar.dateComponents([.year, .month, .day, .hour], from: meetings[1].startDate),
            DateComponents(year: 2026, month: 7, day: 14, hour: 0)
        )
    }

    func testEmptyItems() throws {
        XCTAssertTrue(try parse(#"{"items":[]}"#).isEmpty)
    }

    func testUntitledEventIsKeptWithPlaceholder() throws {
        let meetings = try parse(
            #"{"items":[{"id":"x","start":{"dateTime":"2026-07-13T10:00:00Z"},"end":{"dateTime":"2026-07-13T11:00:00Z"}}]}"#
        )
        XCTAssertEqual(meetings.map(\.title), [Meeting.untitled])
    }

    func testCancelledEventIsSkipped() throws {
        let meetings = try parse(
            #"{"items":[{"id":"x","status":"cancelled","summary":"Gone","start":{"dateTime":"2026-07-13T10:00:00Z"}}]}"#
        )
        XCTAssertTrue(meetings.isEmpty)
    }

    func testLocationTextYieldsOnlyTheLink() throws {
        let meetings = try parse(
            #"{"items":[{"id":"x","summary":"Sync","start":{"dateTime":"2026-07-13T10:00:00Z"},"location":"Room 5 / zoom.us/j/123 (pw 456)"}]}"#
        )
        let link = try XCTUnwrap(meetings.first?.meetingLink)
        XCTAssertEqual(link.host, "zoom.us")
        XCTAssertEqual(link.path, "/j/123")
        XCTAssertEqual(meetings.first?.location, "Room 5 / zoom.us/j/123 (pw 456)")
    }

    func testLocationWithoutConferenceLinkHasNoJoin() throws {
        let meetings = try parse(
            #"{"items":[{"id":"x","summary":"Sync","start":{"dateTime":"2026-07-13T10:00:00Z"},"location":"Conference Room 5"}]}"#
        )
        XCTAssertNil(meetings.first?.meetingLink)
    }

    func testHangoutLinkAndDescriptionFallbacks() throws {
        let hangout = try parse(
            #"{"items":[{"id":"a","summary":"A","start":{"dateTime":"2026-07-13T10:00:00Z"},"hangoutLink":"https://meet.google.com/xyz-abcd-efg"}]}"#
        )
        XCTAssertEqual(hangout.first?.meetingLink?.absoluteString, "https://meet.google.com/xyz-abcd-efg")

        let description = try parse(
            #"{"items":[{"id":"b","summary":"B","start":{"dateTime":"2026-07-13T10:00:00Z"},"description":"Join: https://acme.zoom.us/j/99 thanks"}]}"#
        )
        XCTAssertEqual(description.first?.meetingLink?.absoluteString, "https://acme.zoom.us/j/99")
    }

    func testNextPageToken() throws {
        let page = try GoogleCalendarClient.parsePage(data: Data(#"{"items":[],"nextPageToken":"abc"}"#.utf8))
        XCTAssertEqual(page.nextPageToken, "abc")
    }

    func testCredentialRejectionClassification() {
        XCTAssertTrue(GoogleCalendarClient.isCredentialRejection(status: 400, oauthError: "invalid_grant"))
        XCTAssertTrue(GoogleCalendarClient.isCredentialRejection(status: 401, oauthError: nil))
        XCTAssertFalse(GoogleCalendarClient.isCredentialRejection(status: 503, oauthError: nil))
        XCTAssertFalse(GoogleCalendarClient.isCredentialRejection(status: 500, oauthError: "internal_failure"))
        XCTAssertFalse(GoogleCalendarClient.isCredentialRejection(status: 429, oauthError: nil))
    }
}
