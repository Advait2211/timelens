import SwiftUI
import TimeLensCore

/// Everything about one app or website: totals, trend, when you use it, sessions, its
/// windows or pages, and its category, rating, limit and focus settings.
struct EntityDetailView: View {
    private var model: AppModel { .shared }
    let entity: EntityRef
    @State private var period = Period(kind: .week)
    @State private var data = PeriodData(interval: DateInterval(start: .now, duration: 86_400))
    @State private var titles: [TitleUsage] = []
    @State private var allTotal: Double = 0
    @State private var editingLimit: UsageLimit?

    private var filter: StatsFilter {
        switch entity {
        case let .app(id): .app(id)
        case let .site(site): .site(site)
        case let .category(category): .category(category)
        }
    }

    private var key: String {
        switch entity {
        case let .app(id): id
        case let .site(site): site
        case let .category(category): category.rawValue
        }
    }

    private var name: String {
        switch entity {
        case let .app(id): model.appName(id)
        case let .site(site): model.siteName(site)
        case let .category(category): category.title
        }
    }

    private var category: UsageCategory {
        switch entity {
        case let .app(id): model.categorizer.appCategory(id)
        case let .site(site): model.categorizer.siteCategory(site)
        case let .category(category): category
        }
    }

    private var isBrowser: Bool {
        if case let .app(id) = entity { return BrowserReader.family(of: id) != nil }
        return false
    }

    var body: some View {
        let calendar = model.prefs.calendar
        let color = Theme.color(category)
        Page(title: name) {
            VStack(alignment: .leading, spacing: 14) {
                header
                PeriodBar(period: $period)
            }
        } content: {
            tiles
            Card(period.isMultiDay ? "Day by day" : "Hour by hour") {
                let bars = period.isMultiDay
                    ? BarBuilder.days(data.stats.days, calendar: calendar).map { BarDatum(id: $0.id, label: $0.label, title: $0.title, parts: BarBuilder.single($0.total, name: name, color: color), dimmed: $0.dimmed) }
                    : BarBuilder.hours(data.stats, isToday: period.isCurrent(calendar), calendar: calendar)
                DurationBarChart(bars: bars, average: period.isMultiDay ? data.stats.averagePerDay : nil,
                                 labelStride: bars.count > 16 ? Int((Double(bars.count) / 12).rounded(.up)) : 1, height: 220)
            }
            if period.isMultiDay {
                AdaptiveStack(minimum: .wide) {
                    Card("By hour of day", subtitle: "Average per day") {
                        DurationBarChart(bars: BarBuilder.hours(data.stats, perDay: data.stats.elapsedDays, calendar: calendar).map {
                            BarDatum(id: $0.id, label: $0.label, title: $0.title, parts: BarBuilder.single($0.total, name: name, color: color))
                        }, height: 190)
                    }
                    .layoutPriority(1)
                    Card("By weekday", subtitle: "Average per day") {
                        DurationBarChart(bars: BarBuilder.weekdays(data.stats, calendar: calendar, color: color), height: 190)
                    }
                    .frame(minWidth: 340, maxWidth: 420)
                }
            }
            AdaptiveStack {
                titlesCard
                if isBrowser {
                    Card("Websites in \(name)") {
                        RankedList(items: data.stats.sites.prefix(12).map { .site($0, data.siteSessionStats[$0.key]) },
                                   peak: data.stats.sites.first?.seconds ?? 1)
                    }
                } else if case .site = entity {
                    Card("Browsers") {
                        RankedList(items: data.stats.apps.map { .app($0, data.appSessionStats[$0.key]) },
                                   peak: data.stats.apps.first?.seconds ?? 1)
                    }
                } else {
                    sessionsCard
                }
            }
            if isBrowser || isSite {
                sessionsCard
            }
        }
        .task(id: LoadKey(period: period, version: period.isCurrent(calendar) ? model.dataVersion / 6 : 0, categories: model.categoryVersion, filter: filter)) {
            data = await model.loadPeriod(period, filter: filter)
            let interval = period.interval(calendar)
            if let store = model.store {
                allTotal = await store.hourly(interval).reduce(0) { $0 + $1.seconds }
                switch entity {
                case let .app(id): titles = await store.topTitles(interval, app: id)
                case let .site(site): titles = await store.topTitles(interval, site: site)
                case .category: titles = []
                }
            }
        }
        .sheet(item: $editingLimit) { limit in
            LimitEditor(limit: limit) { saved in
                if let saved { model.limits.save(saved) }
                editingLimit = nil
            }
        }
    }

    private var isSite: Bool {
        if case .site = entity { return true }
        return false
    }

    // MARK: Header

    private var header: some View {
        Card {
            HStack(spacing: 16) {
                EntityIcon(entity: entity, size: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(name).font(.title.weight(.semibold))
                    Text(subtitle).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    HStack(spacing: 8) {
                        categoryMenu
                        ratingMenu
                    }
                    HStack(spacing: 8) {
                        limitControl
                        focusToggle
                    }
                }
            }
        }
    }

    private var subtitle: String {
        switch entity {
        case let .app(id): isBrowser ? "\(id) · browser" : id
        case .site: "Website · \(category.title)"
        case .category: "Category"
        }
    }

    private var overrideKey: String {
        switch entity {
        case let .app(id): Override.appKey(id)
        case let .site(site): Override.siteKey(site)
        case let .category(category): Override.categoryKey(category)
        }
    }

    private var categoryMenu: some View {
        Menu {
            ForEach(UsageCategory.allCases) { option in
                Button {
                    switch entity {
                    case let .app(id): model.setCategory(option, forApp: id)
                    case let .site(site): model.setCategory(option, forSite: site)
                    case .category: break
                    }
                } label: {
                    if option == category { Label(option.title, systemImage: "checkmark") } else { Text(option.title) }
                }
            }
            if model.override(for: overrideKey)?.category != nil {
                Divider()
                Button("Use automatic category") {
                    switch entity {
                    case let .app(id): model.setCategory(nil, forApp: id)
                    case let .site(site): model.setCategory(nil, forSite: site)
                    case .category: break
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                SeriesKey(color: Theme.color(category))
                Text(category.title)
            }
        }
        .fixedSize()
        .disabled({ if case .category = entity { return true } else { return false } }())
    }

    private var ratingMenu: some View {
        let rating: Rating = {
            switch entity {
            case let .app(id): return model.categorizer.rating(app: id, site: "")
            case let .site(site): return model.categorizer.rating(app: "", site: site)
            case let .category(category): return model.categorizer.rating(of: category)
            }
        }()
        return Menu {
            ForEach([Rating.productive, .neutral, .distracting]) { option in
                Button {
                    model.setRating(option, forKey: overrideKey)
                } label: {
                    if option == rating { Label(option.title, systemImage: "checkmark") } else { Text(option.title) }
                }
            }
            if model.override(for: overrideKey)?.rating != nil {
                Divider()
                Button("Use the category's rating") { model.setRating(nil, forKey: overrideKey) }
            }
        } label: {
            HStack(spacing: 6) {
                SeriesKey(color: Theme.color(rating))
                Text(rating.title)
            }
        }
        .fixedSize()
    }

    private var limitKind: UsageLimit.Kind {
        switch entity {
        case .app: .app
        case .site: .site
        case .category: .category
        }
    }

    private var limitControl: some View {
        let existing = model.limits.limit(kind: limitKind, target: key)
        return Button {
            editingLimit = existing ?? UsageLimit(kind: limitKind, target: key, minutes: suggestedMinutes)
        } label: {
            Label(existing.map { "Limit \(DurationFormat.short($0.seconds))/day" } ?? "Set daily limit", systemImage: "hourglass")
        }
    }

    /// A limit a bit under what you use now, in clean steps.
    private var suggestedMinutes: Int {
        let perDay = data.stats.averagePerDay / 60 * 0.8
        let steps = [15, 30, 45, 60, 90, 120, 180, 240]
        return steps.last { Double($0) <= perDay } ?? 15
    }

    @ViewBuilder private var focusToggle: some View {
        switch entity {
        case let .app(id):
            Toggle("Block in focus", isOn: Binding(
                get: { model.prefs.focusBlockedApps.contains(id) },
                set: { on in
                    if on { model.prefs.focusBlockedApps.append(id) } else { model.prefs.focusBlockedApps.removeAll { $0 == id } }
                }
            ))
            .toggleStyle(.checkbox)
        case let .site(site):
            Toggle("Block in focus", isOn: Binding(
                get: { model.prefs.focusBlockedSites.contains(site) },
                set: { on in
                    if on { model.prefs.focusBlockedSites.append(site) } else { model.prefs.focusBlockedSites.removeAll { $0 == site } }
                }
            ))
            .toggleStyle(.checkbox)
        case .category:
            EmptyView()
        }
    }

    // MARK: Tiles

    private var tiles: some View {
        let stats = data.stats
        let sessions = isSite ? (data.siteSessionStats[key] ?? SessionStats()) : (data.appSessionStats[key] ?? data.allSessions)
        return StatGrid(count: 8, minimumWidth: 160) {
            StatTile(title: "Total", symbol: "hourglass", value: DurationFormat.short(stats.total),
                     delta: DurationFormat.change(stats.total, data.previous.total), higherIsBetter: category.defaultRating == .productive ? true : category.defaultRating == .distracting ? false : nil)
            StatTile(title: "Per day", symbol: "calendar", value: DurationFormat.short(stats.averagePerDay),
                     footnote: "\(stats.activeDays) day\(stats.activeDays == 1 ? "" : "s") used")
            StatTile(title: "Share of screen time", symbol: "chart.pie", value: TimeText.percent(stats.total / max(allTotal, 1)),
                     footnote: "of \(DurationFormat.short(allTotal))")
            StatTile(title: isSite ? "Visits" : "Sessions", symbol: "square.stack.3d.up", value: "\(sessions.count)",
                     footnote: period.isMultiDay ? String(format: "%.1f a day", Double(sessions.count) / Double(max(stats.elapsedDays, 1))) : nil)
            StatTile(title: "Average session", symbol: "timer", value: DurationFormat.short(sessions.average),
                     footnote: "median \(DurationFormat.short(sessions.median))")
            StatTile(title: "Longest session", symbol: "flame", value: DurationFormat.short(sessions.longest))
            StatTile(title: "Peak hour", symbol: "clock", value: stats.peakHour.map { TimeText.hour($0) } ?? "—")
            StatTile(title: "Last used", symbol: "clock.arrow.circlepath",
                     value: sessions.lastEnd.map { TimeText.time($0) } ?? "—",
                     footnote: sessions.lastEnd.map { TimeText.day(Date(timeIntervalSince1970: $0)) })
        }
    }

    // MARK: Titles and sessions

    private var titlesCard: some View {
        Card(isSite ? "Pages" : "Windows & documents", subtitle: isSite ? "By page title" : "By window title") {
            if titles.isEmpty {
                EmptyState(symbol: "text.below.photo", title: "No titles recorded",
                           message: isSite || isBrowser ? nil : "Window titles need Accessibility access (Settings → Permissions).")
            } else {
                let peak = titles.first?.seconds ?? 1
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(titles.prefix(15)) { title in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(title.title.isEmpty ? title.page : title.title).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 8)
                                Text(DurationFormat.short(title.seconds)).monospacedDigit()
                            }
                            .font(.callout)
                            if isSite, !title.page.isEmpty, !title.title.isEmpty {
                                Text(title.page).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                            }
                            UsageBar(fraction: title.seconds / peak, color: Theme.color(category), height: 3)
                        }
                    }
                }
            }
        }
    }

    private var sessionsCard: some View {
        let sessions = isSite ? (data.siteSessionStats[key] ?? SessionStats()) : (data.appSessionStats[key] ?? SessionStats())
        return Card("Session lengths") {
            SimpleBarChart(items: SessionStats.bucketTitles.enumerated().map { index, title in
                SimpleBarChart.Item(id: "s\(index)", label: title, value: Double(sessions.histogram[index]),
                                    tooltip: "\(sessions.histogram[index])")
            }, color: Theme.color(category), height: 170)
        }
    }
}
