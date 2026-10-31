import AppKit
import CoreGraphics
import Darwin
import IOKit.pwr_mgt

/// The frontmost app at one instant.
struct FrontApp: Equatable {
    let pid: pid_t
    let bundleID: String
    let name: String
    let bundleURL: URL?

    static func current() -> FrontApp? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let id = app.bundleIdentifier ?? app.executableURL.map { "proc:" + $0.lastPathComponent } ?? "proc:unknown"
        return FrontApp(pid: app.processIdentifier, bundleID: id, name: app.localizedName ?? id, bundleURL: app.bundleURL)
    }
}

/// Lock, display and input state, read straight from the window server and power manager.
enum SystemSignals {
    /// The login window or screensaver is in front of everything.
    static let lockScreenApps: Set<String> = [
        "com.apple.loginwindow", "com.apple.ScreenSaver.Engine", "com.apple.screensaver",
        "com.apple.SecurityAgent", "proc:loginwindow", "proc:ScreenSaverEngine",
    ]

    static func isScreenLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if (session["CGSSessionScreenIsLocked"] as? Bool) == true { return true }
        // Another user is on the console (fast user switching).
        if let onConsole = session[kCGSessionOnConsoleKey as String] as? Bool, !onConsole { return true }
        return false
    }

    static func displaysAsleep() -> Bool {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return false }
        return displays.prefix(Int(count)).allSatisfy { CGDisplayIsAsleep($0) != 0 }
    }

    /// Seconds since the last keyboard, mouse, trackpad or tablet input. Needs no permission.
    static func secondsSinceInput() -> Double {
        let anyInput = CGEventType(rawValue: ~0)!
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    // MARK: Video and calls

    /// Assertion names that are held all the time and say nothing about whether you're
    /// watching (WhatsApp keeps one open whenever it runs).
    static let ignoredAssertionNames = ["idletimer", "caffeinate", "Powerd", "com.apple.powermanagement"]

    /// Apps whose display-sleep assertions mean "someone is watching or talking": players,
    /// meeting apps, and anything a browser does (video in a tab).
    static let mediaApps: Set<String> = [
        "us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams", "com.apple.FaceTime", "com.apple.TV",
        "com.apple.QuickTimePlayerX", "org.videolan.vlc", "com.colliderli.iina", "tv.plex.desktop",
        "com.netflix.Netflix", "com.amazon.aiv.AIVApp", "com.disney.disneyplus", "com.hnc.Discord",
        "com.tinyspeck.slackmacgap", "net.whatsapp.WhatsApp", "desktop.WhatsApp", "com.apple.Photos",
        "com.apple.Keynote", "com.apple.iWork.Keynote", "com.microsoft.Powerpoint", "com.webex.meetingmanager",
        "com.cisco.webexmeetingsapp", "com.google.Chrome.app.meet", "com.apple.podcasts", "com.apple.Music",
    ]

    /// Whether the frontmost app (or one of its helper processes) is playing video or is in a
    /// call right now.
    static func mediaPlaying(in app: FrontApp, isBrowser: Bool) -> Bool {
        guard isBrowser || mediaApps.contains(app.bundleID) || app.bundleID.hasPrefix("com.google.Chrome.app.") else { return false }
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
              let byProcess = unmanaged?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return false }

        let bundlePath = app.bundleURL?.path
        let usesWebKit = app.bundleID.hasPrefix("com.apple.Safari") || app.bundleID == "com.kagi.kagimacOS"
        for (pidNumber, assertions) in byProcess {
            let pid = pidNumber.int32Value
            for assertion in assertions {
                let type = assertion["AssertType"] as? String ?? ""
                let name = assertion["AssertName"] as? String ?? ""
                if ignoredAssertionNames.contains(where: { name.contains($0) }) { continue }
                let onBehalf = (assertion["AssertionOnBehalfOfPID"] as? NSNumber)?.int32Value

                let belongs: Bool = {
                    if pid == app.pid || onBehalf == app.pid { return true }
                    guard let path = processPath(onBehalf ?? pid) else { return false }
                    if let bundlePath, path.hasPrefix(bundlePath) { return true }
                    return usesWebKit && path.contains("com.apple.WebKit")
                }()
                guard belongs else { continue }

                if type == "PreventUserIdleDisplaySleep" || type == "NoDisplaySleepAssertion" {
                    return true
                }
                // A call: the audio server holds the microphone on the app's behalf.
                if let resources = assertion["ResourcesUsed"] as? [String],
                   resources.contains(where: { $0.localizedCaseInsensitiveContains("microphone") || $0.localizedCaseInsensitiveContains("audio-in") }) {
                    return true
                }
            }
        }
        return false
    }

    private static var pathCache: [pid_t: String] = [:]
    private static let pathLock = NSLock()

    static func processPath(_ pid: pid_t) -> String? {
        pathLock.lock()
        defer { pathLock.unlock() }
        if let cached = pathCache[pid] { return cached }
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(cString: buffer)
        if pathCache.count > 500 { pathCache.removeAll() }
        pathCache[pid] = path
        return path
    }
}
