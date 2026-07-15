import Foundation
import os

@MainActor
final class SpacemailCalDAVClient: ObservableObject {
    let source: MeetingSource = .spacemail
    private let logger = Logger(subsystem: "com.meetingmonitor.app", category: "SpacemailCalDAV")
    /// Spacemail redirects bare `/` → `/dav.php`; PROPFIND must hit dav.php so auth is not dropped.
    private let caldavBase = URL(string: "https://caldav.spacemail.com/dav.php/")!
    private let session: URLSession

    @Published private(set) var isConfigured = false
    @Published private(set) var email: String?
    @Published private(set) var lastAuthError: String?
    @Published private(set) var isValidating = false

    private var credentials: CalendarCredentials? {
        didSet { applyCredentialState() }
    }

    init(session: URLSession) {
        self.session = session
        credentials = CredentialStore.load(provider: "spacemail")
        // `didSet` does not run during init — apply loaded credentials explicitly.
        applyCredentialState()
    }

    private func applyCredentialState() {
        let hasUser = credentials?.username?.isEmpty == false
        let hasPass = credentials?.password?.isEmpty == false
        isConfigured = hasUser && hasPass
        email = credentials?.username
    }

    /// Save credentials only after a successful CalDAV principal probe.
    func saveCredentials(email: String, password: String) async -> Bool {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty, !trimmedPassword.isEmpty else {
            lastAuthError = "Email and password are required."
            return false
        }

        isValidating = true
        lastAuthError = nil
        defer { isValidating = false }

        do {
            try await verifyCredentials(username: trimmedEmail, password: trimmedPassword)
        } catch {
            lastAuthError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            logger.error("Spacemail credential check failed: \(self.lastAuthError ?? "", privacy: .public)")
            return false
        }

        let creds = CalendarCredentials(
            provider: "spacemail",
            username: trimmedEmail,
            password: trimmedPassword,
            accessToken: nil,
            refreshToken: nil,
            tokenExpiry: nil,
            clientId: nil,
            clientSecret: nil
        )
        credentials = creds
        CredentialStore.save(credential: creds)
        lastAuthError = nil
        logger.info("Spacemail credentials saved for \(trimmedEmail, privacy: .public)")
        return true
    }

    func clearCredentials() {
        credentials = nil
        lastAuthError = nil
        CredentialStore.delete(provider: "spacemail")
    }

    /// Lightweight PROPFIND against the CalDAV root to confirm username/password.
    private func verifyCredentials(username: String, password: String) async throws {
        let (_, response) = try await propfind(
            url: caldavBase,
            depth: "0",
            username: username,
            password: password,
            body: Self.principalPropfindBody
        )
        guard let http = response as? HTTPURLResponse else {
            throw CalendarProviderError.networkError("Invalid response from Spacemail CalDAV.")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw CalendarProviderError.invalidCredentials
        }
        guard (200...299).contains(http.statusCode) else {
            throw CalendarProviderError.httpStatus(http.statusCode)
        }
    }

    func fetchMeetings(from startDate: Date, to endDate: Date) async throws -> [Meeting] {
        guard let creds = credentials,
              let username = creds.username,
              let password = creds.password else {
            throw CalendarProviderError.notConfigured
        }

        let calendars = try await discoverCalendars(username: username, password: password)
        logger.info("Spacemail discovered \(calendars.count, privacy: .public) calendar(s)")
        if calendars.isEmpty {
            throw CalendarProviderError.networkError("No Spacemail calendars found for this account.")
        }

        var allMeetings: [Meeting] = []
        var lastError: Error?

        for calendarURL in calendars {
            do {
                let meetings = try await fetchEvents(
                    calendarURL: calendarURL,
                    username: username,
                    password: password,
                    from: startDate,
                    to: endDate
                )
                logger.info(
                    "Spacemail \(calendarURL.lastPathComponent, privacy: .public): \(meetings.count, privacy: .public) event(s)"
                )
                allMeetings.append(contentsOf: meetings)
            } catch {
                lastError = error
                logger.warning(
                    "Failed to fetch from calendar \(calendarURL.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        if allMeetings.isEmpty, let lastError {
            throw lastError
        }

        // Expand recurring masters into occurrences that fall inside the window.
        let expanded = Self.expandRecurring(meetings: allMeetings, from: startDate, to: endDate)
        return expanded
            .filter { $0.endDate > startDate && $0.startDate < endDate }
            .sorted { $0.startDate < $1.startDate }
    }

    // MARK: - Discovery

    private func discoverCalendars(username: String, password: String) async throws -> [URL] {
        let (data, response) = try await propfind(
            url: caldavBase,
            depth: "0",
            username: username,
            password: password,
            body: Self.principalPropfindBody
        )
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 { throw CalendarProviderError.invalidCredentials }
            throw CalendarProviderError.httpStatus(code)
        }

        let principalURL = try extractPrincipalURL(from: data) ?? caldavBase
        return try await fetchCalendarHome(principalURL: principalURL, username: username, password: password)
    }

    private func extractPrincipalURL(from data: Data) throws -> URL? {
        guard let root = try multistatusRoot(from: data) else { return nil }
        for response in root.children(of: "response") {
            guard let propstat = successfulPropstat(in: response),
                  let prop = propstat.child(of: "prop"),
                  let principal = prop.child(of: "current-user-principal"),
                  let href = principal.child(of: "href") else {
                continue
            }
            return url(fromHref: href.content ?? "/", relativeTo: caldavBase)
        }
        return nil
    }

    private func fetchCalendarHome(principalURL: URL, username: String, password: String) async throws -> [URL] {
        let body = """
        <?xml version="1.0" encoding="UTF-8"?>
        <d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
          <d:prop>
            <c:calendar-home-set/>
          </d:prop>
        </d:propfind>
        """.data(using: .utf8)!
        let (data, response) = try await propfind(
            url: principalURL,
            depth: "1",
            username: username,
            password: password,
            body: body
        )
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw CalendarProviderError.httpStatus(code)
        }

        let homeSetURL = try extractCalendarHomeSet(from: data) ?? principalURL
        return try await listCalendars(homeURL: homeSetURL, username: username, password: password)
    }

    private func extractCalendarHomeSet(from data: Data) throws -> URL? {
        guard let root = try multistatusRoot(from: data) else { return nil }
        for response in root.children(of: "response") {
            guard let propstat = successfulPropstat(in: response),
                  let prop = propstat.child(of: "prop"),
                  let homeSet = prop.child(of: "calendar-home-set"),
                  let href = homeSet.child(of: "href") else {
                continue
            }
            return url(fromHref: href.content ?? "/", relativeTo: caldavBase)
        }
        return nil
    }

    private func listCalendars(homeURL: URL, username: String, password: String) async throws -> [URL] {
        let body = """
        <?xml version="1.0" encoding="UTF-8"?>
        <d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
          <d:prop>
            <d:displayname/>
            <d:resourcetype/>
          </d:prop>
        </d:propfind>
        """.data(using: .utf8)!
        let (data, response) = try await propfind(
            url: homeURL,
            depth: "1",
            username: username,
            password: password,
            body: body
        )
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw CalendarProviderError.httpStatus(code)
        }

        var calendars: [URL] = []
        guard let root = try multistatusRoot(from: data) else { return calendars }

        for responseNode in root.children(of: "response") {
            let href = responseNode.child(of: "href")?.content ?? ""
            // Skip schedule inbox/outbox pseudo-calendars.
            let lower = href.lowercased()
            if lower.contains("inbox") || lower.contains("outbox") { continue }

            var isCalendar = false
            if let propstat = successfulPropstat(in: responseNode),
               let prop = propstat.child(of: "prop"),
               let resourceType = prop.child(of: "resourcetype"),
               resourceType.child(of: "calendar") != nil {
                isCalendar = true
            }
            // Spacemail/Sabre often uses default/ as the real calendar collection.
            if !isCalendar, lower.hasSuffix("/default/") || lower.hasSuffix("/default") {
                isCalendar = true
            }
            if isCalendar, !href.isEmpty, let url = url(fromHref: href, relativeTo: homeURL) {
                calendars.append(url)
            }
        }

        // Last-resort fallback used by Spacemail SabreDAV layout.
        if calendars.isEmpty {
            let fallback = caldavBase
                .appendingPathComponent("calendars")
                .appendingPathComponent(username)
                .appendingPathComponent("default", isDirectory: true)
            logger.info("No calendars listed; trying fallback \(fallback.absoluteString, privacy: .public)")
            calendars.append(fallback)
        }

        return calendars
    }

    // MARK: - Events

    private func fetchEvents(
        calendarURL: URL,
        username: String,
        password: String,
        from startDate: Date,
        to endDate: Date
    ) async throws -> [Meeting] {
        let start = Self.calDAVTimeRangeString(from: startDate)
        let end = Self.calDAVTimeRangeString(from: endDate)

        // Prefer server-side expand; fall back if the server rejects it.
        let expandBody = calendarQueryBody(start: start, end: end, expand: true)
        let (data, response) = try await report(
            url: calendarURL,
            username: username,
            password: password,
            body: expandBody
        )
        guard let http = response as? HTTPURLResponse else {
            throw CalendarProviderError.networkError("Invalid response")
        }

        if (200...299).contains(http.statusCode) {
            return try Self.parseICalEvents(from: data, calendarName: calendarURL.lastPathComponent)
        }

        logger.info("calendar-data expand unsupported (\(http.statusCode, privacy: .public)); retrying without expand")
        let plainBody = calendarQueryBody(start: start, end: end, expand: false)
        let (plainData, plainResponse) = try await report(
            url: calendarURL,
            username: username,
            password: password,
            body: plainBody
        )
        guard let plainHTTP = plainResponse as? HTTPURLResponse, (200...299).contains(plainHTTP.statusCode) else {
            let code = (plainResponse as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 { throw CalendarProviderError.invalidCredentials }
            throw CalendarProviderError.httpStatus(code)
        }
        return try Self.parseICalEvents(from: plainData, calendarName: calendarURL.lastPathComponent)
    }

    private func calendarQueryBody(start: String, end: String, expand: Bool) -> Data {
        let calendarData: String
        if expand {
            calendarData = """
            <c:calendar-data>
              <c:expand start="\(start)" end="\(end)"/>
            </c:calendar-data>
            """
        } else {
            calendarData = "<c:calendar-data/>"
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
          <d:prop>
            <d:getetag/>
            \(calendarData)
          </d:prop>
          <c:filter>
            <c:comp-filter name="VCALENDAR">
              <c:comp-filter name="VEVENT">
                <c:time-range start="\(start)" end="\(end)"/>
              </c:comp-filter>
            </c:comp-filter>
          </c:filter>
        </c:calendar-query>
        """.data(using: .utf8)!
    }

    // MARK: - Parsing (testable)

    /// CalDAV RFC 4791 compact UTC form: `20260713T150000Z`.
    nonisolated static func calDAVTimeRangeString(from date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: date)
    }

    nonisolated static func parseICalEvents(from xmlData: Data, calendarName: String) throws -> [Meeting] {
        guard let root = try multistatusRootStatic(from: xmlData) else { return [] }

        var meetings: [Meeting] = []
        for responseNode in root.children(of: "response") {
            guard let propstat = successfulPropstatStatic(in: responseNode),
                  let prop = propstat.child(of: "prop"),
                  let calendarData = prop.child(of: "calendar-data") else {
                continue
            }
            // calendar-data may be element text or CDATA.
            let icalString = calendarData.content
                ?? calendarData.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let icalString, !icalString.isEmpty else { continue }
            meetings.append(contentsOf: parseICalString(icalString, calendarName: calendarName))
        }
        return meetings
    }

    nonisolated static func parseICalString(_ ical: String, calendarName: String) -> [Meeting] {
        var meetings: [Meeting] = []
        let lines = unfoldICalLines(ical)

        var currentEvent: [String: String] = [:]
        var currentParams: [String: String] = [:]
        var attendees: [String] = []
        var exdates: [Date] = []
        var inEvent = false

        for line in lines {
            if line.hasPrefix("BEGIN:VEVENT") {
                inEvent = true
                currentEvent = [:]
                currentParams = [:]
                attendees = []
                exdates = []
                continue
            }
            if line.hasPrefix("END:VEVENT") {
                inEvent = false
                if let meeting = makeMeeting(
                    from: currentEvent,
                    params: currentParams,
                    attendees: attendees,
                    exdates: exdates,
                    calendarName: calendarName
                ) {
                    meetings.append(meeting)
                }
                continue
            }
            guard inEvent else { continue }

            guard let colon = line.firstIndex(of: ":") else { continue }
            let namePart = String(line[..<colon])
            let value = String(line[line.index(after: colon)...])
            let key = propertyName(from: namePart).uppercased()

            if key == "ATTENDEE" {
                if let email = mailtoEmail(from: value) {
                    attendees.append(email)
                }
                continue
            }

            if key == "EXDATE" {
                let tzid = paramValue(from: namePart, name: "TZID")
                for part in value.split(separator: ",") {
                    if let d = parseDate(String(part), tzid: tzid) {
                        exdates.append(d)
                    }
                }
                continue
            }

            // Keep last value; also store params for DTSTART/DTEND/RRULE handling.
            currentEvent[key] = value
            currentParams[key] = namePart
        }

        return meetings
    }

    nonisolated static func makeMeeting(
        from event: [String: String],
        params: [String: String],
        attendees: [String],
        exdates: [Date],
        calendarName: String
    ) -> Meeting? {
        guard let summary = event["SUMMARY"] else { return nil }
        guard let dtStart = event["DTSTART"] else { return nil }

        let startParams = params["DTSTART"] ?? "DTSTART"
        let endParams = params["DTEND"] ?? "DTEND"
        let startTzid = paramValue(from: startParams, name: "TZID")
        let endTzid = paramValue(from: endParams, name: "TZID") ?? startTzid
        let isAllDay = (paramValue(from: startParams, name: "VALUE")?.uppercased() == "DATE")
            || (dtStart.count == 8 && !dtStart.contains("T"))

        guard let startDate = parseDate(dtStart, tzid: startTzid) else { return nil }
        let endRaw = event["DTEND"] ?? dtStart
        var endDate = parseDate(endRaw, tzid: endTzid) ?? startDate
        // All-day DTEND is exclusive; keep as-is for overlap math.

        // Timed events with missing DTEND default to 1 hour.
        if !isAllDay, event["DTEND"] == nil, let duration = event["DURATION"],
           let seconds = parseDuration(duration) {
            endDate = startDate.addingTimeInterval(seconds)
        } else if !isAllDay, event["DTEND"] == nil {
            endDate = startDate.addingTimeInterval(3600)
        }

        let location = event["LOCATION"]
        let description = event["DESCRIPTION"]
        let meetingLink = extractMeetingLink(from: location) ?? extractMeetingLink(from: description)
        let rrule = event["RRULE"]
        let isRecurring = rrule != nil

        let eventUID = event["UID"] ?? UUID().uuidString
        let id = "spacemail_\(eventUID)_\(Int(startDate.timeIntervalSince1970))"

        if let rrule, !rrule.isEmpty {
            RecurrenceStore.set(
                id: id,
                rrule: rrule,
                exdates: exdates,
                duration: endDate.timeIntervalSince(startDate)
            )
        }

        return Meeting(
            id: id,
            title: summary,
            startDate: startDate,
            endDate: endDate,
            location: location,
            meetingLink: meetingLink,
            isAllDay: isAllDay,
            source: .spacemail,
            attendees: attendees,
            isRecurring: isRecurring,
            calendarName: calendarName
        )
    }

    /// Expand recurring masters into concrete occurrences that overlap `[from, to)`.
    nonisolated static func expandRecurring(
        meetings: [Meeting],
        from: Date,
        to: Date
    ) -> [Meeting] {
        defer { RecurrenceStore.clear() }

        var result: [Meeting] = []
        var seen = Set<String>()

        for meeting in meetings {
            guard meeting.isRecurring,
                  let meta = RecurrenceStore.get(id: meeting.id) else {
                // Non-recurring (or already expanded instance from server).
                if seen.insert(meeting.id).inserted {
                    result.append(meeting)
                }
                continue
            }

            let starts = occurrenceStarts(
                masterStart: meeting.startDate,
                rrule: meta.rrule,
                exdates: meta.exdates,
                from: from,
                to: to,
                isAllDay: meeting.isAllDay
            )

            if starts.isEmpty {
                // Server may have already expanded (instance DTSTART in range) or no hits.
                // If the master itself overlaps the window, keep it.
                if meeting.endDate > from && meeting.startDate < to, seen.insert(meeting.id).inserted {
                    result.append(meeting)
                }
                continue
            }

            for start in starts {
                let end = start.addingTimeInterval(meta.duration)
                let instanceID = "\(meeting.id)_occ_\(Int(start.timeIntervalSince1970))"
                guard seen.insert(instanceID).inserted else { continue }
                result.append(
                    Meeting(
                        id: instanceID,
                        title: meeting.title,
                        startDate: start,
                        endDate: end,
                        location: meeting.location,
                        meetingLink: meeting.meetingLink,
                        isAllDay: meeting.isAllDay,
                        source: meeting.source,
                        attendees: meeting.attendees,
                        isRecurring: true,
                        calendarName: meeting.calendarName
                    )
                )
            }
        }
        return result
    }

    /// Compute occurrence start dates for common RRULE forms (DAILY / WEEKLY / MONTHLY).
    nonisolated static func occurrenceStarts(
        masterStart: Date,
        rrule: String,
        exdates: [Date],
        from: Date,
        to: Date,
        isAllDay: Bool
    ) -> [Date] {
        let parts = parseRRule(rrule)
        guard let freq = parts["FREQ"]?.uppercased() else { return [] }

        let interval = Int(parts["INTERVAL"] ?? "1") ?? 1
        let count = parts["COUNT"].flatMap(Int.init)
        let until = parts["UNTIL"].flatMap { parseDate($0, tzid: nil) }
        let byDays = (parts["BYDAY"] ?? "")
            .split(separator: ",")
            .map { String($0).uppercased() }
            .filter { !$0.isEmpty }

        let calendar = Calendar.current
        let exSet: Set<TimeInterval> = Set(exdates.map { calendar.startOfDay(for: $0).timeIntervalSince1970 })

        var results: [Date] = []
        var cursor = masterStart
        var generated = 0
        let hardCap = 500

        // Walk forward from the master start until past `to`.
        while generated < hardCap {
            if let until, cursor > until { break }
            if let count, generated >= count { break }
            if cursor >= to { break }

            // Occurrence start in [from, to).
            if cursor >= from && cursor < to {
                let dayKey = calendar.startOfDay(for: cursor).timeIntervalSince1970
                if !exSet.contains(dayKey) {
                    results.append(cursor)
                }
            }
            generated += 1

            guard let next = advance(
                cursor: cursor,
                freq: freq,
                interval: interval,
                byDays: byDays,
                masterStart: masterStart,
                calendar: calendar,
                isAllDay: isAllDay
            ) else { break }

            if next <= cursor { break }
            cursor = next
        }

        return results
    }

    nonisolated private static func advance(
        cursor: Date,
        freq: String,
        interval: Int,
        byDays: [String],
        masterStart: Date,
        calendar: Calendar,
        isAllDay: Bool
    ) -> Date? {
        switch freq {
        case "DAILY":
            return calendar.date(byAdding: .day, value: max(interval, 1), to: cursor)
        case "WEEKLY":
            if byDays.isEmpty {
                return calendar.date(byAdding: .day, value: 7 * max(interval, 1), to: cursor)
            }
            let weekdayMap: [String: Int] = [
                "SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7
            ]
            let targets = Set(byDays.compactMap { token -> Int? in
                let key = String(token.suffix(2))
                return weekdayMap[key]
            })
            guard !targets.isEmpty else {
                return calendar.date(byAdding: .day, value: 7 * max(interval, 1), to: cursor)
            }
            var d = calendar.date(byAdding: .day, value: 1, to: cursor) ?? cursor
            for _ in 0..<400 {
                let wd = calendar.component(.weekday, from: d)
                if targets.contains(wd) {
                    let days = calendar.dateComponents(
                        [.day],
                        from: calendar.startOfDay(for: masterStart),
                        to: calendar.startOfDay(for: d)
                    ).day ?? 0
                    if days >= 0, (days / 7) % max(interval, 1) == 0 {
                        return applyTime(of: masterStart, onto: d, calendar: calendar, isAllDay: isAllDay)
                    }
                }
                guard let next = calendar.date(byAdding: .day, value: 1, to: d) else { return nil }
                d = next
            }
            return nil
        case "MONTHLY":
            return calendar.date(byAdding: .month, value: max(interval, 1), to: cursor)
        case "YEARLY":
            return calendar.date(byAdding: .year, value: max(interval, 1), to: cursor)
        default:
            return nil
        }
    }

    nonisolated private static func applyTime(
        of source: Date,
        onto day: Date,
        calendar: Calendar,
        isAllDay: Bool
    ) -> Date {
        if isAllDay {
            return calendar.startOfDay(for: day)
        }
        var comps = calendar.dateComponents([.year, .month, .day], from: day)
        let time = calendar.dateComponents([.hour, .minute, .second], from: source)
        comps.hour = time.hour
        comps.minute = time.minute
        comps.second = time.second
        return calendar.date(from: comps) ?? day
    }

    nonisolated static func parseRRule(_ rrule: String) -> [String: String] {
        var result: [String: String] = [:]
        for part in rrule.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            result[kv[0].uppercased()] = kv[1]
        }
        return result
    }

    nonisolated static func parseDate(_ dateStr: String, tzid: String? = nil) -> Date? {
        let cleaned = dateStr.trimmingCharacters(in: .whitespacesAndNewlines)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")

        if cleaned.count == 8, !cleaned.contains("T") {
            f.timeZone = TimeZone.current
            f.dateFormat = "yyyyMMdd"
            return f.date(from: cleaned)
        }

        if cleaned.hasSuffix("Z") {
            f.timeZone = TimeZone(secondsFromGMT: 0)
            f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            if let date = f.date(from: cleaned) { return date }
            f.dateFormat = "yyyyMMdd'T'HHmmss"
            return f.date(from: String(cleaned.dropLast()))
        }

        if let tzid, let tz = TimeZone(identifier: tzid) {
            f.timeZone = tz
        } else {
            f.timeZone = TimeZone.current
        }
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        if let date = f.date(from: cleaned) { return date }
        f.dateFormat = "yyyyMMdd'T'HHmmssZ"
        return f.date(from: cleaned)
    }

    /// Legacy entry point used by tests.
    nonisolated static func parseDate(_ dateStr: String) -> Date? {
        parseDate(dateStr, tzid: nil)
    }

    nonisolated static func parseDuration(_ value: String) -> TimeInterval? {
        // Basic ISO-8601 duration: PT1H30M / PT45M / P1D
        var s = value.uppercased()
        guard s.hasPrefix("P") else { return nil }
        s = String(s.dropFirst())
        var total: TimeInterval = 0
        if let tRange = s.range(of: "T") {
            let datePart = String(s[..<tRange.lowerBound])
            let timePart = String(s[tRange.upperBound...])
            total += scanDurationUnits(datePart, day: 86400, hour: 0, minute: 0, second: 0)
            total += scanDurationUnits(timePart, day: 0, hour: 3600, minute: 60, second: 1)
        } else {
            total += scanDurationUnits(s, day: 86400, hour: 3600, minute: 60, second: 1)
        }
        return total > 0 ? total : nil
    }

    nonisolated private static func scanDurationUnits(
        _ s: String,
        day: TimeInterval,
        hour: TimeInterval,
        minute: TimeInterval,
        second: TimeInterval
    ) -> TimeInterval {
        var total: TimeInterval = 0
        var num = ""
        for ch in s {
            if ch.isNumber {
                num.append(ch)
                continue
            }
            let n = TimeInterval(num) ?? 0
            num = ""
            switch ch {
            case "D": total += n * day
            case "H": total += n * hour
            case "M": total += n * minute
            case "S": total += n * second
            case "W": total += n * 7 * 86400
            default: break
            }
        }
        return total
    }

    nonisolated static func extractMeetingLink(from text: String?) -> String? {
        guard let text else { return nil }
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        let matches = detector?.matches(in: text, range: range) ?? []
        for match in matches {
            guard let url = match.url else { continue }
            let urlStr = url.absoluteString.lowercased()
            if urlStr.contains("meet.google") || urlStr.contains("zoom") ||
               urlStr.contains("teams.microsoft") || urlStr.contains("webex") {
                return url.absoluteString
            }
        }
        return nil
    }

    // MARK: - Helpers

    nonisolated private static func unfoldICalLines(_ ical: String) -> [String] {
        var result: [String] = []
        for raw in ical.components(separatedBy: .newlines) {
            if raw.hasPrefix(" ") || raw.hasPrefix("\t"), !result.isEmpty {
                result[result.count - 1] += raw.dropFirst()
            } else if !raw.isEmpty {
                result.append(raw)
            }
        }
        return result
    }

    nonisolated private static func propertyName(from namePart: String) -> String {
        // "DTSTART;TZID=America/New_York" → "DTSTART"
        let base = namePart.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first
            .map(String.init) ?? namePart
        return base.trimmingCharacters(in: .whitespaces)
    }

    nonisolated private static func paramValue(from namePart: String, name: String) -> String? {
        // "DTSTART;TZID=America/Denver;VALUE=DATE" → param lookup
        let parts = namePart.split(separator: ";").dropFirst()
        for part in parts {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2, kv[0].uppercased() == name.uppercased() {
                return kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return nil
    }

    nonisolated private static func mailtoEmail(from value: String) -> String? {
        if let range = value.range(of: "mailto:", options: .caseInsensitive) {
            return String(value[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        if value.contains("@") {
            return value.trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private func successfulPropstat(in response: XMLNode) -> XMLNode? {
        Self.successfulPropstatStatic(in: response)
    }

    nonisolated private static func successfulPropstatStatic(in response: XMLNode) -> XMLNode? {
        for propstat in response.children(of: "propstat") {
            if let status = propstat.child(of: "status")?.content,
               status.contains("200") {
                return propstat
            }
            // Some servers omit status on success when only one propstat exists.
            if propstat.child(of: "prop") != nil, propstat.child(of: "status") == nil {
                return propstat
            }
        }
        // Fallback: first propstat with a prop child.
        return response.children(of: "propstat").first { $0.child(of: "prop") != nil }
    }

    private static let principalPropfindBody = """
    <?xml version="1.0" encoding="UTF-8"?>
    <d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
      <d:prop>
        <d:current-user-principal/>
      </d:prop>
    </d:propfind>
    """.data(using: .utf8)!

    private func basicAuth(username: String, password: String) -> String {
        let combined = "\(username):\(password)"
        return "Basic \(Data(combined.utf8).base64EncodedString())"
    }

    private func propfind(
        url: URL,
        depth: String,
        username: String,
        password: String,
        body: Data
    ) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "PROPFIND"
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(depth, forHTTPHeaderField: "Depth")
        request.setValue(basicAuth(username: username, password: password), forHTTPHeaderField: "Authorization")
        request.httpBody = body
        return try await session.data(for: request)
    }

    private func report(
        url: URL,
        username: String,
        password: String,
        body: Data
    ) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "REPORT"
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue(basicAuth(username: username, password: password), forHTTPHeaderField: "Authorization")
        request.httpBody = body
        return try await session.data(for: request)
    }

    /// Root element *is* `multistatus` (not a parent of it). Looking for a nested child always failed.
    private func multistatusRoot(from data: Data) throws -> XMLNode? {
        try Self.multistatusRootStatic(from: data)
    }

    nonisolated private static func multistatusRootStatic(from data: Data) throws -> XMLNode? {
        let root = try XMLDocument(data: data).rootElement()
        if root?.matchesXMLName("multistatus") == true {
            return root
        }
        return root?.child(of: "multistatus")
    }

    private func url(fromHref href: String, relativeTo base: URL) -> URL? {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return URL(string: trimmed)
        }
        // Build absolute URL without URLComponents path quirks around `@` in emails.
        if trimmed.hasPrefix("/") {
            return URL(string: "https://caldav.spacemail.com" + trimmed)
        }
        return URL(string: trimmed, relativeTo: base)?.absoluteURL
    }
}

// MARK: - Recurrence metadata (parse → expand)

/// Temporary RRULE/EXDATE stash for masters between parse and expand.
private enum RecurrenceStore {
    struct Meta {
        var rrule: String
        var exdates: [Date]
        var duration: TimeInterval
    }

    private static let lock = NSLock()
    private static var map: [String: Meta] = [:]

    static func set(id: String, rrule: String, exdates: [Date], duration: TimeInterval) {
        lock.lock()
        map[id] = Meta(rrule: rrule, exdates: exdates, duration: max(duration, 60))
        lock.unlock()
    }

    static func get(id: String) -> Meta? {
        lock.lock()
        defer { lock.unlock() }
        return map[id]
    }

    static func clear() {
        lock.lock()
        map.removeAll(keepingCapacity: false)
        lock.unlock()
    }
}

extension XMLNode {
    func matchesXMLName(_ name: String) -> Bool {
        let target = name.lowercased()
        if localName?.lowercased() == target { return true }
        if self.name?.lowercased() == target { return true }
        if let full = self.name?.lowercased(), full.hasSuffix(":" + target) { return true }
        return false
    }

    func child(of name: String) -> XMLNode? {
        children?.first { $0.matchesXMLName(name) }
    }

    func children(of name: String) -> [XMLNode] {
        children?.filter { $0.matchesXMLName(name) } ?? []
    }

    var content: String? {
        stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
