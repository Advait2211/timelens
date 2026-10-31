import Foundation
import TimeLensCore

/// Everything a dashboard page needs about one period, loaded in one go.
struct PeriodData {
    var interval: DateInterval
    var stats: UsageStats
    var previous: UsageStats
    var segments: [UsageSegment] = []
    var appSessions: [Session] = []
    var siteSessions: [Session] = []
    var screenSessions: [Session] = []
    var appSessionStats: [String: SessionStats] = [:]
    var siteSessionStats: [String: SessionStats] = [:]
    var allSessions = SessionStats()
    var screenStats = SessionStats()
    var pickups: [EventRecord] = []
    var previousPickups = 0
    /// First and last moment on screen per waking day — a day that runs 4 AM to 4 AM, so a
    /// late night counts toward the evening it started in, not the next morning.
    var dayBounds: [Date: (first: Double, last: Double)] = [:]
    var focus: [FocusRecord] = []
    var switches = 0
    var isLoaded = false

    init(interval: DateInterval) {
        self.interval = interval
        stats = UsageStats(interval: interval)
        previous = UsageStats(interval: interval)
    }

    /// Waking days start at 4 AM.
    static let dayStartOffset: Double = 4 * 3600

    var longestScreenSession: Session? { screenSessions.max { $0.duration < $1.duration } }

    var pickupsPerDay: Double { Double(pickups.count) / Double(max(stats.elapsedDays, 1)) }

    var focusSeconds: Double { focus.reduce(0) { $0 + $1.duration } }

    var firstPickup: Double? {
        dayBounds.values.map(\.first).min()
    }

    /// Pickups in each hour of the day (0–23), summed over the period.
    var pickupsByHour: [Int] {
        var counts = Array(repeating: 0, count: 24)
        let calendar = Calendar.current
        for event in pickups {
            counts[calendar.component(.hour, from: Date(timeIntervalSince1970: event.time))] += 1
        }
        return counts
    }
}

extension AppModel {
    /// Loads a period's stats, the period before it for comparison, and (optionally) the raw
    /// segments for sessions, pickups and first/last use.
    func loadPeriod(_ period: Period, filter: StatsFilter = .all, sessions: Bool = true) async -> PeriodData {
        let calendar = prefs.calendar
        let interval = period.interval(calendar)
        let comparison = period.comparisonInterval(calendar)
        return await load(interval: interval, comparison: comparison, filter: filter, sessions: sessions)
    }

    func load(interval: DateInterval, comparison: DateInterval?, filter: StatsFilter = .all, sessions: Bool = true) async -> PeriodData {
        guard let store else { return PeriodData(interval: interval) }
        let calendar = prefs.calendar
        let categorizer = categorizer

        let rows = await store.hourly(interval)
        let previousRows = comparison != nil ? await store.hourly(comparison!) : []
        var segments: [UsageSegment] = []
        var pickups: [EventRecord] = []
        var previousPickups = 0
        var focus: [FocusRecord] = []
        if sessions {
            switch filter {
            case let .app(app): segments = await store.segments(interval, app: app)
            case let .site(site): segments = await store.segments(interval, site: site)
            default: segments = await store.segments(interval)
            }
            pickups = await store.events(interval, kinds: [.pickup])
            if let comparison { previousPickups = await store.events(comparison, kinds: [.pickup]).count }
            focus = await store.focusSessions(interval)
        }

        return await Task.detached(priority: .userInitiated) {
            var data = PeriodData(interval: interval)
            data.stats = StatsBuilder.build(rows: rows, interval: interval, calendar: calendar, categorizer: categorizer, filter: filter)
            if let comparison {
                data.previous = StatsBuilder.build(rows: previousRows, interval: comparison, calendar: calendar, categorizer: categorizer, filter: filter)
            }
            if sessions {
                var kept = segments
                if case let .category(category) = filter {
                    kept = segments.filter { categorizer.category(app: $0.app, site: $0.site) == category }
                }
                data.segments = kept
                data.appSessions = Sessions.apps(kept)
                data.siteSessions = Sessions.sites(kept)
                data.screenSessions = Sessions.screen(kept)
                data.appSessionStats = SessionStats.grouped(data.appSessions)
                data.siteSessionStats = SessionStats.grouped(data.siteSessions)
                data.allSessions = SessionStats(data.appSessions)
                data.screenStats = SessionStats(data.screenSessions, minimum: 10)
                data.switches = Sessions.switches(data.appSessions)
                data.pickups = pickups
                data.previousPickups = previousPickups
                data.focus = focus
                var bounds: [Date: (first: Double, last: Double)] = [:]
                for segment in kept where segment.duration >= 1 {
                    let day = calendar.startOfDay(for: Date(timeIntervalSince1970: segment.start - PeriodData.dayStartOffset))
                    guard day >= interval.start else { continue }
                    let current = bounds[day] ?? (segment.start, segment.end)
                    bounds[day] = (min(current.first, segment.start), max(current.last, segment.end))
                }
                data.dayBounds = bounds
            }
            data.isLoaded = true
            return data
        }.value
    }
}
