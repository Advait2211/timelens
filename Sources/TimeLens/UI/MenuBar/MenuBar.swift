import AppKit
import SwiftUI
import TimeLensCore

/// The status item: today's screen time, or the focus countdown while a session runs.
struct MenuBarLabel: View {
    private var model: AppModel { .shared }

    var body: some View {
        Group {
            if model.focus.active != nil {
                // Minutes only: a ticking timer text here redraws the status item endlessly.
                HStack(spacing: 4) {
                    Image(systemName: "moon.fill")
                    Text("\(model.focus.minutesLeft)m")
                        .monospacedDigit()
                }
            } else if model.prefs.menuBarStyle == .time, !model.prefs.paused {
                HStack(spacing: 4) {
                    Image(systemName: "hourglass")
                    Text(model.todayShort)
                        .monospacedDigit()
                }
            } else {
                Image(systemName: model.prefs.paused ? "pause.circle" : "hourglass")
            }
        }
    }
}

/// The popover under the status item: today at a glance, what you're on now, focus and
/// limits — each in its own soft tile.
struct MenuBarContent: View {
    private var model: AppModel { .shared }
    @AppStorage("popoverList") private var listKind = "apps"
    @State private var today = UsageStats(interval: DateInterval(start: .now, duration: 86_400))
    @State private var yesterdaySoFar: Double = 0
    @State private var pickups = 0
    /// MenuBarExtra keeps these views alive after the popover closes. While it's closed they
    /// read a frozen copy of the live values instead of the model, so nothing redraws until
    /// it opens again.
    @State private var isOpen = true
    @State private var frozen = Frozen()

    private struct Frozen {
        var live = LiveSnapshot()
        var todayTotal: Double = 0
        var todayRows: [HourUsage] = []
    }

    private var live: LiveSnapshot { isOpen ? model.live : frozen.live }
    private var todayTotal: Double { isOpen ? model.todayTotal : frozen.todayTotal }
    private var todayRows: [HourUsage] { isOpen ? model.todayRows : frozen.todayRows }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            todayTile
            nowTile
            topTile
            focusTile
            if !limitRows.isEmpty { limitsTile }
            Button { open(nil) } label: {
                Text("Open Dashboard").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .padding(12)
        .frame(width: 350)
        .background {
            Button("Quit TimeLens") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .background(WindowKeyObserver { setOpen($0) })
        .task(id: isOpen ? model.dataVersion : -1) {
            guard isOpen else { return }
            await reload()
        }
    }

    /// Runs inside the window's key change, before the frame is drawn: opening shows current
    /// numbers from the first frame.
    private func setOpen(_ open: Bool) {
        guard open != isOpen else { return }
        if open {
            isOpen = true
            rebuildToday()
        } else {
            frozen = Frozen(live: model.live, todayTotal: model.todayTotal, todayRows: model.todayRows)
            isOpen = false
        }
    }

    private func rebuildToday() {
        let calendar = model.prefs.calendar
        let day = calendar.dateInterval(of: .day, for: .now)!
        today = StatsBuilder.build(rows: todayRows, interval: day, calendar: calendar, categorizer: model.categorizer)
    }

    private func reload() async {
        rebuildToday()
        guard let store = model.store else { return }
        let calendar = model.prefs.calendar
        let comparison = Period.today.comparisonInterval(calendar)
        yesterdaySoFar = await store.hourly(comparison).reduce(0) { $0 + $1.seconds }
        pickups = await store.events(calendar.dateInterval(of: .day, for: .now)!, kinds: [.pickup]).count
    }

    private func open(_ section: DashboardSection?) {
        NotificationCenter.default.post(name: .openDashboard, object: nil, userInfo: section.map { ["section": $0.rawValue] })
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 22, height: 22)
            Text("TimeLens").font(.headline)
            if model.isDemo {
                Text("DEMO").font(.caption2.weight(.bold)).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Theme.warning.opacity(0.3), in: Capsule())
            }
            Spacer()
            Menu {
                Button("Open Dashboard") { open(nil) }
                Button("Stats") { open(.stats) }
                Button("Settings…") { open(.settings) }
                Divider()
                Button(model.prefs.paused ? "Resume Tracking" : "Pause Tracking") { model.prefs.paused.toggle() }
                Divider()
                Button("Quit TimeLens") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More")
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 2)
    }

    private var todayTile: some View {
        PopoverTile {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Today").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Text(DurationFormat.short(todayTotal))
                        .font(.system(size: 30, weight: .semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    if let change = DurationFormat.change(todayTotal, yesterdaySoFar) {
                        HStack(spacing: 4) {
                            DeltaBadge(change: change, higherIsBetter: false)
                            Text("vs yesterday").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Label("\(pickups) pickup\(pickups == 1 ? "" : "s")", systemImage: "hand.tap")
                        .font(.caption).foregroundStyle(.secondary)
                    if let score = today.productivityScore {
                        Label("\(Int(score.rounded())) productivity", systemImage: "bolt.fill")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            MiniHourBars(hours: (0..<24).map { today.hourTotal($0) }, currentHour: Calendar.current.component(.hour, from: .now))
            if let goal = model.prefs.dailyGoal {
                VStack(alignment: .leading, spacing: 4) {
                    UsageBar(fraction: todayTotal / goal, color: todayTotal > goal ? Theme.critical : Theme.good, height: 6)
                    Text(todayTotal > goal
                         ? "\(DurationFormat.short(todayTotal - goal)) over your \(DurationFormat.short(goal)) goal"
                         : "\(DurationFormat.short(goal - todayTotal)) left of your \(DurationFormat.short(goal)) goal")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var nowTile: some View {
        let live = self.live
        return PopoverTile {
            HStack(spacing: 10) {
                if let front = live.front, live.counting || live.reason == .idle {
                    if !live.site.isEmpty {
                        SiteIconView(site: live.site, size: 30)
                    } else {
                        AppIconView(app: front.bundleID, size: 30)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(live.site.isEmpty ? front.name : "\(model.siteName(live.site)) · \(front.name)")
                            .font(.callout.weight(.medium)).lineLimit(1)
                        Text(live.title ?? model.category(app: front.bundleID, site: live.site).title)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    if let start = live.sessionStart {
                        TimelineView(.periodic(from: .now, by: isOpen ? 1 : 3600)) { context in
                            Text(DurationFormat.precise(context.date.timeIntervalSince1970 - start))
                                .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                        }
                    } else if live.reason == .idle {
                        Text("Idle").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Image(systemName: model.isDemo ? "sparkles" : "pause.circle").font(.title2).foregroundStyle(.secondary)
                    Text(model.isDemo ? "Showing demo data" : (live.reason?.title ?? "Waiting for activity"))
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                }
            }
            if live.mediaPlaying {
                Label("Video or call playing — counted without input", systemImage: "play.rectangle")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var topTile: some View {
        PopoverTile {
            HStack {
                Text("Top today").font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                Spacer()
                CardPicker(selection: $listKind, options: [("apps", "Apps"), ("sites", "Sites"), ("categories", "Categories")])
            }
            let rows = topRows
            if rows.isEmpty {
                Text("Nothing yet today").font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 40)
            } else {
                let peak = rows.first?.seconds ?? 1
                VStack(spacing: 4) {
                    ForEach(rows, id: \.key) { row in
                        HStack(spacing: 8) {
                            EntityIcon(entity: row.entity, size: 20)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(row.name).font(.callout).lineLimit(1)
                                    Spacer()
                                    Text(DurationFormat.short(row.seconds)).font(.callout).monospacedDigit()
                                }
                                UsageBar(fraction: row.seconds / peak, color: row.color, height: 4)
                            }
                        }
                    }
                }
            }
        }
    }

    private struct TopRow {
        let key: String
        let entity: EntityRef
        let name: String
        let seconds: Double
        let color: Color
    }

    private var topRows: [TopRow] {
        switch listKind {
        case "sites":
            return today.sites.prefix(5).map { ranked in
                TopRow(key: ranked.key, entity: .site(ranked.key), name: model.siteName(ranked.key), seconds: ranked.seconds,
                       color: Theme.color(model.categorizer.siteCategory(ranked.key)))
            }
        case "categories":
            return today.categories.prefix(5).compactMap { ranked in
                guard let category = UsageCategory(rawValue: ranked.key) else { return nil }
                return TopRow(key: ranked.key, entity: .category(category), name: category.title, seconds: ranked.seconds, color: Theme.color(category))
            }
        default:
            return today.apps.prefix(5).map { ranked in
                TopRow(key: ranked.key, entity: .app(ranked.key), name: model.appName(ranked.key), seconds: ranked.seconds,
                       color: Theme.color(model.categorizer.appCategory(ranked.key)))
            }
        }
    }

    private var focusTile: some View {
        PopoverTile {
            if let active = model.focus.active {
                HStack {
                    Image(systemName: "moon.fill").foregroundStyle(Theme.series[6])
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Focusing").font(.callout.weight(.medium))
                        Text("\(active.blocked) distraction\(active.blocked == 1 ? "" : "s") blocked").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    TimelineView(.periodic(from: .now, by: isOpen ? 1 : 3600)) { context in
                        Text(DurationFormat.clock(active.end.timeIntervalSince(context.date)))
                            .font(.title3.weight(.semibold)).monospacedDigit()
                    }
                    Button("End") { model.focus.end(completed: false) }
                        .controlSize(.small)
                }
            } else {
                HStack {
                    Label("Focus", systemImage: "moon").font(.callout.weight(.medium))
                    Spacer()
                    ForEach([25, 50, 90], id: \.self) { minutes in
                        Button("\(minutes)m") { model.focus.start(minutes: minutes) }
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    private var limitRows: [(limit: UsageLimit, used: Double)] {
        let calendar = model.prefs.calendar
        let active: [UsageLimit] = model.limits.limits.filter { $0.enabled && $0.applies(on: .now, calendar: calendar) }
        let rows: [(limit: UsageLimit, used: Double)] = active.map { limit in
            (limit, model.limits.used(limit, rows: todayRows, categorizer: model.categorizer))
        }
        let sorted = rows.sorted { a, b in a.used / a.limit.seconds > b.used / b.limit.seconds }
        return Array(sorted.prefix(3))
    }

    private var limitsTile: some View {
        PopoverTile {
            Text("Limits").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            ForEach(limitRows, id: \.limit.id) { row in
                LimitProgressRow(name: model.limitName(row.limit), used: row.used, limit: row.limit.seconds)
            }
        }
    }
}

/// One limit's progress today: name, used / allowed, and a status-colored bar.
struct LimitProgressRow: View {
    let name: String
    let used: Double
    let limit: Double

    var body: some View {
        let fraction = used / max(limit, 1)
        let color: Color = fraction >= 1 ? Theme.critical : fraction >= 0.8 ? Theme.warning : Theme.good
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(name).font(.callout).lineLimit(1)
                Spacer()
                if fraction >= 1 {
                    Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(Theme.critical).font(.caption)
                }
                Text("\(DurationFormat.short(used)) / \(DurationFormat.short(limit))")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            UsageBar(fraction: fraction, color: color, height: 4)
        }
    }
}
