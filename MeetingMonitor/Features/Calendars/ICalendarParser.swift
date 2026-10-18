import Foundation

/// A DATE or DATE-TIME value together with the zone it was expressed in.
struct ICalDateTime: Sendable, Equatable {
    let date: Date
    let isDateOnly: Bool
    let timeZone: TimeZone

    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// Same instant, or the same day when either side is a DATE value.
    func matches(_ other: Date) -> Bool {
        if isDateOnly {
            return calendar.isDate(date, inSameDayAs: other)
        }
        return abs(date.timeIntervalSince(other)) < 1
    }
}

/// One VEVENT: the fields the app displays plus what recurrence expansion needs.
struct ICalEvent: Sendable {
    let uid: String
    let title: String
    let start: ICalDateTime
    let end: Date
    let location: String?
    let meetingLink: URL?
    let rrule: String?
    let exdates: [ICalDateTime]
    /// Set on an instance that overrides one occurrence of a recurring series.
    let recurrenceID: ICalDateTime?

    var isAllDay: Bool { start.isDateOnly }
}

/// RFC 5545 parsing for the subset of iCalendar that calendar servers return for VEVENTs.
enum ICalendarParser {
    struct Property {
        let name: String
        let parameters: [String: String]
        let value: String

        /// Splits `NAME;PARAM=a;PARAM="b:c":value`, honoring quoted parameter values.
        init?(line: String) {
            var segments: [String] = []
            var current = ""
            var inQuotes = false
            var valueStart: String.Index?
            for index in line.indices {
                let char = line[index]
                if char == "\"" {
                    inQuotes.toggle()
                    current.append(char)
                } else if !inQuotes, char == ";" {
                    segments.append(current)
                    current = ""
                } else if !inQuotes, char == ":" {
                    segments.append(current)
                    valueStart = line.index(after: index)
                    break
                } else {
                    current.append(char)
                }
            }
            guard let valueStart, let rawName = segments.first,
                  !rawName.trimmingCharacters(in: .whitespaces).isEmpty else {
                return nil
            }
            name = rawName.trimmingCharacters(in: .whitespaces).uppercased()
            var parameters: [String: String] = [:]
            for segment in segments.dropFirst() {
                let pair = segment.split(separator: "=", maxSplits: 1).map(String.init)
                guard pair.count == 2 else { continue }
                parameters[pair[0].uppercased()] = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
            self.parameters = parameters
            value = String(line[valueStart...])
        }
    }

    /// Top-level VEVENTs in `ical`. Nested components (VALARM, …) are skipped, and cancelled
    /// events are dropped.
    static func events(in ical: String) -> [ICalEvent] {
        var events: [ICalEvent] = []
        var properties: [Property] = []
        var inEvent = false
        var nestedDepth = 0

        for line in unfoldedLines(ical) {
            guard let property = Property(line: line) else { continue }
            let component = property.value.trimmingCharacters(in: .whitespaces).uppercased()
            switch property.name {
            case "BEGIN" where !inEvent && component == "VEVENT":
                inEvent = true
                nestedDepth = 0
                properties = []
            case "BEGIN" where inEvent:
                nestedDepth += 1
            case "END" where inEvent && nestedDepth == 0 && component == "VEVENT":
                inEvent = false
                if let event = makeEvent(from: properties) {
                    events.append(event)
                }
            case "END" where inEvent:
                nestedDepth = max(nestedDepth - 1, 0)
            default:
                if inEvent, nestedDepth == 0 {
                    properties.append(property)
                }
            }
        }
        return events
    }

    static func makeEvent(from properties: [Property]) -> ICalEvent? {
        func first(_ name: String) -> Property? {
            properties.first { $0.name == name }
        }

        if first("STATUS")?.value.uppercased() == "CANCELLED" { return nil }
        guard let dtStart = first("DTSTART"),
              let start = parseDateTime(dtStart.value, parameters: dtStart.parameters) else {
            return nil
        }

        let calendar = start.calendar
        let end: Date
        if let dtEnd = first("DTEND"), let parsed = parseDateTime(dtEnd.value, parameters: dtEnd.parameters) {
            end = max(parsed.date, start.date)
        } else if let rawDuration = first("DURATION")?.value, let duration = parseDuration(rawDuration) {
            let shifted = calendar.date(byAdding: .day, value: duration.days, to: start.date) ?? start.date
            end = shifted.addingTimeInterval(duration.seconds)
        } else if start.isDateOnly {
            // A DATE start with no end lasts the whole day.
            end = calendar.date(byAdding: .day, value: 1, to: start.date) ?? start.date
        } else {
            end = start.date.addingTimeInterval(3600)
        }

        let title = first("SUMMARY").map { unescapeText($0.value) }.flatMap { $0.isEmpty ? nil : $0 }
            ?? Meeting.untitled
        let location = first("LOCATION").map { unescapeText($0.value) }.flatMap { $0.isEmpty ? nil : $0 }
        let description = first("DESCRIPTION").map { unescapeText($0.value) }
        let meetingLink = MeetingLinkDetector.conferenceURL(from: first("URL")?.value)
            ?? MeetingLinkDetector.firstLink(in: location)
            ?? MeetingLinkDetector.firstLink(in: description)

        let exdates = properties
            .filter { $0.name == "EXDATE" }
            .flatMap { property in
                property.value.split(separator: ",").compactMap {
                    parseDateTime(String($0), parameters: property.parameters)
                }
            }
        let recurrenceID = first("RECURRENCE-ID").flatMap { parseDateTime($0.value, parameters: $0.parameters) }
        let uid = first("UID")?.value.trimmingCharacters(in: .whitespaces)
            ?? "nouid-\(title)-\(Int(start.date.timeIntervalSince1970))"

        return ICalEvent(
            uid: uid,
            title: title,
            start: start,
            end: end,
            location: location,
            meetingLink: meetingLink,
            rrule: first("RRULE")?.value,
            exdates: exdates,
            recurrenceID: recurrenceID
        )
    }

    // MARK: - Values

    /// Parses `yyyyMMdd`, `yyyyMMddTHHmmss` (floating or with TZID) and `yyyyMMddTHHmmssZ`.
    /// DATE values are floating and resolve in the current time zone.
    static func parseDateTime(_ raw: String, parameters: [String: String] = [:]) -> ICalDateTime? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let isUTC = trimmed.uppercased().hasSuffix("Z")
        let body = isUTC ? String(trimmed.dropLast()) : trimmed
        let parts = body.split(separator: "T", maxSplits: 1, omittingEmptySubsequences: false)

        guard let datePart = parts.first, datePart.count == 8,
              let year = Int(datePart.prefix(4)),
              let month = Int(datePart.dropFirst(4).prefix(2)),
              let day = Int(datePart.suffix(2)),
              (1...12).contains(month), (1...31).contains(day) else {
            return nil
        }

        var components = DateComponents(year: year, month: month, day: day)
        let isDateOnly = parts.count == 1
        if !isDateOnly {
            let time = parts[1]
            guard time.count == 6,
                  let hour = Int(time.prefix(2)),
                  let minute = Int(time.dropFirst(2).prefix(2)),
                  let second = Int(time.suffix(2)),
                  (0...23).contains(hour), (0...59).contains(minute), (0...60).contains(second) else {
                return nil
            }
            components.hour = hour
            components.minute = minute
            components.second = second
        }

        let timeZone: TimeZone
        if isUTC {
            timeZone = TimeZone(identifier: "UTC")!
        } else if !isDateOnly, let tzid = parameters["TZID"], let zone = TimeZone(identifier: tzid) {
            timeZone = zone
        } else {
            timeZone = .current
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let date = calendar.date(from: components),
              calendar.component(.day, from: date) == day else {
            return nil
        }
        return ICalDateTime(date: date, isDateOnly: isDateOnly, timeZone: timeZone)
    }

    /// ISO 8601 duration (`PT1H30M`, `P1D`, `P1W`), split into calendar days and clock seconds.
    static func parseDuration(_ value: String) -> (days: Int, seconds: TimeInterval)? {
        var text = value.uppercased().trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("+") { text.removeFirst() }
        guard text.hasPrefix("P") else { return nil }
        text.removeFirst()

        let halves = text.split(separator: "T", maxSplits: 1, omittingEmptySubsequences: false)
        guard let days = sumUnits(String(halves[0]), ["W": 7, "D": 1]),
              let seconds = halves.count > 1 ? sumUnits(String(halves[1]), ["H": 3600, "M": 60, "S": 1]) : 0,
              days > 0 || seconds > 0 else {
            return nil
        }
        return (days, TimeInterval(seconds))
    }

    /// Sums `<number><unit>` pairs; nil for unknown units or dangling numbers.
    private static func sumUnits(_ text: String, _ multipliers: [Character: Int]) -> Int? {
        var total = 0
        var number = ""
        for char in text {
            if char.isNumber {
                number.append(char)
            } else if let multiplier = multipliers[char], let amount = Int(number) {
                total += amount * multiplier
                number = ""
            } else {
                return nil
            }
        }
        return number.isEmpty ? total : nil
    }

    /// Decodes TEXT escapes: `\\`, `\,`, `\;`, `\n` / `\N`.
    static func unescapeText(_ value: String) -> String {
        var result = ""
        var escaping = false
        for char in value {
            if escaping {
                result.append(char == "n" || char == "N" ? "\n" : char)
                escaping = false
            } else if char == "\\" {
                escaping = true
            } else {
                result.append(char)
            }
        }
        if escaping { result.append("\\") }
        return result
    }

    /// Splits on CRLF or LF and joins folded continuation lines.
    static func unfoldedLines(_ ical: String) -> [String] {
        // "\r\n" is a single Character in Swift, so normalize before splitting.
        let normalized = ical
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var result: [String] = []
        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if let first = line.first, first == " " || first == "\t", !result.isEmpty {
                result[result.count - 1] += line.dropFirst()
            } else if !line.isEmpty {
                result.append(line)
            }
        }
        return result
    }
}
