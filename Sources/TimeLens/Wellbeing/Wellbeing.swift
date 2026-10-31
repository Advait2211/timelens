import AppKit
import Observation
import TimeLensCore

// MARK: Limits

/// Daily limits per app, website or category: warnings as you get close, a shield when
/// you're over.
@MainActor
@Observable
final class LimitsEngine {
    private(set) var limits: [UsageLimit] = []
    /// Limit id → until when it's snoozed.
    private(set) var snoozed: [Int64: Date] = [:]
    /// Limit id → the day it's ignored for.
    private(set) var ignoredDay: [Int64: Date] = [:]
    @ObservationIgnored private var warned: Set<String> = []
    @ObservationIgnored private let store: ActivityStore?

    init(store: ActivityStore?) {
        self.store = store
        limits = store?.limits() ?? []
    }

    func save(_ limit: UsageLimit) {
        guard let store else { return }
        var saved = limit
        saved.id = store.saveLimit(limit)
        if let index = limits.firstIndex(where: { $0.id == saved.id }) {
            limits[index] = saved
        } else {
            limits.append(saved)
        }
    }

    func delete(_ limit: UsageLimit) {
        store?.deleteLimit(limit.id)
        limits.removeAll { $0.id == limit.id }
    }

    func limit(kind: UsageLimit.Kind, target: String) -> UsageLimit? {
        limits.first { $0.kind == kind && $0.target == target }
    }

    /// Seconds used today on what the limit covers.
    func used(_ limit: UsageLimit, rows: [HourUsage], categorizer: Categorizer) -> Double {
        rows.reduce(0) { total, row in
            switch limit.kind {
            case .app: row.app == limit.target ? total + row.seconds : total
            case .site: row.site == limit.target ? total + row.seconds : total
            case .category: categorizer.category(app: row.app, site: row.site).rawValue == limit.target ? total + row.seconds : total
            }
        }
    }

    func covers(_ limit: UsageLimit, app: String, site: String, categorizer: Categorizer) -> Bool {
        switch limit.kind {
        case .app: app == limit.target
        case .site: site == limit.target
        case .category: categorizer.category(app: app, site: site).rawValue == limit.target
        }
    }

    func isSuspended(_ limit: UsageLimit, now: Date, calendar: Calendar) -> Bool {
        if let until = snoozed[limit.id], until > now { return true }
        if let day = ignoredDay[limit.id], calendar.isDate(day, inSameDayAs: now) { return true }
        return false
    }

    func snooze(_ limit: UsageLimit, minutes: Int) {
        snoozed[limit.id] = Date().addingTimeInterval(Double(minutes) * 60)
    }

    func ignoreToday(_ limit: UsageLimit) {
        ignoredDay[limit.id] = Date()
    }

    /// The limit that should shield what's in front of you right now, if any — and sends
    /// the "5 minutes left" warnings along the way.
    func evaluate(app: String, site: String, rows: [HourUsage], categorizer: Categorizer, calendar: Calendar,
                  warnings: Bool, name: (UsageLimit) -> String) -> (limit: UsageLimit, used: Double)? {
        let now = Date()
        let day = calendar.startOfDay(for: now).timeIntervalSince1970
        var exceeded: (limit: UsageLimit, used: Double)?
        for limit in limits where limit.enabled && limit.applies(on: now, calendar: calendar) {
            guard covers(limit, app: app, site: site, categorizer: categorizer) else { continue }
            let used = used(limit, rows: rows, categorizer: categorizer)
            let left = limit.seconds - used
            if left <= 0 {
                if !isSuspended(limit, now: now, calendar: calendar), exceeded == nil {
                    exceeded = (limit, used)
                    let key = "\(limit.id)-over-\(day)"
                    if !warned.contains(key) {
                        warned.insert(key)
                        store?.addEvent(.limitReached, app: app, site: site, info: limit.target)
                    }
                }
            } else if warnings {
                for threshold in [300.0, 60.0] where left <= threshold {
                    let key = "\(limit.id)-\(Int(threshold))-\(day)"
                    guard !warned.contains(key) else { continue }
                    warned.insert(key)
                    // Don't send both at once when a limit is set close to what's already used.
                    if threshold == 300, left <= 60 { continue }
                    store?.addEvent(.limitWarning, app: app, site: site, info: limit.target)
                    Notifier.shared.send(
                        id: key,
                        title: "\(Int((left / 60).rounded(.up))) min left on \(name(limit))",
                        body: "You've used \(DurationFormat.short(used)) of your \(DurationFormat.short(limit.seconds)) daily limit.",
                        section: DashboardSection.limits.rawValue
                    )
                }
            }
        }
        return exceeded
    }
}

// MARK: Focus

@MainActor
@Observable
final class FocusEngine {
    struct Active: Equatable {
        var id: Int64
        var start: Date
        var end: Date
        var blocked: Int
    }

    private(set) var active: Active?
    /// Whole minutes left, rounded up. Changes once a minute, so the menu bar label redraws
    /// only then (a live timer text in a status item spins the main thread).
    private(set) var minutesLeft = 0
    var onChange: (() -> Void)?
    @ObservationIgnored private let store: ActivityStore?
    @ObservationIgnored private let prefs: Preferences
    @ObservationIgnored private var timer: Timer?

    init(store: ActivityStore?, prefs: Preferences) {
        self.store = store
        self.prefs = prefs
        let now = Date().timeIntervalSince1970
        if let open = store?.resumableFocus(now: now) {
            active = Active(id: open.id, start: Date(timeIntervalSince1970: open.start),
                            end: Date(timeIntervalSince1970: open.plannedEnd), blocked: open.blocked)
            startTimer()
        }
        // Anything else left open (older, or already over) gets closed.
        store?.closeAbandonedFocus(now: now, keeping: active?.id)
    }

    var remaining: Double { active.map { max($0.end.timeIntervalSinceNow, 0) } ?? 0 }

    func start(minutes: Int) {
        if active != nil { end(completed: false) }
        let start = Date()
        let end = start.addingTimeInterval(Double(minutes) * 60)
        let id = store?.startFocus(start: start.timeIntervalSince1970, plannedEnd: end.timeIntervalSince1970, label: "") ?? 0
        active = Active(id: id, start: start, end: end, blocked: 0)
        startTimer()
        onChange?()
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        updateMinutesLeft()
    }

    private func updateMinutesLeft() {
        let minutes = Int((remaining / 60).rounded(.up))
        if minutes != minutesLeft { minutesLeft = minutes }
    }

    func end(completed: Bool) {
        guard let active else { return }
        timer?.invalidate()
        timer = nil
        store?.finishFocus(id: active.id, end: Date().timeIntervalSince1970, completed: completed, blocked: active.blocked)
        self.active = nil
        if completed {
            Notifier.shared.send(
                title: "Focus session complete",
                body: "\(DurationFormat.short(active.end.timeIntervalSince(active.start))) of focus done\(active.blocked > 0 ? ", \(active.blocked) distraction\(active.blocked == 1 ? "" : "s") blocked" : ""). Take a break.",
                section: DashboardSection.focus.rawValue
            )
        }
        onChange?()
    }

    func recordBlocked() {
        guard var active else { return }
        active.blocked += 1
        self.active = active
        store?.updateFocusBlocked(id: active.id, blocked: active.blocked)
        store?.addEvent(.focusBlocked)
    }

    private func check() {
        updateMinutesLeft()
        guard let active, Date() >= active.end else { return }
        end(completed: true)
    }

    func blocks(app: String, site: String, categorizer: Categorizer) -> Bool {
        guard active != nil else { return false }
        if prefs.focusBlockedApps.contains(app) { return true }
        if !site.isEmpty, prefs.focusBlockedSites.contains(site) { return true }
        let category = categorizer.category(app: app, site: site)
        return prefs.focusBlockedCategories.contains(category.rawValue)
    }
}

// MARK: Breaks

/// Reminds you to step away after a long stretch, and (optionally) to rest your eyes every
/// 20 minutes. A pause of `breakLengthMinutes` or more resets the clock.
@MainActor
final class BreakReminder {
    private let prefs: Preferences
    private var streakStart: Date?
    private var pauseStart: Date?
    private var remindersSent = 0
    private var eyeRemindersSent = 0
    private var timer: Timer?
    var isCounting: () -> Bool = { false }
    var onReminder: (() -> Void)?

    init(prefs: Preferences) {
        self.prefs = prefs
    }

    func start() {
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// How long you've been on screen without a break.
    var continuous: Double {
        guard let streakStart, pauseStart == nil else { return 0 }
        return Date().timeIntervalSince(streakStart)
    }

    private func check() {
        let now = Date()
        guard isCounting() else {
            if pauseStart == nil { pauseStart = now }
            if let pause = pauseStart, now.timeIntervalSince(pause) >= Double(prefs.breakLengthMinutes) * 60 {
                streakStart = nil
                remindersSent = 0
                eyeRemindersSent = 0
            }
            return
        }
        pauseStart = nil
        if streakStart == nil { streakStart = now }
        guard let streakStart else { return }
        let elapsed = now.timeIntervalSince(streakStart)

        let interval = Double(max(prefs.breakIntervalMinutes, 5)) * 60
        if prefs.breakReminders, elapsed >= interval * Double(remindersSent + 1) {
            remindersSent += 1
            onReminder?()
            Notifier.shared.send(
                id: "break",
                title: "Time for a break",
                body: "You've been on screen for \(DurationFormat.short(elapsed)) straight. Stand up, stretch, look away for \(prefs.breakLengthMinutes) minutes.",
                section: DashboardSection.overview.rawValue
            )
        }
        if prefs.eyeReminders, elapsed >= 1200 * Double(eyeRemindersSent + 1) {
            eyeRemindersSent += 1
            Notifier.shared.send(
                id: "eyes",
                title: "20-20-20",
                body: "Look at something 20 feet away for 20 seconds.",
                sound: false
            )
        }
    }
}

// MARK: Summaries

/// The end-of-day summary and the weekly report.
@MainActor
final class SummaryScheduler {
    private let prefs: Preferences
    private let store: ActivityStore
    private let names: (String) -> String
    private let categorizer: () -> Categorizer
    private var timer: Timer?
    private let defaults = UserDefaults.standard

    init(prefs: Preferences, store: ActivityStore, names: @escaping (String) -> String, categorizer: @escaping () -> Categorizer) {
        self.prefs = prefs
        self.store = store
        self.names = names
        self.categorizer = categorizer
    }

    func start() {
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        check()
    }

    private func check() {
        let calendar = prefs.calendar
        let now = Date()
        let minute = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        guard minute >= prefs.summaryMinute else { return }
        let today = calendar.startOfDay(for: now)
        let todayKey = ISO8601DateFormatter().string(from: today)

        if prefs.dailySummary, defaults.string(forKey: "lastDailySummary") != todayKey {
            defaults.set(todayKey, forKey: "lastDailySummary")
            Task { await sendDaily() }
        }
        if prefs.weeklySummary, calendar.component(.weekday, from: now) == prefs.weeklySummaryDay,
           defaults.string(forKey: "lastWeeklySummary") != todayKey {
            defaults.set(todayKey, forKey: "lastWeeklySummary")
            Task { await sendWeekly() }
        }
    }

    func sendDaily() async {
        let calendar = prefs.calendar
        let today = calendar.dateInterval(of: .day, for: .now)!
        let weekBefore = DateInterval(start: calendar.date(byAdding: .day, value: -7, to: today.start)!, end: today.start)
        let categorizer = categorizer()
        let stats = StatsBuilder.build(rows: await store.hourly(today), interval: today, calendar: calendar, categorizer: categorizer)
        let previous = StatsBuilder.build(rows: await store.hourly(weekBefore), interval: weekBefore, calendar: calendar, categorizer: categorizer)
        guard stats.total >= 60 else { return }
        let average = previous.total / 7
        var body = "Top: " + stats.apps.prefix(3).map { "\(names($0.key)) \(DurationFormat.short($0.seconds))" }.joined(separator: " · ")
        if let site = stats.sites.first(where: { !SiteKey.isPseudo($0.key) }) {
            body += "\nTop site: \(site.key) \(DurationFormat.short(site.seconds))"
        }
        let comparison = DurationFormat.comparison(stats.total, average, period: "your daily average").map { " — \($0.lowercased())" } ?? ""
        Notifier.shared.send(
            id: "daily-summary",
            title: "Today: \(DurationFormat.short(stats.total)) of screen time\(comparison)",
            body: body,
            section: DashboardSection.stats.rawValue
        )
    }

    func sendWeekly() async {
        let calendar = prefs.calendar
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now))!
        let week = DateInterval(start: calendar.date(byAdding: .day, value: -7, to: end)!, end: end)
        let before = DateInterval(start: calendar.date(byAdding: .day, value: -7, to: week.start)!, end: week.start)
        let categorizer = categorizer()
        let stats = StatsBuilder.build(rows: await store.hourly(week), interval: week, calendar: calendar, categorizer: categorizer)
        let previous = StatsBuilder.build(rows: await store.hourly(before), interval: before, calendar: calendar, categorizer: categorizer)
        guard stats.total >= 600 else { return }
        let comparison = DurationFormat.comparison(stats.total, previous.total, period: "the week before") ?? "Your first full week"
        let top = stats.apps.prefix(3).map { "\(names($0.key)) \(DurationFormat.short($0.seconds))" }.joined(separator: " · ")
        Notifier.shared.send(
            id: "weekly-summary",
            title: "Your week: \(DurationFormat.short(stats.total)) (\(DurationFormat.short(stats.averagePerDay))/day)",
            body: "\(comparison).\nTop: \(top)",
            section: DashboardSection.stats.rawValue
        )
    }
}
