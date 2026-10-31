import Foundation

/// What's in front of you at one instant.
public struct Activity: Equatable, Sendable {
    /// Bundle ID of the frontmost app.
    public var app: String
    /// Website for browser time (`SiteKey`), "" otherwise.
    public var site: String
    /// Window or page title, when known.
    public var title: String?
    /// Host + path, for browser time.
    public var page: String?

    public init(app: String, site: String = "", title: String? = nil, page: String? = nil) {
        self.app = app
        self.site = site
        self.title = title
        self.page = page
    }
}

/// One reading of the tracker, taken about once a second.
public struct Sample: Sendable {
    public var time: Double
    /// nil when nothing should count: screen locked or asleep, an excluded app, a shield up.
    public var activity: Activity?
    /// Seconds since the last keyboard, mouse or trackpad input.
    public var idleSeconds: Double
    /// The frontmost app is playing video or is in a call (it holds a display-sleep assertion).
    public var mediaPlaying: Bool

    public init(time: Double, activity: Activity?, idleSeconds: Double = 0, mediaPlaying: Bool = false) {
        self.time = time
        self.activity = activity
        self.idleSeconds = idleSeconds
        self.mediaPlaying = mediaPlaying
    }
}

/// A stretch of time on one app (and one website, for browsers). Never crosses a local hour
/// boundary, so hourly rollups are a plain sum.
public struct UsageSegment: Equatable, Sendable {
    public var id: Int64
    public var start: Double
    public var end: Double
    public var app: String
    public var site: String

    public init(id: Int64, start: Double, end: Double, app: String, site: String) {
        self.id = id
        self.start = start
        self.end = end
        self.app = app
        self.site = site
    }

    public var duration: Double { max(end - start, 0) }
}

/// A stretch of time on one window title or page.
public struct DetailSegment: Equatable, Sendable {
    public var id: Int64
    public var start: Double
    public var end: Double
    public var app: String
    public var site: String
    public var title: String
    public var page: String

    public init(id: Int64, start: Double, end: Double, app: String, site: String, title: String, page: String) {
        self.id = id
        self.start = start
        self.end = end
        self.app = app
        self.site = site
        self.title = title
        self.page = page
    }

    public var duration: Double { max(end - start, 0) }
}

/// Everything the store needs to write since the last flush.
public struct SegmentChanges: Sendable {
    public var usage: [UsageSegment] = []
    public var details: [DetailSegment] = []
    public var deletedUsage: [Int64] = []
    public var deletedDetails: [Int64] = []

    public var isEmpty: Bool { usage.isEmpty && details.isEmpty && deletedUsage.isEmpty && deletedDetails.isEmpty }

    /// Every segment start and end touched, for working out which hourly buckets to rebuild.
    public var touchedTimes: [Double] {
        usage.flatMap { [$0.start, $0.end] }
    }
}

public enum TrackerTransition: Equatable, Sendable {
    /// No input for the idle threshold: everything after `since` was taken back.
    case wentIdle(since: Double)
    /// Something counts again after idle or away time.
    case resumed(at: Double)
    /// Nothing to count (locked, asleep, excluded).
    case wentAway(at: Double)
}

/// The tracking state machine. Feed it a `Sample` every second; it keeps the open segments,
/// closes them when the app, site, title or hour changes, and takes idle time back when you
/// stop touching the Mac. It never touches the clock or the system itself, which keeps it
/// testable.
public final class SegmentBuilder {
    public struct Config: Sendable {
        /// No input for this long (and no video or call) counts as idle.
        public var idleThreshold: Double
        /// Ticks further apart than this mean the Mac slept or the app was suspended; the
        /// segment ends at the last tick.
        public var gapLimit: Double
        /// Video and calls keep time counting without input, but not forever.
        public var mediaCap: Double
        /// Count time while video plays or a call runs with no input.
        public var honorMedia: Bool

        public init(idleThreshold: Double = 120, gapLimit: Double = 5, mediaCap: Double = 3 * 3600, honorMedia: Bool = true) {
            self.idleThreshold = idleThreshold
            self.gapLimit = gapLimit
            self.mediaCap = mediaCap
            self.honorMedia = honorMedia
        }
    }

    public enum State: Equatable, Sendable {
        case active
        case idle
        case away
    }

    public var config: Config
    public private(set) var state: State = .away
    public private(set) var openUsage: UsageSegment?
    public private(set) var openDetail: DetailSegment?
    /// When the current run of activity began (after the last idle or away stretch).
    public private(set) var activeSince: Double?

    private var recentUsage: [UsageSegment] = []
    private var recentDetails: [DetailSegment] = []
    private var dirtyUsage: [Int64: UsageSegment] = [:]
    private var dirtyDetails: [Int64: DetailSegment] = [:]
    private var deletedUsage: Set<Int64> = []
    private var deletedDetails: Set<Int64> = []
    private var nextUsageID: Int64
    private var nextDetailID: Int64
    private var lastTick: Double?
    private var lastMedia: Double?
    private let calendar: Calendar

    public init(config: Config = Config(), nextUsageID: Int64 = 1, nextDetailID: Int64 = 1, calendar: Calendar = .current) {
        self.config = config
        self.nextUsageID = nextUsageID
        self.nextDetailID = nextDetailID
        self.calendar = calendar
    }

    // MARK: Ticks

    @discardableResult
    public func tick(_ sample: Sample) -> [TrackerTransition] {
        var transitions: [TrackerTransition] = []
        let time = sample.time

        // The Mac slept, or this process didn't run: what was open ended at the last tick.
        if let last = lastTick, time - last > config.gapLimit, openUsage != nil {
            close(at: last)
            activeSince = nil
            state = .away
        }
        lastTick = time

        if config.honorMedia, sample.mediaPlaying, sample.activity != nil, sample.idleSeconds < config.mediaCap {
            lastMedia = time
        }
        let lastInput = time - max(sample.idleSeconds, 0)
        let engagedAt = max(lastInput, lastMedia ?? -.infinity)

        guard let activity = sample.activity else {
            if state != .away {
                close(at: time)
                transitions.append(.wentAway(at: time))
            }
            state = .away
            activeSince = nil
            return transitions
        }

        if time - engagedAt >= config.idleThreshold {
            if state == .active {
                // Take back the idle tail: nothing after the last input (or video frame) counts.
                trim(after: engagedAt)
                transitions.append(.wentIdle(since: engagedAt))
            }
            state = .idle
            activeSince = nil
            return transitions
        }

        if state != .active {
            transitions.append(.resumed(at: time))
            state = .active
            activeSince = time
        }
        if activeSince == nil { activeSince = time }
        advance(to: time, with: activity)
        pruneRecent(before: time - config.idleThreshold - 60)
        return transitions
    }

    /// Ends everything at `time` — for sleep, logout and quitting.
    public func closeAll(at time: Double) {
        close(at: time)
        state = .away
        activeSince = nil
        lastTick = nil
    }

    /// What changed since the last call. Open segments are included with their current end,
    /// so a crash loses at most one flush interval.
    public func takeChanges() -> SegmentChanges {
        if let open = openUsage { dirtyUsage[open.id] = open }
        if let open = openDetail { dirtyDetails[open.id] = open }
        let changes = SegmentChanges(
            usage: dirtyUsage.values.filter { $0.end > $0.start }.sorted { $0.start < $1.start },
            details: dirtyDetails.values.filter { $0.end > $0.start }.sorted { $0.start < $1.start },
            deletedUsage: Array(deletedUsage) + dirtyUsage.values.filter { $0.end <= $0.start }.map(\.id),
            deletedDetails: Array(deletedDetails) + dirtyDetails.values.filter { $0.end <= $0.start }.map(\.id)
        )
        dirtyUsage.removeAll()
        dirtyDetails.removeAll()
        deletedUsage.removeAll()
        deletedDetails.removeAll()
        return changes
    }

    // MARK: Internals

    private func advance(to time: Double, with activity: Activity) {
        // Usage segment: one app + site, inside one local hour.
        if var open = openUsage, open.app == activity.app, open.site == activity.site {
            let boundary = nextHour(after: open.start)
            if time > boundary {
                open.end = boundary
                finish(open)
                openUsage = makeUsage(start: boundary, end: time, activity: activity)
            } else {
                open.end = time
                openUsage = open
            }
        } else {
            if let open = openUsage {
                var closed = open
                closed.end = max(closed.start, min(time, nextHour(after: closed.start)))
                finish(closed)
            }
            openUsage = makeUsage(start: time, end: time, activity: activity)
        }

        // Detail segment: one title/page, also inside one hour.
        let title = activity.title ?? ""
        let page = activity.page ?? ""
        guard !(title.isEmpty && page.isEmpty) else {
            if let open = openDetail {
                var closed = open
                closed.end = max(closed.start, min(time, nextHour(after: closed.start)))
                finishDetail(closed)
                openDetail = nil
            }
            return
        }
        if var open = openDetail, open.app == activity.app, open.site == activity.site, open.title == title, open.page == page {
            let boundary = nextHour(after: open.start)
            if time > boundary {
                open.end = boundary
                finishDetail(open)
                openDetail = makeDetail(start: boundary, end: time, activity: activity, title: title, page: page)
            } else {
                open.end = time
                openDetail = open
            }
        } else {
            if let open = openDetail {
                var closed = open
                closed.end = max(closed.start, min(time, nextHour(after: closed.start)))
                finishDetail(closed)
            }
            openDetail = makeDetail(start: time, end: time, activity: activity, title: title, page: page)
        }
    }

    private func makeUsage(start: Double, end: Double, activity: Activity) -> UsageSegment {
        defer { nextUsageID += 1 }
        return UsageSegment(id: nextUsageID, start: start, end: end, app: activity.app, site: activity.site)
    }

    private func makeDetail(start: Double, end: Double, activity: Activity, title: String, page: String) -> DetailSegment {
        defer { nextDetailID += 1 }
        return DetailSegment(id: nextDetailID, start: start, end: end, app: activity.app, site: activity.site, title: title, page: page)
    }

    private func finish(_ segment: UsageSegment) {
        dirtyUsage[segment.id] = segment
        recentUsage.append(segment)
    }

    private func finishDetail(_ segment: DetailSegment) {
        dirtyDetails[segment.id] = segment
        recentDetails.append(segment)
    }

    private func close(at time: Double) {
        if var open = openUsage {
            open.end = max(open.start, min(time, nextHour(after: open.start)))
            finish(open)
            openUsage = nil
        }
        if var open = openDetail {
            open.end = max(open.start, min(time, nextHour(after: open.start)))
            finishDetail(open)
            openDetail = nil
        }
    }

    /// Cuts everything back to `cutoff`: segments that started after it go, ones spanning it
    /// end there.
    private func trim(after cutoff: Double) {
        close(at: lastTick ?? cutoff)
        recentUsage = recentUsage.compactMap { segment in
            if segment.start >= cutoff {
                dirtyUsage[segment.id] = nil
                deletedUsage.insert(segment.id)
                return nil
            }
            if segment.end > cutoff {
                var trimmed = segment
                trimmed.end = cutoff
                dirtyUsage[segment.id] = trimmed
                return trimmed
            }
            return segment
        }
        recentDetails = recentDetails.compactMap { segment in
            if segment.start >= cutoff {
                dirtyDetails[segment.id] = nil
                deletedDetails.insert(segment.id)
                return nil
            }
            if segment.end > cutoff {
                var trimmed = segment
                trimmed.end = cutoff
                dirtyDetails[segment.id] = trimmed
                return trimmed
            }
            return segment
        }
    }

    private func pruneRecent(before time: Double) {
        if let first = recentUsage.first, first.end < time {
            recentUsage.removeAll { $0.end < time }
        }
        if let first = recentDetails.first, first.end < time {
            recentDetails.removeAll { $0.end < time }
        }
    }

    private var hourCache: (start: Double, end: Double)?

    /// The end of the local hour containing `time`.
    private func nextHour(after time: Double) -> Double {
        if let cache = hourCache, time >= cache.start, time < cache.end { return cache.end }
        let interval = calendar.dateInterval(of: .hour, for: Date(timeIntervalSince1970: time))
            ?? DateInterval(start: Date(timeIntervalSince1970: floor(time / 3600) * 3600), duration: 3600)
        hourCache = (interval.start.timeIntervalSince1970, interval.end.timeIntervalSince1970)
        return interval.end.timeIntervalSince1970
    }
}
