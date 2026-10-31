import AppKit
import SwiftUI
import TimeLensCore

enum Route: Hashable {
    case app(String)
    case site(String)
}

struct DashboardView: View {
    private var model: AppModel { .shared }
    @AppStorage("dashboardSection") private var section: DashboardSection = .overview
    @AppStorage("onboardingDone") private var onboardingDone = false
    @State private var path: [Route] = []
    @State private var showOnboarding = false

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                Section {
                    ForEach([DashboardSection.overview, .stats, .timeline, .insights]) { item in
                        Label(item.title, systemImage: item.symbol).tag(item)
                    }
                }
                Section("Breakdown") {
                    ForEach([DashboardSection.apps, .websites]) { item in
                        Label(item.title, systemImage: item.symbol).tag(item)
                    }
                }
                Section("Wellbeing") {
                    ForEach([DashboardSection.focus, .limits]) { item in
                        Label(item.title, systemImage: item.symbol).tag(item)
                    }
                }
                Section {
                    Label(DashboardSection.settings.title, systemImage: DashboardSection.settings.symbol).tag(DashboardSection.settings)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
            .safeAreaInset(edge: .bottom) {
                SidebarNow()
                    .padding(12)
            }
        } detail: {
            NavigationStack(path: $path) {
                page
                    .navigationDestination(for: Route.self) { route in
                        switch route {
                        case let .app(id): EntityDetailView(entity: .app(id))
                        case let .site(site): EntityDetailView(entity: .site(site))
                        }
                    }
            }
        }
        .onChange(of: section) { path = [] }
        .frame(minWidth: 640, minHeight: 520)
        .sheet(isPresented: $showOnboarding) {
            OnboardingView { onboardingDone = true; showOnboarding = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSection)) { note in
            if let raw = note.userInfo?["section"] as? String, let target = DashboardSection(rawValue: raw) {
                section = target
                path = []
            }
        }
        .onAppear {
            if !onboardingDone, !model.isDemo { showOnboarding = true }
        }
    }

    private var page: some View {
        SectionPage(section: section, path: $path)
    }
}

/// The page for one sidebar section.
struct SectionPage: View {
    let section: DashboardSection
    @Binding var path: [Route]

    var body: some View {
        switch section {
        case .overview: OverviewView(path: $path)
        case .stats: StatsView(path: $path)
        case .timeline: TimelinePage()
        case .apps: RankingView(kind: .apps, path: $path)
        case .websites: RankingView(kind: .websites, path: $path)
        case .insights: InsightsView()
        case .focus: FocusView()
        case .limits: LimitsView()
        case .settings: SettingsView()
        }
    }
}

extension Notification.Name {
    static let openSection = Notification.Name("com.advait.timelens.openSection")
}

/// What you're on right now, pinned to the bottom of the sidebar.
private struct SidebarNow: View {
    private var model: AppModel { .shared }

    var body: some View {
        let live = model.live
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Right now").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                if live.counting { LiveDot() } else { LiveDot(color: Theme.muted) }
            }
            if let front = live.front, live.counting {
                HStack(spacing: 8) {
                    if !live.site.isEmpty {
                        SiteIconView(site: live.site, size: 22)
                    } else {
                        AppIconView(app: front.bundleID, size: 22)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(live.site.isEmpty ? front.name : model.siteName(live.site))
                            .font(.callout.weight(.medium)).lineLimit(1)
                        if let start = live.sessionStart {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                Text(DurationFormat.precise(context.date.timeIntervalSince1970 - start))
                                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else {
                Text(model.isDemo ? "Demo data — not tracking" : (live.reason?.title ?? "Waiting…"))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Text("Today").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(DurationFormat.short(model.todayTotal)).font(.callout.weight(.semibold)).monospacedDigit()
            }
        }
        .padding(12)
        .background(Theme.cardBackground.opacity(0.7), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.cardBorder))
    }
}

/// Day / week / month / year / custom, with ◀ ▶ to step through them.
struct PeriodBar: View {
    private var model: AppModel { .shared }
    @Binding var period: Period
    var kinds: [PeriodKind] = PeriodKind.allCases

    var body: some View {
        let calendar = model.prefs.calendar
        HStack(spacing: 10) {
            if kinds.count > 1 {
                Picker("Period", selection: $period.kind) {
                    ForEach(kinds) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            Spacer(minLength: 8)

            if period.kind == .custom {
                DatePicker("From", selection: $period.customStart, in: ...Date(), displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.field)
                Text("to").foregroundStyle(.secondary)
                DatePicker("To", selection: $period.customEnd, in: ...Date(), displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.field)
            }

            HStack(spacing: 2) {
                Button { period = period.shifted(by: -1, calendar) } label: {
                    Image(systemName: "chevron.left").frame(width: 22, height: 22)
                }
                .help("Previous")
                Text(period.title(calendar))
                    .font(.headline)
                    .monospacedDigit()
                    .frame(minWidth: 150)
                    .lineLimit(1)
                Button { period = period.shifted(by: 1, calendar) } label: {
                    Image(systemName: "chevron.right").frame(width: 22, height: 22)
                }
                .disabled(!period.canGoForward(calendar))
                .help("Next")
            }
            .buttonStyle(.borderless)

            if !period.isCurrent(calendar), period.kind != .custom {
                Button("Now") { period.anchor = .now }
                    .controlSize(.small)
            }
        }
    }
}

/// A scrolling dashboard page with a consistent width and padding, and a layout class for
/// children that re-flow.
struct Page<Header: View, Content: View>: View {
    var title: String
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content
    @State private var layout = LayoutClass.regular

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                content
            }
            .padding(24)
            .frame(maxWidth: 1400, alignment: .leading)
            .frame(maxWidth: .infinity)
            .environment(\.layoutClass, layout)
            .onWidthChange { layout = LayoutClass(width: $0 - 48) }
        }
        .navigationTitle(title)
    }
}

extension Page where Header == EmptyView {
    init(title: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, header: { EmptyView() }, content: content)
    }
}
