import Charts
import SwiftUI
import TimeLensCore

/// One part of a stacked bar.
struct BarPart: Identifiable, Hashable {
    let key: String
    let name: String
    let color: Color
    let seconds: Double
    var id: String { key }
}

/// One bar: an hour, day, weekday or month.
struct BarDatum: Identifiable, Hashable {
    let id: String
    /// Axis label ("Mon", "9", "Oct").
    let label: String
    /// Tooltip heading ("Monday 19 October").
    let title: String
    let parts: [BarPart]
    /// Drawn more faintly: future buckets, or ones outside the focus.
    var dimmed = false

    var total: Double { parts.reduce(0) { $0 + $1.seconds } }
}

/// Finds the bar under the pointer on a categorical x axis. `ChartProxy.value(atX:)` traps
/// on some layouts (an empty or changing domain), so the band is worked out from the plot
/// frame instead: n ids split the plot width evenly.
enum BandHit {
    static func id(at location: CGPoint, in ids: [String], proxy: ChartProxy, geometry: GeometryProxy) -> String? {
        guard !ids.isEmpty, let anchor = proxy.plotFrame else { return nil }
        let plot = geometry[anchor]
        guard plot.width > 0, plot.minX...plot.maxX ~= location.x else { return nil }
        let index = Int((location.x - plot.minX) / plot.width * CGFloat(ids.count))
        return ids[min(max(index, 0), ids.count - 1)]
    }
}

/// Stacked duration bars with an optional average and goal line, and a hover tooltip.
struct DurationBarChart: View {
    let bars: [BarDatum]
    var average: Double?
    var averageLabel = "avg"
    var goal: Double?
    /// Show every nth axis label.
    var labelStride = 1
    var height: CGFloat = 220
    var highlightID: String?
    var onSelect: ((BarDatum) -> Void)?

    @State private var hovered: String?

    private var ticks: DurationTicks {
        DurationTicks(max: max(bars.map(\.total).max() ?? 0, average ?? 0, goal ?? 0) * 1.05)
    }

    var body: some View {
        let ticks = ticks
        // A 2 pt surface gap between stacked fills, in data units.
        let gap = ticks.top * 2 / Double(max(height - 30, 1))
        Chart {
            ForEach(bars) { bar in
                let stack = stacked(bar, gap: gap)
                ForEach(stack, id: \.part.key) { piece in
                    BarMark(
                        x: .value("Bucket", bar.id),
                        yStart: .value("Start", piece.start),
                        yEnd: .value("End", piece.end),
                        width: .ratio(0.72)
                    )
                    .foregroundStyle(piece.part.color)
                    .opacity(opacity(for: bar))
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: piece.isTop ? 3 : 0, topTrailingRadius: piece.isTop ? 3 : 0, style: .continuous))
                }
            }
            if let average, average > 0 {
                RuleMark(y: .value("Average", average))
                    .foregroundStyle(Theme.muted)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .annotation(position: .top, alignment: .trailing, spacing: 2) {
                        Text("\(averageLabel) \(DurationFormat.short(average))")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .background(Theme.cardBackground.opacity(0.85), in: Capsule())
                    }
            }
            if let goal, goal > 0 {
                RuleMark(y: .value("Goal", goal))
                    .foregroundStyle(Theme.good)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .annotation(position: .top, alignment: .leading, spacing: 2) {
                        Label("goal \(DurationFormat.short(goal))", systemImage: "flag.fill")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
            }
            if let hovered, let bar = bars.first(where: { $0.id == hovered }) {
                RuleMark(x: .value("Bucket", bar.id))
                    .foregroundStyle(Color.primary.opacity(0.06))
                    .lineStyle(StrokeStyle(lineWidth: 26))
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        BarTooltip(bar: bar)
                    }
            }
        }
        .chartXScale(domain: bars.map(\.id))
        .chartYScale(domain: 0...ticks.top)
        .chartXAxis {
            AxisMarks(values: axisValues) { value in
                AxisValueLabel {
                    if let id = value.as(String.self), let bar = bars.first(where: { $0.id == id }) {
                        Text(bar.label)
                            .font(.caption2)
                            .fontWeight(bar.id == highlightID ? .bold : .regular)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: ticks.values) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Theme.gridline)
                AxisValueLabel {
                    if let seconds = value.as(Double.self) { Text(DurationFormat.axis(seconds)).font(.caption2) }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case let .active(location):
                            hovered = BandHit.id(at: location, in: bars.map(\.id), proxy: proxy, geometry: geometry)
                        case .ended:
                            hovered = nil
                        }
                    }
                    .onTapGesture { location in
                        guard let onSelect else { return }
                        if let id = BandHit.id(at: location, in: bars.map(\.id), proxy: proxy, geometry: geometry),
                           let bar = bars.first(where: { $0.id == id }) {
                            onSelect(bar)
                        }
                    }
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel(accessibilitySummary)
    }

    private var axisValues: [String] {
        let stride = max(labelStride, 1)
        return bars.enumerated().filter { $0.offset % stride == 0 }.map(\.element.id)
    }

    private func opacity(for bar: BarDatum) -> Double {
        if bar.dimmed { return 0.35 }
        if let hovered, hovered != bar.id { return 0.55 }
        return 1
    }

    private struct Piece {
        let part: BarPart
        let start: Double
        let end: Double
        let isTop: Bool
    }

    private func stacked(_ bar: BarDatum, gap: Double) -> [Piece] {
        let parts = bar.parts.filter { $0.seconds > 0 }
        var pieces: [Piece] = []
        var cursor = 0.0
        for (index, part) in parts.enumerated() {
            let start = cursor + (index > 0 ? gap / 2 : 0)
            let end = cursor + part.seconds - (index < parts.count - 1 ? gap / 2 : 0)
            pieces.append(Piece(part: part, start: start, end: max(end, start), isTop: index == parts.count - 1))
            cursor += part.seconds
        }
        return pieces
    }

    private var accessibilitySummary: String {
        let peak = bars.max { $0.total < $1.total }
        return "Bar chart of \(bars.count) bars. Highest: \(peak?.title ?? "none"), \(DurationFormat.short(peak?.total ?? 0))."
    }
}

struct BarTooltip: View {
    let bar: BarDatum

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(bar.title).font(.caption.weight(.semibold))
            Text(DurationFormat.short(bar.total)).font(.callout.weight(.semibold)).monospacedDigit()
            let parts = bar.parts.filter { $0.seconds >= 30 }.sorted { $0.seconds > $1.seconds }
            ForEach(parts.prefix(6)) { part in
                HStack(spacing: 6) {
                    SeriesKey(color: part.color)
                    Text(part.name).font(.caption).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(DurationFormat.short(part.seconds)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if parts.count > 6 {
                Text("+ \(parts.count - 6) more").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(minWidth: 150, maxWidth: 230, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.cardBorder))
    }
}

// MARK: Building bars

enum BarBuilder {
    /// Parts by category, in palette order so stacks always read the same way.
    static func categoryParts(_ byCategory: [UsageCategory: Double]) -> [BarPart] {
        UsageCategory.allCases.compactMap { category in
            guard let seconds = byCategory[category], seconds > 0 else { return nil }
            return BarPart(key: category.rawValue, name: category.title, color: Theme.color(category), seconds: seconds)
        }
    }

    static func single(_ seconds: Double, name: String = "Screen time", color: Color = Theme.accent) -> [BarPart] {
        [BarPart(key: "total", name: name, color: color, seconds: seconds)]
    }

    /// 24 hourly bars. With `perDay`, each is the average over that many days.
    static func hours(_ stats: UsageStats, perDay days: Int = 1, now: Date = .now, isToday: Bool = false, calendar: Calendar = .current) -> [BarDatum] {
        let currentHour = calendar.component(.hour, from: now)
        return (0..<24).map { hour in
            var byCategory = stats.hours[hour]
            if days > 1 { byCategory = byCategory.mapValues { $0 / Double(days) } }
            return BarDatum(
                id: "h\(hour)",
                label: hour % 3 == 0 ? TimeText.shortHour(hour) : "",
                title: "\(TimeText.hour(hour)) – \(TimeText.hour((hour + 1) % 24))\(days > 1 ? " · daily average" : "")",
                parts: categoryParts(byCategory),
                dimmed: isToday && hour > currentHour
            )
        }
    }

    static func days(_ days: [DayTotal], now: Date = .now, calendar: Calendar = .current) -> [BarDatum] {
        let today = calendar.startOfDay(for: now)
        let long = days.count > 14
        return days.map { day in
            let label = long
                ? day.day.formatted(.dateTime.day())
                : day.day.formatted(.dateTime.weekday(.abbreviated))
            return BarDatum(
                id: "d\(Int(day.day.timeIntervalSince1970))",
                label: label,
                title: day.day.formatted(.dateTime.weekday(.wide).day().month(.wide)),
                parts: categoryParts(day.byCategory),
                dimmed: day.day > today
            )
        }
    }

    static func months(_ months: [DayTotal], now: Date = .now, calendar: Calendar = .current) -> [BarDatum] {
        months.map { month in
            BarDatum(
                id: "m\(Int(month.day.timeIntervalSince1970))",
                label: month.day.formatted(.dateTime.month(.abbreviated)),
                title: month.day.formatted(.dateTime.month(.wide).year()),
                parts: categoryParts(month.byCategory),
                dimmed: month.day > now
            )
        }
    }

    /// Mon–Sun (or Sun–Sat) average per day.
    static func weekdays(_ stats: UsageStats, calendar: Calendar, color: Color? = nil) -> [BarDatum] {
        (0..<7).map { offset in
            let weekday = (calendar.firstWeekday - 1 + offset) % 7
            let average = stats.weekdayAverage(weekday)
            let weekend = weekday == 0 || weekday == 6
            return BarDatum(
                id: "w\(weekday)",
                label: calendar.shortStandaloneWeekdaySymbols[weekday],
                title: "\(calendar.standaloneWeekdaySymbols[weekday]) · average over \(stats.weekdayCounts[weekday]) day\(stats.weekdayCounts[weekday] == 1 ? "" : "s")",
                parts: single(average, name: "Average", color: color ?? (weekend ? Theme.series[1] : Theme.series[0]))
            )
        }
    }
}

// MARK: Donut

struct DonutSlice: Identifiable, Hashable {
    let key: String
    let name: String
    let color: Color
    let seconds: Double
    var id: String { key }
}

struct DonutChart: View {
    let slices: [DonutSlice]
    var centerTitle: String
    var centerValue: String
    var size: CGFloat = 170
    @Binding var hovered: String?

    var body: some View {
        Chart(slices) { slice in
            SectorMark(
                angle: .value("Time", slice.seconds),
                innerRadius: .ratio(0.64),
                outerRadius: .ratio(hovered == slice.key ? 1 : 0.94),
                angularInset: 1.5
            )
            .cornerRadius(3)
            .foregroundStyle(slice.color)
            .opacity(hovered == nil || hovered == slice.key ? 1 : 0.4)
        }
        .chartLegend(.hidden)
        .chartBackground { _ in
            VStack(spacing: 2) {
                if let hovered, let slice = slices.first(where: { $0.key == hovered }) {
                    Text(slice.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Text(DurationFormat.short(slice.seconds)).font(.title3.weight(.semibold)).monospacedDigit()
                } else {
                    Text(centerTitle).font(.caption).foregroundStyle(.secondary)
                    Text(centerValue).font(.title3.weight(.semibold)).monospacedDigit()
                }
            }
            .frame(width: size * 0.56)
        }
        .frame(width: size, height: size)
    }
}

/// Category donut with a legend list beside it.
struct CategoryBreakdown: View {
    let stats: UsageStats
    var onSelect: ((UsageCategory) -> Void)?
    @State private var hovered: String?

    var body: some View {
        let slices = stats.categories.compactMap { ranked -> DonutSlice? in
            guard let category = UsageCategory(rawValue: ranked.key) else { return nil }
            return DonutSlice(key: ranked.key, name: category.title, color: Theme.color(category), seconds: ranked.seconds)
        }
        if slices.isEmpty {
            EmptyState(symbol: "chart.pie", title: "Nothing yet")
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 20) {
                    DonutChart(slices: slices, centerTitle: "Total", centerValue: DurationFormat.short(stats.total), hovered: $hovered)
                    legend(slices).fixedSize()
                }
                VStack(spacing: 16) {
                    DonutChart(slices: slices, centerTitle: "Total", centerValue: DurationFormat.short(stats.total), hovered: $hovered)
                    legend(slices)
                }
            }
        }
    }
}

extension CategoryBreakdown {
    fileprivate func legend(_ slices: [DonutSlice]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(slices) { slice in
                Button {
                    if let category = UsageCategory(rawValue: slice.key) { onSelect?(category) }
                } label: {
                    HStack(spacing: 8) {
                        SeriesKey(color: slice.color)
                        Text(slice.name).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(DurationFormat.short(slice.seconds)).monospacedDigit()
                        Text(TimeText.percent(slice.seconds / max(stats.total, 1)))
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .trailing)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside { hovered = slice.key } else if hovered == slice.key { hovered = nil }
                }
            }
        }
        .font(.callout)
    }
}

// MARK: Small charts

struct Sparkline: View {
    let values: [Double]
    var color: Color = Theme.accent

    var body: some View {
        Chart {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                AreaMark(x: .value("i", index), y: .value("v", value))
                    .foregroundStyle(color.opacity(0.15))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("i", index), y: .value("v", value))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.monotone)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartYScale(domain: 0...max(values.max() ?? 1, 1))
        .accessibilityHidden(true)
    }
}

/// Plain bars for small histograms (session lengths, pickups by hour).
struct SimpleBarChart: View {
    struct Item: Identifiable, Hashable {
        let id: String
        let label: String
        let value: Double
        let tooltip: String
    }

    let items: [Item]
    var color: Color = Theme.accent
    var height: CGFloat = 150
    var labelStride = 1
    @State private var hovered: String?

    var body: some View {
        Chart(items) { item in
            BarMark(x: .value("Bucket", item.id), y: .value("Value", item.value), width: .ratio(0.7))
                .foregroundStyle(color)
                .opacity(hovered == nil || hovered == item.id ? 1 : 0.5)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3, style: .continuous))
                .annotation(position: .top, spacing: 2) {
                    if hovered == item.id {
                        Text(item.tooltip)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.regularMaterial, in: Capsule())
                    }
                }
        }
        .chartXScale(domain: items.map(\.id))
        .chartXAxis {
            AxisMarks(values: items.enumerated().filter { $0.offset % max(labelStride, 1) == 0 }.map(\.element.id)) { value in
                AxisValueLabel {
                    if let id = value.as(String.self), let item = items.first(where: { $0.id == id }) {
                        Text(item.label).font(.caption2)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Theme.gridline)
                AxisValueLabel().font(.caption2)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case let .active(location):
                            hovered = BandHit.id(at: location, in: items.map(\.id), proxy: proxy, geometry: geometry)
                        case .ended:
                            hovered = nil
                        }
                    }
            }
        }
        .frame(height: height)
    }
}

/// Tiny hourly bars for the menu bar popover.
struct MiniHourBars: View {
    let hours: [Double]
    var currentHour: Int?

    var body: some View {
        let peak = max(hours.max() ?? 0, 60)
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<hours.count, id: \.self) { hour in
                UnevenRoundedRectangle(topLeadingRadius: 1.5, topTrailingRadius: 1.5)
                    .fill(hour == currentHour ? Theme.accent : Theme.accent.opacity(0.55))
                    .frame(height: max(CGFloat(hours[hour] / peak) * 38, hours[hour] > 0 ? 2 : 1))
                    .opacity(hours[hour] > 0 ? 1 : 0.25)
                    .help("\(TimeText.hour(hour)): \(DurationFormat.short(hours[hour]))")
            }
        }
        .frame(height: 38, alignment: .bottom)
    }
}
