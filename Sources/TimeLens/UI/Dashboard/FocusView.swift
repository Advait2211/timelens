import SwiftUI
import TimeLensCore

/// Focus sessions: start one, see what's blocked, and how your focus has gone.
struct FocusView: View {
    private var model: AppModel { .shared }
    @State private var history: [FocusRecord] = []
    @State private var newSite = ""

    var body: some View {
        @Bindable var prefs = model.prefs
        Page(title: "Focus") {
            EmptyView()
        } content: {
            AdaptiveStack(minimum: .wide) {
                sessionCard.layoutPriority(1)
                statsCard.frame(minWidth: 320, maxWidth: 420)
            }
            Card("Blocked during focus", subtitle: "Opening any of these while a session runs brings up a reminder to get back to work") {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Categories").font(.callout.weight(.medium))
                    FlowLayout(spacing: 8, lineSpacing: 8) {
                        ForEach(UsageCategory.allCases) { category in
                            let on = prefs.focusBlockedCategories.contains(category.rawValue)
                            Button {
                                if on { prefs.focusBlockedCategories.removeAll { $0 == category.rawValue } } else { prefs.focusBlockedCategories.append(category.rawValue) }
                            } label: {
                                Label(category.title, systemImage: on ? "checkmark.circle.fill" : category.symbol)
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(on ? Theme.color(category).opacity(0.25) : Theme.track, in: Capsule())
                                    .overlay(Capsule().strokeBorder(on ? Theme.color(category) : .clear, lineWidth: 1.5))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Divider()
                    HStack(alignment: .top, spacing: 24) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Apps").font(.callout.weight(.medium))
                                Spacer()
                                Menu("Add App") {
                                    ForEach(model.directory.allApps.filter { !prefs.focusBlockedApps.contains($0.id) }, id: \.id) { app in
                                        Button(app.name) { prefs.focusBlockedApps.append(app.id) }
                                    }
                                }
                                .fixedSize()
                            }
                            if prefs.focusBlockedApps.isEmpty {
                                Text("None — categories above still apply").font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(prefs.focusBlockedApps, id: \.self) { app in
                                HStack {
                                    AppIconView(app: app, size: 18)
                                    Text(model.appName(app))
                                    Spacer()
                                    Button { prefs.focusBlockedApps.removeAll { $0 == app } } label: { Image(systemName: "minus.circle") }
                                        .buttonStyle(.borderless)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Websites").font(.callout.weight(.medium))
                                Spacer()
                                TextField("example.com", text: $newSite)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 160)
                                    .onSubmit(addSite)
                                Button("Add", action: addSite).disabled(SiteKey.parse(newSite) == nil)
                            }
                            if prefs.focusBlockedSites.isEmpty {
                                Text("None — categories above still apply").font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(prefs.focusBlockedSites, id: \.self) { site in
                                HStack {
                                    SiteIconView(site: site, size: 18)
                                    Text(site)
                                    Spacer()
                                    Button { prefs.focusBlockedSites.removeAll { $0 == site } } label: { Image(systemName: "minus.circle") }
                                        .buttonStyle(.borderless)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            Card("Recent sessions") {
                if history.isEmpty {
                    EmptyState(symbol: "moon", title: "No focus sessions yet")
                } else {
                    VStack(spacing: 6) {
                        ForEach(history.prefix(20)) { record in
                            HStack(spacing: 10) {
                                Image(systemName: record.completed ? "checkmark.circle.fill" : "xmark.circle")
                                    .foregroundStyle(record.completed ? Theme.good : .secondary)
                                Text(Date(timeIntervalSince1970: record.start).formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))
                                    .monospacedDigit()
                                Text(record.completed ? "Completed" : "Ended early").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                if record.blocked > 0 {
                                    Label("\(record.blocked)", systemImage: "shield.lefthalf.filled").font(.caption).foregroundStyle(.secondary)
                                        .help("Distractions blocked")
                                }
                                Text("\(DurationFormat.short(record.duration)) of \(DurationFormat.short(record.plannedDuration))")
                                    .monospacedDigit()
                            }
                            .font(.callout)
                        }
                    }
                }
            }
        }
        .task(id: model.focus.active?.id ?? -1) {
            let end = Date().addingTimeInterval(86_400)
            history = await model.store?.focusSessions(DateInterval(start: end.addingTimeInterval(-90 * 86_400), end: end)) ?? []
        }
    }

    private func addSite() {
        guard let parsed = SiteKey.parse(newSite), !model.prefs.focusBlockedSites.contains(parsed.site) else { return }
        model.prefs.focusBlockedSites.append(parsed.site)
        newSite = ""
    }

    private var sessionCard: some View {
        @Bindable var prefs = model.prefs
        return Card {
            HStack(spacing: 28) {
                FocusRing(active: model.focus.active, plannedMinutes: prefs.focusMinutes)
                    .frame(width: 190, height: 190)
                VStack(alignment: .leading, spacing: 14) {
                    if let active = model.focus.active {
                        Text("Focusing").font(.title2.weight(.semibold))
                        Text("Ends at \(active.end.formatted(date: .omitted, time: .shortened)). \(active.blocked) distraction\(active.blocked == 1 ? "" : "s") blocked so far.")
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("End Early", role: .destructive) { model.focus.end(completed: false) }
                        }
                    } else {
                        Text("Start a focus session").font(.title2.weight(.semibold))
                        Text("Distracting apps and sites get a reminder screen until the timer runs out.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            ForEach([25, 50, 90], id: \.self) { minutes in
                                Button("\(minutes) min") { prefs.focusMinutes = minutes }
                                    .buttonStyle(.bordered)
                                    .tint(prefs.focusMinutes == minutes ? Theme.accent : .secondary)
                            }
                            Stepper(value: $prefs.focusMinutes, in: 5...240, step: 5) {
                                Text("\(prefs.focusMinutes) min").monospacedDigit()
                            }
                            .fixedSize()
                        }
                        Button {
                            model.focus.start(minutes: prefs.focusMinutes)
                        } label: {
                            Label("Start Focus", systemImage: "play.fill").frame(minWidth: 140)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var statsCard: some View {
        let calendar = model.prefs.calendar
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: .now)?.start ?? .now
        let week = history.filter { $0.start >= weekStart.timeIntervalSince1970 }
        let total = week.reduce(0) { $0 + $1.duration }
        let completed = week.filter(\.completed).count
        let blocked = week.reduce(0) { $0 + $1.blocked }
        let days: [(Date, Double)] = (0..<14).reversed().map { offset in
            let day = calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: .now))!
            let next = calendar.date(byAdding: .day, value: 1, to: day)!
            let seconds = history.filter { $0.start >= day.timeIntervalSince1970 && $0.start < next.timeIntervalSince1970 }.reduce(0) { $0 + $1.duration }
            return (day, seconds)
        }
        return Card("This week") {
            HStack(spacing: 18) {
                metric("Focus time", DurationFormat.short(total))
                metric("Sessions", "\(week.count)")
                metric("Completed", week.isEmpty ? "—" : TimeText.percent(Double(completed) / Double(week.count)))
                metric("Blocked", "\(blocked)")
            }
            SimpleBarChart(items: days.map { day, seconds in
                SimpleBarChart.Item(id: "f\(Int(day.timeIntervalSince1970))", label: day.formatted(.dateTime.day()),
                                    value: seconds / 60, tooltip: "\(day.formatted(.dateTime.weekday(.abbreviated).day())): \(DurationFormat.short(seconds))")
            }, color: Theme.series[6], height: 130, labelStride: 2)
            Text("Minutes of focus per day, last 14 days").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
        }
    }
}

/// The countdown ring.
private struct FocusRing: View {
    let active: FocusEngine.Active?
    let plannedMinutes: Int

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            let total = active.map { $0.end.timeIntervalSince($0.start) } ?? Double(plannedMinutes) * 60
            let left = active.map { max($0.end.timeIntervalSince(now), 0) } ?? total
            ZStack {
                Circle().stroke(Theme.track, lineWidth: 14)
                Circle()
                    .trim(from: 0, to: active == nil ? 1 : left / max(total, 1))
                    .stroke(Theme.series[6], style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .opacity(active == nil ? 0.35 : 1)
                VStack(spacing: 2) {
                    Image(systemName: "moon.fill").foregroundStyle(Theme.series[6])
                    Text(DurationFormat.clock(left)).font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text(active == nil ? "ready" : "left").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
