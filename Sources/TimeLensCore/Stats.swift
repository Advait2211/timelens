import Foundation

/// One row of the hourly rollup: seconds on one app + site in one local hour.
public struct HourUsage: Equatable, Sendable {
    /// Start of the local wall-clock hour, seconds since 1970.
    public var bucket: Int64
    public var app: String
    public var site: String
    public var seconds: Double

    public init(bucket: Int64, app: String, site: String, seconds: Double) {
        self.bucket = bucket
        self.app = app
        self.site = site
        self.seconds = seconds
    }
}

/// An app, site or category with its time.
public struct Ranked: Identifiable, Hashable, Sendable {
    public let key: String
    public let seconds: Double
    /// Of the total in scope, 0–1.
    public let share: Double
    public var id: String { key }

    public init(key: String, seconds: Double, share: Double) {
        self.key = key
        self.seconds = seconds
        self.share = share
    }
}

public struct DayTotal: Identifiable, Hashable, Sendable {
    public let day: Date
    public var total: Double
    public var byCategory: [Category: Double]
    public var byRating: [Rating: Double] = [:]
    public var id: Date { day }

    public init(day: Date, total: Double, byCategory: [Category: Double], byRating: [Rating: Double] = [:]) {
        self.day = day
        self.total = total
        self.byCategory = byCategory
        self.byRating = byRating
    }
}

/// What to keep from the hourly rows.
public enum StatsFilter: Hashable, Sendable {
    case all
    case app(String)
    case site(String)
    case category(Category)

    public func matches(_ row: HourUsage, _ categorizer: Categorizer) -> Bool {
        switch self {
        case .all: true
        case let .app(id): row.app == id
        case let .site(site): row.site == site
        case let .category(category): categorizer.category(app: row.app, site: row.site) == category
        }
    }
}

/// Every breakdown of screen time in a window, computed in one pass over the hourly rollup.
public struct UsageStats: Sendable {
    public var interval: DateInterval
    public var total: Double = 0
    public var apps: [Ranked] = []
    public var sites: [Ranked] = []
    public var categories: [Ranked] = []
    public var ratings: [Rating: Double] = [:]
    /// Index 0–23: seconds in that hour of the day, summed over the window, by category.
    public var hours: [[Category: Double]] = Array(repeating: [:], count: 24)
    /// Every day in the window, including days with nothing.
    public var days: [DayTotal] = []
    /// Index 0–6 = Sunday–Saturday (Calendar weekday − 1): seconds summed over the window.
    public var weekdays: [Double] = Array(repeating: 0, count: 7)
    /// How many of each weekday have elapsed in the window, for averages.
    public var weekdayCounts: [Int] = Array(repeating: 0, count: 7)
    /// [weekday 0–6][hour 0–23], summed.
    public var heatmap: [[Double]] = Array(repeating: Array(repeating: 0, count: 24), count: 7)
    /// Seconds per day index (into `days`) for every app and site, for sparklines and trends.
    public var appDays: [String: [Int: Double]] = [:]
    public var siteDays: [String: [Int: Double]] = [:]
    /// Days up to and including today.
    public var elapsedDays: Int = 1
    /// Days with any use.
    public var activeDays: Int = 0

    public init(interval: DateInterval) {
        self.interval = interval
    }

    public var averagePerDay: Double { total / Double(max(elapsedDays, 1)) }
    public var averagePerActiveDay: Double { total / Double(max(activeDays, 1)) }

    /// 0–100: productive time counts 100, neutral 50, distracting 0.
    public var productivityScore: Double? {
        let rated = ratings.values.reduce(0, +)
        guard rated > 0 else { return nil }
        return ratings.reduce(0) { $0 + $1.key.score * $1.value } / rated
    }

    public var peakHour: Int? {
        let totals = hours.map { $0.values.reduce(0, +) }
        guard let max = totals.max(), max > 0 else { return nil }
        return totals.firstIndex(of: max)
    }

    public func hourTotal(_ hour: Int) -> Double { hours[hour].values.reduce(0, +) }

    /// Average seconds per day for the weekday (0 = Sunday).
    public func weekdayAverage(_ weekday: Int) -> Double {
        weekdays[weekday] / Double(max(weekdayCounts[weekday], 1))
    }

    public func dailySeries(app: String) -> [Double] {
        let values = appDays[app] ?? [:]
        return days.indices.map { values[$0] ?? 0 }
    }

    public func dailySeries(site: String) -> [Double] {
        let values = siteDays[site] ?? [:]
        return days.indices.map { values[$0] ?? 0 }
    }

    public var busiestDay: DayTotal? { days.max { $0.total < $1.total }.flatMap { $0.total > 0 ? $0 : nil } }
}

public enum StatsBuilder {
    public static func build(
        rows: [HourUsage],
        interval: DateInterval,
        now: Date = .now,
        calendar: Calendar = .current,
        categorizer: Categorizer,
        filter: StatsFilter = .all
    ) -> UsageStats {
        var stats = UsageStats(interval: interval)

        // Every day in the window.
        var dayStarts: [Date] = []
        var cursor = calendar.startOfDay(for: interval.start)
        while cursor < interval.end {
            dayStarts.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        let todayStart = calendar.startOfDay(for: now)
        stats.days = dayStarts.map { DayTotal(day: $0, total: 0, byCategory: [:]) }
        stats.elapsedDays = max(dayStarts.filter { $0 <= todayStart }.count, 1)
        for day in dayStarts where day <= todayStart {
            stats.weekdayCounts[calendar.component(.weekday, from: day) - 1] += 1
        }
        var dayIndex: [Date: Int] = [:]
        for (index, day) in dayStarts.enumerated() { dayIndex[day] = index }

        // Hour buckets repeat across rows; resolve each once.
        struct Slot { let day: Int; let weekday: Int; let hour: Int }
        var slots: [Int64: Slot] = [:]
        var categoryCache: [String: Category] = [:]
        var ratingCache: [String: Rating] = [:]
        var apps: [String: Double] = [:]
        var sites: [String: Double] = [:]
        var categories: [Category: Double] = [:]

        let start = interval.start.timeIntervalSince1970
        let end = interval.end.timeIntervalSince1970
        for row in rows {
            let time = Double(row.bucket)
            guard time >= start - 1, time < end, row.seconds > 0, filter.matches(row, categorizer) else { continue }
            let slot: Slot
            if let cached = slots[row.bucket] {
                slot = cached
            } else {
                let date = Date(timeIntervalSince1970: time)
                let components = calendar.dateComponents([.hour, .weekday], from: date)
                slot = Slot(day: dayIndex[calendar.startOfDay(for: date)] ?? -1,
                            weekday: (components.weekday ?? 1) - 1,
                            hour: components.hour ?? 0)
                slots[row.bucket] = slot
            }
            guard slot.day >= 0 else { continue }

            let cacheKey = row.app + "\u{1}" + row.site
            let category: Category
            if let cached = categoryCache[cacheKey] {
                category = cached
            } else {
                category = categorizer.category(app: row.app, site: row.site)
                categoryCache[cacheKey] = category
            }
            let rating: Rating
            if let cached = ratingCache[cacheKey] {
                rating = cached
            } else {
                rating = categorizer.rating(app: row.app, site: row.site)
                ratingCache[cacheKey] = rating
            }

            let seconds = row.seconds
            stats.total += seconds
            apps[row.app, default: 0] += seconds
            if !row.site.isEmpty { sites[row.site, default: 0] += seconds }
            categories[category, default: 0] += seconds
            stats.ratings[rating, default: 0] += seconds
            stats.hours[slot.hour][category, default: 0] += seconds
            stats.days[slot.day].total += seconds
            stats.days[slot.day].byCategory[category, default: 0] += seconds
            stats.days[slot.day].byRating[rating, default: 0] += seconds
            stats.weekdays[slot.weekday] += seconds
            stats.heatmap[slot.weekday][slot.hour] += seconds
            stats.appDays[row.app, default: [:]][slot.day, default: 0] += seconds
            if !row.site.isEmpty { stats.siteDays[row.site, default: [:]][slot.day, default: 0] += seconds }
        }

        let total = max(stats.total, 1)
        stats.apps = apps.map { Ranked(key: $0.key, seconds: $0.value, share: $0.value / total) }.sorted(by: rank)
        stats.sites = sites.map { Ranked(key: $0.key, seconds: $0.value, share: $0.value / total) }.sorted(by: rank)
        stats.categories = categories.map { Ranked(key: $0.key.rawValue, seconds: $0.value, share: $0.value / total) }.sorted(by: rank)
        stats.activeDays = stats.days.filter { $0.total >= 60 }.count
        return stats
    }

    private static func rank(_ a: Ranked, _ b: Ranked) -> Bool {
        a.seconds == b.seconds ? a.key < b.key : a.seconds > b.seconds
    }

    /// Groups days into weeks or months for long ranges.
    public static func group(_ days: [DayTotal], by component: Calendar.Component, calendar: Calendar = .current) -> [DayTotal] {
        var groups: [Date: DayTotal] = [:]
        for day in days {
            guard let start = calendar.dateInterval(of: component, for: day.day)?.start else { continue }
            var group = groups[start] ?? DayTotal(day: start, total: 0, byCategory: [:])
            group.total += day.total
            for (category, seconds) in day.byCategory { group.byCategory[category, default: 0] += seconds }
            for (rating, seconds) in day.byRating { group.byRating[rating, default: 0] += seconds }
            groups[start] = group
        }
        return groups.values.sorted { $0.day < $1.day }
    }
}

// MARK: Sessions

/// A continuous stretch on one app (or one site, or the screen as a whole).
public struct Session: Hashable, Sendable {
    public var key: String
    public var start: Double
    public var end: Double
    public var duration: Double { end - start }

    public init(key: String, start: Double, end: Double) {
        self.key = key
        self.start = start
        self.end = end
    }
}

public enum Sessions {
    /// Joins consecutive segments that share a key and are no more than `gap` apart. Segments
    /// with a nil key break runs. Input must be sorted by start.
    public static func merge(_ segments: [UsageSegment], gap: Double, key: (UsageSegment) -> String?) -> [Session] {
        var sessions: [Session] = []
        var current: Session?
        for segment in segments {
            guard let segmentKey = key(segment) else {
                if let open = current { sessions.append(open) }
                current = nil
                continue
            }
            if var open = current, open.key == segmentKey, segment.start - open.end <= gap {
                open.end = max(open.end, segment.end)
                current = open
            } else {
                if let open = current { sessions.append(open) }
                current = Session(key: segmentKey, start: segment.start, end: segment.end)
            }
        }
        if let open = current { sessions.append(open) }
        return sessions
    }

    /// Runs on one app. Hour splits and sub-second blips are invisible here.
    public static func apps(_ segments: [UsageSegment]) -> [Session] {
        merge(segments, gap: 5) { $0.app }
    }

    /// Runs on one website.
    public static func sites(_ segments: [UsageSegment]) -> [Session] {
        merge(segments, gap: 5) { $0.site.isEmpty ? nil : $0.site }
    }

    /// Continuous screen use across apps, broken by any pause longer than `gap`.
    public static func screen(_ segments: [UsageSegment], gap: Double = 120) -> [Session] {
        merge(segments, gap: gap) { _ in "screen" }
    }

    /// App switches: how often the frontmost app changed (sessions of at least 2 s).
    public static func switches(_ appSessions: [Session]) -> Int {
        max(appSessions.filter { $0.duration >= 2 }.count - 1, 0)
    }
}

public struct SessionStats: Sendable, Hashable {
    public var count: Int = 0
    public var total: Double = 0
    public var longest: Double = 0
    public var median: Double = 0
    public var lastEnd: Double?
    /// Counts per length bucket, in `SessionStats.bucketTitles` order.
    public var histogram: [Int] = Array(repeating: 0, count: SessionStats.bucketBounds.count + 1)

    public var average: Double { count > 0 ? total / Double(count) : 0 }

    public static let bucketBounds: [Double] = [60, 300, 900, 1800, 3600, 7200]
    public static let bucketTitles = ["< 1m", "1–5m", "5–15m", "15–30m", "30–60m", "1–2h", "2h+"]

    public init() {}

    /// Sessions shorter than `minimum` (flicking through apps) don't count.
    public init(_ sessions: [Session], minimum: Double = 2) {
        let kept = sessions.filter { $0.duration >= minimum }
        count = kept.count
        total = kept.reduce(0) { $0 + $1.duration }
        longest = kept.map(\.duration).max() ?? 0
        let sorted = kept.map(\.duration).sorted()
        median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        lastEnd = kept.map(\.end).max()
        for session in kept {
            let index = Self.bucketBounds.firstIndex { session.duration < $0 } ?? Self.bucketBounds.count
            histogram[index] += 1
        }
    }

    /// Per-key stats, e.g. sessions for every app.
    public static func grouped(_ sessions: [Session], minimum: Double = 2) -> [String: SessionStats] {
        Dictionary(grouping: sessions, by: \.key).mapValues { SessionStats($0, minimum: minimum) }
    }
}
