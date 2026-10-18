import Foundation

/// Request bodies and WebDAV multistatus parsing for `SpacemailCalDAVClient`.
extension SpacemailCalDAVClient {
    nonisolated static func propfindBody(_ properties: String) -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
          <d:prop>\(properties)</d:prop>
        </d:propfind>
        """.utf8)
    }

    nonisolated static func calendarQueryBody(start: String, end: String, expand: Bool) -> Data {
        let calendarData = expand
            ? "<c:calendar-data><c:expand start=\"\(start)\" end=\"\(end)\"/></c:calendar-data>"
            : "<c:calendar-data/>"
        return Data("""
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
        """.utf8)
    }

    /// CalDAV RFC 4791 compact UTC form: `20260713T150000Z`.
    nonisolated static func calDAVTimeRangeString(from date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d%02d%02dT%02d%02d%02dZ",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0
        )
    }

    /// Events from every `calendar-data` in a calendar-query multistatus response.
    nonisolated static func parseCalendarQuery(_ xmlData: Data) throws -> [ICalEvent] {
        guard let root = try multistatusRoot(from: xmlData) else { return [] }
        return root.children(of: "response").flatMap { response -> [ICalEvent] in
            guard let calendarData = successfulPropstat(in: response)?
                .child(of: "prop")?
                .child(of: "calendar-data")?
                .content,
                !calendarData.isEmpty else {
                return []
            }
            return ICalendarParser.events(in: calendarData)
        }
    }

    /// First `<d:href>` inside `property` of a successful propstat.
    nonisolated static func firstHref(in data: Data, property: String) throws -> URL? {
        guard let root = try multistatusRoot(from: data) else { return nil }
        for response in root.children(of: "response") {
            if let href = successfulPropstat(in: response)?
                .child(of: "prop")?
                .child(of: property)?
                .child(of: "href")?
                .content {
                return resolve(href: href, relativeTo: caldavBase)
            }
        }
        return nil
    }

    /// Calendar collections in a Depth 1 PROPFIND of the calendar home.
    nonisolated static func calendarCollections(in data: Data, relativeTo homeURL: URL) throws -> [URL] {
        guard let root = try multistatusRoot(from: data) else { return [] }
        var calendars: [URL] = []
        for response in root.children(of: "response") {
            guard let href = response.child(of: "href")?.content, !href.isEmpty else { continue }
            let resourceType = successfulPropstat(in: response)?.child(of: "prop")?.child(of: "resourcetype")
            if resourceType?.child(of: "schedule-inbox") != nil || resourceType?.child(of: "schedule-outbox") != nil {
                continue
            }
            let lower = href.lowercased()
            let isCalendar = resourceType?.child(of: "calendar") != nil
                // Spacemail/Sabre often uses default/ as the real calendar collection.
                || lower.hasSuffix("/default/") || lower.hasSuffix("/default")
            if isCalendar, let url = resolve(href: href, relativeTo: homeURL) {
                calendars.append(url)
            }
        }
        return calendars
    }

    /// Resolves a server href against `base`, accepting only https URLs on the CalDAV host so
    /// credentials are never sent elsewhere.
    nonisolated static func resolve(href: String, relativeTo base: URL) -> URL? {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed, relativeTo: base)?.absoluteURL,
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              host == caldavBase.host?.lowercased() else {
            return nil
        }
        return url
    }

    private nonisolated static func successfulPropstat(in response: XMLNode) -> XMLNode? {
        for propstat in response.children(of: "propstat") {
            if let status = propstat.child(of: "status")?.content, status.contains(" 200 ") || status.hasSuffix(" 200") {
                return propstat
            }
            // Some servers omit status on success when only one propstat exists.
            if propstat.child(of: "prop") != nil, propstat.child(of: "status") == nil {
                return propstat
            }
        }
        return nil
    }

    /// The root element is the `multistatus` element itself.
    private nonisolated static func multistatusRoot(from data: Data) throws -> XMLNode? {
        let root = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever]).rootElement()
        return root?.matchesXMLName("multistatus") == true ? root : nil
    }
}

extension XMLNode {
    func matchesXMLName(_ name: String) -> Bool {
        let target = name.lowercased()
        if localName?.lowercased() == target { return true }
        guard let full = self.name?.lowercased() else { return false }
        return full == target || full.hasSuffix(":" + target)
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
