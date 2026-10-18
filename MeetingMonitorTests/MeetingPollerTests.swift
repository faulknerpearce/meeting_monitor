@testable import MeetingMonitor
import XCTest

@MainActor
private final class FakeProvider: MeetingProvider {
    let source: MeetingSource
    var isConfigured = true
    var result: Result<[Meeting], Error>

    init(_ source: MeetingSource, _ result: Result<[Meeting], Error>) {
        self.source = source
        self.result = result
    }

    func fetchMeetings(from startDate: Date, to endDate: Date) async throws -> [Meeting] {
        try result.get()
    }
}

@MainActor
final class MeetingPollerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        suiteName = "MeetingPollerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func upcoming(_ id: String, source: MeetingSource) -> Meeting {
        let now = Date()
        return TestSupport.meeting(id: id, start: now.addingTimeInterval(600), end: now.addingTimeInterval(1200), source: source)
    }

    func testFailingSourceKeepsItsPreviousMeetings() async {
        let google = FakeProvider(.googleCalendar, .success([upcoming("g1", source: .googleCalendar)]))
        let spacemail = FakeProvider(.spacemail, .success([upcoming("s1", source: .spacemail)]))
        let poller = MeetingPoller(settings: AppSettings(defaults: defaults), providers: [google, spacemail])

        await poller.refreshNow()
        XCTAssertEqual(Set(poller.upcomingMeetings.map(\.id)), ["g1", "s1"])

        spacemail.result = .failure(CalendarProviderError.httpStatus(500))
        google.result = .success([upcoming("g2", source: .googleCalendar)])
        await poller.refreshNow()

        XCTAssertEqual(Set(poller.upcomingMeetings.map(\.id)), ["g2", "s1"])
        XCTAssertNil(poller.error(for: .googleCalendar))
        XCTAssertEqual(poller.error(for: .spacemail) as? CalendarProviderError, .httpStatus(500))
        XCTAssertEqual(poller.lastError, "Spacemail: Server returned HTTP 500.")
        XCTAssertEqual(poller.backoffSeconds, 0)
    }

    func testAllSourcesFailingBacksOff() async {
        let google = FakeProvider(.googleCalendar, .success([upcoming("g1", source: .googleCalendar)]))
        let poller = MeetingPoller(settings: AppSettings(defaults: defaults), providers: [google])
        await poller.refreshNow()

        google.result = .failure(URLError(.notConnectedToInternet))
        await poller.refreshNow()
        XCTAssertEqual(poller.upcomingMeetings.map(\.id), ["g1"])
        XCTAssertEqual(poller.backoffSeconds, 30)

        await poller.refreshNow()
        XCTAssertEqual(poller.backoffSeconds, 60)
    }

    func testCancellationDoesNotReplaceError() async {
        let google = FakeProvider(.googleCalendar, .failure(CalendarProviderError.httpStatus(503)))
        let poller = MeetingPoller(settings: AppSettings(defaults: defaults), providers: [google])
        await poller.refreshNow()

        google.result = .failure(URLError(.cancelled))
        await poller.refreshNow()
        XCTAssertEqual(poller.error(for: .googleCalendar) as? CalendarProviderError, .httpStatus(503))
    }

    func testDisconnectedSourceIsDropped() async {
        let google = FakeProvider(.googleCalendar, .success([upcoming("g1", source: .googleCalendar)]))
        let poller = MeetingPoller(settings: AppSettings(defaults: defaults), providers: [google])
        await poller.refreshNow()

        google.isConfigured = false
        await poller.refreshNow()
        XCTAssertTrue(poller.upcomingMeetings.isEmpty)
        XCTAssertFalse(poller.isConfigured(.googleCalendar))
    }

    func testCredentialRejectionIsTyped() async {
        let spacemail = FakeProvider(.spacemail, .failure(CalendarProviderError.invalidCredentials))
        let poller = MeetingPoller(settings: AppSettings(defaults: defaults), providers: [spacemail])
        await poller.refreshNow()
        XCTAssertEqual(poller.error(for: .spacemail) as? CalendarProviderError, .invalidCredentials)
    }

    func testFetchWindowIsAnchoredAtNow() {
        let calendar = TestSupport.denverCalendar
        let afternoon = TestSupport.date(2026, 7, 13, 14)
        let endOfToday = TestSupport.date(2026, 7, 14)

        let short = MeetingPoller.fetchWindow(now: afternoon, lookaheadHours: 1, calendar: calendar)
        XCTAssertEqual(short.start, TestSupport.date(2026, 7, 13))
        XCTAssertEqual(short.end, endOfToday)

        let lateNight = TestSupport.date(2026, 7, 13, 23)
        let long = MeetingPoller.fetchWindow(now: lateNight, lookaheadHours: 72, calendar: calendar)
        XCTAssertEqual(long.end, lateNight.addingTimeInterval(72 * 3600))
    }
}
