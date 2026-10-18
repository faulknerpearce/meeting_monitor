@testable import MeetingMonitor
import XCTest

final class SpacemailCalDAVClientTests: XCTestCase {
    private let home = URL(string: "https://caldav.spacemail.com/dav.php/calendars/me@example.com/")!

    func testTimeRangeFormat() {
        let date = Date(timeIntervalSince1970: 1_783_954_800)
        XCTAssertEqual(SpacemailCalDAVClient.calDAVTimeRangeString(from: date), "20260713T150000Z")
    }

    func testResolveHrefStaysOnCalDAVHost() {
        XCTAssertEqual(
            SpacemailCalDAVClient.resolve(href: "/dav.php/calendars/me@example.com/default/", relativeTo: home)?.absoluteString,
            "https://caldav.spacemail.com/dav.php/calendars/me@example.com/default/"
        )
        XCTAssertEqual(
            SpacemailCalDAVClient.resolve(href: "work/", relativeTo: home)?.absoluteString,
            "https://caldav.spacemail.com/dav.php/calendars/me@example.com/work/"
        )
        XCTAssertNil(SpacemailCalDAVClient.resolve(href: "https://evil.example.com/steal", relativeTo: home))
        XCTAssertNil(SpacemailCalDAVClient.resolve(href: "http://caldav.spacemail.com/dav.php/", relativeTo: home))
    }

    /// One `<d:response>` with a single propstat.
    private func response(_ href: String, prop: String, status: String = "200 OK") -> String {
        """
        <d:response><d:href>\(href)</d:href>
          <d:propstat><d:prop>\(prop)</d:prop><d:status>HTTP/1.1 \(status)</d:status></d:propstat>
        </d:response>
        """
    }

    private func multistatus(_ responses: String...) -> Data {
        Data("""
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
        \(responses.joined(separator: "\n"))
        </d:multistatus>
        """.utf8)
    }

    func testCalendarCollectionsSkipScheduleInboxAndOutbox() throws {
        let base = "/dav.php/calendars/me@example.com/"
        let data = multistatus(
            response(base, prop: "<d:resourcetype><d:collection/></d:resourcetype>"),
            response(base + "work/", prop: "<d:resourcetype><d:collection/><c:calendar/></d:resourcetype>"),
            response(base + "inbox/", prop: "<d:resourcetype><d:collection/><c:schedule-inbox/></d:resourcetype>"),
            response(base + "inbox-reviews/", prop: "<d:resourcetype><d:collection/><c:calendar/></d:resourcetype>")
        )
        let calendars = try SpacemailCalDAVClient.calendarCollections(in: data, relativeTo: home)
        XCTAssertEqual(calendars.map(\.lastPathComponent), ["work", "inbox-reviews"])
    }

    func testFirstHrefIgnoresFailedPropstat() throws {
        let principal = { (href: String) in "<d:current-user-principal><d:href>\(href)</d:href></d:current-user-principal>" }
        let data = multistatus(
            response("/dav.php/", prop: principal("/wrong/"), status: "404 Not Found"),
            response("/dav.php/", prop: principal("/dav.php/principals/me@example.com/"))
        )
        let url = try SpacemailCalDAVClient.firstHref(in: data, property: "current-user-principal")
        XCTAssertEqual(url?.absoluteString, "https://caldav.spacemail.com/dav.php/principals/me@example.com/")
    }

    func testParseCalendarQuery() throws {
        let ical = TestSupport.calendar(["UID:x", "DTSTART:20260713T150000Z", "SUMMARY:From REPORT"])
        let data = multistatus(
            response("/dav.php/calendars/me/default/x.ics", prop: "<c:calendar-data><![CDATA[\(ical)]]></c:calendar-data>")
        )
        let events = try SpacemailCalDAVClient.parseCalendarQuery(data)
        XCTAssertEqual(events.map(\.title), ["From REPORT"])
    }

    func testStatusClassification() {
        XCTAssertEqual(CalendarProviderError.forStatus(401), .invalidCredentials)
        XCTAssertEqual(CalendarProviderError.forStatus(403), .invalidCredentials)
        XCTAssertEqual(CalendarProviderError.forStatus(500), .httpStatus(500))
        XCTAssertTrue(SpacemailCalDAVClient.isExpandRejection(400))
        XCTAssertTrue(SpacemailCalDAVClient.isExpandRejection(501))
        XCTAssertFalse(SpacemailCalDAVClient.isExpandRejection(401))
        XCTAssertFalse(SpacemailCalDAVClient.isExpandRejection(503))
    }
}
