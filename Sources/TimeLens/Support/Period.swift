import Foundation

enum PeriodKind: String, CaseIterable, Identifiable, Codable {
    case day, week, month, year, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: "Day"
        case .week: "Week"
        case .month: "Month"
        case .year: "Year"
        case .custom: "Custom"
        }
    }
}

/// The time window a dashboard page shows: a calendar day, week, month or year (stepped with
/// ◀ ▶), or a custom range.
struct Period: Hashable, Codable {
    var kind: PeriodKind
    /// Any instant inside the period.
    var anchor: Date
    var customStart: Date
    var customEnd: Date

    init(kind: PeriodKind, anchor: Date = .now, customStart: Date? = nil, customEnd: Date? = nil) {
        self.kind = kind
        self.anchor = anchor
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        self.customStart = customStart ?? calendar.date(byAdding: .day, value: -13, to: today)!
        self.customEnd = customEnd ?? today
    }

    static var today: Period { Period(kind: .day, anchor: currentAnchor) }

    /// Where pages start: now, read fresh each time so a long-running app moves on past
    /// midnight. Debug snapshots can start on an earlier day with TIMELENS_DAYS_AGO=n.
    static var currentAnchor: Date {
        guard let daysAgo else { return .now }
        return Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now) ?? .now
    }

    private static let daysAgo: Int? = ProcessInfo.processInfo.environment["TIMELENS_DAYS_AGO"].flatMap { Int($0) }

    func interval(_ calendar: Calendar) -> DateInterval {
        switch kind {
        case .day:
            return calendar.dateInterval(of: .day, for: anchor)!
        case .week:
            return calendar.dateInterval(of: .weekOfYear, for: anchor)!
        case .month:
            return calendar.dateInterval(of: .month, for: anchor)!
        case .year:
            return calendar.dateInterval(of: .year, for: anchor)!
        case .custom:
            let start = calendar.startOfDay(for: min(customStart, customEnd))
            let lastDay = calendar.startOfDay(for: max(customStart, customEnd))
            return DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: lastDay)!)
        }
    }

    func isCurrent(_ calendar: Calendar, now: Date = .now) -> Bool {
        interval(calendar).contains(now)
    }

    var stepComponent: Calendar.Component {
        switch kind {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        case .custom: .day
        }
    }

    func shifted(by steps: Int, _ calendar: Calendar) -> Period {
        var copy = self
        if kind == .custom {
            let length = (calendar.dateComponents([.day], from: interval(calendar).start, to: interval(calendar).end).day ?? 1) * steps
            copy.customStart = calendar.date(byAdding: .day, value: length, to: customStart)!
            copy.customEnd = calendar.date(byAdding: .day, value: length, to: customEnd)!
        } else {
            copy.anchor = calendar.date(byAdding: stepComponent, value: steps, to: anchor)!
        }
        return copy
    }

    func canGoForward(_ calendar: Calendar, now: Date = .now) -> Bool {
        shifted(by: 1, calendar).interval(calendar).start <= now
    }

    /// The period before, for comparisons. A period still in progress is compared with the
    /// same stretch of the one before (today until now vs yesterday until this time).
    func comparisonInterval(_ calendar: Calendar, now: Date = .now) -> DateInterval {
        let current = interval(calendar)
        let previous = shifted(by: -1, calendar).interval(calendar)
        guard current.contains(now) else { return previous }
        let elapsed = now.timeIntervalSince(current.start)
        return DateInterval(start: previous.start, end: min(previous.end, previous.start.addingTimeInterval(elapsed)))
    }

    /// "yesterday", "last week", "the previous 14 days".
    func previousName(_ calendar: Calendar, now: Date = .now) -> String {
        let current = isCurrent(calendar, now: now)
        switch kind {
        case .day: return current ? "yesterday at this time" : "the day before"
        case .week: return current ? "last week so far" : "the week before"
        case .month: return current ? "last month so far" : "the month before"
        case .year: return current ? "last year so far" : "the year before"
        case .custom: return "the \(dayCount(calendar)) days before"
        }
    }

    var periodName: String {
        switch kind {
        case .day: "today"
        case .week: "this week"
        case .month: "this month"
        case .year: "this year"
        case .custom: "in this range"
        }
    }

    func periodName(_ calendar: Calendar) -> String {
        guard isCurrent(calendar) else {
            switch kind {
            case .day: return "that day"
            case .week: return "that week"
            case .month: return "that month"
            case .year: return "that year"
            case .custom: return "in this range"
            }
        }
        return periodName
    }

    func dayCount(_ calendar: Calendar) -> Int {
        let interval = interval(calendar)
        return max(calendar.dateComponents([.day], from: interval.start, to: interval.end).day ?? 1, 1)
    }

    /// Hours for a day, days for a week or month, months for a year.
    var isMultiDay: Bool { kind != .day && !(kind == .custom && customStart == customEnd) }

    func title(_ calendar: Calendar, now: Date = .now) -> String {
        let interval = interval(calendar)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        switch kind {
        case .day:
            if calendar.isDateInToday(anchor) { return "Today" }
            if calendar.isDateInYesterday(anchor) { return "Yesterday" }
            formatter.setLocalizedDateFormatFromTemplate(calendar.isDate(anchor, equalTo: now, toGranularity: .year) ? "EEEE d MMMM" : "EEE d MMM yyyy")
            return formatter.string(from: anchor)
        case .week:
            if interval.contains(now) { return "This week" }
            if let last = calendar.date(byAdding: .weekOfYear, value: -1, to: now), interval.contains(last) { return "Last week" }
            return rangeTitle(interval, calendar)
        case .month:
            formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
            return formatter.string(from: anchor)
        case .year:
            formatter.setLocalizedDateFormatFromTemplate("yyyy")
            return formatter.string(from: anchor)
        case .custom:
            return rangeTitle(interval, calendar)
        }
    }

    private func rangeTitle(_ interval: DateInterval, _ calendar: Calendar) -> String {
        let formatter = DateIntervalFormatter()
        formatter.calendar = calendar
        formatter.dateTemplate = "d MMM yyyy"
        let last = interval.end.addingTimeInterval(-1)
        return formatter.string(from: interval.start, to: last)
    }
}
