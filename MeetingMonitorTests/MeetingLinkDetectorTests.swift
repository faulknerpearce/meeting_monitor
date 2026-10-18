@testable import MeetingMonitor
import XCTest

final class MeetingLinkDetectorTests: XCTestCase {
    func testFindsConferenceLinksInText() {
        XCTAssertEqual(
            MeetingLinkDetector.firstLink(in: "Notes https://example.com then https://us02web.zoom.us/j/1")?.host,
            "us02web.zoom.us"
        )
        XCTAssertEqual(
            MeetingLinkDetector.firstLink(in: "Teams: https://teams.microsoft.com/l/meetup-join/abc")?.host,
            "teams.microsoft.com"
        )
        XCTAssertEqual(MeetingLinkDetector.firstLink(in: "zoom.us/j/123")?.host, "zoom.us")
    }

    func testIgnoresLookalikeHosts() {
        XCTAssertNil(MeetingLinkDetector.firstLink(in: "Policy: https://wiki.example.com/zoom-room-booking-policy"))
        XCTAssertNil(MeetingLinkDetector.firstLink(in: "https://evilzoom.us/j/1"))
        XCTAssertNil(MeetingLinkDetector.firstLink(in: nil))
        XCTAssertNil(MeetingLinkDetector.conferenceURL(from: "javascript:alert(1)"))
    }
}
