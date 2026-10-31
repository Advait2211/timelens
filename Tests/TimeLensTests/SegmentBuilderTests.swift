import Foundation
import Testing
@testable import TimeLensCore

@Suite struct SegmentBuilderTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return calendar
    }()

    /// 10:00:00 local, a round hour.
    var base: Double {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 10))!.timeIntervalSince1970
    }

    func run(_ builder: SegmentBuilder, from start: Double, seconds: Int, activity: Activity?, idle: (Int) -> Double = { _ in 0 }, media: Bool = false) {
        for offset in 0...seconds {
            builder.tick(Sample(time: start + Double(offset), activity: activity, idleSeconds: idle(offset), mediaPlaying: media))
        }
    }

    /// Applies changes the way the store does, to see the final picture.
    final class FakeStore {
        var usage: [Int64: UsageSegment] = [:]
        var details: [Int64: DetailSegment] = [:]
        func apply(_ changes: SegmentChanges) {
            for segment in changes.usage { usage[segment.id] = segment }
            for segment in changes.details { details[segment.id] = segment }
            for id in changes.deletedUsage { usage[id] = nil }
            for id in changes.deletedDetails { details[id] = nil }
        }
        var total: Double { usage.values.reduce(0) { $0 + $1.duration } }
        func total(app: String) -> Double { usage.values.filter { $0.app == app }.reduce(0) { $0 + $1.duration } }
        func total(site: String) -> Double { usage.values.filter { $0.site == site }.reduce(0) { $0 + $1.duration } }
    }

    @Test func countsContinuousUse() {
        let builder = SegmentBuilder(calendar: calendar)
        let store = FakeStore()
        run(builder, from: base, seconds: 60, activity: Activity(app: "a"))
        store.apply(builder.takeChanges())
        #expect(store.total == 60)
        #expect(store.usage.count == 1)
    }

    @Test func switchesSplitSegments() {
        let builder = SegmentBuilder(calendar: calendar)
        let store = FakeStore()
        run(builder, from: base, seconds: 30, activity: Activity(app: "a"))
        run(builder, from: base + 31, seconds: 29, activity: Activity(app: "b", site: ""))
        run(builder, from: base + 61, seconds: 19, activity: Activity(app: "chrome", site: "github.com", title: "Repo", page: "github.com/x"))
        run(builder, from: base + 81, seconds: 9, activity: Activity(app: "chrome", site: "youtube.com", title: "Video", page: "youtube.com/watch"))
        store.apply(builder.takeChanges())
        #expect(store.total(app: "a") == 31)
        #expect(store.total(app: "b") == 30)
        #expect(store.total(site: "github.com") == 20)
        #expect(store.total(site: "youtube.com") == 9)
        #expect(store.details.count == 2)
    }

    @Test func idleTailIsTakenBack() {
        let builder = SegmentBuilder(config: .init(idleThreshold: 120), calendar: calendar)
        let store = FakeStore()
        // 60 s of input, then hands off for 200 s.
        run(builder, from: base, seconds: 260, activity: Activity(app: "a"), idle: { $0 <= 60 ? 0 : Double($0 - 60) })
        store.apply(builder.takeChanges())
        #expect(store.total == 60)
        #expect(builder.state == .idle)
    }

    @Test func idleTailIsTakenBackAcrossAppChanges() {
        let builder = SegmentBuilder(config: .init(idleThreshold: 120), calendar: calendar)
        let store = FakeStore()
        run(builder, from: base, seconds: 60, activity: Activity(app: "a"))
        store.apply(builder.takeChanges())
        // A notification brings another app forward while no one is there.
        run(builder, from: base + 61, seconds: 150, activity: Activity(app: "b"), idle: { Double($0 + 1) })
        store.apply(builder.takeChanges())
        #expect(store.total(app: "a") == 60)
        #expect(store.total(app: "b") == 0)
    }

    @Test func videoKeepsCountingWithoutInput() {
        let builder = SegmentBuilder(config: .init(idleThreshold: 120), calendar: calendar)
        let store = FakeStore()
        run(builder, from: base, seconds: 600, activity: Activity(app: "chrome", site: "youtube.com"), idle: { Double($0) }, media: true)
        store.apply(builder.takeChanges())
        #expect(store.total == 600)
        // Video ends; hands still off. Time counts until the last frame only.
        run(builder, from: base + 601, seconds: 200, activity: Activity(app: "chrome", site: "youtube.com"), idle: { Double($0 + 601) }, media: false)
        store.apply(builder.takeChanges())
        #expect(store.total == 600)
    }

    @Test func mediaIgnoredWhenDisabled() {
        let builder = SegmentBuilder(config: .init(idleThreshold: 120, honorMedia: false), calendar: calendar)
        let store = FakeStore()
        run(builder, from: base, seconds: 300, activity: Activity(app: "chrome", site: "youtube.com"), idle: { Double($0) }, media: true)
        store.apply(builder.takeChanges())
        #expect(store.total == 0)
    }

    @Test func gapEndsAtLastTick() {
        let builder = SegmentBuilder(calendar: calendar)
        let store = FakeStore()
        run(builder, from: base, seconds: 10, activity: Activity(app: "a"))
        // The Mac slept for an hour.
        run(builder, from: base + 3610, seconds: 10, activity: Activity(app: "a"))
        store.apply(builder.takeChanges())
        #expect(store.total == 20)
        #expect(store.usage.count == 2)
    }

    @Test func awayStopsCounting() {
        let builder = SegmentBuilder(calendar: calendar)
        let store = FakeStore()
        run(builder, from: base, seconds: 10, activity: Activity(app: "a"))
        run(builder, from: base + 11, seconds: 100, activity: nil)
        run(builder, from: base + 112, seconds: 10, activity: Activity(app: "a"))
        store.apply(builder.takeChanges())
        #expect(store.total == 21)
    }

    @Test func segmentsNeverCrossAnHour() {
        let builder = SegmentBuilder(calendar: calendar)
        let store = FakeStore()
        run(builder, from: base + 3600 - 30, seconds: 60, activity: Activity(app: "a", title: "Doc"))
        store.apply(builder.takeChanges())
        #expect(store.total == 60)
        #expect(store.usage.count == 2)
        let boundary = base + 3600
        #expect(store.usage.values.allSatisfy { $0.end <= boundary || $0.start >= boundary })
        #expect(store.details.count == 2)
    }

    @Test func flushedSegmentsAreDeletedWhenTrimmed() {
        let builder = SegmentBuilder(config: .init(idleThreshold: 60), calendar: calendar)
        let store = FakeStore()
        run(builder, from: base, seconds: 10, activity: Activity(app: "a"))
        store.apply(builder.takeChanges())
        // Input stops at +10; a new app comes up at +20 and gets flushed before idle hits.
        run(builder, from: base + 11, seconds: 8, activity: Activity(app: "a"), idle: { Double($0 + 1) })
        run(builder, from: base + 20, seconds: 20, activity: Activity(app: "b"), idle: { Double($0 + 10) })
        store.apply(builder.takeChanges())
        #expect(store.total(app: "b") > 0)
        run(builder, from: base + 41, seconds: 40, activity: Activity(app: "b"), idle: { Double($0 + 31) })
        store.apply(builder.takeChanges())
        #expect(store.total(app: "b") == 0)
        #expect(store.total(app: "a") == 10)
    }
}

@Suite struct StatsTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return calendar
    }()

    func hour(_ day: Int, _ hour: Int) -> Int64 {
        Int64(calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!.timeIntervalSince1970)
    }

    @Test func breakdowns() {
        let rows = [
            HourUsage(bucket: hour(19, 9), app: "com.microsoft.VSCode", site: "", seconds: 2000),
            HourUsage(bucket: hour(19, 22), app: "com.google.Chrome", site: "youtube.com", seconds: 1800),
            HourUsage(bucket: hour(20, 22), app: "com.google.Chrome", site: "youtube.com", seconds: 1200),
            HourUsage(bucket: hour(20, 10), app: "com.google.Chrome", site: "github.com", seconds: 600),
        ]
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 19))!
        let end = calendar.date(byAdding: .day, value: 7, to: start)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 23))!
        let stats = StatsBuilder.build(rows: rows, interval: DateInterval(start: start, end: end), now: now, calendar: calendar, categorizer: Categorizer())

        #expect(stats.total == 5600)
        #expect(stats.apps.first?.key == "com.google.Chrome")
        #expect(stats.apps.first?.seconds == 3600)
        #expect(stats.sites.first?.key == "youtube.com")
        #expect(stats.days.count == 7)
        #expect(stats.elapsedDays == 2)
        #expect(stats.days[0].total == 3800)
        #expect(stats.days[1].total == 1800)
        #expect(stats.hourTotal(22) == 3000)
        #expect(stats.peakHour == 22)
        // Oct 19 2026 is a Monday.
        #expect(stats.weekdays[1] == 3800)
        #expect(stats.heatmap[2][22] == 1200)
        #expect(stats.dailySeries(site: "youtube.com") == [1800, 1200, 0, 0, 0, 0, 0])
        #expect(stats.categories.first?.key == Category.entertainment.rawValue)
        // 2600 productive (VS Code + GitHub), 3000 distracting.
        let score = stats.productivityScore ?? -1
        #expect(abs(score - 2600.0 / 5600.0 * 100) < 0.01)

        let filtered = StatsBuilder.build(rows: rows, interval: DateInterval(start: start, end: end), now: now, calendar: calendar, categorizer: Categorizer(), filter: .site("youtube.com"))
        #expect(filtered.total == 3000)
        #expect(filtered.apps.count == 1)
    }

    @Test func sessionsMergeAcrossHourSplits() {
        let segments = [
            UsageSegment(id: 1, start: 0, end: 100, app: "a", site: ""),
            UsageSegment(id: 2, start: 100, end: 200, app: "a", site: ""),
            UsageSegment(id: 3, start: 201, end: 300, app: "b", site: ""),
            UsageSegment(id: 4, start: 302, end: 400, app: "a", site: ""),
            UsageSegment(id: 5, start: 1000, end: 1100, app: "a", site: ""),
        ]
        let apps = Sessions.apps(segments)
        #expect(apps.map(\.key) == ["a", "b", "a", "a"])
        #expect(apps[0].duration == 200)
        let screen = Sessions.screen(segments)
        #expect(screen.count == 2)
        #expect(screen[0].duration == 400)
        let stats = SessionStats(apps)
        #expect(stats.count == 4)
        #expect(stats.longest == 200)
        #expect(Sessions.switches(apps) == 3)
    }

    @Test func durationFormatting() {
        #expect(DurationFormat.short(38) == "38s")
        #expect(DurationFormat.short(45 * 60) == "45m")
        #expect(DurationFormat.short(2 * 3600 + 13 * 60) == "2h 13m")
        #expect(DurationFormat.short(3600) == "1h")
        #expect(DurationFormat.clock(65) == "1:05")
        #expect(DurationTicks(max: 5000).values == [0, 1800, 3600, 5400])
    }
}
