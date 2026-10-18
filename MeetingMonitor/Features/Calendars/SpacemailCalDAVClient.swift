import Foundation
import os

@MainActor
final class SpacemailCalDAVClient: ObservableObject, MeetingProvider {
    /// HTTP Basic credentials for CalDAV requests.
    struct BasicAuth: Sendable {
        let username: String
        let password: String

        var headerValue: String {
            "Basic \(Data("\(username):\(password)".utf8).base64EncodedString())"
        }
    }

    let source: MeetingSource = .spacemail
    /// Spacemail redirects bare `/` → `/dav.php`; requests go straight to dav.php so auth is kept.
    nonisolated static let caldavBase = URL(string: "https://caldav.spacemail.com/dav.php/")!

    private let logger = Logger(category: "SpacemailCalDAV")
    private let session: URLSession

    @Published private(set) var isConfigured = false
    @Published private(set) var email: String?
    /// Error from the most recent "Save & Verify".
    @Published private(set) var lastAuthError: String?
    @Published private(set) var isValidating = false

    private var credentials: CalendarCredentials? {
        didSet {
            applyCredentialState()
            discoveredCalendars = nil
            expandUnsupported = []
        }
    }

    /// Calendar collections found for the current credentials; cleared when a fetch fails.
    private var discoveredCalendars: [URL]?
    /// Collections whose server rejected `<c:expand>`; queried without it.
    private var expandUnsupported = Set<URL>()

    init(session: URLSession) {
        self.session = session
        credentials = CredentialStore.load(provider: MeetingSource.spacemail.credentialKey)
        // `didSet` does not run during init — apply loaded credentials explicitly.
        applyCredentialState()
    }

    private func applyCredentialState() {
        let hasUser = credentials?.username?.isEmpty == false
        let hasPass = credentials?.password?.isEmpty == false
        isConfigured = hasUser && hasPass
        email = credentials?.username
    }

    /// Saves credentials only after a successful CalDAV principal probe.
    func saveCredentials(email: String, password: String) async -> Bool {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty, !password.isEmpty else {
            lastAuthError = "Email and password are required."
            return false
        }

        isValidating = true
        lastAuthError = nil
        defer { isValidating = false }

        do {
            _ = try await principalURL(auth: BasicAuth(username: trimmedEmail, password: password))
        } catch {
            lastAuthError = error.localizedDescription
            logger.error("Spacemail credential check failed: \(error.localizedDescription, privacy: .public)")
            return false
        }

        let creds = CalendarCredentials(
            provider: MeetingSource.spacemail.credentialKey,
            username: trimmedEmail,
            password: password,
            accessToken: nil,
            refreshToken: nil,
            tokenExpiry: nil,
            clientId: nil,
            clientSecret: nil
        )
        credentials = creds
        CredentialStore.save(credential: creds)
        lastAuthError = nil
        logger.info("Spacemail credentials saved for \(trimmedEmail, privacy: .private)")
        return true
    }

    func clearCredentials() {
        credentials = nil
        lastAuthError = nil
        CredentialStore.delete(provider: MeetingSource.spacemail.credentialKey)
    }

    func fetchMeetings(from startDate: Date, to endDate: Date) async throws -> [Meeting] {
        guard let username = credentials?.username, let password = credentials?.password else {
            throw CalendarProviderError.notConfigured
        }
        let auth = BasicAuth(username: username, password: password)
        let calendars = try await calendarURLs(auth: auth)

        var events: [ICalEvent] = []
        var lastError: Error?
        var failures = 0
        for calendarURL in calendars {
            do {
                let calendarEvents = try await fetchEvents(calendarURL: calendarURL, auth: auth, from: startDate, to: endDate)
                events.append(contentsOf: calendarEvents)
            } catch {
                failures += 1
                lastError = error
                let name = calendarURL.lastPathComponent
                logger.warning("Spacemail calendar \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        if failures > 0 {
            // Collections may have moved; rediscover on the next fetch.
            discoveredCalendars = nil
        }
        if failures == calendars.count, let lastError {
            throw lastError
        }

        let parsedEvents = events
        return await Task.detached(priority: .utility) {
            RecurrenceExpander.meetings(
                from: parsedEvents,
                idPrefix: "spacemail",
                source: .spacemail,
                from: startDate,
                to: endDate
            )
        }.value
    }

    // MARK: - Discovery

    private func calendarURLs(auth: BasicAuth) async throws -> [URL] {
        if let discoveredCalendars { return discoveredCalendars }
        let principal = try await principalURL(auth: auth)
        let home = try await calendarHomeURL(principalURL: principal, auth: auth)
        let calendars = try await listCalendars(homeURL: home, auth: auth)
        logger.info("Spacemail discovered \(calendars.count, privacy: .public) calendar(s)")
        discoveredCalendars = calendars
        return calendars
    }

    /// PROPFIND `current-user-principal` on the CalDAV root; also serves as the credential check.
    private func principalURL(auth: BasicAuth) async throws -> URL {
        let data = try await send(
            "PROPFIND",
            to: Self.caldavBase,
            depth: "0",
            auth: auth,
            body: Self.propfindBody("<d:current-user-principal/>")
        )
        return try Self.firstHref(in: data, property: "current-user-principal") ?? Self.caldavBase
    }

    private func calendarHomeURL(principalURL: URL, auth: BasicAuth) async throws -> URL {
        let data = try await send(
            "PROPFIND",
            to: principalURL,
            depth: "0",
            auth: auth,
            body: Self.propfindBody("<c:calendar-home-set/>")
        )
        return try Self.firstHref(in: data, property: "calendar-home-set") ?? principalURL
    }

    private func listCalendars(homeURL: URL, auth: BasicAuth) async throws -> [URL] {
        let data = try await send(
            "PROPFIND",
            to: homeURL,
            depth: "1",
            auth: auth,
            body: Self.propfindBody("<d:displayname/><d:resourcetype/>")
        )
        let calendars = try Self.calendarCollections(in: data, relativeTo: homeURL)
        guard calendars.isEmpty else { return calendars }

        // Spacemail's SabreDAV layout keeps the default collection here.
        let fallback = Self.caldavBase
            .appendingPathComponent("calendars")
            .appendingPathComponent(auth.username)
            .appendingPathComponent("default", isDirectory: true)
        logger.info("No calendars listed; trying the default collection")
        return [fallback]
    }

    // MARK: - Events

    private func fetchEvents(calendarURL: URL, auth: BasicAuth, from startDate: Date, to endDate: Date) async throws -> [ICalEvent] {
        let start = Self.calDAVTimeRangeString(from: startDate)
        let end = Self.calDAVTimeRangeString(from: endDate)

        if !expandUnsupported.contains(calendarURL) {
            do {
                let body = Self.calendarQueryBody(start: start, end: end, expand: true)
                let data = try await send("REPORT", to: calendarURL, depth: "1", auth: auth, body: body)
                return try await Self.parseOffMain(data)
            } catch let CalendarProviderError.httpStatus(status) where Self.isExpandRejection(status) {
                logger.info("Server rejected calendar-data expand (\(status, privacy: .public)); querying without it")
                expandUnsupported.insert(calendarURL)
            }
        }

        let body = Self.calendarQueryBody(start: start, end: end, expand: false)
        let data = try await send("REPORT", to: calendarURL, depth: "1", auth: auth, body: body)
        return try await Self.parseOffMain(data)
    }

    /// Statuses a server uses to refuse the `<c:expand>` element itself (not auth or outages).
    nonisolated static func isExpandRejection(_ status: Int) -> Bool {
        [400, 412, 415, 422, 501].contains(status)
    }

    private nonisolated static func parseOffMain(_ data: Data) async throws -> [ICalEvent] {
        try await Task.detached(priority: .utility) {
            try parseCalendarQuery(data)
        }.value
    }

    // MARK: - Requests

    /// Sends a WebDAV request and returns the body of a 2xx response.
    private func send(_ method: String, to url: URL, depth: String, auth: BasicAuth, body: Data) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(depth, forHTTPHeaderField: "Depth")
        request.setValue(auth.headerValue, forHTTPHeaderField: "Authorization")
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CalendarProviderError.networkError("Invalid response from Spacemail CalDAV.")
        }
        guard (200...299).contains(http.statusCode) else {
            throw CalendarProviderError.forStatus(http.statusCode)
        }
        return data
    }
}
