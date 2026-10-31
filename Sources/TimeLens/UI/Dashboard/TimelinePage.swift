import SwiftUI
import TimeLensCore

/// The day in exact order: a ribbon of every stretch, a lane per app, and a log down to the
/// window title, with the gaps where you were away.
struct TimelinePage: View {
    private var model: AppModel { .shared }
    @State private var period = Period.today
    @State private var data = PeriodData(interval: DateInterval(start: .now, duration: 86_400))
    @State private var details: [DetailSegment] = []
    @AppStorage("timelineZoom") private var zoom = "active"
    @AppStorage("timelineMinimum") private var minimumSeconds = 30.0

    var body: some View {
        let calendar = model.prefs.calendar
        Page(title: "Timeline") {
            PeriodBar(period: $period, kinds: [.day])
        } content: {
            Card("The day", subtitle: "Colored by category; gaps are idle, locked or away", accessory: {
                CardPicker(selection: $zoom, options: [("active", "Active hours"), ("day", "24 hours"), ("morning", "Morning"), ("afternoon", "Afternoon"), ("evening", "Evening")])
            }) {
                if data.segments.isEmpty {
                    EmptyState(symbol: "calendar.day.timeline.left", title: "Nothing recorded this day")
                } else {
                    TimelineRibbon(blocks: RibbonData.blocks(data, model: model), window: window(calendar), height: 54,
                                   now: period.isCurrent(calendar) ? Date().timeIntervalSince1970 : nil)
                    CategoryLegend(categories: UsageCategory.allCases.filter { data.stats.categories.map(\.key).contains($0.rawValue) })
                }
            }
            if !data.segments.isEmpty {
                Card("By app", subtitle: "When each of your most-used apps was in front") {
                    lanes(calendar)
                }
                Card("Log", subtitle: "\(logEntries.filter { !$0.isGap }.count) stretches", accessory: {
                    Picker("Shortest", selection: $minimumSeconds) {
                        Text("Everything").tag(0.0)
                        Text("30 s or longer").tag(30.0)
                        Text("2 min or longer").tag(120.0)
                        Text("10 min or longer").tag(600.0)
                    }
                    .labelsHidden()
                    .fixedSize()
                    .controlSize(.small)
                }) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(logEntries) { entry in
                            if entry.isGap {
                                GapRow(entry: entry)
                            } else {
                                LogRow(entry: entry)
                                Divider().opacity(0.4)
                            }
                        }
                    }
                }
            }
        }
        .task(id: LoadKey(period: period, version: period.isCurrent(calendar) ? model.dataVersion / 3 : 0, categories: model.categoryVersion)) {
            data = await model.loadPeriod(period)
            details = await model.store?.details(period.interval(calendar)) ?? []
        }
    }

    private func window(_ calendar: Calendar) -> ClosedRange<Double> {
        let start = data.interval.start
        func at(_ hour: Int) -> Double { calendar.date(byAdding: .hour, value: hour, to: start)!.timeIntervalSince1970 }
        switch zoom {
        case "day": return at(0)...at(24)
        case "morning": return at(5)...at(12)
        case "afternoon": return at(12)...at(18)
        case "evening": return at(18)...at(24)
        default: return RibbonData.activeWindow(data, calendar: calendar)
        }
    }

    // MARK: Lanes

    private func lanes(_ calendar: Calendar) -> some View {
        let top = data.stats.apps.prefix(8)
        let window = window(calendar)
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(top) { app in
                HStack(spacing: 10) {
                    AppIconView(app: app.key, size: 18)
                    Text(model.appName(app.key)).font(.callout).lineLimit(1).frame(width: 140, alignment: .leading)
                    LaneStrip(sessions: data.appSessions.filter { $0.key == app.key }, window: window,
                              color: Theme.color(model.categorizer.appCategory(app.key)))
                        .frame(height: 14)
                    Text(DurationFormat.short(app.seconds)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .trailing)
                }
            }
        }
    }

    // MARK: Log

    struct Entry: Identifiable {
        let id: Int
        let start: Double
        let end: Double
        let app: String
        let site: String
        let title: String?
        let isGap: Bool
        var duration: Double { end - start }
    }

    private var logEntries: [Entry] {
        let runs = Sessions.merge(data.segments, gap: 5) { "\($0.app)\u{1}\($0.site)" }
        var entries: [Entry] = []
        var previousEnd: Double?
        for (index, run) in runs.enumerated() {
            if let previousEnd, run.start - previousEnd >= 120 {
                entries.append(Entry(id: -index - 1, start: previousEnd, end: run.start, app: "", site: "", title: nil, isGap: true))
            }
            previousEnd = max(previousEnd ?? 0, run.end)
            guard run.duration >= minimumSeconds else { continue }
            let parts = run.key.split(separator: "\u{1}", omittingEmptySubsequences: false).map(String.init)
            entries.append(Entry(id: index, start: run.start, end: run.end, app: parts.first ?? "", site: parts.count > 1 ? parts[1] : "",
                                 title: dominantTitle(app: parts.first ?? "", start: run.start, end: run.end), isGap: false))
        }
        return entries.reversed()
    }

    /// The title with the most time inside a run.
    private func dominantTitle(app: String, start: Double, end: Double) -> String? {
        var totals: [String: Double] = [:]
        for detail in details where detail.app == app && detail.end > start && detail.start < end && !detail.title.isEmpty {
            totals[detail.title, default: 0] += min(detail.end, end) - max(detail.start, start)
        }
        return totals.max { $0.value < $1.value }?.key
    }
}

private struct LogRow: View {
    private var model: AppModel { .shared }
    let entry: TimelinePage.Entry

    var body: some View {
        let category = model.category(app: entry.app, site: entry.site)
        HStack(spacing: 10) {
            Text(TimeText.range(entry.start, entry.end))
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)
            Capsule().fill(Theme.color(category)).frame(width: 4, height: 26)
            if entry.site.isEmpty {
                AppIconView(app: entry.app, size: 22)
            } else {
                SiteIconView(site: entry.site, size: 22)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.site.isEmpty ? model.appName(entry.app) : "\(model.siteName(entry.site))")
                    .font(.callout.weight(.medium)).lineLimit(1)
                Text(entry.title ?? (entry.site.isEmpty ? category.title : model.appName(entry.app)))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 10)
            Text(DurationFormat.short(entry.duration)).font(.callout).monospacedDigit()
        }
        .padding(.vertical, 6)
    }
}

private struct GapRow: View {
    let entry: TimelinePage.Entry

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "moon.zzz").font(.caption).foregroundStyle(.tertiary)
            Text("Away \(DurationFormat.short(entry.duration))").font(.caption).foregroundStyle(.secondary)
            Text(TimeText.range(entry.start, entry.end)).font(.caption).foregroundStyle(.tertiary)
            Rectangle().fill(Theme.track).frame(height: 1)
        }
        .padding(.vertical, 6)
    }
}

/// A thin strip with marks wherever an app was in front.
private struct LaneStrip: View {
    let sessions: [Session]
    let window: ClosedRange<Double>
    let color: Color

    var body: some View {
        Canvas { context, size in
            let span = max(window.upperBound - window.lowerBound, 1)
            context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 3), with: .color(Theme.track))
            for session in sessions where session.end > window.lowerBound && session.start < window.upperBound {
                let x0 = CGFloat((max(session.start, window.lowerBound) - window.lowerBound) / span) * size.width
                let x1 = CGFloat((min(session.end, window.upperBound) - window.lowerBound) / span) * size.width
                context.fill(Path(CGRect(x: x0, y: 0, width: max(x1 - x0, 1), height: size.height)), with: .color(color))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
    }
}
