import Charts
import SwiftUI
import TimeLensCore

/// Every breakdown of screen time for a period: by day (or hour, week, month), hour of day,
/// weekday, weekday × hour, category, productivity, app, website, sessions and pickups. A
/// filter narrows all of it to one app, site or category.
struct StatsView: View {
    private var model: AppModel { .shared }
    @Binding var path: [Route]
    @State private var period = Period(kind: .week)
    @State private var filter: StatsFilter = .all
    @State private var data = PeriodData(interval: DateInterval(start: .now, duration: 86_400))
    @State private var options = UsageStats(interval: DateInterval(start: .now, duration: 1))
    @AppStorage("statsTrendStack") private var trendStack = "category"

    var body: some View {
        let calendar = model.prefs.calendar
        Page(title: "Stats") {
            VStack(alignment: .leading, spacing: 12) {
                PeriodBar(period: $period)
                FilterBar(filter: $filter, options: options)
            }
        } content: {
            summaryTiles
            trendCard
            if period.isMultiDay {
                AdaptiveStack(minimum: .wide) {
                    hourCard.layoutPriority(1)
                    weekdayCard.frame(minWidth: 380, maxWidth: 460)
                }
                Card("When you're on screen", subtitle: "Average per weekday and hour") {
                    WeekHourHeatmap(stats: data.stats, calendar: calendar)
                }
            }
            AdaptiveStack(minimum: .wide) {
                Card("By category") {
                    CategoryBreakdown(stats: data.stats) { filter = .category($0) }
                }
                productivityCard
            }
            AdaptiveStack {
                appsCard
                sitesCard
            }
            AdaptiveStack(minimum: .wide) {
                sessionsCard
                pickupsCard
            }
            if period.isMultiDay, data.stats.days.count <= 62 {
                firstLastCard
            }
            if data.stats.days.count > 31 {
                Card("Every day", subtitle: "Darker is more screen time") {
                    CalendarHeatmap(days: data.stats.days, calendar: calendar, goal: model.prefs.dailyGoal)
                }
            }
        }
        .task(id: LoadKey(period: period, version: period.isCurrent(calendar) ? model.dataVersion / 6 : 0,
                          categories: model.categoryVersion, filter: filter)) {
            data = await model.loadPeriod(period, filter: filter)
            if filter == .all {
                options = data.stats
            } else if options.total == 0 {
                options = await model.loadPeriod(period, sessions: false).stats
            }
        }
    }

    // MARK: Summary

    private var summaryTiles: some View {
        let stats = data.stats
        let previous = data.previous
        let previousDays = max(previous.elapsedDays, 1)
        let previousAverage = previous.total / Double(previousDays)
        return StatGrid(count: 8, minimumWidth: 165) {
            StatTile(title: "Total", symbol: "hourglass", value: DurationFormat.short(stats.total),
                     footnote: "vs \(DurationFormat.short(previous.total)) \(shortPrevious)",
                     delta: DurationFormat.change(stats.total, previous.total), higherIsBetter: false)
            StatTile(title: "Daily average", symbol: "calendar", value: DurationFormat.short(stats.averagePerDay),
                     footnote: "\(stats.activeDays) active of \(stats.elapsedDays) day\(stats.elapsedDays == 1 ? "" : "s")",
                     delta: period.isMultiDay ? DurationFormat.change(stats.averagePerDay, previousAverage) : nil, higherIsBetter: false)
            StatTile(title: "Pickups", symbol: "hand.tap", value: "\(data.pickups.count)",
                     footnote: period.isMultiDay ? String(format: "%.1f a day", data.pickupsPerDay) : "unlocks & wakes",
                     delta: data.previousPickups > 0 ? (Double(data.pickups.count) - Double(data.previousPickups)) / Double(data.previousPickups) : nil,
                     higherIsBetter: false)
            StatTile(title: "Sessions", symbol: "square.stack.3d.up", value: "\(data.allSessions.count)",
                     footnote: "avg \(DurationFormat.short(data.allSessions.average)) · median \(DurationFormat.short(data.allSessions.median))")
            StatTile(title: "Longest stretch", symbol: "timer", value: DurationFormat.short(data.longestScreenSession?.duration ?? 0),
                     footnote: data.longestScreenSession.map { "\(TimeText.day(Date(timeIntervalSince1970: $0.start))), \(TimeText.time($0.start))" })
            StatTile(title: "Productivity", symbol: "bolt.fill",
                     value: stats.productivityScore.map { "\(Int($0.rounded())) / 100" } ?? "—",
                     footnote: "\(TimeText.percent((stats.ratings[.productive] ?? 0) / max(stats.total, 1))) productive",
                     delta: stats.productivityScore.flatMap { score in previous.productivityScore.map { (score - $0) / max($0, 1) } }, higherIsBetter: true)
            StatTile(title: "Peak hour", symbol: "clock", value: stats.peakHour.map { TimeText.hour($0) } ?? "—",
                     footnote: stats.peakHour.map { "\(DurationFormat.short(stats.hourTotal($0) / Double(max(stats.elapsedDays, 1))))\(period.isMultiDay ? " a day" : "")" })
            StatTile(title: "Focus", symbol: "moon.fill", value: DurationFormat.short(data.focusSeconds),
                     footnote: "\(data.focus.count) session\(data.focus.count == 1 ? "" : "s")")
        }
    }

    private var shortPrevious: String {
        switch period.kind {
        case .day: "yesterday"
        case .week: "last week"
        case .month: "last month"
        case .year: "last year"
        case .custom: "before"
        }
    }

    // MARK: Trend

    private enum Grain { case hour, day, week, month }

    private var grain: Grain {
        switch period.kind {
        case .day: .hour
        case .year: .month
        case .custom where data.stats.days.count > 62: .week
        default: .day
        }
    }

    private var trendTitle: String {
        switch grain {
        case .hour: "Hour by hour"
        case .day: "Day by day"
        case .week: "Week by week"
        case .month: "Month by month"
        }
    }

    private var trendCard: some View {
        let calendar = model.prefs.calendar
        let bars = trendBars
        let goal: Double? = grain == .day ? model.prefs.dailyGoal : nil
        let average: Double? = switch grain {
        case .hour: nil
        case .day: data.stats.averagePerDay
        case .week, .month: bars.isEmpty ? nil : bars.filter { !$0.dimmed }.map(\.total).reduce(0, +) / Double(max(bars.filter { !$0.dimmed }.count, 1))
        }
        return Card(trendTitle, subtitle: trendSubtitle, accessory: {
            if grain != .hour {
                CardPicker(selection: $trendStack, options: [("category", "Categories"), ("apps", "Apps"), ("rating", "Productivity"), ("total", "Total")])
            }
        }) {
            DurationBarChart(
                bars: bars,
                average: average,
                averageLabel: grain == .day ? "daily avg" : "avg",
                goal: goal,
                labelStride: bars.count > 16 ? Int((Double(bars.count) / 12).rounded(.up)) : 1,
                height: 260,
                highlightID: grain == .day ? "d\(Int(calendar.startOfDay(for: .now).timeIntervalSince1970))" : nil,
                onSelect: { bar in
                    // Drill into a day.
                    guard grain == .day, let seconds = Double(bar.id.dropFirst()) else { return }
                    period = Period(kind: .day, anchor: Date(timeIntervalSince1970: seconds + 3600))
                }
            )
            trendLegend
        }
    }

    private var trendSubtitle: String {
        var parts: [String] = []
        if grain == .day { parts.append("Click a day to open it") }
        if model.prefs.dailyGoal != nil, grain == .day { parts.append("green line is your goal") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var trendLegend: some View {
        if grain == .hour || trendStack == "category" {
            CategoryLegend(categories: UsageCategory.allCases.filter { data.stats.categories.map(\.key).contains($0.rawValue) })
        } else if trendStack == "apps" {
            FlowLayout(spacing: 12, lineSpacing: 4) {
                ForEach(Array(topAppKeys.enumerated()), id: \.offset) { index, app in
                    Label { Text(model.appName(app)) } icon: { SeriesKey(color: Theme.series[index]) }
                        .labelStyle(KeyLabelStyle())
                }
                Label { Text("Other") } icon: { SeriesKey(color: Theme.other) }
                    .labelStyle(KeyLabelStyle())
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if trendStack == "rating" {
            HStack(spacing: 12) {
                ForEach([Rating.productive, .neutral, .distracting]) { rating in
                    Label { Text(rating.title) } icon: { SeriesKey(color: Theme.color(rating)) }
                        .labelStyle(KeyLabelStyle())
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var topAppKeys: [String] { Array(data.stats.apps.prefix(7).map(\.key)) }

    private var trendBars: [BarDatum] {
        let calendar = model.prefs.calendar
        let stats = data.stats
        switch grain {
        case .hour:
            return BarBuilder.hours(stats, isToday: period.isCurrent(calendar), calendar: calendar)
        case .day:
            let bars = BarBuilder.days(stats.days, calendar: calendar)
            return restack(bars, days: stats.days.indices.map { [$0] })
        case .week, .month:
            let component: Calendar.Component = grain == .week ? .weekOfYear : .month
            let groups = StatsBuilder.group(stats.days, by: component, calendar: calendar)
            var indices: [[Int]] = Array(repeating: [], count: groups.count)
            for (index, day) in stats.days.enumerated() {
                guard let start = calendar.dateInterval(of: component, for: day.day)?.start,
                      let group = groups.firstIndex(where: { $0.day == start }) else { continue }
                indices[group].append(index)
            }
            let bars = grain == .month
                ? BarBuilder.months(groups, calendar: calendar)
                : groups.map { week in
                    BarDatum(id: "wk\(Int(week.day.timeIntervalSince1970))", label: week.day.formatted(.dateTime.day().month(.abbreviated)),
                             title: "Week of \(week.day.formatted(.dateTime.day().month(.wide)))", parts: BarBuilder.categoryParts(week.byCategory),
                             dimmed: week.day > Date())
                }
            return restack(bars, days: indices, groups: groups)
        }
    }

    /// Swaps category parts for apps, ratings or one total, as the picker says.
    private func restack(_ bars: [BarDatum], days: [[Int]], groups: [DayTotal]? = nil) -> [BarDatum] {
        let stats = data.stats
        switch trendStack {
        case "apps":
            let top = topAppKeys
            return bars.enumerated().map { index, bar in
                var parts: [BarPart] = []
                var used = 0.0
                for (rank, app) in top.enumerated() {
                    let seconds = days[index].reduce(0) { $0 + (stats.appDays[app]?[$1] ?? 0) }
                    used += seconds
                    parts.append(BarPart(key: app, name: model.appName(app), color: Theme.series[rank], seconds: seconds))
                }
                let total = days[index].reduce(0) { $0 + stats.days[$1].total }
                parts.append(BarPart(key: "other", name: "Other", color: Theme.other, seconds: max(total - used, 0)))
                return BarDatum(id: bar.id, label: bar.label, title: bar.title, parts: parts, dimmed: bar.dimmed)
            }
        case "rating":
            return bars.enumerated().map { index, bar in
                var byRating: [Rating: Double] = [:]
                for day in days[index] {
                    for (rating, seconds) in stats.days[day].byRating { byRating[rating, default: 0] += seconds }
                }
                let parts = [Rating.productive, .neutral, .distracting].map {
                    BarPart(key: $0.title, name: $0.title, color: Theme.color($0), seconds: byRating[$0] ?? 0)
                }
                return BarDatum(id: bar.id, label: bar.label, title: bar.title, parts: parts, dimmed: bar.dimmed)
            }
        case "total":
            return bars.map { BarDatum(id: $0.id, label: $0.label, title: $0.title, parts: BarBuilder.single($0.total), dimmed: $0.dimmed) }
        default:
            return bars
        }
    }

    // MARK: Hour and weekday

    private var hourCard: some View {
        let calendar = model.prefs.calendar
        let stats = data.stats
        return Card("By hour of day", subtitle: "Average per day, stacked by category") {
            DurationBarChart(bars: BarBuilder.hours(stats, perDay: stats.elapsedDays, calendar: calendar), height: 220)
            if let peak = stats.peakHour {
                let morning = (5..<12).reduce(0) { $0 + stats.hourTotal($1) }
                let afternoon = (12..<17).reduce(0) { $0 + stats.hourTotal($1) }
                let evening = (17..<22).reduce(0) { $0 + stats.hourTotal($1) }
                let night = stats.total - morning - afternoon - evening
                HStack(spacing: 16) {
                    Label("Peak \(TimeText.hour(peak))", systemImage: "flame").foregroundStyle(.secondary)
                    ForEach([("Morning", morning), ("Afternoon", afternoon), ("Evening", evening), ("Night", night)], id: \.0) { part in
                        Text("\(part.0) ").foregroundStyle(.secondary)
                        + Text(TimeText.percent(part.1 / max(stats.total, 1))).fontWeight(.semibold)
                    }
                }
                .font(.caption)
            }
        }
    }

    private var weekdayCard: some View {
        let calendar = model.prefs.calendar
        let stats = data.stats
        let weekendDays = stats.weekdayCounts[0] + stats.weekdayCounts[6]
        let weekdayDays = (1...5).reduce(0) { $0 + stats.weekdayCounts[$1] }
        let weekendAverage = (stats.weekdays[0] + stats.weekdays[6]) / Double(max(weekendDays, 1))
        let weekdayAverage = (1...5).reduce(0) { $0 + stats.weekdays[$1] } / Double(max(weekdayDays, 1))
        return Card("By weekday", subtitle: "Average per day") {
            DurationBarChart(bars: BarBuilder.weekdays(stats, calendar: calendar), height: 220)
            HStack(spacing: 14) {
                Label { Text("Weekdays \(DurationFormat.short(weekdayAverage))") } icon: { SeriesKey(color: Theme.series[0]) }
                    .labelStyle(KeyLabelStyle())
                Label { Text("Weekends \(DurationFormat.short(weekendAverage))") } icon: { SeriesKey(color: Theme.series[1]) }
                    .labelStyle(KeyLabelStyle())
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: Productivity

    private var productivityCard: some View {
        let stats = data.stats
        return Card("Productivity", subtitle: "Rate apps, sites and categories in Settings or on their pages") {
            if let score = stats.productivityScore {
                ProductivityGauge(score: score, ratings: stats.ratings)
                Divider()
                VStack(spacing: 6) {
                    ForEach(UsageCategory.allCases) { category in
                        let seconds = stats.categories.first { $0.key == category.rawValue }?.seconds ?? 0
                        if seconds > 0 {
                            HStack(spacing: 8) {
                                EntityIcon(entity: .category(category), size: 18)
                                Text(category.title).font(.callout)
                                Spacer()
                                let rating = model.categorizer.rating(of: category)
                                Text(rating.title).font(.caption).foregroundStyle(.secondary)
                                SeriesKey(color: Theme.color(rating))
                                Text(DurationFormat.short(seconds)).font(.callout).monospacedDigit().frame(width: 64, alignment: .trailing)
                            }
                        }
                    }
                }
            } else {
                EmptyState(symbol: "bolt", title: "Nothing to rate yet")
            }
        }
    }

    // MARK: Apps & sites

    private var appsCard: some View {
        Card("Apps", subtitle: "\(data.stats.apps.count) used", accessory: {
            Button("See all") { NotificationCenter.default.post(name: .openSection, object: nil, userInfo: ["section": DashboardSection.apps.rawValue]) }
                .buttonStyle(.link)
        }) {
            RankedList(items: data.stats.apps.prefix(12).map { .app($0, data.appSessionStats[$0.key]) },
                       peak: data.stats.apps.first?.seconds ?? 1,
                       sparklines: period.isMultiDay ? { item in data.stats.dailySeries(app: item.ranked.key) } : nil, open: { path.append($0) })
        }
    }

    private var sitesCard: some View {
        Card("Websites", subtitle: "\(data.stats.sites.count) visited", accessory: {
            Button("See all") { NotificationCenter.default.post(name: .openSection, object: nil, userInfo: ["section": DashboardSection.websites.rawValue]) }
                .buttonStyle(.link)
        }) {
            RankedList(items: data.stats.sites.prefix(12).map { .site($0, data.siteSessionStats[$0.key]) },
                       peak: data.stats.sites.first?.seconds ?? 1,
                       sparklines: period.isMultiDay ? { item in data.stats.dailySeries(site: item.ranked.key) } : nil, open: { path.append($0) })
        }
    }

    // MARK: Sessions & pickups

    private var sessionsCard: some View {
        let sessions = data.allSessions
        return Card("Session lengths", subtitle: "How long you stay on one app before switching") {
            SimpleBarChart(items: SessionStats.bucketTitles.enumerated().map { index, title in
                SimpleBarChart.Item(id: "s\(index)", label: title, value: Double(sessions.histogram[index]),
                                    tooltip: "\(sessions.histogram[index]) session\(sessions.histogram[index] == 1 ? "" : "s")")
            }, color: Theme.series[6], height: 170)
            HStack(spacing: 18) {
                metric("Sessions", "\(sessions.count)")
                metric("Average", DurationFormat.short(sessions.average))
                metric("Median", DurationFormat.short(sessions.median))
                metric("Longest", DurationFormat.short(sessions.longest))
                metric("Switches", "\(data.switches)")
            }
        }
    }

    private var pickupsCard: some View {
        let byHour = data.pickupsByHour
        let firstTimes = data.dayBounds.values.map(\.first)
        let calendar = model.prefs.calendar
        let averageFirst: String = {
            guard !firstTimes.isEmpty else { return "—" }
            let minutes = firstTimes.map { time -> Double in
                let date = Date(timeIntervalSince1970: time)
                return Double(calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date))
            }
            let average = minutes.reduce(0, +) / Double(minutes.count)
            let date = calendar.date(bySettingHour: Int(average) / 60, minute: Int(average) % 60, second: 0, of: .now) ?? .now
            return date.formatted(date: .omitted, time: .shortened)
        }()
        return Card("Pickups", subtitle: "Coming back to the Mac after it was locked, asleep or dark") {
            SimpleBarChart(items: (0..<24).map { hour in
                SimpleBarChart.Item(id: "p\(hour)", label: hour % 3 == 0 ? TimeText.shortHour(hour) : "", value: Double(byHour[hour]),
                                    tooltip: "\(TimeText.hour(hour)): \(byHour[hour])")
            }, color: Theme.series[2], height: 170)
            HStack(spacing: 18) {
                metric("Total", "\(data.pickups.count)")
                metric("Per day", String(format: "%.1f", data.pickupsPerDay))
                metric(period.isMultiDay ? "Avg first pickup" : "First pickup", period.isMultiDay ? averageFirst : (data.firstPickup.map(TimeText.time) ?? "—"))
                metric("Minutes per pickup", data.pickups.isEmpty ? "—" : DurationFormat.short(data.stats.total / Double(data.pickups.count)))
            }
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.semibold)).monospacedDigit()
        }
    }

    // MARK: First and last use

    private var firstLastCard: some View {
        let rows: [(day: Date, first: Double, last: Double)] = data.stats.days.compactMap { day in
            guard let bounds = data.dayBounds[day.day] else { return nil }
            let first = Date(timeIntervalSince1970: bounds.first).timeIntervalSince(day.day) / 3600
            let last = Date(timeIntervalSince1970: bounds.last).timeIntervalSince(day.day) / 3600
            return (day.day, first, min(max(last, first + 0.25), 28))
        }
        return Card("First and last use", subtitle: "From your first pickup to when you stopped, each day (days run 4 AM to 4 AM)") {
            if rows.isEmpty {
                EmptyState(symbol: "sunrise", title: "Not enough days yet")
            } else {
                Chart(rows, id: \.day) { row in
                    BarMark(x: .value("Day", row.day, unit: .day), yStart: .value("First", row.first), yEnd: .value("Last", row.last), width: .ratio(0.4))
                        .foregroundStyle(Theme.series[0])
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                .chartYScale(domain: [28, 4])
                .chartYAxis {
                    AxisMarks(position: .leading, values: [4, 8, 12, 16, 20, 24, 28]) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Theme.gridline)
                        AxisValueLabel {
                            if let hour = value.as(Double.self) { Text(TimeText.hour(Int(hour) % 24)).font(.caption2) }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: rows.count > 14 ? 3 : 1)) { _ in
                        AxisValueLabel(format: rows.count > 14 ? .dateTime.day() : .dateTime.weekday(.abbreviated)).font(.caption2)
                    }
                }
                .frame(height: 220)
            }
        }
    }
}

/// "Showing: Everything ▾" — narrows every stat on the page to one app, site or category.
struct FilterBar: View {
    private var model: AppModel { .shared }
    @Binding var filter: StatsFilter
    let options: UsageStats

    var body: some View {
        HStack(spacing: 8) {
            Text("Showing").foregroundStyle(.secondary)
            Menu {
                Button("Everything") { filter = .all }
                Divider()
                Menu("Category") {
                    ForEach(UsageCategory.allCases) { category in
                        Button(category.title) { filter = .category(category) }
                    }
                }
                Menu("App") {
                    ForEach(options.apps.prefix(30)) { app in
                        Button(model.appName(app.key)) { filter = .app(app.key) }
                    }
                }
                Menu("Website") {
                    ForEach(options.sites.prefix(30)) { site in
                        Button(model.siteName(site.key)) { filter = .site(site.key) }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    switch filter {
                    case .all: Image(systemName: "square.stack")
                    case let .app(id): AppIconView(app: id, size: 16)
                    case let .site(site): SiteIconView(site: site, size: 16)
                    case let .category(category): EntityIcon(entity: .category(category), size: 16)
                    }
                    Text(title)
                }
            }
            .fixedSize()
            if filter != .all {
                Button { filter = .all } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Show everything")
            }
            Spacer()
        }
    }

    private var title: String {
        switch filter {
        case .all: "Everything"
        case let .app(id): model.appName(id)
        case let .site(site): model.siteName(site)
        case let .category(category): category.title
        }
    }
}
