import SwiftUI
import TimeLensCore

/// Plain-English observations for a period, records, streaks, and the year at a glance.
struct InsightsView: View {
    private var model: AppModel { .shared }
    @State private var period = Period(kind: .week)
    @State private var data = PeriodData(interval: DateInterval(start: .now, duration: 86_400))
    @State private var year = PeriodData(interval: DateInterval(start: .now, duration: 86_400))

    var body: some View {
        let calendar = model.prefs.calendar
        Page(title: "Insights") {
            PeriodBar(period: $period)
        } content: {
            let insights = InsightEngine.insights(
                current: data.stats,
                previous: data.previous,
                periodName: period.periodName(calendar),
                previousName: period.previousName(calendar),
                appName: model.appName,
                longestSession: data.longestScreenSession,
                calendar: calendar
            )
            if insights.isEmpty {
                Card { EmptyState(symbol: "sparkles", title: "Not enough data yet", message: "Insights appear once there's some screen time in this period.") }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], spacing: 12) {
                    ForEach(insights) { insight in
                        InsightCard(insight: insight)
                    }
                }
            }
            AdaptiveStack(minimum: .wide) {
                recordsCard
                streaksCard.frame(minWidth: 320, maxWidth: 420)
            }
            Card("The last 12 months", subtitle: "Daily screen time — hover a day") {
                CalendarHeatmap(days: year.stats.days, calendar: calendar, goal: model.prefs.dailyGoal)
            }
            Card("Week by week", subtitle: "By category, last 12 months") {
                let weeks = StatsBuilder.group(year.stats.days, by: .weekOfYear, calendar: calendar).suffix(26)
                DurationBarChart(bars: weeks.map { week in
                    BarDatum(id: "wk\(Int(week.day.timeIntervalSince1970))", label: week.day.formatted(.dateTime.day().month(.abbreviated)),
                             title: "Week of \(week.day.formatted(.dateTime.day().month(.wide)))", parts: BarBuilder.categoryParts(week.byCategory))
                }, labelStride: 4, height: 220)
                CategoryLegend(categories: UsageCategory.allCases.filter { year.stats.categories.map(\.key).contains($0.rawValue) })
            }
        }
        .task(id: LoadKey(period: period, version: 0, categories: model.categoryVersion)) {
            data = await model.loadPeriod(period)
        }
        .task(id: model.categoryVersion) {
            let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now))!
            let interval = DateInterval(start: calendar.date(byAdding: .day, value: -364, to: end)!, end: end)
            year = await model.load(interval: interval, comparison: nil)
        }
    }

    // MARK: Records

    private var recordsCard: some View {
        let stats = year.stats
        let active = stats.days.filter { $0.total >= 600 }
        let busiest = active.max { $0.total < $1.total }
        let lightest = active.min { $0.total < $1.total }
        let longest = year.longestScreenSession
        let topApp = stats.apps.first
        let topSite = stats.sites.first { !SiteKey.isPseudo($0.key) }
        return Card("Records", subtitle: "Last 12 months") {
            VStack(spacing: 10) {
                record("flame.fill", "Most screen time in a day", busiest.map { DurationFormat.short($0.total) }, busiest.map { $0.day.formatted(.dateTime.weekday(.wide).day().month(.wide)) })
                record("leaf.fill", "Lightest active day", lightest.map { DurationFormat.short($0.total) }, lightest.map { $0.day.formatted(.dateTime.weekday(.wide).day().month(.wide)) })
                record("timer", "Longest stretch without a break", longest.map { DurationFormat.short($0.duration) },
                       longest.map { "\(TimeText.day(Date(timeIntervalSince1970: $0.start))), \(TimeText.range($0.start, $0.end))" })
                record("app.fill", "Most-used app", topApp.map { DurationFormat.short($0.seconds) }, topApp.map { model.appName($0.key) })
                record("globe", "Most-visited website", topSite.map { DurationFormat.short($0.seconds) }, topSite.map { $0.key })
                record("sum", "Tracked in total", DurationFormat.short(stats.total), "\(active.count) active days · \(DurationFormat.short(stats.averagePerActiveDay)) per active day")
                record("hand.tap.fill", "Pickups", "\(year.pickups.count)", String(format: "%.1f per day", Double(year.pickups.count) / Double(max(active.count, 1))))
            }
        }
    }

    private func record(_ symbol: String, _ title: String, _ value: String?, _ detail: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).frame(width: 22).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            Text(value ?? "—").font(.callout.weight(.semibold)).monospacedDigit()
        }
    }

    // MARK: Streaks

    private var streaksCard: some View {
        let calendar = model.prefs.calendar
        let today = calendar.startOfDay(for: .now)
        // From the first tracked day: days before TimeLens existed aren't "under goal".
        let firstTracked = year.stats.days.first { $0.total >= 60 }?.day ?? today
        let days = year.stats.days.filter { $0.day <= today && $0.day >= firstTracked }
        let goal = model.prefs.dailyGoal
        let average = year.stats.averagePerActiveDay
        let threshold = goal ?? average
        // Today isn't over, so streaks count finished days.
        let finished = days.filter { $0.day < today }
        let under: (DayTotal) -> Bool = { $0.total <= threshold }
        var current = 0
        for day in finished.reversed() {
            if under(day) { current += 1 } else { break }
        }
        var best = 0
        var run = 0
        for day in finished {
            run = under(day) ? run + 1 : 0
            best = max(best, run)
        }
        var activeStreak = 0
        for day in days.reversed() {
            if day.total >= 60 { activeStreak += 1 } else if day.day < today { break }
        }
        return Card("Streaks", subtitle: goal == nil ? "Days under your average of \(DurationFormat.short(average)) — set a goal in Settings" : "Days under your \(DurationFormat.short(goal!)) goal") {
            HStack(spacing: 24) {
                streak("\(current)", "current", Theme.good)
                streak("\(best)", "best", Theme.accent)
                streak("\(activeStreak)", "days in a row on the Mac", Theme.muted)
            }
            let recent = Array(finished.suffix(28))
            VStack(alignment: .leading, spacing: 4) {
                Text("Last 4 weeks").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 3) {
                    ForEach(recent) { day in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(day.total < 60 ? Theme.track : under(day) ? Theme.good : Theme.critical.opacity(0.75))
                            .frame(height: 18)
                            .help("\(day.day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))): \(DurationFormat.short(day.total))")
                    }
                }
                HStack(spacing: 12) {
                    Label { Text("Under") } icon: { SeriesKey(color: Theme.good) }.labelStyle(KeyLabelStyle())
                    Label { Text("Over") } icon: { SeriesKey(color: Theme.critical.opacity(0.75)) }.labelStyle(KeyLabelStyle())
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func streak(_ value: String, _ title: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 30, weight: .bold)).monospacedDigit().foregroundStyle(color)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct InsightCard: View {
    let insight: Insight

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: insight.symbol)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 32, height: 32)
                .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(insight.title).font(.headline)
                Text(insight.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.cardBorder))
    }

    private var color: Color {
        switch insight.tone {
        case .good: Theme.good
        case .bad: Theme.critical
        case .neutral: Theme.accent
        }
    }
}
