import AppKit
import SwiftUI

/// Debug aid: `--snapshot <section> <out-file> [height] [route]` renders one dashboard page
/// into a borderless window behind the desktop picture and writes its window number to `out-file`, so
/// `screencapture -l` can grab the whole page without touching what's on screen.
@MainActor
enum Snapshotter {
    private static var windows: [NSWindow] = []

    static func run(arguments: [String]) {
        guard arguments.count >= 2 else { return }
        let output = arguments[1]
        if arguments[0] == "window" {
            showDashboardWindow(output: output, section: arguments.count > 2 ? DashboardSection(rawValue: arguments[2]) : nil)
            return
        }
        if let special = special(arguments[0]) {
            show(special, size: NSSize(width: arguments[0] == "shield" ? 1100 : (arguments[0] == "menubar" ? 380 : 640), height: arguments.count > 2 ? CGFloat(Double(arguments[2]) ?? 900) : 900), output: output)
            return
        }
        guard let section = DashboardSection(rawValue: arguments[0]) else { return }
        let height = arguments.count > 2 ? CGFloat(Double(arguments[2]) ?? 3000) : 3000
        let route: Route? = arguments.count > 3 ? {
            let value = arguments[3]
            if value.hasPrefix("app:") { return .app(String(value.dropFirst(4))) }
            if value.hasPrefix("site:") { return .site(String(value.dropFirst(5))) }
            return nil
        }() : nil
        let dark = ProcessInfo.processInfo.environment["SNAPSHOT_LIGHT"] == nil
        let root = SnapshotHost(section: section, route: route)
            .environment(\.colorScheme, dark ? .dark : .light)
            .frame(width: 1060, height: height)
            .background(Color(nsColor: .windowBackgroundColor))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.isOpaque = true
        window.backgroundColor = dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.96, alpha: 1)
        window.contentView = NSHostingView(rootView: root)
        window.setFrame(NSRect(x: 0, y: 0, width: 1060, height: height), display: true)
        // Behind the desktop picture: rendered, but never seen.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        windows.append(window)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            try? "\(window.windowNumber)".write(toFile: output, atomically: true, encoding: .utf8)
        }
    }
}

extension Snapshotter {
    /// Views that aren't dashboard pages: the shield, the menu bar popover, onboarding.
    static func special(_ name: String) -> AnyView? {
        let model = AppModel.shared
        switch name {
        case "shield":
            let app = FrontApp(pid: 1, bundleID: "com.google.Chrome", name: "Google Chrome", bundleURL: nil)
            let request = ShieldRequest(reason: .limit(UsageLimit(id: 1, kind: .site, target: "youtube.com", minutes: 60)),
                                        targetName: "youtube.com", app: app, site: "youtube.com", used: 3720)
            return AnyView(ShieldView(request: request, showsContent: true, icon: model.directory.icon("com.google.Chrome")) { _ in })
        case "menubar":
            return AnyView(MenuBarContent())
        case "onboarding":
            return AnyView(OnboardingView {})
        default:
            return nil
        }
    }

    /// The real dashboard window, sidebar and toolbar included.
    static func showDashboardWindow(output: String, section: DashboardSection?) {
        if let section { UserDefaults.standard.set(section.rawValue, forKey: "dashboardSection") }
        let window = DashboardWindow.shared.prepared()
        // Don't let the off-screen copy overwrite the real window's saved frame.
        window.setFrameAutosaveName("")
        let dark = ProcessInfo.processInfo.environment["SNAPSHOT_LIGHT"] == nil
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        window.setFrame(NSRect(x: 0, y: 0, width: 1220, height: 860), display: true)
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            // Also draw the window in-process, for when the caller can't use screencapture.
            if let frame = window.contentView?.superview, let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
                frame.cacheDisplay(in: frame.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output + ".png"))
            }
            try? "\(window.windowNumber)".write(toFile: output, atomically: true, encoding: .utf8)
        }
    }

    static func show(_ view: AnyView, size: NSSize, output: String) {
        let dark = ProcessInfo.processInfo.environment["SNAPSHOT_LIGHT"] == nil
        let root = view
            .environment(\.colorScheme, dark ? .dark : .light)
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.isOpaque = true
        window.backgroundColor = dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.96, alpha: 1)
        window.contentView = NSHostingView(rootView: root)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        windows.append(window)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            try? "\(window.windowNumber)".write(toFile: output, atomically: true, encoding: .utf8)
        }
    }
}

private struct SnapshotHost: View {
    let section: DashboardSection
    let route: Route?
    @State private var path: [Route] = []

    var body: some View {
        NavigationStack(path: $path) {
            SectionPage(section: section, path: $path)
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case let .app(id): EntityDetailView(entity: .app(id))
                    case let .site(site): EntityDetailView(entity: .site(site))
                    }
                }
        }
        .onAppear { if let route { path = [route] } }
    }
}
