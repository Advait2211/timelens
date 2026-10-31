import AppKit
import Observation
import TimeLensCore

enum DashboardSection: String, CaseIterable, Identifiable {
    case overview, stats, timeline, apps, websites, insights, focus, limits, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Today"
        case .stats: "Stats"
        case .timeline: "Timeline"
        case .apps: "Apps"
        case .websites: "Websites"
        case .insights: "Insights"
        case .focus: "Focus"
        case .limits: "Limits"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "sun.max"
        case .stats: "chart.bar.xaxis"
        case .timeline: "calendar.day.timeline.left"
        case .apps: "square.grid.2x2"
        case .websites: "globe"
        case .insights: "sparkles"
        case .focus: "moon.circle"
        case .limits: "hourglass"
        case .settings: "gearshape"
        }
    }
}

/// Owns the store, tracker and wellbeing engines, and what the UI shows live.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let prefs = Preferences.shared
    @ObservationIgnored let store: ActivityStore?
    @ObservationIgnored let tracker: ActivityTracker?
    @ObservationIgnored let directory = AppDirectory()
    @ObservationIgnored let shield = ShieldController()
    @ObservationIgnored let breaks: BreakReminder
    @ObservationIgnored private var summaries: SummaryScheduler?

    let limits: LimitsEngine
    let focus: FocusEngine
    let isDemo: Bool

    private(set) var categorizer = Categorizer()
    private(set) var live = LiveSnapshot()
    /// Bumped after every write, so views showing today can refresh.
    private(set) var dataVersion = 0
    /// Bumped when categories or ratings change, so every view recomputes.
    private(set) var categoryVersion = 0
    private(set) var todayRows: [HourUsage] = []
    private(set) var todayTotal: Double = 0
    /// `todayTotal` as the menu bar shows it. Changes about once a minute, so the status item
    /// redraws only then rather than after every write.
    private(set) var todayShort = ""
    private(set) var problem: String?

    private init() {
        isDemo = CommandLine.arguments.contains("--demo-data")
        var store: ActivityStore?
        do {
            store = try ActivityStore(url: isDemo ? ActivityStore.demoURL : ActivityStore.defaultURL)
        } catch {
            problem = error.localizedDescription
        }
        self.store = store
        tracker = (store != nil && !isDemo) ? ActivityTracker(store: store!) : nil
        limits = LimitsEngine(store: store)
        focus = FocusEngine(store: store, prefs: Preferences.shared)
        breaks = BreakReminder(prefs: Preferences.shared)

        if let store {
            directory.load(store.apps())
            categorizer = Categorizer(overrides: store.overrides(), declaredCategories: directory.declaredCategories)
        }
        start()
    }

    private func start() {
        Notifier.shared.setUp()
        guard let store else { return }

        if isDemo, store.isEmpty {
            Task {
                await DemoData.fill(store)
                directory.load(store.apps())
                categorizer.declaredCategories = directory.declaredCategories
                await refreshToday()
            }
        }

        if let tracker {
            tracker.onLive = { [weak self] snapshot in self?.receive(snapshot) }
            tracker.onFlush = { [weak self] in
                Task { await self?.refreshToday() }
            }
            tracker.onNewApp = { [weak self] record in
                guard let self else { return }
                directory.remember(record)
                categorizer.declaredCategories = directory.declaredCategories
            }
            tracker.update(prefs.trackerSettings)
            observeTrackerSettings()
            tracker.start()
        }

        shield.onAction = { [weak self] action, request in self?.perform(action, on: request) }
        focus.onChange = { [weak self] in self?.evaluateShield() }
        breaks.isCounting = { [weak self] in self?.live.counting ?? false }
        breaks.start()

        let summaries = SummaryScheduler(prefs: prefs, store: store, names: { [weak self] in self?.directory.name($0) ?? $0 },
                                         categorizer: { [weak self] in self?.categorizer ?? Categorizer() })
        summaries.start()
        self.summaries = summaries

        if prefs.detailRetentionDays > 0 {
            store.pruneDetails(before: Date().addingTimeInterval(-Double(prefs.detailRetentionDays) * 86_400))
        }
        Task { await refreshToday() }
    }

    func shutdown() {
        tracker?.stop()
        if let active = focus.active {
            store?.finishFocus(id: active.id, end: Date().timeIntervalSince1970, completed: false, blocked: active.blocked)
        }
    }

    /// Pushes tracker settings whenever a preference they depend on changes.
    private func observeTrackerSettings() {
        withObservationTracking {
            _ = prefs.trackerSettings
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.tracker?.update(self.prefs.trackerSettings)
                self.observeTrackerSettings()
            }
        }
    }

    // MARK: Live

    private func receive(_ snapshot: LiveSnapshot) {
        live = snapshot
        evaluateShield()
    }

    func refreshToday() async {
        guard let store else { return }
        let today = prefs.calendar.dateInterval(of: .day, for: .now)!
        let rows = await store.hourly(today)
        todayRows = rows
        todayTotal = rows.reduce(0) { $0 + $1.seconds }
        let short = DurationFormat.short(todayTotal)
        if short != todayShort { todayShort = short }
        dataVersion += 1
        evaluateShield()
    }

    // MARK: Names

    func appName(_ id: String) -> String { directory.name(id) }

    func siteName(_ site: String) -> String { SiteKey.displayName(site) }

    func category(app: String, site: String) -> UsageCategory { categorizer.category(app: app, site: site) }

    func limitName(_ limit: UsageLimit) -> String {
        switch limit.kind {
        case .app: appName(limit.target)
        case .site: siteName(limit.target)
        case .category: UsageCategory(rawValue: limit.target)?.title ?? limit.target
        }
    }

    // MARK: Overrides

    func setCategory(_ category: UsageCategory?, forApp app: String) {
        updateOverride(Override.appKey(app)) { $0.category = category }
    }

    func setCategory(_ category: UsageCategory?, forSite site: String) {
        updateOverride(Override.siteKey(site)) { $0.category = category }
    }

    func setRating(_ rating: Rating?, forKey key: String) {
        updateOverride(key) { $0.rating = rating }
    }

    func override(for key: String) -> Override? { categorizer.overrides[key] }

    private func updateOverride(_ key: String, _ change: (inout Override) -> Void) {
        var value = categorizer.overrides[key] ?? Override()
        change(&value)
        if value.category == nil, value.rating == nil {
            categorizer.overrides[key] = nil
            store?.setOverride(nil, for: key)
        } else {
            categorizer.overrides[key] = value
            store?.setOverride(value, for: key)
        }
        categoryVersion += 1
    }

    // MARK: Shield

    private func evaluateShield() {
        guard let front = live.front, front.bundleID != Bundle.main.bundleIdentifier,
              live.reason == nil || live.reason == .shield || live.reason == .idle else {
            hideShield()
            return
        }
        let app = front.bundleID
        let site = live.site

        if let active = focus.active, focus.blocks(app: app, site: site, categorizer: categorizer) {
            let appBlocked = prefs.focusBlockedApps.contains(app) || (site.isEmpty && focus.blocks(app: app, site: "", categorizer: categorizer))
            let request = ShieldRequest(
                reason: .focus(endsAt: active.end.timeIntervalSince1970),
                targetName: appBlocked || site.isEmpty ? appName(app) : siteName(site),
                app: front,
                site: appBlocked ? "" : site,
                used: 0
            )
            if !request.sameTarget(as: shield.current) { focus.recordBlocked() }
            showShield(request)
            return
        }

        if let hit = limits.evaluate(app: app, site: site, rows: todayRows, categorizer: categorizer, calendar: prefs.calendar,
                                     warnings: prefs.limitWarnings, name: limitName) {
            let request = ShieldRequest(
                reason: .limit(hit.limit),
                targetName: limitName(hit.limit),
                app: front,
                site: hit.limit.kind == .app ? "" : site,
                used: hit.used
            )
            showShield(request)
            return
        }
        hideShield()
    }

    private func showShield(_ request: ShieldRequest) {
        let wasVisible = shield.isVisible
        shield.show(request, directory: directory)
        if !wasVisible { tracker?.setShield(active: true) }
    }

    private func hideShield() {
        guard shield.isVisible else { return }
        shield.hide()
        tracker?.setShield(active: false)
    }

    private func perform(_ action: ShieldAction, on request: ShieldRequest) {
        switch action {
        case .leave:
            if request.isWebsite, BrowserReader.family(of: request.app.bundleID) != nil {
                tracker?.browser.closeActiveTab(of: request.app)
            } else {
                NSRunningApplication(processIdentifier: request.app.pid)?.hide()
            }
        case let .snooze(minutes):
            if case let .limit(limit) = request.reason { limits.snooze(limit, minutes: minutes) }
        case .ignoreToday:
            if case let .limit(limit) = request.reason { limits.ignoreToday(limit) }
        case .endFocus:
            focus.end(completed: false)
        }
        hideShield()
        tracker?.tickSoon()
    }

    // MARK: Summaries (for Settings' test buttons)

    func sendTestSummary(weekly: Bool) {
        Task {
            await Notifier.shared.requestAuthorization()
            if weekly { await summaries?.sendWeekly() } else { await summaries?.sendDaily() }
        }
    }
}
