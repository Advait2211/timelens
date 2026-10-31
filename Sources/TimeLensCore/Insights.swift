import Foundation

/// Duration text used across the app.
public enum DurationFormat {
    /// "2h 13m", "45m", "38s". Whole minutes past the first minute; never "0h".
    public static func short(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0).rounded())
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }

    /// "2h 13m" but with seconds below 10 minutes: "4m 12s". For live counters.
    public static func precise(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0))
        if total < 60 { return "\(total)s" }
        if total < 600 { return "\(total / 60)m \(total % 60)s" }
        return short(Double(total))
    }

    /// "1:02:03" or "12:05" — countdowns.
    public static func clock(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0).rounded(.up))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }

    /// Axis ticks: "0", "30m", "2h", "1.5h".
    public static func axis(_ seconds: Double) -> String {
        guard seconds > 0 else { return "0" }
        if seconds < 3600 { return "\(Int((seconds / 60).rounded()))m" }
        let minutes = Int((seconds / 60).rounded())
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        if minutes % 30 == 0 { return String(format: "%.1fh", Double(minutes) / 60) }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    /// Relative change, or nil when there's nothing to compare against.
    public static func change(_ current: Double, _ previous: Double) -> Double? {
        guard previous >= 60 else { return nil }
        return (current - previous) / previous
    }

    /// "12% more than last week", "About the same as yesterday".
    public static func comparison(_ current: Double, _ previous: Double, period: String) -> String? {
        guard let change = change(current, previous) else { return nil }
        let percent = change * 100
        if abs(percent) < 2 { return "About the same as \(period)" }
        if percent >= 900 { return String(format: "%.0f× %@", current / previous, period) }
        return String(format: "%.0f%% %@ than %@", abs(percent), percent > 0 ? "more" : "less", period)
    }
}

/// "Nice" ticks for a duration axis: 0, 30m, 1h, ... with a clean top.
public struct DurationTicks: Sendable {
    public let values: [Double]
    public var top: Double { values.last ?? 3600 }

    public init(max maximum: Double, count: Int = 4) {
        let candidates: [Double] = [60, 120, 300, 600, 900, 1200, 1800, 3600, 7200, 10800, 14400, 21600, 28800, 43200, 86400, 172_800, 360_000, 720_000, 1_440_000, 3_600_000]
        let maximum = Swift.max(maximum, 60)
        let rough = maximum / Double(count)
        let step = candidates.first { $0 >= rough } ?? rough.rounded(.up)
        let steps = Int((maximum / step).rounded(.up))
        values = (0...Swift.max(steps, 1)).map { Double($0) * step }
    }
}

/// A plain-English observation about the period.
public struct Insight: Identifiable, Hashable, Sendable {
    public enum Tone: Sendable { case neutral, good, bad }

    public let id: String
    public let symbol: String
    public let title: String
    public let detail: String
    public let tone: Tone

    public init(id: String, symbol: String, title: String, detail: String, tone: Tone = .neutral) {
        self.id = id
        self.symbol = symbol
        self.title = title
        self.detail = detail
        self.tone = tone
    }
}

public enum InsightEngine {
    public static func insights(
        current: UsageStats,
        previous: UsageStats?,
        periodName: String,
        previousName: String,
        appName: (String) -> String,
        siteName: (String) -> String = SiteKey.displayName,
        longestSession: Session? = nil,
        calendar: Calendar = .current
    ) -> [Insight] {
        var result: [Insight] = []
        guard current.total >= 60 else { return result }

        // Total vs the period before.
        if let previous, let change = DurationFormat.change(current.total, previous.total), abs(change) >= 0.02 {
            let up = change > 0
            result.append(Insight(
                id: "total",
                symbol: up ? "arrow.up.right" : "arrow.down.right",
                title: "Screen time \(up ? "up" : "down") \(Int((abs(change) * 100).rounded()))%",
                detail: "\(DurationFormat.short(current.total)) \(periodName) vs \(DurationFormat.short(previous.total)) \(previousName).",
                tone: up ? .bad : .good
            ))
        }

        // The biggest movers among apps and sites.
        if let previous {
            var movers: [(name: String, now: Double, before: Double)] = []
            let before = Dictionary(previous.apps.map { ($0.key, $0.seconds) }, uniquingKeysWith: +)
            for app in current.apps.prefix(25) {
                movers.append((appName(app.key), app.seconds, before[app.key] ?? 0))
            }
            let beforeSites = Dictionary(previous.sites.map { ($0.key, $0.seconds) }, uniquingKeysWith: +)
            for site in current.sites.prefix(25) where !SiteKey.isPseudo(site.key) {
                movers.append((siteName(site.key), site.seconds, beforeSites[site.key] ?? 0))
            }
            let rising = movers.filter { $0.now - $0.before >= 600 && $0.before >= 300 && ($0.now - $0.before) / $0.before >= 0.25 }
                .max { ($0.now - $0.before) < ($1.now - $1.before) }
            if let rising {
                let percent = Int(((rising.now - rising.before) / rising.before * 100).rounded())
                result.append(Insight(
                    id: "rising",
                    symbol: "chart.line.uptrend.xyaxis",
                    title: "\(rising.name) up \(percent)%",
                    detail: "+\(DurationFormat.short(rising.now - rising.before)) compared with \(previousName).",
                    tone: .neutral
                ))
            }
            // Falling: compare everything that was big before.
            var fallers: [(name: String, now: Double, before: Double)] = []
            let nowApps = Dictionary(current.apps.map { ($0.key, $0.seconds) }, uniquingKeysWith: +)
            for app in previous.apps.prefix(25) {
                fallers.append((appName(app.key), nowApps[app.key] ?? 0, app.seconds))
            }
            let falling = fallers.filter { $0.before - $0.now >= 600 && ($0.before - $0.now) / $0.before >= 0.25 }
                .max { ($0.before - $0.now) < ($1.before - $1.now) }
            if let falling {
                let percent = Int(((falling.before - falling.now) / falling.before * 100).rounded())
                result.append(Insight(
                    id: "falling",
                    symbol: "chart.line.downtrend.xyaxis",
                    title: "\(falling.name) down \(percent)%",
                    detail: "−\(DurationFormat.short(falling.before - falling.now)) compared with \(previousName).",
                    tone: .neutral
                ))
            }
        }

        // Peak hour.
        if let peak = current.peakHour {
            let hourTotal = current.hourTotal(peak)
            let perDay = hourTotal / Double(max(current.elapsedDays, 1))
            result.append(Insight(
                id: "peak",
                symbol: "clock.fill",
                title: "Busiest hour: \(hourLabel(peak, calendar: calendar))",
                detail: current.elapsedDays > 1
                    ? "On average \(DurationFormat.short(perDay)) of that hour is on screen."
                    : "\(DurationFormat.short(hourTotal)) between \(hourLabel(peak, calendar: calendar)) and \(hourLabel((peak + 1) % 24, calendar: calendar)).",
                tone: .neutral
            ))
        }

        // Late nights.
        let lateNight = (0..<5).reduce(0) { $0 + current.hourTotal($1) }
        if lateNight >= 900 {
            result.append(Insight(
                id: "late",
                symbol: "moon.stars.fill",
                title: "\(DurationFormat.short(lateNight)) after midnight",
                detail: "Time on screen between 12 AM and 5 AM \(periodName).",
                tone: .bad
            ))
        }

        // Productive share.
        if let score = current.productivityScore {
            let productive = current.ratings[.productive] ?? 0
            let share = productive / max(current.total, 1)
            var detail = "Productivity score \(Int(score.rounded())) / 100."
            if let previousScore = previous?.productivityScore {
                let delta = Int((score - previousScore).rounded())
                if delta != 0 { detail += " \(delta > 0 ? "Up" : "Down") \(abs(delta)) from \(previousName)." }
            }
            result.append(Insight(
                id: "productive",
                symbol: "bolt.fill",
                title: "\(Int((share * 100).rounded()))% productive",
                detail: detail,
                tone: share >= 0.5 ? .good : .neutral
            ))
        }

        // Top category.
        if let top = current.categories.first, let category = Category(rawValue: top.key) {
            result.append(Insight(
                id: "category",
                symbol: category.symbol,
                title: "\(category.title) leads with \(Int((top.share * 100).rounded()))%",
                detail: "\(DurationFormat.short(top.seconds)) \(periodName).",
                tone: .neutral
            ))
        }

        // Weekday pattern and weekend vs weekdays.
        if current.elapsedDays >= 7 {
            let averages = (0..<7).map { current.weekdayAverage($0) }
            if let max = averages.max(), max > 0, let index = averages.firstIndex(of: max) {
                let name = calendar.standaloneWeekdaySymbols[index]
                result.append(Insight(
                    id: "weekday",
                    symbol: "calendar",
                    title: "\(name)s are your heaviest day",
                    detail: "\(DurationFormat.short(max)) on an average \(name).",
                    tone: .neutral
                ))
            }
            let weekend = [0, 6]
            let weekendDays = weekend.reduce(0) { $0 + current.weekdayCounts[$1] }
            let weekdayDays = (1...5).reduce(0) { $0 + current.weekdayCounts[$1] }
            if weekendDays > 0, weekdayDays > 0 {
                let weekendAverage = weekend.reduce(0) { $0 + current.weekdays[$1] } / Double(weekendDays)
                let weekdayAverage = (1...5).reduce(0) { $0 + current.weekdays[$1] } / Double(weekdayDays)
                result.append(Insight(
                    id: "weekend",
                    symbol: "sun.max.fill",
                    title: "Weekends: \(DurationFormat.short(weekendAverage)) a day",
                    detail: "Weekdays average \(DurationFormat.short(weekdayAverage)).",
                    tone: .neutral
                ))
            }
        }

        // Busiest day.
        if current.days.count > 1, let busiest = current.busiestDay {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.setLocalizedDateFormatFromTemplate("EEEE d MMM")
            result.append(Insight(
                id: "busiest",
                symbol: "flame.fill",
                title: "Most screen time: \(formatter.string(from: busiest.day))",
                detail: "\(DurationFormat.short(busiest.total)) that day.",
                tone: .neutral
            ))
        }

        if let longestSession, longestSession.duration >= 1200 {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeStyle = .short
            result.append(Insight(
                id: "longest",
                symbol: "timer",
                title: "Longest stretch: \(DurationFormat.short(longestSession.duration))",
                detail: "Without a break of more than 2 minutes, from \(formatter.string(from: Date(timeIntervalSince1970: longestSession.start))).",
                tone: longestSession.duration >= 7200 ? .bad : .neutral
            ))
        }
        return result
    }

    public static func hourLabel(_ hour: Int, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.setLocalizedDateFormatFromTemplate("j")
        let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: Date(timeIntervalSince1970: 0)) ?? .now
        return formatter.string(from: date)
    }
}
