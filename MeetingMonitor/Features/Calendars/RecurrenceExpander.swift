import Foundation
import os

/// The supported subset of an RFC 5545 RRULE: FREQ (DAILY/WEEKLY/MONTHLY/YEARLY), INTERVAL,
/// COUNT, UNTIL, BYDAY (with ordinals for MONTHLY/YEARLY), BYMONTHDAY, BYMONTH and WKST.
struct RecurrenceRule: Equatable {
    enum Frequency: String {
        case daily = "DAILY"
        case weekly = "WEEKLY"
        case monthly = "MONTHLY"
        case yearly = "YEARLY"
    }

    struct WeekdayRule: Equatable {
        /// `2` in `2TU`, `-1` in `-1FR`; nil for every such weekday in the period.
        let ordinal: Int?
        /// `Calendar` weekday number (1 = Sunday … 7 = Saturday).
        let weekday: Int
    }

    static let weekdayNumbers = ["SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7]
    private static let unsupportedParts: Set<String> = [
        "BYSETPOS", "BYHOUR", "BYMINUTE", "BYSECOND", "BYWEEKNO", "BYYEARDAY",
    ]

    let frequency: Frequency
    let interval: Int
    let count: Int?
    let until: ICalDateTime?
    let byDay: [WeekdayRule]
    let byMonthDay: [Int]
    let byMonth: [Int]
    let weekStart: Int

    /// Nil when the rule uses parts outside the supported subset.
    init?(_ rrule: String) {
        let parts = Self.parts(of: rrule)
        guard let frequency = parts["FREQ"].flatMap({ Frequency(rawValue: $0.uppercased()) }),
              parts.keys.allSatisfy({ !Self.unsupportedParts.contains($0) }),
              let byDay = Self.weekdayRules(parts["BYDAY"]) else {
            return nil
        }
        let byMonthDay = Self.integers(parts["BYMONTHDAY"])
        let byMonth = Self.integers(parts["BYMONTH"])
        guard Self.isExpressible(frequency, byDay: byDay, byMonthDay: byMonthDay, byMonth: byMonth) else {
            return nil
        }

        self.frequency = frequency
        interval = max(Int(parts["INTERVAL"] ?? "") ?? 1, 1)
        count = parts["COUNT"].flatMap { Int($0) }
        until = parts["UNTIL"].flatMap { ICalendarParser.parseDateTime($0) }
        self.byDay = byDay
        self.byMonthDay = byMonthDay
        self.byMonth = byMonth
        weekStart = parts["WKST"].flatMap { Self.weekdayNumbers[$0.uppercased()] } ?? 2
    }

    private static func parts(of rrule: String) -> [String: String] {
        var parts: [String: String] = [:]
        for part in rrule.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if pair.count == 2 {
                parts[pair[0].uppercased()] = pair[1]
            }
        }
        return parts
    }

    private static func integers(_ list: String?) -> [Int] {
        (list?.split(separator: ",") ?? []).compactMap { Int($0) }
    }

    /// Parses `MO,2TU,-1FR`; nil when any token is malformed.
    private static func weekdayRules(_ list: String?) -> [WeekdayRule]? {
        var rules: [WeekdayRule] = []
        for token in list?.split(separator: ",") ?? [] {
            let upper = token.uppercased()
            guard let weekday = weekdayNumbers[String(upper.suffix(2))] else { return nil }
            let prefix = upper.dropLast(2)
            guard prefix.isEmpty || (Int(prefix) ?? 0) != 0 else { return nil }
            rules.append(WeekdayRule(ordinal: prefix.isEmpty ? nil : Int(prefix), weekday: weekday))
        }
        return rules
    }

    /// Combinations this expander can evaluate.
    private static func isExpressible(
        _ frequency: Frequency,
        byDay: [WeekdayRule],
        byMonthDay: [Int],
        byMonth: [Int]
    ) -> Bool {
        let hasOrdinals = byDay.contains { $0.ordinal != nil }
        switch frequency {
        case .daily, .weekly:
            return !hasOrdinals && byMonthDay.isEmpty
        case .yearly:
            // Ordinals across a whole year ("20MO") need BYMONTH to be expressible per month.
            return !hasOrdinals || !byMonth.isEmpty
        case .monthly:
            return true
        }
    }
}

/// Turns parsed VEVENTs into `Meeting`s, expanding recurring series inside a window.
enum RecurrenceExpander {
    private static let logger = Logger(category: "Recurrence")
    /// Upper bound on periods walked per series, guarding against malformed rules.
    static let maxPeriods = 50000

    static func meetings(
        from events: [ICalEvent],
        idPrefix: String,
        source: MeetingSource,
        from windowStart: Date,
        to windowEnd: Date
    ) -> [Meeting] {
        var overridesByUID: [String: [ICalDateTime]] = [:]
        for event in events {
            if let recurrenceID = event.recurrenceID {
                overridesByUID[event.uid, default: []].append(recurrenceID)
            }
        }

        var result: [Meeting] = []
        var seen = Set<String>()
        for event in events {
            var starts = [event.start.date]
            if event.recurrenceID == nil, let raw = event.rrule {
                if let rule = RecurrenceRule(raw) {
                    starts = occurrenceStarts(
                        of: event,
                        rule: rule,
                        excluding: event.exdates + (overridesByUID[event.uid] ?? []),
                        from: windowStart,
                        to: windowEnd
                    )
                } else {
                    logger.info("Unsupported RRULE; showing the series start only: \(raw, privacy: .public)")
                }
            }
            for start in starts {
                let meeting = makeMeeting(event, start: start, idPrefix: idPrefix, source: source)
                guard meeting.endDate > windowStart, meeting.startDate < windowEnd,
                      seen.insert(meeting.id).inserted else {
                    continue
                }
                result.append(meeting)
            }
        }
        return result.sorted { $0.startDate < $1.startDate }
    }

    static func makeMeeting(_ event: ICalEvent, start: Date, idPrefix: String, source: MeetingSource) -> Meeting {
        let end: Date
        if event.isAllDay {
            let calendar = event.start.calendar
            let days = max(calendar.dateComponents([.day], from: event.start.date, to: event.end).day ?? 1, 1)
            end = calendar.date(byAdding: .day, value: days, to: start) ?? start
        } else {
            end = start.addingTimeInterval(event.end.timeIntervalSince(event.start.date))
        }
        return Meeting(
            id: "\(idPrefix)_\(event.uid)_\(Int(start.timeIntervalSince1970))",
            title: event.title,
            startDate: start,
            endDate: end,
            location: event.location,
            meetingLink: event.meetingLink,
            isAllDay: event.isAllDay,
            source: source
        )
    }

    /// Occurrence starts of `event` overlapping `[from, to)`, minus `excluded` instants.
    static func occurrenceStarts(
        of event: ICalEvent,
        rule: RecurrenceRule,
        excluding excluded: [ICalDateTime] = [],
        from windowStart: Date,
        to windowEnd: Date
    ) -> [Date] {
        var calendar = event.start.calendar
        calendar.firstWeekday = rule.weekStart
        let walker = PeriodWalker(rule: rule, seriesStart: event.start.date, isAllDay: event.isAllDay, calendar: calendar)
        let duration = max(event.end.timeIntervalSince(event.start.date), 1)

        let untilBound: Date? = rule.until.map { until in
            until.isDateOnly
                ? until.calendar.date(byAdding: .day, value: 1, to: until.date) ?? until.date
                : until.date.addingTimeInterval(1)
        }

        // COUNT needs every occurrence from the series start; otherwise skip ahead to the window.
        let firstPeriod = rule.count == nil
            ? max(walker.periodIndex(of: windowStart.addingTimeInterval(-duration)) - 1, 0)
            : 0

        var results: [Date] = []
        var generated = 0
        for period in firstPeriod..<(firstPeriod + maxPeriods) {
            guard let periodStart = walker.periodStart(period), periodStart < windowEnd else { break }
            if let untilBound, periodStart >= untilBound { break }

            for candidate in walker.candidates(inPeriod: period) where candidate >= event.start.date {
                if let untilBound, candidate >= untilBound { return results }
                generated += 1
                if let count = rule.count, generated > count { return results }
                guard candidate < windowEnd, candidate.addingTimeInterval(duration) > windowStart,
                      !excluded.contains(where: { $0.matches(candidate) }) else {
                    continue
                }
                results.append(candidate)
            }
        }
        return results
    }
}

/// Enumerates the periods (days, weeks, months, years) of a rule and the candidate starts in each.
private struct PeriodWalker {
    let rule: RecurrenceRule
    let seriesStart: Date
    let isAllDay: Bool
    let calendar: Calendar
    let anchor: Date

    init(rule: RecurrenceRule, seriesStart: Date, isAllDay: Bool, calendar: Calendar) {
        self.rule = rule
        self.seriesStart = seriesStart
        self.isAllDay = isAllDay
        self.calendar = calendar
        let unit: Calendar.Component
        switch rule.frequency {
        case .daily: unit = .day
        case .weekly: unit = .weekOfYear
        case .monthly: unit = .month
        case .yearly: unit = .year
        }
        anchor = calendar.dateInterval(of: unit, for: seriesStart)?.start ?? calendar.startOfDay(for: seriesStart)
    }

    func periodStart(_ index: Int) -> Date? {
        let step = index * rule.interval
        switch rule.frequency {
        case .daily: return calendar.date(byAdding: .day, value: step, to: anchor)
        case .weekly: return calendar.date(byAdding: .day, value: 7 * step, to: anchor)
        case .monthly: return calendar.date(byAdding: .month, value: step, to: anchor)
        case .yearly: return calendar.date(byAdding: .year, value: step, to: anchor)
        }
    }

    /// Index of the period containing `date` (0 for anything before the series).
    func periodIndex(of date: Date) -> Int {
        guard date > anchor else { return 0 }
        let units: Int
        switch rule.frequency {
        case .daily: units = calendar.dateComponents([.day], from: anchor, to: date).day ?? 0
        case .weekly: units = (calendar.dateComponents([.day], from: anchor, to: date).day ?? 0) / 7
        case .monthly: units = calendar.dateComponents([.month], from: anchor, to: date).month ?? 0
        case .yearly: units = calendar.dateComponents([.year], from: anchor, to: date).year ?? 0
        }
        return units / rule.interval
    }

    /// Candidate starts within a period, in chronological order.
    func candidates(inPeriod index: Int) -> [Date] {
        guard let start = periodStart(index) else { return [] }
        var days: [Date]
        switch rule.frequency {
        case .daily:
            days = [start]
        case .weekly:
            let week = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
            if rule.byDay.isEmpty {
                let weekday = calendar.component(.weekday, from: seriesStart)
                days = week.filter { calendar.component(.weekday, from: $0) == weekday }
            } else {
                days = week
            }
        case .monthly:
            days = monthDays(monthStart: start)
        case .yearly:
            let year = calendar.component(.year, from: start)
            let months = rule.byMonth.isEmpty ? [calendar.component(.month, from: seriesStart)] : rule.byMonth.sorted()
            days = months.flatMap { month -> [Date] in
                guard let monthStart = calendar.date(from: DateComponents(year: year, month: month, day: 1)) else {
                    return []
                }
                return monthDays(monthStart: monthStart)
            }
        }

        let weekdays = Set(rule.byDay.map(\.weekday))
        return days
            .filter { day in
                if rule.frequency != .monthly, rule.frequency != .yearly, !weekdays.isEmpty,
                   !weekdays.contains(calendar.component(.weekday, from: day)) {
                    return false
                }
                if rule.frequency != .yearly, !rule.byMonth.isEmpty,
                   !rule.byMonth.contains(calendar.component(.month, from: day)) {
                    return false
                }
                return true
            }
            .compactMap(applySeriesTime)
            .sorted()
    }

    /// Days of the month selected by BYMONTHDAY / BYDAY, defaulting to the series' day of month
    /// (months without that day are skipped).
    private func monthDays(monthStart: Date) -> [Date] {
        guard let dayCount = calendar.range(of: .day, in: .month, for: monthStart)?.count else { return [] }
        let allDays = Array(1...dayCount)
        func weekday(_ day: Int) -> Int {
            let date = calendar.date(byAdding: .day, value: day - 1, to: monthStart) ?? monthStart
            return calendar.component(.weekday, from: date)
        }

        var selected: [Int]
        if !rule.byMonthDay.isEmpty {
            selected = rule.byMonthDay.compactMap { value in
                let day = value > 0 ? value : dayCount + value + 1
                return allDays.contains(day) ? day : nil
            }
            if !rule.byDay.isEmpty {
                let weekdays = Set(rule.byDay.map(\.weekday))
                selected = selected.filter { weekdays.contains(weekday($0)) }
            }
        } else if !rule.byDay.isEmpty {
            selected = rule.byDay.flatMap { dayRule -> [Int] in
                let matching = allDays.filter { weekday($0) == dayRule.weekday }
                guard let ordinal = dayRule.ordinal else { return matching }
                let position = ordinal > 0 ? ordinal - 1 : matching.count + ordinal
                return matching.indices.contains(position) ? [matching[position]] : []
            }
        } else {
            let seriesDay = calendar.component(.day, from: seriesStart)
            selected = allDays.contains(seriesDay) ? [seriesDay] : []
        }

        return Set(selected).sorted().compactMap {
            calendar.date(byAdding: .day, value: $0 - 1, to: monthStart)
        }
    }

    private func applySeriesTime(to day: Date) -> Date? {
        let dayStart = calendar.startOfDay(for: day)
        if isAllDay { return dayStart }
        let time = calendar.dateComponents([.hour, .minute, .second], from: seriesStart)
        return calendar.date(
            bySettingHour: time.hour ?? 0,
            minute: time.minute ?? 0,
            second: time.second ?? 0,
            of: dayStart
        )
    }
}
