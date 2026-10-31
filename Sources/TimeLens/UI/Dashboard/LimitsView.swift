import SwiftUI
import TimeLensCore

/// Daily limits: today's progress on each, suggestions, and the editor.
struct LimitsView: View {
    private var model: AppModel { .shared }
    @State private var editing: UsageLimit?
    @State private var week = UsageStats(interval: DateInterval(start: .now, duration: 1))

    var body: some View {
        let limits = model.limits.limits
        Page(title: "Limits") {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Daily limits").font(.title2.weight(.semibold))
                    Text("Get a heads-up 5 minutes and 1 minute before, then a full-screen reminder when time's up. You can always take 15 more minutes or ignore a limit for the day.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    editing = UsageLimit(kind: .app, target: model.todayRows.first?.app ?? "", minutes: 60)
                } label: {
                    Label("Add Limit", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
        } content: {
            Card("Today") {
                if limits.isEmpty {
                    EmptyState(symbol: "hourglass", title: "No limits yet", message: "Add one above, or start from a suggestion below.")
                } else {
                    VStack(spacing: 12) {
                        ForEach(limits) { limit in
                            LimitRow(limit: limit) { editing = limit }
                            if limit.id != limits.last?.id { Divider() }
                        }
                    }
                }
            }
            if !suggestions.isEmpty {
                Card("Suggestions", subtitle: "Your most distracting apps and sites over the last 7 days") {
                    VStack(spacing: 8) {
                        ForEach(suggestions, id: \.target) { suggestion in
                            HStack(spacing: 10) {
                                EntityIcon(entity: suggestion.kind == .app ? .app(suggestion.target) : .site(suggestion.target), size: 24)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(suggestion.kind == .app ? model.appName(suggestion.target) : model.siteName(suggestion.target))
                                    Text("\(DurationFormat.short(suggestion.perDay)) a day on average").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Limit to \(DurationFormat.short(Double(suggestion.minutes) * 60))") {
                                    editing = UsageLimit(kind: suggestion.kind, target: suggestion.target, minutes: suggestion.minutes)
                                }
                            }
                        }
                    }
                }
            }
        }
        .sheet(item: $editing) { limit in
            LimitEditor(limit: limit) { saved in
                if let saved { model.limits.save(saved) }
                editing = nil
            }
        }
        .task {
            let calendar = model.prefs.calendar
            let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now))!
            let interval = DateInterval(start: calendar.date(byAdding: .day, value: -7, to: end)!, end: end)
            week = await model.load(interval: interval, comparison: nil, sessions: false).stats
        }
    }

    private struct Suggestion {
        let kind: UsageLimit.Kind
        let target: String
        let perDay: Double
        let minutes: Int
    }

    private var suggestions: [Suggestion] {
        let days = Double(max(week.elapsedDays, 1))
        var result: [Suggestion] = []
        let candidates: [(UsageLimit.Kind, Ranked)] = week.sites.map { (.site, $0) } + week.apps.filter { BrowserReader.family(of: $0.key) == nil }.map { (.app, $0) }
        for (kind, ranked) in candidates.sorted(by: { $0.1.seconds > $1.1.seconds }) {
            let rating = kind == .app ? model.categorizer.rating(app: ranked.key, site: "") : model.categorizer.rating(app: "", site: ranked.key)
            guard rating == .distracting, !SiteKey.isPseudo(ranked.key), model.limits.limit(kind: kind, target: ranked.key) == nil else { continue }
            let perDay = ranked.seconds / days
            guard perDay >= 15 * 60 else { continue }
            let steps = [15, 30, 45, 60, 90, 120, 180]
            let minutes = steps.last { Double($0 * 60) <= perDay * 0.75 } ?? 15
            result.append(Suggestion(kind: kind, target: ranked.key, perDay: perDay, minutes: minutes))
            if result.count == 5 { break }
        }
        return result
    }
}

private struct LimitRow: View {
    private var model: AppModel { .shared }
    let limit: UsageLimit
    let edit: () -> Void

    var body: some View {
        let used = model.limits.used(limit, rows: model.todayRows, categorizer: model.categorizer)
        let appliesToday = limit.applies(on: .now, calendar: model.prefs.calendar)
        HStack(spacing: 12) {
            EntityIcon(entity: entity, size: 30)
                .opacity(limit.enabled ? 1 : 0.4)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(model.limitName(limit)).font(.headline)
                    Text(limit.kind.title).font(.caption).foregroundStyle(.secondary)
                    if !limit.enabled {
                        Text("Off").font(.caption2.weight(.semibold)).padding(.horizontal, 5).background(Theme.track, in: Capsule())
                    } else if !appliesToday {
                        Text("Not today").font(.caption2.weight(.semibold)).padding(.horizontal, 5).background(Theme.track, in: Capsule())
                    }
                    Spacer()
                    Text("\(DurationFormat.short(used)) of \(DurationFormat.short(limit.seconds))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                LimitProgressRow(name: daysText, used: used, limit: limit.seconds)
                    .font(.caption)
            }
            Toggle("", isOn: Binding(get: { limit.enabled }, set: { on in
                var changed = limit
                changed.enabled = on
                model.limits.save(changed)
            }))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
            Menu {
                Button("Edit…", action: edit)
                Button("Delete", role: .destructive) { model.limits.delete(limit) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private var entity: EntityRef {
        switch limit.kind {
        case .app: .app(limit.target)
        case .site: .site(limit.target)
        case .category: .category(UsageCategory(rawValue: limit.target) ?? .other)
        }
    }

    private var daysText: String {
        if limit.days == 127 { return "Every day" }
        if limit.days == 0b0111110 { return "Weekdays" }
        if limit.days == 0b1000001 { return "Weekends" }
        let symbols = Calendar.current.shortWeekdaySymbols
        return (0..<7).filter { limit.days & (1 << $0) != 0 }.map { symbols[$0] }.joined(separator: ", ")
    }
}

/// Add or change a limit.
struct LimitEditor: View {
    private var model: AppModel { .shared }
    @State var limit: UsageLimit
    let done: (UsageLimit?) -> Void
    @State private var candidates = UsageStats(interval: DateInterval(start: .now, duration: 1))
    @State private var customSite = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(limit.id == 0 ? "New Limit" : "Edit Limit").font(.title2.weight(.semibold))
            Form {
                Picker("Limit", selection: $limit.kind) {
                    ForEach(UsageLimit.Kind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: limit.kind) { _, kind in
                    switch kind {
                    case .app: limit.target = candidates.apps.first?.key ?? ""
                    case .site: limit.target = candidates.sites.first(where: { !SiteKey.isPseudo($0.key) })?.key ?? ""
                    case .category: limit.target = UsageCategory.entertainment.rawValue
                    }
                }
                switch limit.kind {
                case .app:
                    Picker("App", selection: $limit.target) {
                        ForEach(appOptions, id: \.self) { id in
                            Text(model.appName(id)).tag(id)
                        }
                    }
                case .site:
                    Picker("Website", selection: $limit.target) {
                        ForEach(siteOptions, id: \.self) { site in
                            Text(site).tag(site)
                        }
                    }
                    HStack {
                        TextField("Or type a site", text: $customSite, prompt: Text("example.com"))
                        Button("Use") {
                            if let parsed = SiteKey.parse(customSite) { limit.target = parsed.site }
                        }
                        .disabled(SiteKey.parse(customSite) == nil)
                    }
                case .category:
                    Picker("Category", selection: $limit.target) {
                        ForEach(UsageCategory.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                }
                LabeledContent("Daily time") {
                    HStack {
                        Stepper(value: $limit.minutes, in: 5...720, step: 5) {
                            Text(DurationFormat.short(Double(limit.minutes) * 60)).monospacedDigit()
                        }
                    }
                }
                LabeledContent("Days") {
                    HStack(spacing: 4) {
                        ForEach(0..<7, id: \.self) { index in
                            let weekday = (Calendar.current.firstWeekday - 1 + index) % 7
                            let on = limit.days & (1 << weekday) != 0
                            Button(Calendar.current.veryShortWeekdaySymbols[weekday]) {
                                limit.days ^= (1 << weekday)
                            }
                            .buttonStyle(.bordered)
                            .tint(on ? Theme.accent : .secondary)
                            .fontWeight(on ? .bold : .regular)
                        }
                    }
                }
                if let perDay = averagePerDay {
                    LabeledContent("You average") {
                        Text("\(DurationFormat.short(perDay)) a day (last 7 days)").foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                if limit.id != 0 {
                    Button("Delete", role: .destructive) {
                        model.limits.delete(limit)
                        done(nil)
                    }
                }
                Spacer()
                Button("Cancel") { done(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { done(limit) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(limit.target.isEmpty || limit.days == 0)
            }
        }
        .padding(20)
        .frame(width: 480)
        .task {
            let calendar = model.prefs.calendar
            let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now))!
            let interval = DateInterval(start: calendar.date(byAdding: .day, value: -7, to: end)!, end: end)
            candidates = await model.load(interval: interval, comparison: nil, sessions: false).stats
        }
    }

    private var appOptions: [String] {
        var ids = candidates.apps.map(\.key)
        for app in model.directory.allApps.map(\.id) where !ids.contains(app) { ids.append(app) }
        if !limit.target.isEmpty, !ids.contains(limit.target) { ids.insert(limit.target, at: 0) }
        return ids
    }

    private var siteOptions: [String] {
        var sites = candidates.sites.map(\.key).filter { !SiteKey.isPseudo($0) }
        if !limit.target.isEmpty, !sites.contains(limit.target) { sites.insert(limit.target, at: 0) }
        return sites
    }

    private var averagePerDay: Double? {
        let days = Double(max(candidates.elapsedDays, 1))
        switch limit.kind {
        case .app: return candidates.apps.first { $0.key == limit.target }.map { $0.seconds / days }
        case .site: return candidates.sites.first { $0.key == limit.target }.map { $0.seconds / days }
        case .category: return candidates.categories.first { $0.key == limit.target }.map { $0.seconds / days }
        }
    }
}
