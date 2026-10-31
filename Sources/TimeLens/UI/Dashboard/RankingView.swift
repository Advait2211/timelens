import SwiftUI
import TimeLensCore

enum RankingKind {
    case apps, websites
}

/// Every app (or website) in a period, in a sortable table: time, share, daily average,
/// sessions, average and longest session, change vs the period before, and a trend line.
struct RankingView: View {
    private var model: AppModel { .shared }
    let kind: RankingKind
    @Binding var path: [Route]
    @State private var period = Period(kind: .week)
    @State private var data = PeriodData(interval: DateInterval(start: .now, duration: 86_400))
    @State private var browsers: [Ranked] = []
    @State private var browser: String?
    @State private var search = ""
    @State private var selection: String?
    @State private var sortOrder = [KeyPathComparator(\Row.seconds, order: .reverse)]

    struct Row: Identifiable {
        let id: String
        let name: String
        let category: UsageCategory
        let seconds: Double
        let share: Double
        let perDay: Double
        let sessions: Int
        let averageSession: Double
        let longestSession: Double
        let change: Double
        let hasChange: Bool
        let trend: [Double]
        let lastUsed: Double

        var isBrowser: Bool { BrowserReader.family(of: id) != nil }
        var categoryName: String { isBrowser ? "Browser" : category.title }
    }

    var body: some View {
        let calendar = model.prefs.calendar
        VStack(alignment: .leading, spacing: 12) {
            PeriodBar(period: $period)
            HStack(spacing: 10) {
                TextField(kind == .apps ? "Search apps" : "Search websites", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                if kind == .websites, !browsers.isEmpty {
                    Picker("Browser", selection: $browser) {
                        Text("All browsers").tag(String?.none)
                        ForEach(browsers) { item in
                            Text(model.appName(item.key)).tag(String?.some(item.key))
                        }
                    }
                    .fixedSize()
                }
                Spacer()
                Text("\(rows.count) \(kind == .apps ? "apps" : "sites") · \(DurationFormat.short(rows.reduce(0) { $0 + $1.seconds }))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            table
        }
        .padding(24)
        .navigationTitle(kind == .apps ? "Apps" : "Websites")
        .task(id: LoadKey(period: period, version: period.isCurrent(calendar) ? model.dataVersion / 12 : 0, categories: model.categoryVersion,
                          filter: browser.map { .app($0) } ?? .all)) {
            data = await model.loadPeriod(period, filter: browser.map { .app($0) } ?? .all)
            if kind == .websites, browser == nil {
                browsers = data.stats.apps.filter { BrowserReader.family(of: $0.key) != nil }
            }
        }
    }

    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn(kind == .apps ? "App" : "Website", value: \.name) { row in
                HStack(spacing: 8) {
                    EntityIcon(entity: kind == .apps ? .app(row.id) : .site(row.id), size: 20)
                    Text(row.name).lineLimit(1)
                }
            }
            .width(min: 180, ideal: 240)
            TableColumn("Category", value: \.categoryName) { row in
                HStack(spacing: 6) {
                    if row.isBrowser {
                        Image(systemName: "globe").font(.caption).foregroundStyle(.secondary)
                    } else {
                        SeriesKey(color: Theme.color(row.category))
                    }
                    Text(row.categoryName).foregroundStyle(.secondary)
                }
            }
            .width(min: 90, ideal: 130)
            TableColumn("Time", value: \.seconds) { row in
                Text(DurationFormat.short(row.seconds)).monospacedDigit().fontWeight(.medium)
            }
            .width(min: 60, ideal: 75)
            TableColumn("Share", value: \.share) { row in
                HStack(spacing: 6) {
                    UsageBar(fraction: row.share / max(rows.map(\.share).max() ?? 1, 0.0001), color: Theme.color(row.category), height: 4)
                        .frame(width: 44)
                    Text(TimeText.percent(row.share)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .width(min: 80, ideal: 95)
            TableColumn("Per day", value: \.perDay) { row in
                Text(DurationFormat.short(row.perDay)).monospacedDigit()
            }
            .width(min: 55, ideal: 70)
            TableColumn(kind == .apps ? "Sessions" : "Visits", value: \.sessions) { row in
                Text("\(row.sessions)").monospacedDigit()
            }
            .width(min: 50, ideal: 65)
            TableColumn("Avg session", value: \.averageSession) { row in
                Text(DurationFormat.short(row.averageSession)).monospacedDigit()
            }
            .width(min: 70, ideal: 85)
            TableColumn("Longest", value: \.longestSession) { row in
                Text(DurationFormat.short(row.longestSession)).monospacedDigit()
            }
            .width(min: 55, ideal: 70)
            TableColumn("Change", value: \.change) { row in
                if row.hasChange {
                    DeltaBadge(change: row.change)
                } else {
                    Text("new").font(.caption).foregroundStyle(.secondary)
                }
            }
            .width(min: 55, ideal: 65)
            TableColumn("Trend") { row in
                if row.trend.count > 1 {
                    Sparkline(values: row.trend, color: Theme.color(row.category)).frame(height: 18)
                }
            }
            .width(min: 60, ideal: 90)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first {
                Button("Open") { path.append(kind == .apps ? .app(id) : .site(id)) }
            }
        } primaryAction: { ids in
            if let id = ids.first { path.append(kind == .apps ? .app(id) : .site(id)) }
        }
    }

    private var rows: [Row] {
        let stats = data.stats
        let previous = kind == .apps
            ? Dictionary(data.previous.apps.map { ($0.key, $0.seconds) }, uniquingKeysWith: +)
            : Dictionary(data.previous.sites.map { ($0.key, $0.seconds) }, uniquingKeysWith: +)
        let ranked = kind == .apps ? stats.apps : stats.sites
        let sessions = kind == .apps ? data.appSessionStats : data.siteSessionStats
        let days = Double(max(stats.elapsedDays, 1))
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        let result: [Row] = ranked.compactMap { item in
            let name = kind == .apps ? model.appName(item.key) : model.siteName(item.key)
            if !needle.isEmpty, !name.lowercased().contains(needle), !item.key.lowercased().contains(needle) { return nil }
            let session = sessions[item.key] ?? SessionStats()
            let before = previous[item.key] ?? 0
            let change = DurationFormat.change(item.seconds, before)
            return Row(
                id: item.key,
                name: name,
                category: kind == .apps ? model.categorizer.appCategory(item.key) : model.categorizer.siteCategory(item.key),
                seconds: item.seconds,
                share: item.share,
                perDay: item.seconds / days,
                sessions: session.count,
                averageSession: session.average,
                longestSession: session.longest,
                change: change ?? 0,
                hasChange: change != nil,
                trend: stats.days.count > 1 ? (kind == .apps ? stats.dailySeries(app: item.key) : stats.dailySeries(site: item.key)) : [],
                lastUsed: session.lastEnd ?? 0
            )
        }
        return result.sorted(using: sortOrder)
    }
}
