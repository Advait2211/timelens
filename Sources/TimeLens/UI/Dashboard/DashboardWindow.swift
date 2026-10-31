import AppKit
import SwiftUI

/// Owns the dashboard window. It's an AppKit window rather than a SwiftUI `Window` scene so
/// it can always be opened from the app delegate and notifications, even when the menu bar
/// item is hidden (behind the notch, or by a menu bar manager) and its views never run.
@MainActor
final class DashboardWindow: NSObject, NSWindowDelegate {
    static let shared = DashboardWindow()

    private var window: NSWindow?

    /// Opens the dashboard whenever anything posts `.openDashboard`.
    func listen() {
        NotificationCenter.default.addObserver(forName: .openDashboard, object: nil, queue: .main) { note in
            let section = (note.userInfo?["section"] as? String).flatMap(DashboardSection.init(rawValue:))
            MainActor.assumeIsolated { DashboardWindow.shared.show(section: section) }
        }
    }

    func show(section: DashboardSection? = nil) {
        if let section {
            UserDefaults.standard.set(section.rawValue, forKey: "dashboardSection")
            NotificationCenter.default.post(name: .openSection, object: nil, userInfo: ["section": section.rawValue])
        }
        let window = prepared()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // Coming from the accessory policy, activation can land a beat after the window.
        DispatchQueue.main.async { window.orderFrontRegardless() }
    }

    /// The window, created on first use but not yet shown.
    func prepared() -> NSWindow {
        if let window { return window }
        let window = makeWindow()
        self.window = window
        return window
    }

    private func makeWindow() -> NSWindow {
        let host = NSHostingController(rootView: DashboardView())
        host.sizingOptions = [.minSize]
        host.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.title = "TimeLens"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(NSSize(width: 1220, height: 860))
        if !window.setFrameUsingName("TimeLensDashboard") { window.center() }
        window.setFrameAutosaveName("TimeLensDashboard")
        return window
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Tear the view tree down like a closed scene does, so its pages stop refreshing.
        DispatchQueue.main.async { [self] in
            guard let window, !window.isVisible else { return }
            window.contentViewController = nil
            self.window = nil
        }
    }
}
