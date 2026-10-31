import AppKit
import TimeLensCore

enum PrivateMode: String, CaseIterable, Identifiable {
    /// Counts toward the browser as "Private browsing", with no site or title kept.
    case label
    /// Tracked like any other window.
    case track
    /// Not counted at all.
    case ignore

    var id: String { rawValue }

    var title: String {
        switch self {
        case .label: "Log as “Private browsing”"
        case .track: "Track sites normally"
        case .ignore: "Don't count"
        }
    }
}

enum AwayReason: String {
    case locked, asleep, screenOff, excluded, shield, privateWindow, noApp, paused, idle

    var title: String {
        switch self {
        case .locked: "Screen locked"
        case .asleep: "Asleep"
        case .screenOff: "Display off"
        case .excluded: "Excluded app"
        case .shield: "Paused by a limit or focus session"
        case .privateWindow: "Private window (not counted)"
        case .noApp: "Nothing in front"
        case .paused: "Tracking paused"
        case .idle: "Idle"
        }
    }
}

struct TrackerSettings: Equatable {
    var idleThreshold: Double = 120
    var honorMedia = true
    var privateMode: PrivateMode = .label
    var trackTitles = true
    var excluded: Set<String> = []
    var paused = false
}

/// What's happening right now, published to the UI whenever it changes.
struct LiveSnapshot: Equatable {
    var front: FrontApp?
    var site: String = ""
    var title: String?
    var counting = false
    var reason: AwayReason?
    /// When you started on this app (or site) without a break.
    var sessionStart: Double?
    /// When the current run of activity began.
    var activeSince: Double?
    var mediaPlaying = false

    var app: String? { front?.bundleID }
}

/// Samples what's in front of you every second and turns it into segments.
///
/// Everything runs on one serial queue. The UI hears about changes through `onLive` and
/// `onFlush`, always on the main queue.
final class ActivityTracker: @unchecked Sendable {
    let store: ActivityStore
    let browser = BrowserReader()

    var onLive: ((LiveSnapshot) -> Void)?
    var onFlush: (() -> Void)?
    var onNewApp: ((AppRecord) -> Void)?
    var onPickup: (() -> Void)?

    private let queue = DispatchQueue(label: "com.advait.timelens.tracker", qos: .utility)
    private var timer: DispatchSourceTimer?
    /// Seconds between ticks: 1 while there's something to track, longer while the Mac is locked,
    /// dark or paused. The notifications for coming back tick right away.
    private var interval: Int = 1
    /// The last media check, reused for a few seconds: it reads every power assertion on the system.
    private var lastMediaCheck: (pid: pid_t, time: Double, playing: Bool)?
    private let builder: SegmentBuilder
    private var settings = TrackerSettings()
    private var shieldActive = false
    private var systemAsleep = false
    private var ticksSinceFlush = 0
    private var live = LiveSnapshot()
    private var lastAwayReason: AwayReason? = .noApp
    private var awaySince: Double?
    private var knownApps: Set<String>
    private var observers: [NSObjectProtocol] = []

    init(store: ActivityStore) {
        self.store = store
        let ids = store.nextIDs()
        builder = SegmentBuilder(nextUsageID: ids.usage, nextDetailID: ids.detail)
        knownApps = Set(store.apps().map(\.id))
    }

    // MARK: Control

    func start() {
        observeSystem()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // Each tick stamps its own time, so the leeway only lets macOS batch wakeups.
        timer.schedule(deadline: .now() + 0.5, repeating: .seconds(interval), leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    func update(_ settings: TrackerSettings) {
        queue.async {
            let resumed = self.settings.paused && !settings.paused
            self.settings = settings
            self.builder.config.idleThreshold = settings.idleThreshold
            self.builder.config.honorMedia = settings.honorMedia
            // Paused ticks are slow; pick up again on the spot.
            if resumed { self.tick() }
        }
    }

    func setShield(active: Bool) {
        queue.async {
            guard self.shieldActive != active else { return }
            self.shieldActive = active
            self.tick()
        }
    }

    /// Writes everything out before the app quits.
    func stop() {
        queue.sync {
            timer?.cancel()
            builder.closeAll(at: Date().timeIntervalSince1970)
            store.apply(builder.takeChanges(), synchronously: true)
        }
    }

    /// A tick right away — when the frontmost app changes, so switches land on time.
    func tickSoon() {
        queue.async { self.tick() }
    }

    // MARK: Sampling

    private func tick() {
        let now = Date().timeIntervalSince1970
        let front = FrontApp.current()
        var reason: AwayReason?
        var activity: Activity?
        var mediaPlaying = false

        if systemAsleep {
            reason = .asleep
        } else if SystemSignals.isScreenLocked() {
            reason = .locked
        } else if SystemSignals.displaysAsleep() {
            reason = .screenOff
        } else if let front, SystemSignals.lockScreenApps.contains(front.bundleID) {
            reason = .locked
        } else if settings.paused {
            reason = .paused
        } else if let front {
            if settings.excluded.contains(front.bundleID) {
                reason = .excluded
            } else {
                let observed = sample(front, now: now)
                activity = observed.activity
                reason = observed.reason
                if shieldActive {
                    reason = .shield
                    live.site = observed.activity?.site ?? ""
                }
            }
        } else {
            reason = .noApp
        }

        let idleSeconds = SystemSignals.secondsSinceInput()
        if let front, activity != nil, reason == nil, settings.honorMedia, idleSeconds > 20 {
            mediaPlaying = self.mediaPlaying(in: front, now: now)
        }

        let counted = reason == nil ? activity : nil
        let transitions = builder.tick(Sample(time: now, activity: counted, idleSeconds: idleSeconds, mediaPlaying: mediaPlaying))
        if builder.state == .idle, reason == nil { reason = .idle }

        handle(transitions, reason: reason, now: now, front: front, activity: activity)
        publish(front: front, activity: activity, reason: reason, mediaPlaying: mediaPlaying, now: now)

        ticksSinceFlush += 1
        if ticksSinceFlush >= 5 || !transitions.isEmpty {
            flush()
        }
        pace(for: reason)
    }

    /// Slows ticking while nothing can be tracked. Nothing is open then, so the longer gaps
    /// don't cut a segment short.
    private func pace(for reason: AwayReason?) {
        let away: Set<AwayReason> = [.locked, .asleep, .screenOff, .paused]
        let wanted = reason.map(away.contains) == true ? 10 : 1
        guard wanted != interval else { return }
        interval = wanted
        timer?.schedule(deadline: .now() + .seconds(wanted), repeating: .seconds(wanted), leeway: .milliseconds(wanted == 1 ? 250 : 1000))
    }

    /// Whether the frontmost app is playing video or in a call. A stale answer only moves when
    /// idle starts by a few seconds, against a threshold of minutes.
    private func mediaPlaying(in front: FrontApp, now: Double) -> Bool {
        if let last = lastMediaCheck, last.pid == front.pid, now - last.time < 5 { return last.playing }
        let playing = SystemSignals.mediaPlaying(in: front, isBrowser: BrowserReader.family(of: front.bundleID) != nil)
        lastMediaCheck = (front.pid, now, playing)
        return playing
    }

    /// What the frontmost app is showing: for browsers the site and page, otherwise the
    /// window title.
    private func sample(_ front: FrontApp, now: Double) -> (activity: Activity?, reason: AwayReason?) {
        rememberApp(front)
        if BrowserReader.family(of: front.bundleID) != nil {
            guard let reading = browser.reading(for: front), let parsed = SiteKey.parse(reading.url) else {
                // Unknown tab (no window yet, or no permission): time goes to the browser itself.
                let title = settings.trackTitles ? TitleCleaner.clean(Accessibility.focusedWindowTitle(front.pid), appName: front.name) : nil
                return (Activity(app: front.bundleID, site: "", title: title), nil)
            }
            if reading.isPrivate {
                switch settings.privateMode {
                case .label: return (Activity(app: front.bundleID, site: SiteKey.privateSite), nil)
                case .ignore: return (nil, .privateWindow)
                case .track: break
                }
            }
            let title = settings.trackTitles ? TitleCleaner.clean(reading.title, appName: front.name) : nil
            return (Activity(app: front.bundleID, site: parsed.site, title: title, page: settings.trackTitles ? parsed.page : nil), nil)
        }
        let title = settings.trackTitles ? TitleCleaner.clean(Accessibility.focusedWindowTitle(front.pid), appName: front.name) : nil
        return (Activity(app: front.bundleID, title: title), nil)
    }

    private func handle(_ transitions: [TrackerTransition], reason: AwayReason?, now: Double, front: FrontApp?, activity: Activity?) {
        // Pickups: back at the Mac after it was locked, asleep or dark for a while.
        let unavailable: Set<AwayReason> = [.locked, .asleep, .screenOff]
        if let reason, unavailable.contains(reason) {
            if lastAwayReason == nil || !unavailable.contains(lastAwayReason!) { awaySince = now }
        } else if reason == nil || reason == .idle || reason == .excluded {
            if let since = awaySince, let last = lastAwayReason, unavailable.contains(last), now - since >= 10 {
                store.addEvent(.pickup, at: now, app: front?.bundleID ?? "", site: activity?.site ?? "")
                DispatchQueue.main.async { self.onPickup?() }
            }
            awaySince = nil
        }
        lastAwayReason = reason

        for transition in transitions {
            switch transition {
            case let .wentIdle(since):
                store.addEvent(.idle, at: since, app: front?.bundleID ?? "")
            case let .resumed(at):
                store.addEvent(.resume, at: at, app: front?.bundleID ?? "")
            case .wentAway:
                break
            }
        }
    }

    private func publish(front: FrontApp?, activity: Activity?, reason: AwayReason?, mediaPlaying: Bool, now: Double) {
        var next = live
        let counting = reason == nil
        let sameRun = next.front?.bundleID == front?.bundleID && next.site == (activity?.site ?? "") && next.counting && counting
        next.front = front
        next.site = activity?.site ?? (reason == .shield ? live.site : "")
        next.title = activity?.title
        next.counting = counting
        next.reason = reason
        next.sessionStart = counting ? (sameRun ? live.sessionStart ?? now : now) : nil
        next.activeSince = builder.activeSince
        next.mediaPlaying = mediaPlaying
        guard next != live else { return }
        live = next
        DispatchQueue.main.async { self.onLive?(next) }
    }

    private func flush() {
        ticksSinceFlush = 0
        let changes = builder.takeChanges()
        guard !changes.isEmpty else { return }
        store.apply(changes)
        // The store queue is serial, so the notification follows the write.
        store.runAsync { _ in
            DispatchQueue.main.async { self.onFlush?() }
        }
    }

    private func rememberApp(_ front: FrontApp) {
        guard !knownApps.contains(front.bundleID) else { return }
        knownApps.insert(front.bundleID)
        let bundle = front.bundleURL.flatMap(Bundle.init(url:))
        let declared = bundle?.infoDictionary?["LSApplicationCategoryType"] as? String ?? ""
        let record = AppRecord(id: front.bundleID, name: front.name, path: front.bundleURL?.path ?? "", declaredCategory: declared)
        store.saveApp(record)
        DispatchQueue.main.async { self.onNewApp?(record) }
    }

    // MARK: System events

    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()

        observers.append(workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil) { [weak self] _ in
            self?.tickSoon()
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            queue.sync {
                self.systemAsleep = true
                let now = Date().timeIntervalSince1970
                self.builder.closeAll(at: now)
                self.store.addEvent(.sleep, at: now)
                self.flush()
            }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            queue.async {
                self.systemAsleep = false
                self.store.addEvent(.wake)
                self.tick()
            }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: nil) { [weak self] _ in
            self?.store.addEvent(.screenOff)
            self?.tickSoon()
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.store.addEvent(.screenOn)
            self?.tickSoon()
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: nil) { [weak self] _ in
            self?.tickSoon()
        })
        observers.append(distributed.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: nil) { [weak self] _ in
            self?.store.addEvent(.lock)
            self?.tickSoon()
        })
        observers.append(distributed.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: nil) { [weak self] _ in
            self?.store.addEvent(.unlock)
            self?.tickSoon()
        })
    }
}
