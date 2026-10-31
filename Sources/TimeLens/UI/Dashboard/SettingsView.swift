import AppKit
import SwiftUI
import TimeLensCore
import UniformTypeIdentifiers
import UserNotifications

struct SettingsView: View {
    private var model: AppModel { .shared }
    @State private var confirmDelete = false
    @State private var deleteBefore = 90
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var message: String?
    @AppStorage("appearance") private var appearance: AppearancePreference = .system

    var body: some View {
        @Bindable var prefs = model.prefs
        Form {
            Section("Permissions") {
                PermissionsList()
            }

            Section {
                Picker("Count as idle after", selection: $prefs.idleMinutes) {
                    ForEach([1.0, 2, 3, 5, 10, 15], id: \.self) { minutes in
                        Text("\(Int(minutes)) minute\(minutes == 1 ? "" : "s") without input").tag(minutes)
                    }
                }
                Toggle("Keep counting while video plays or a call is on", isOn: $prefs.honorMedia)
                Picker("Private & incognito windows", selection: $prefs.privateMode) {
                    ForEach(PrivateMode.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Record window titles and page names", isOn: $prefs.trackTitles)
                Toggle("Pause tracking", isOn: $prefs.paused)
                ExcludedAppsEditor()
            } header: {
                Text("Tracking")
            } footer: {
                Text("Idle time is taken back: when you stop touching the Mac, everything after your last input is removed, so time away never counts. Video and calls are detected from the power assertions apps hold to keep the screen awake.")
            }

            Section("Goal & display") {
                Picker("Daily screen time goal", selection: $prefs.dailyGoalMinutes) {
                    Text("None").tag(0)
                    ForEach([60, 120, 180, 240, 300, 360, 420, 480, 600], id: \.self) { minutes in
                        Text(DurationFormat.short(Double(minutes) * 60)).tag(minutes)
                    }
                }
                Picker("Menu bar shows", selection: $prefs.menuBarStyle) {
                    ForEach(MenuBarStyle.allCases) { Text($0.title).tag($0) }
                }
                Picker("Weeks start on", selection: $prefs.weekStartsOn) {
                    Text("Monday").tag(2)
                    Text("Sunday").tag(1)
                }
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppearancePreference.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: appearance) { _, value in value.apply() }
                Toggle("Open at login", isOn: $launchAtLogin)
                    .disabled(!LaunchAtLogin.isSupported)
                    .onChange(of: launchAtLogin) { _, on in try? LaunchAtLogin.set(on) }
            }

            Section {
                Toggle("Remind me to take breaks", isOn: $prefs.breakReminders)
                Stepper("After \(prefs.breakIntervalMinutes) minutes of continuous use", value: $prefs.breakIntervalMinutes, in: 10...180, step: 5)
                    .disabled(!prefs.breakReminders)
                Stepper("A break is \(prefs.breakLengthMinutes) minutes away", value: $prefs.breakLengthMinutes, in: 1...30)
                Toggle("20-20-20 eye reminders (every 20 minutes)", isOn: $prefs.eyeReminders)
            } header: {
                Text("Breaks")
            }

            Section {
                Toggle("Daily summary", isOn: $prefs.dailySummary)
                DatePicker("Send at", selection: summaryTime, displayedComponents: .hourAndMinute)
                Toggle("Weekly report", isOn: $prefs.weeklySummary)
                Picker("Weekly report on", selection: $prefs.weeklySummaryDay) {
                    ForEach(1...7, id: \.self) { Text(Calendar.current.weekdaySymbols[$0 - 1]).tag($0) }
                }
                .disabled(!prefs.weeklySummary)
                Toggle("Warn 5 minutes and 1 minute before a limit", isOn: $prefs.limitWarnings)
                HStack {
                    Button("Send Test Daily Summary") { model.sendTestSummary(weekly: false) }
                    Button("Send Test Weekly Report") { model.sendTestSummary(weekly: true) }
                }
            } header: {
                Text("Notifications")
            }

            Section {
                ForEach(UsageCategory.allCases) { category in
                    Picker(selection: Binding(
                        get: { model.categorizer.rating(of: category) },
                        set: { model.setRating($0 == category.defaultRating ? nil : $0, forKey: Override.categoryKey(category)) }
                    )) {
                        ForEach([Rating.productive, .neutral, .distracting]) { Text($0.title).tag($0) }
                    } label: {
                        Label { Text(category.title) } icon: { EntityIcon(entity: .category(category), size: 18) }
                    }
                }
                OverridesList()
            } header: {
                Text("Categories & productivity")
            } footer: {
                Text("Change an app's or site's category and rating from its page (click it anywhere in the dashboard).")
            }

            Section("Data") {
                LabeledContent("Database") {
                    HStack {
                        Text(ByteCountFormatter.string(fromByteCount: model.store?.fileSize() ?? 0, countStyle: .file)).monospacedDigit()
                        Button("Show in Finder") {
                            if let url = model.store?.url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        }
                    }
                }
                Picker("Keep window titles and pages", selection: $prefs.detailRetentionDays) {
                    Text("Forever").tag(0)
                    Text("1 year").tag(365)
                    Text("90 days").tag(90)
                    Text("30 days").tag(30)
                }
                HStack {
                    Button("Export Activity (CSV)…") { Task { await exportCSV() } }
                    Button("Export Daily Totals (JSON)…") { Task { await exportJSON() } }
                }
                HStack {
                    Picker("Delete history older than", selection: $deleteBefore) {
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                        Text("1 year").tag(365)
                    }
                    .fixedSize()
                    Button("Delete") {
                        Task {
                            await model.store?.delete(before: Date().addingTimeInterval(-Double(deleteBefore) * 86_400))
                            await model.refreshToday()
                            message = "Deleted history older than \(deleteBefore) days."
                        }
                    }
                }
                Button("Delete All Data…", role: .destructive) { confirmDelete = true }
                if let message {
                    Text(message).foregroundStyle(.secondary)
                }
            }

            Section("About") {
                LabeledContent("TimeLens", value: "1.0")
                Text("Everything stays on this Mac in ~/Library/Application Support/TimeLens. Website icons are fetched straight from each site, never through a third party.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .confirmationDialog("Delete all TimeLens data?", isPresented: $confirmDelete) {
            Button("Delete Everything", role: .destructive) {
                Task {
                    await model.store?.deleteAll()
                    await model.refreshToday()
                    message = "All data deleted."
                }
            }
        } message: {
            Text("Every recorded minute, title, pickup and focus session is removed. Limits and settings stay.")
        }
    }

    private var summaryTime: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: model.prefs.summaryMinute / 60, minute: model.prefs.summaryMinute % 60, second: 0, of: .now) ?? .now
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                model.prefs.summaryMinute = (parts.hour ?? 21) * 60 + (parts.minute ?? 30)
            }
        )
    }

    // MARK: Export

    private func exportCSV() async {
        guard let store = model.store, let first = await store.firstActivity() else { message = "Nothing to export yet."; return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "TimeLens Activity.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let segments = await store.segments(DateInterval(start: first, end: Date().addingTimeInterval(60)))
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        var lines = ["start,end,seconds,app_id,app,website,category,rating"]
        for segment in segments {
            let category = model.category(app: segment.app, site: segment.site)
            let rating = model.categorizer.rating(app: segment.app, site: segment.site)
            let fields = [
                formatter.string(from: Date(timeIntervalSince1970: segment.start)),
                formatter.string(from: Date(timeIntervalSince1970: segment.end)),
                String(format: "%.1f", segment.duration),
                segment.app,
                model.appName(segment.app),
                SiteKey.isPseudo(segment.site) ? SiteKey.displayName(segment.site) : segment.site,
                category.title,
                rating.title,
            ]
            lines.append(fields.map(csvEscape).joined(separator: ","))
        }
        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            message = "Exported \(segments.count) rows."
        } catch {
            message = "Couldn't export: \(error.localizedDescription)"
        }
    }

    private func exportJSON() async {
        guard let store = model.store, let first = await store.firstActivity() else { message = "Nothing to export yet."; return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "TimeLens Daily.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let calendar = model.prefs.calendar
        let interval = DateInterval(start: calendar.startOfDay(for: first), end: calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now))!)
        let rows = await store.hourly(interval)
        var days: [String: [String: Any]] = [:]
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        for row in rows {
            let day = dayFormatter.string(from: Date(timeIntervalSince1970: Double(row.bucket)))
            var entry = days[day] ?? ["total": 0.0, "apps": [String: Double](), "websites": [String: Double]()]
            entry["total"] = (entry["total"] as? Double ?? 0) + row.seconds
            var apps = entry["apps"] as? [String: Double] ?? [:]
            apps[model.appName(row.app), default: 0] += row.seconds
            entry["apps"] = apps
            if !row.site.isEmpty {
                var sites = entry["websites"] as? [String: Double] ?? [:]
                sites[SiteKey.displayName(row.site), default: 0] += row.seconds
                entry["websites"] = sites
            }
            days[day] = entry
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: days, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url)
            message = "Exported \(days.count) days."
        } catch {
            message = "Couldn't export: \(error.localizedDescription)"
        }
    }

    private func csvEscape(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

// MARK: Permissions

/// Accessibility, per-browser Automation and notifications, with live status.
struct PermissionsList: View {
    private var model: AppModel { .shared }
    @State private var accessibility = Accessibility.isTrusted
    @State private var automation: [String: AutomationStatus] = [:]
    @State private var notifications: UNAuthorizationStatus = .notDetermined

    private var browsers: [(id: String, name: String)] {
        BrowserReader.browsers
            .filter { $0.value.family != .firefox && NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.key) != nil }
            .map { ($0.key, $0.value.name) }
            .sorted { $0.name < $1.name }
    }

    private var firefoxes: [String] {
        BrowserReader.browsers
            .filter { $0.value.family == .firefox && NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.key) != nil }
            .map(\.value.name)
            .sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            row(
                symbol: "accessibility",
                title: "Accessibility",
                detail: "Window titles (which document, project or chat) and the address bar of \(firefoxes.isEmpty ? "Firefox" : firefoxes.joined(separator: ", ")).",
                granted: accessibility
            ) {
                Button("Grant…") {
                    Accessibility.requestTrust()
                    Accessibility.openSettings()
                }
            }
            ForEach(browsers, id: \.id) { browser in
                let status = automation[browser.id] ?? .unknown
                row(
                    icon: browser.id,
                    title: browser.name,
                    detail: status == .notRunning ? "Open \(browser.name) once, then allow TimeLens to read its current tab." : "Lets TimeLens read the current tab's address, so time goes to the website.",
                    granted: status == .allowed
                ) {
                    if status == .denied {
                        Button("Open Settings…") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    } else {
                        Button("Allow…") {
                            let id = browser.id
                            Task.detached {
                                let result = BrowserReader.requestAutomation(bundleID: id)
                                await MainActor.run { automation[id] = result }
                            }
                        }
                        .disabled(status == .notRunning)
                    }
                }
            }
            row(symbol: "bell.badge", title: "Notifications", detail: "Limit warnings, break reminders and your daily summary.",
                granted: notifications == .authorized || notifications == .provisional) {
                Button(notifications == .denied ? "Open Settings…" : "Allow…") {
                    if notifications == .denied {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") { NSWorkspace.shared.open(url) }
                    } else {
                        Task {
                            await Notifier.shared.requestAuthorization()
                            notifications = Notifier.shared.authorization
                        }
                    }
                }
            }
        }
        .task {
            // Grants happen in System Settings; keep the list current.
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func refresh() async {
        accessibility = Accessibility.isTrusted
        await Notifier.shared.refreshAuthorization()
        notifications = Notifier.shared.authorization
        let ids = browsers.map(\.id)
        let results = await Task.detached {
            Dictionary(ids.map { ($0, BrowserReader.checkAutomation(bundleID: $0)) }) { first, _ in first }
        }.value
        automation = results
    }

    private func row<Action: View>(symbol: String? = nil, icon: String? = nil, title: String, detail: String, granted: Bool,
                                   @ViewBuilder action: () -> Action) -> some View {
        HStack(spacing: 12) {
            Group {
                if let icon {
                    AppIconView(app: icon, size: 28)
                } else if let symbol {
                    Image(systemName: symbol).font(.title3).frame(width: 28, height: 28)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.good)
                    .font(.callout)
            } else {
                action()
            }
        }
    }
}

// MARK: Excluded apps and overrides

private struct ExcludedAppsEditor: View {
    private var model: AppModel { .shared }

    var body: some View {
        @Bindable var prefs = model.prefs
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Never track")
                Spacer()
                Menu("Add App") {
                    ForEach(model.directory.allApps.filter { !prefs.excludedApps.contains($0.id) }, id: \.id) { app in
                        Button(app.name) { prefs.excludedApps.append(app.id) }
                    }
                }
                .fixedSize()
            }
            if prefs.excludedApps.isEmpty {
                Text("No apps excluded").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(prefs.excludedApps, id: \.self) { app in
                HStack {
                    AppIconView(app: app, size: 18)
                    Text(model.appName(app))
                    Spacer()
                    Button { prefs.excludedApps.removeAll { $0 == app } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
        }
    }
}

private struct OverridesList: View {
    private var model: AppModel { .shared }

    var body: some View {
        let overrides = model.categorizer.overrides.filter { !$0.key.hasPrefix("category:") }.sorted { $0.key < $1.key }
        if !overrides.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Your changes").font(.callout.weight(.medium))
                ForEach(overrides, id: \.key) { key, value in
                    HStack(spacing: 8) {
                        if key.hasPrefix("app:") {
                            AppIconView(app: String(key.dropFirst(4)), size: 18)
                            Text(model.appName(String(key.dropFirst(4))))
                        } else {
                            SiteIconView(site: String(key.dropFirst(5)), size: 18)
                            Text(String(key.dropFirst(5)))
                        }
                        Spacer()
                        Text([value.category?.title, value.rating?.title].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                        Button {
                            model.setRating(nil, forKey: key)
                            if key.hasPrefix("app:") { model.setCategory(nil, forApp: String(key.dropFirst(4))) } else { model.setCategory(nil, forSite: String(key.dropFirst(5))) }
                        } label: { Image(systemName: "arrow.uturn.backward.circle") }
                            .buttonStyle(.borderless)
                            .help("Back to automatic")
                    }
                }
            }
        }
    }
}

// MARK: Onboarding

struct OnboardingView: View {
    private var model: AppModel { .shared }
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to TimeLens").font(.title.weight(.bold))
                    Text("Precise screen time for every app and website. It's already tracking — it lives in your menu bar.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Label("Counts to the second, and takes idle time back when you step away", systemImage: "stopwatch")
                Label("Keeps counting while you watch a video or sit in a call", systemImage: "play.rectangle")
                Label("Splits browser time by website, and apps by window", systemImage: "globe")
                Label("Never sends anything anywhere — all data stays on this Mac", systemImage: "lock")
            }
            .font(.callout)
            Divider()
            Text("For the full picture, allow these:").font(.headline)
            PermissionsList()
            HStack {
                Text("You can change these any time in Settings.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: done)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        .frame(width: 600)
    }
}
