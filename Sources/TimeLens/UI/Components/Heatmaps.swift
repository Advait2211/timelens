import SwiftUI
import TimeLensCore

/// Weekday × hour of day: when you're on screen, averaged per weekday.
struct WeekHourHeatmap: View {
    let stats: UsageStats
    let calendar: Calendar
    @State private var hovered: (weekday: Int, hour: Int)?

    var body: some View {
        let order = (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 }
        let values = order.map { weekday in
            (0..<24).map { hour in stats.heatmap[weekday][hour] / Double(max(stats.weekdayCounts[weekday], 1)) }
        }
        let peak = values.flatMap { $0 }.max() ?? 0

        VStack(alignment: .leading, spacing: 8) {
            Grid(horizontalSpacing: 3, verticalSpacing: 3) {
                ForEach(Array(order.enumerated()), id: \.offset) { row, weekday in
                    GridRow {
                        Text(calendar.shortStandaloneWeekdaySymbols[weekday])
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: 30, alignment: .leading)
                        ForEach(0..<24, id: \.self) { hour in
                            let value = values[row][hour]
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(Theme.heat(peak > 0 ? value / peak : 0))
                                .frame(maxWidth: .infinity, minHeight: 16, maxHeight: 22)
                                .overlay {
                                    if hovered?.weekday == weekday && hovered?.hour == hour {
                                        RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Color.primary.opacity(0.6), lineWidth: 1.5)
                                    }
                                }
                                .onHover { inside in
                                    if inside { hovered = (weekday, hour) } else if hovered?.weekday == weekday && hovered?.hour == hour { hovered = nil }
                                }
                        }
                    }
                }
                GridRow {
                    Color.clear.frame(width: 30, height: 1)
                    ForEach(0..<24, id: \.self) { hour in
                        Text(hour % 6 == 0 ? TimeText.hour(hour) : "")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            HStack {
                if let hovered {
                    let value = stats.heatmap[hovered.weekday][hovered.hour] / Double(max(stats.weekdayCounts[hovered.weekday], 1))
                    Text("\(calendar.standaloneWeekdaySymbols[hovered.weekday]) \(TimeText.hour(hovered.hour)): ")
                        .foregroundStyle(.secondary)
                    + Text(DurationFormat.short(value)).fontWeight(.semibold)
                    + Text(stats.elapsedDays > 1 ? " on average" : "").foregroundStyle(.secondary)
                } else {
                    Text("Hover a cell for details").foregroundStyle(.tertiary)
                }
                Spacer()
                HeatLegend(peak: peak)
            }
            .font(.caption)
        }
    }
}

struct HeatLegend: View {
    let peak: Double

    var body: some View {
        HStack(spacing: 3) {
            Text("Less").foregroundStyle(.secondary)
            ForEach(Array(Theme.heatSteps.enumerated()), id: \.offset) { _, color in
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            }
            Text("More").foregroundStyle(.secondary)
            if peak > 0 { Text("(max \(DurationFormat.short(peak)))").foregroundStyle(.tertiary) }
        }
        .font(.caption2)
    }
}

/// A GitHub-style calendar of daily screen time.
struct CalendarHeatmap: View {
    let days: [DayTotal]
    let calendar: Calendar
    var goal: Double?
    var onSelect: ((Date) -> Void)?
    @State private var hovered: DayTotal?

    var body: some View {
        let columns = weeks
        let peak = days.map(\.total).max() ?? 0
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .top, spacing: 3) {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(0..<7, id: \.self) { row in
                                let weekday = (calendar.firstWeekday - 1 + row) % 7
                                Text(row % 2 == 0 ? calendar.veryShortStandaloneWeekdaySymbols[weekday] : "")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 12, height: 12)
                            }
                        }
                        ForEach(Array(columns.enumerated()), id: \.offset) { _, week in
                            VStack(spacing: 3) {
                                ForEach(0..<7, id: \.self) { row in
                                    if let day = week[row] {
                                        cell(day, peak: peak)
                                    } else {
                                        Color.clear.frame(width: 12, height: 12)
                                    }
                                }
                            }
                        }
                    }
                    HStack(spacing: 3) {
                        Color.clear.frame(width: 12, height: 1)
                        ForEach(Array(columns.enumerated()), id: \.offset) { index, week in
                            Text(monthLabel(week, index: index, columns: columns))
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .fixedSize()
                                .frame(width: 12, alignment: .leading)
                        }
                    }
                }
                .padding(.trailing, 20)
            }
            HStack {
                if let hovered {
                    Text(hovered.day.formatted(.dateTime.weekday(.wide).day().month(.wide).year()) + ": ").foregroundStyle(.secondary)
                    + Text(DurationFormat.short(hovered.total)).fontWeight(.semibold)
                } else {
                    Text("\(days.filter { $0.total >= 60 }.count) active days").foregroundStyle(.secondary)
                }
                Spacer()
                HeatLegend(peak: peak)
            }
            .font(.caption)
        }
    }

    private func cell(_ day: DayTotal, peak: Double) -> some View {
        let isFuture = day.day > Date()
        return RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .fill(isFuture ? Color.clear : Theme.heat(peak > 0 ? day.total / peak : 0))
            .overlay {
                if hovered == day {
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous).strokeBorder(Color.primary.opacity(0.7), lineWidth: 1.5)
                } else if let goal, day.total > goal, !isFuture {
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous).strokeBorder(Theme.critical.opacity(0.0), lineWidth: 0)
                }
            }
            .frame(width: 12, height: 12)
            .onHover { inside in
                if inside { hovered = day } else if hovered == day { hovered = nil }
            }
            .onTapGesture { onSelect?(day.day) }
    }

    /// Days arranged into week columns, each with 7 slots in display order.
    private var weeks: [[DayTotal?]] {
        guard let first = days.first else { return [] }
        var columns: [[DayTotal?]] = []
        var column = [DayTotal?](repeating: nil, count: 7)
        let startRow = (calendar.component(.weekday, from: first.day) - calendar.firstWeekday + 7) % 7
        var row = startRow
        for day in days {
            column[row] = day
            row += 1
            if row == 7 {
                columns.append(column)
                column = [DayTotal?](repeating: nil, count: 7)
                row = 0
            }
        }
        if row != 0 { columns.append(column) }
        return columns
    }

    private func monthLabel(_ week: [DayTotal?], index: Int, columns: [[DayTotal?]]) -> String {
        guard let first = week.compactMap({ $0 }).first else { return "" }
        let month = calendar.component(.month, from: first.day)
        if index == 0 { return first.day.formatted(.dateTime.month(.abbreviated)) }
        guard let previous = columns[index - 1].compactMap({ $0 }).first else { return "" }
        return calendar.component(.month, from: previous.day) != month ? first.day.formatted(.dateTime.month(.abbreviated)) : ""
    }
}
