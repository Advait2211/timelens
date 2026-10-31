import SwiftUI
import TimeLensCore

/// One day at a glance: the total, the headline numbers, hour by hour, categories, the
/// timeline and the top apps and sites.
struct OverviewView: View {
    private var model: AppModel { .shared }
    @Binding var path: [Route]
    @State private var period = Period.today
    @State private var data = PeriodData(interval: DateInterval(start: .now, duration: 86_400))
    @State private var weekAverage: Double = 0

    var body: some View {
        let calendar = model.prefs.calendar
        Page(title: "Today") {
            PeriodBar(period: $period, kinds: [.day])
        } content: {
            hero
            tiles
            AdaptiveStack(minimum: .wide) {
                Card("Hour by hour", subtitle: "Stacked by category") {
                    DurationBarChart(
                        bars: BarBuilder.hours(data.stats, isToday: period.isCurrent(calendar), calendar: calendar),
                        highlightID: period.isCurrent(calendar) ? "h\(calendar.component(.hour, from: .now))" : nil
                    )
                    CategoryLegend(categories: UsageCategory.allCases.filter { data.stats.categories.map(\.key).contains($0.rawValue) })
                }
                .frame(minWidth: 0)
                .layoutPriority(1)
                Card("Categories") {
                    CategoryBreakdown(stats: data.stats)
                }
                .frame(minWidth: 400, maxWidth: 460)
            }
            Card("Timeline", subtitle: "Every stretch of the day, in order") {
                if data.segments.isEmpty {
                    EmptyState(symbol: "calendar.day.timeline.left", title: "Nothing recorded")
                } else {
                    TimelineRibbon(blocks: RibbonData.blocks(data, model: model), window: RibbonData.activeWindow(data, calendar: calendar),
                                   now: period.isCurrent(calendar) ? Date().timeIntervalSince1970 : nil)
                }
            }
            AdaptiveStack {
                topApps
                topSites
            }
        }
        .task(id: LoadKey(period: period, version: period.isCurrent(calendar) ? model.dataVersion : 0, categories: model.categoryVersion)) {
            data = await model.loadPeriod(period)
            if let store = model.store {
                let day = period.interval(calendar)
                let week = DateInterval(start: calendar.date(byAdding: .day, value: -7, to: day.start)!, end: day.start)
                let rows = await store.hourly(week)
                let activeDays = Set(rows.map { calendar.startOfDay(for: Date(timeIntervalSince1970: Double($0.bucket))) }).count
                weekAverage = rows.reduce(0) { $0 + $1.seconds } / Double(max(activeDays, 1))
            }
        }
    }

    private var hero: some View {
        let calendar = model.prefs.calendar
        let stats = data.stats
        return Card {
            HStack(alignment: .center, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(period.isCurrent(calendar) ? "Screen time today" : "Screen time")
                        .font(.callout).foregroundStyle(.secondary)
                    Text(DurationFormat.short(stats.total))
                        .font(.system(size: 46, weight: .bold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    VStack(alignment: .leading, spacing: 3) {
                        if let text = DurationFormat.comparison(stats.total, data.previous.total, period: period.previousName(calendar)) {
                            comparisonLine(text, change: DurationFormat.change(stats.total, data.previous.total))
                        }
                        if weekAverage >= 60, let text = DurationFormat.comparison(stats.total, weekAverage, period: "your 7-day average (\(DurationFormat.short(weekAverage)))") {
                            comparisonLine(text, change: period.isCurrent(calendar) ? nil : DurationFormat.change(stats.total, weekAverage))
                        }
                    }
                }
                Spacer()
                if let goal = model.prefs.dailyGoal {
                    GoalRing(used: stats.total, goal: goal)
                        .frame(width: 110, height: 110)
                }
                if let score = stats.productivityScore {
                    ProductivityGauge(score: score, ratings: stats.ratings)
                        .frame(width: 220)
                }
            }
        }
    }

    private func comparisonLine(_ text: String, change: Double?) -> some View {
        HStack(spacing: 6) {
            if let change { DeltaBadge(change: change, higherIsBetter: false) }
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
    }

    private var tiles: some View {
        let first = data.firstPickup.map(TimeText.time) ?? "—"
        let last = data.dayBounds.values.map(\.last).max().map(TimeText.time) ?? "—"
        let pickupChange = data.previousPickups > 0 ? (Double(data.pickups.count) - Double(data.previousPickups)) / Double(data.previousPickups) : nil
        return StatGrid(count: 8, minimumWidth: 160) {
            StatTile(title: "Pickups", symbol: "hand.tap", value: "\(data.pickups.count)",
                     footnote: "unlocks & wakes", delta: pickupChange, higherIsBetter: false)
            StatTile(title: "Sessions", symbol: "square.stack.3d.up", value: "\(data.allSessions.count)",
                     footnote: "avg \(DurationFormat.short(data.allSessions.average))")
            StatTile(title: "Longest stretch", symbol: "timer", value: DurationFormat.short(data.longestScreenSession?.duration ?? 0),
                     footnote: data.longestScreenSession.map { TimeText.range($0.start, $0.end) })
            StatTile(title: "App switches", symbol: "arrow.left.arrow.right", value: "\(data.switches)",
                     footnote: data.stats.total > 0 ? String(format: "%.0f per hour", Double(data.switches) / max(data.stats.total / 3600, 1)) : nil)
            StatTile(title: "First pickup", symbol: "sunrise", value: first, footnote: "last use \(last)")
            StatTile(title: "Productive", symbol: "bolt.fill",
                     value: TimeText.percent((data.stats.ratings[.productive] ?? 0) / max(data.stats.total, 1)),
                     footnote: DurationFormat.short(data.stats.ratings[.productive] ?? 0))
            StatTile(title: "Distracting", symbol: "sparkles.tv",
                     value: DurationFormat.short(data.stats.ratings[.distracting] ?? 0),
                     footnote: TimeText.percent((data.stats.ratings[.distracting] ?? 0) / max(data.stats.total, 1)) + " of the day")
            StatTile(title: "Focus", symbol: "moon.fill", value: DurationFormat.short(data.focusSeconds),
                     footnote: "\(data.focus.count) session\(data.focus.count == 1 ? "" : "s")")
        }
    }

    private var topApps: some View {
        Card("Top apps", accessory: {
            Button("See all") { NotificationCenter.default.post(name: .openSection, object: nil, userInfo: ["section": DashboardSection.apps.rawValue]) }
                .buttonStyle(.link)
        }) {
            RankedList(items: data.stats.apps.prefix(8).map { .app($0, data.appSessionStats[$0.key]) }, peak: data.stats.apps.first?.seconds ?? 1, open: { path.append($0) })
        }
    }

    private var topSites: some View {
        Card("Top websites", accessory: {
            Button("See all") { NotificationCenter.default.post(name: .openSection, object: nil, userInfo: ["section": DashboardSection.websites.rawValue]) }
                .buttonStyle(.link)
        }) {
            RankedList(items: data.stats.sites.prefix(8).map { .site($0, data.siteSessionStats[$0.key]) }, peak: data.stats.sites.first?.seconds ?? 1, open: { path.append($0) })
        }
    }
}

struct LoadKey: Hashable {
    var period: Period
    var version: Int
    var categories: Int
    var filter: StatsFilter = .all
}

/// A clickable list of apps or sites with time, share, sessions and a bar.
struct RankedList: View {
    enum Item {
        case app(Ranked, SessionStats?)
        case site(Ranked, SessionStats?)

        var ranked: Ranked {
            switch self {
            case let .app(ranked, _), let .site(ranked, _): ranked
            }
        }
    }

    private var model: AppModel { .shared }
    let items: [Item]
    let peak: Double
    var sparklines: ((Item) -> [Double]?)?
    var open: ((Route) -> Void)?

    var body: some View {
        if items.isEmpty {
            EmptyState(symbol: "tray", title: "Nothing here yet")
        } else {
            VStack(spacing: 2) {
                ForEach(items, id: \.ranked.key) { item in
                    if let open {
                        Button { open(route(item)) } label: { row(item) }
                            .buttonStyle(.plain)
                    } else {
                        NavigationLink(value: route(item)) { row(item) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func route(_ item: Item) -> Route {
        switch item {
        case let .app(ranked, _): .app(ranked.key)
        case let .site(ranked, _): .site(ranked.key)
        }
    }

    @ViewBuilder private func row(_ item: Item) -> some View {
        switch item {
        case let .app(ranked, sessions):
            let category = model.categorizer.appCategory(ranked.key)
            RankedRow(entity: .app(ranked.key), name: model.appName(ranked.key),
                      subtitle: sessions.map { "\($0.count) session\($0.count == 1 ? "" : "s")" },
                      seconds: ranked.seconds, fraction: ranked.seconds / max(peak, 1), share: ranked.share,
                      color: Theme.color(category), sparkline: sparklines?(item))
        case let .site(ranked, sessions):
            let category = model.categorizer.siteCategory(ranked.key)
            RankedRow(entity: .site(ranked.key), name: model.siteName(ranked.key),
                      subtitle: sessions.map { "\($0.count) visit\($0.count == 1 ? "" : "s")" },
                      seconds: ranked.seconds, fraction: ranked.seconds / max(peak, 1), share: ranked.share,
                      color: Theme.color(category), sparkline: sparklines?(item))
        }
    }
}

/// Progress toward the daily goal as a ring.
struct GoalRing: View {
    let used: Double
    let goal: Double

    var body: some View {
        let fraction = used / max(goal, 1)
        ZStack {
            Circle().stroke(Theme.track, lineWidth: 10)
            Circle()
                .trim(from: 0, to: min(fraction, 1))
                .stroke(fraction > 1 ? Theme.critical : Theme.good, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Image(systemName: fraction > 1 ? "exclamationmark.triangle.fill" : "flag.fill")
                    .font(.caption).foregroundStyle(fraction > 1 ? Theme.critical : Theme.good)
                Text(TimeText.percent(fraction)).font(.headline).monospacedDigit()
                Text("of \(DurationFormat.short(goal))").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The productivity score with the productive / neutral / distracting split.
struct ProductivityGauge: View {
    let score: Double
    let ratings: [Rating: Double]

    var body: some View {
        let total = max(ratings.values.reduce(0, +), 1)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Productivity").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(score.rounded()))").font(.title2.weight(.bold)).monospacedDigit()
                Text("/ 100").font(.caption).foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    ForEach([Rating.productive, .neutral, .distracting]) { rating in
                        let share = (ratings[rating] ?? 0) / total
                        if share > 0 {
                            Rectangle().fill(Theme.color(rating))
                                .frame(width: max((proxy.size.width - 4) * share, 2))
                        }
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 8)
            HStack(spacing: 10) {
                ForEach([Rating.productive, .neutral, .distracting]) { rating in
                    Label { Text("\(rating.title) \(DurationFormat.short(ratings[rating] ?? 0))") } icon: { SeriesKey(color: Theme.color(rating)) }
                        .labelStyle(KeyLabelStyle())
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}

/// Turns segments into ribbon blocks and picks the window worth showing.
enum RibbonData {
    @MainActor
    static func blocks(_ data: PeriodData, model: AppModel) -> [RibbonBlock] {
        let runs = Sessions.merge(data.segments, gap: 5) { "\($0.app)\u{1}\($0.site)" }
        return runs.enumerated().map { index, run in
            let parts = run.key.split(separator: "\u{1}", omittingEmptySubsequences: false).map(String.init)
            let app = parts.first ?? ""
            let site = parts.count > 1 ? parts[1] : ""
            let category = model.category(app: app, site: site)
            let name = site.isEmpty ? model.appName(app) : "\(model.siteName(site)) (\(model.appName(app)))"
            return RibbonBlock(id: index, start: run.start, end: run.end, color: Theme.color(category), label: name,
                               detail: "\(TimeText.range(run.start, run.end)) · \(DurationFormat.short(run.duration)) · \(category.title)")
        }
    }

    /// From an hour before the first use to an hour after the last, within the day.
    static func activeWindow(_ data: PeriodData, calendar: Calendar) -> ClosedRange<Double> {
        let day = data.interval
        let start = day.start.timeIntervalSince1970
        let end = day.end.timeIntervalSince1970
        guard let first = data.segments.first?.start, let last = data.segments.map(\.end).max() else { return start...end }
        // Local hour boundaries (IST is half an hour off UTC hours).
        let fromHour = calendar.dateInterval(of: .hour, for: Date(timeIntervalSince1970: first - 1800))?.start.timeIntervalSince1970 ?? first
        let toHour = calendar.dateInterval(of: .hour, for: Date(timeIntervalSince1970: last + 1800))?.end.timeIntervalSince1970 ?? last
        let from = max(start, fromHour)
        let to = min(end, toHour)
        return from...max(to, from + 3600)
    }
}
