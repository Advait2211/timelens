import AppKit
import SwiftUI

@main
struct TimeLensApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Start tracking immediately, before any view asks for the model.
        MainActor.assumeIsolated {
            _ = AppModel.shared
            DashboardWindow.shared.listen()
        }
        AppearancePreference.saved.apply()

        let defaults = UserDefaults.standard
        let snapshot = CommandLine.arguments.firstIndex(of: "--snapshot")
        // Opened by hand (Finder, Spotlight, Dock): show the dashboard, since the menu bar item
        // may be hidden. Started at login: stay quietly in the menu bar.
        if snapshot == nil, !launchedAtLogin || !defaults.bool(forKey: "hasLaunchedBefore") {
            defaults.set(true, forKey: "hasLaunchedBefore")
            MainActor.assumeIsolated { DashboardWindow.shared.show() }
        }
        if let index = snapshot, index + 1 < CommandLine.arguments.count {
            MainActor.assumeIsolated { Snapshotter.run(arguments: Array(CommandLine.arguments[(index + 1)...])) }
        }
        // Start at login from now on — once, and only for an installed copy.
        if !defaults.bool(forKey: "loginItemConfigured"), LaunchAtLogin.isInstalled {
            defaults.set(true, forKey: "loginItemConfigured")
            try? LaunchAtLogin.set(true)
        }
    }

    /// Whether macOS started the app as a login item.
    private var launchedAtLogin: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.shutdown() }
    }

    /// Launching the app again while it's running (Finder, Spotlight) opens the dashboard.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { DashboardWindow.shared.show() }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
