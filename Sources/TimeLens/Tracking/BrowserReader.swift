import AppKit
import Foundation

enum BrowserFamily: String {
    /// Chrome, Brave, Edge, Arc, Vivaldi, Opera: scriptable tabs with an incognito `mode`.
    case chromium
    /// Safari and Safari-compatible browsers.
    case safari
    /// Firefox and its forks: no scripting, so the address bar is read via Accessibility.
    case firefox
}

struct BrowserReading: Equatable {
    var url: String
    var title: String?
    var isPrivate: Bool
}

enum AutomationStatus: String {
    case unknown, allowed, denied, notRunning
}

/// Reads the URL and title of the tab you're looking at.
///
/// AppleScript calls run on one dedicated thread (OSA isn't safe to call from many), and the
/// tracker never waits more than a moment for them: the first call to a browser can block on
/// the system's permission prompt for as long as the prompt is up.
final class BrowserReader: @unchecked Sendable {
    static let browsers: [String: (family: BrowserFamily, name: String)] = [
        "com.google.Chrome": (.chromium, "Google Chrome"),
        "com.google.Chrome.beta": (.chromium, "Chrome Beta"),
        "com.google.Chrome.dev": (.chromium, "Chrome Dev"),
        "com.google.Chrome.canary": (.chromium, "Chrome Canary"),
        "org.chromium.Chromium": (.chromium, "Chromium"),
        "com.brave.Browser": (.chromium, "Brave"),
        "com.brave.Browser.beta": (.chromium, "Brave Beta"),
        "com.brave.Browser.nightly": (.chromium, "Brave Nightly"),
        "com.microsoft.edgemac": (.chromium, "Microsoft Edge"),
        "com.microsoft.edgemac.Beta": (.chromium, "Edge Beta"),
        "com.microsoft.edgemac.Dev": (.chromium, "Edge Dev"),
        "company.thebrowser.Browser": (.chromium, "Arc"),
        "company.thebrowser.dia": (.chromium, "Dia"),
        "com.vivaldi.Vivaldi": (.chromium, "Vivaldi"),
        "com.operasoftware.Opera": (.chromium, "Opera"),
        "com.operasoftware.OperaGX": (.chromium, "Opera GX"),
        "ai.perplexity.comet": (.chromium, "Comet"),
        "com.apple.Safari": (.safari, "Safari"),
        "com.apple.SafariTechnologyPreview": (.safari, "Safari Technology Preview"),
        "com.kagi.kagimacOS": (.safari, "Orion"),
        "org.mozilla.firefox": (.firefox, "Firefox"),
        "org.mozilla.firefoxdeveloperedition": (.firefox, "Firefox Developer Edition"),
        "org.mozilla.nightly": (.firefox, "Firefox Nightly"),
        "app.zen-browser.zen": (.firefox, "Zen"),
        "io.gitlab.librewolf-community": (.firefox, "LibreWolf"),
        "net.waterfox.waterfox": (.firefox, "Waterfox"),
        "net.mullvad.mullvadbrowser": (.firefox, "Mullvad Browser"),
        "org.torproject.torbrowser": (.firefox, "Tor Browser"),
    ]

    static func family(of bundleID: String) -> BrowserFamily? { browsers[bundleID]?.family }

    private let thread = ScriptThread()
    private let lock = NSLock()
    private var cache: [pid_t: (reading: BrowserReading?, time: Double)] = [:]
    private var inFlight: Set<pid_t> = []
    private var scripts: [String: NSAppleScript] = [:]   // touched only on `thread`
    private var status: [String: (AutomationStatus, Double)] = [:]

    init() {
        thread.start()
    }

    /// The reading for the frontmost browser. Waits up to `wait` for a fresh one; otherwise
    /// returns the last one from the past few seconds.
    func reading(for app: FrontApp, wait: TimeInterval = 0.3) -> BrowserReading? {
        guard let family = Self.family(of: app.bundleID) else { return nil }
        let now = Date().timeIntervalSince1970

        lock.lock()
        let alreadyRunning = inFlight.contains(app.pid)
        if !alreadyRunning { inFlight.insert(app.pid) }
        lock.unlock()

        if !alreadyRunning {
            let done = DispatchSemaphore(value: 0)
            thread.enqueue { [self] in
                let reading = read(app, family: family)
                lock.lock()
                cache[app.pid] = (reading, Date().timeIntervalSince1970)
                inFlight.remove(app.pid)
                lock.unlock()
                done.signal()
            }
            _ = done.wait(timeout: .now() + wait)
        }

        lock.lock()
        defer { lock.unlock() }
        guard let cached = cache[app.pid], now - cached.time < 4 else { return nil }
        return cached.reading
    }

    func automationStatus(_ bundleID: String) -> AutomationStatus {
        lock.lock()
        defer { lock.unlock() }
        return status[bundleID]?.0 ?? .unknown
    }

    // MARK: Reading (on the script thread)

    private func read(_ app: FrontApp, family: BrowserFamily) -> BrowserReading? {
        switch family {
        case .firefox:
            return readAddressBar(app, privateMarker: "Private Browsing")
        case .chromium, .safari:
            // Recently denied: don't ask again every second, read the address bar instead.
            lock.lock()
            let known = status[app.bundleID]
            lock.unlock()
            if let known, known.0 == .denied, Date().timeIntervalSince1970 - known.1 < 30 {
                return readAddressBar(app, privateMarker: nil)
            }
            if let reading = runScript(app, family: family) { return reading }
            if automationStatus(app.bundleID) == .denied { return readAddressBar(app, privateMarker: nil) }
            return nil
        }
    }

    private func runScript(_ app: FrontApp, family: BrowserFamily) -> BrowserReading? {
        let script: NSAppleScript
        if let cached = scripts[app.bundleID] {
            script = cached
        } else {
            guard let made = NSAppleScript(source: Self.source(for: app.bundleID, family: family)) else { return nil }
            var compileError: NSDictionary?
            guard made.compileAndReturnError(&compileError) else { return nil }
            scripts[app.bundleID] = made
            script = made
        }

        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            let outcome: AutomationStatus = switch code {
            case -1743, -10004: .denied
            case -600, -609: .notRunning
            default: automationStatus(app.bundleID) == .denied ? .denied : .allowed
            }
            setStatus(outcome, for: app.bundleID)
            return nil
        }
        setStatus(.allowed, for: app.bundleID)
        guard let text = result.stringValue, !text.isEmpty else { return nil }
        let parts = text.components(separatedBy: "\n")
        guard let url = parts.first, !url.isEmpty, url != "missing value" else { return nil }
        let title = parts.count > 1 ? parts[1] : nil
        let mode = parts.count > 2 ? parts[2] : "normal"
        return BrowserReading(url: url, title: title == "missing value" ? nil : title, isPrivate: mode == "incognito" || mode == "private")
    }

    private func setStatus(_ value: AutomationStatus, for bundleID: String) {
        lock.lock()
        status[bundleID] = (value, Date().timeIntervalSince1970)
        lock.unlock()
    }

    private func readAddressBar(_ app: FrontApp, privateMarker: String?) -> BrowserReading? {
        guard let bar = Accessibility.addressBarValue(pid: app.pid) else { return nil }
        let title = bar.windowTitle
        let isPrivate = privateMarker.map { marker in title?.contains(marker) == true } ?? false
        var cleanTitle = title
        if let marker = privateMarker, let range = cleanTitle?.range(of: " — \(marker)") ?? cleanTitle?.range(of: " - \(marker)") {
            cleanTitle?.removeSubrange(range.lowerBound...)
        }
        return BrowserReading(url: bar.value, title: cleanTitle, isPrivate: isPrivate)
    }

    private static func source(for bundleID: String, family: BrowserFamily) -> String {
        switch family {
        case .chromium:
            return """
            tell application id "\(bundleID)"
                with timeout of 2 seconds
                    if (count of windows) is 0 then return ""
                    set w to front window
                    set u to URL of active tab of w
                    set t to ""
                    try
                        set t to title of active tab of w
                    end try
                    set m to "normal"
                    try
                        set m to mode of w
                    end try
                    return u & linefeed & t & linefeed & m
                end timeout
            end tell
            """
        case .safari, .firefox:
            return """
            tell application id "\(bundleID)"
                with timeout of 2 seconds
                    if (count of windows) is 0 then return ""
                    set w to front window
                    set u to URL of current tab of w
                    set t to ""
                    try
                        set t to name of current tab of w
                    end try
                    return u & linefeed & t & linefeed & "normal"
                end timeout
            end tell
            """
        }
    }

    // MARK: Actions

    /// Closes the tab you're looking at (for the shield's "Close tab"). Firefox gets ⌘W.
    func closeActiveTab(of app: FrontApp) {
        guard let family = Self.family(of: app.bundleID) else { return }
        thread.enqueue {
            switch family {
            case .chromium:
                Self.runOnce("tell application id \"\(app.bundleID)\" to close active tab of front window")
            case .safari:
                Self.runOnce("tell application id \"\(app.bundleID)\" to close current tab of front window")
            case .firefox:
                Self.pressCommandW(pid: app.pid)
            }
        }
    }

    private static func runOnce(_ source: String) {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
    }

    private static func pressCommandW(pid: pid_t) {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyW: CGKeyCode = 13
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: keyW, keyDown: down)
            event?.flags = .maskCommand
            event?.postToPid(pid)
        }
    }

    /// Asks macOS whether TimeLens may script the browser, showing the prompt if it hasn't
    /// been answered. Call off the main thread.
    static func requestAutomation(bundleID: String) -> AutomationStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let desc = target.aeDesc else { return .unknown }
        let status = AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, true)
        switch status {
        case noErr: return .allowed
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(procNotFound): return .notRunning
        default: return .unknown
        }
    }

    /// The current answer without prompting.
    static func checkAutomation(bundleID: String) -> AutomationStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let desc = target.aeDesc else { return .unknown }
        let status = AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, false)
        switch status {
        case noErr: return .allowed
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(procNotFound): return .notRunning
        default: return .unknown
        }
    }
}

/// One long-lived thread that runs jobs in order.
final class ScriptThread: Thread, @unchecked Sendable {
    private let condition = NSCondition()
    private var jobs: [() -> Void] = []

    override init() {
        super.init()
        name = "com.advait.timelens.scripts"
        qualityOfService = .utility
    }

    override func main() {
        while true {
            condition.lock()
            while jobs.isEmpty { condition.wait() }
            let job = jobs.removeFirst()
            condition.unlock()
            autoreleasepool { job() }
        }
    }

    func enqueue(_ job: @escaping () -> Void) {
        condition.lock()
        jobs.append(job)
        condition.signal()
        condition.unlock()
    }
}
