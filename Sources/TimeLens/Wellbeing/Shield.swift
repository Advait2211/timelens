import AppKit
import SwiftUI
import TimeLensCore

/// What the shield is covering and why.
struct ShieldRequest: Equatable {
    enum Reason: Equatable {
        case limit(UsageLimit)
        case focus(endsAt: Double)
    }

    let reason: Reason
    /// What's blocked: "YouTube", "Google Chrome", "Entertainment".
    let targetName: String
    /// The frontmost app underneath.
    let app: FrontApp
    let site: String
    /// Used today on the blocked target.
    let used: Double

    /// Same shield, ignoring the ticking usage number.
    func sameTarget(as other: ShieldRequest?) -> Bool {
        guard let other else { return false }
        return reason == other.reason && targetName == other.targetName && app.pid == other.app.pid && site == other.site
    }

    var isWebsite: Bool { !site.isEmpty && !SiteKey.isPseudo(site) }
}

enum ShieldAction {
    case leave           // close the tab or hide the app
    case snooze(minutes: Int)
    case ignoreToday
    case endFocus
}

/// Full-screen panels over every display. They never take focus from the app underneath
/// (non-activating), so the tracker still knows what's behind them — and time with a shield
/// up doesn't count.
@MainActor
final class ShieldController {
    private var panels: [NSPanel] = []
    private(set) var current: ShieldRequest?
    var onAction: ((ShieldAction, ShieldRequest) -> Void)?

    var isVisible: Bool { !panels.isEmpty }

    func show(_ request: ShieldRequest, directory: AppDirectory) {
        if request.sameTarget(as: current), isVisible {
            current = request
            return
        }
        hide()
        current = request
        for screen in NSScreen.screens {
            let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.isMovable = false
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = true
            panel.isReleasedWhenClosed = false
            let isMain = screen == NSScreen.main
            let view = ShieldView(request: request, showsContent: isMain, icon: directory.icon(request.app.bundleID)) { [weak self] action in
                guard let self, let current = self.current else { return }
                self.onAction?(action, current)
            }
            panel.contentView = NSHostingView(rootView: view)
            panel.setFrame(screen.frame, display: true)
            panel.orderFrontRegardless()
            panels.append(panel)
        }
    }

    func hide() {
        for panel in panels { panel.orderOut(nil) }
        panels.removeAll()
        current = nil
    }
}

struct ShieldView: View {
    let request: ShieldRequest
    let showsContent: Bool
    let icon: NSImage?
    let act: (ShieldAction) -> Void

    var body: some View {
        ZStack {
            VisualEffectBackground()
            Color.black.opacity(0.35)
            if showsContent { content }
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
    }

    private var content: some View {
        VStack(spacing: 22) {
            ZStack(alignment: .bottomTrailing) {
                if let icon {
                    Image(nsImage: icon).resizable().frame(width: 96, height: 96)
                } else {
                    Image(systemName: "hourglass").font(.system(size: 64)).foregroundStyle(.white)
                }
                Image(systemName: symbol)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(Circle().fill(badgeColor))
                    .offset(x: 10, y: 8)
            }
            VStack(spacing: 8) {
                Text(headline)
                    .font(.system(size: 34, weight: .bold))
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }
            if case let .focus(endsAt) = request.reason {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(DurationFormat.clock(endsAt - context.date.timeIntervalSince1970))
                        .font(.system(size: 54, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
            }
            HStack(spacing: 12) {
                Button(action: { act(.leave) }) {
                    Label(request.isWebsite ? "Close tab" : "Hide \(request.app.name)", systemImage: request.isWebsite ? "xmark.square" : "eye.slash")
                        .frame(minWidth: 160)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.extraLarge)
                .keyboardShortcut(.defaultAction)

                switch request.reason {
                case .limit:
                    Button("15 more minutes") { act(.snooze(minutes: 15)) }
                        .controlSize(.extraLarge)
                    Button("Ignore limit today") { act(.ignoreToday) }
                        .controlSize(.extraLarge)
                case .focus:
                    Button("End focus session") { act(.endFocus) }
                        .controlSize(.extraLarge)
                }
            }
            .padding(.top, 6)
        }
        .foregroundStyle(.white)
        .padding(48)
    }

    private var symbol: String {
        switch request.reason {
        case .limit: "hourglass.bottomhalf.filled"
        case .focus: "moon.fill"
        }
    }

    private var badgeColor: Color {
        switch request.reason {
        case .limit: Color(red: 0.82, green: 0.23, blue: 0.23)
        case .focus: Color(red: 0.38, green: 0.31, blue: 0.84)
        }
    }

    private var headline: String {
        switch request.reason {
        case .limit: "Time's up on \(request.targetName)"
        case .focus: "\(request.targetName) is blocked while you focus"
        }
    }

    private var message: String {
        switch request.reason {
        case let .limit(limit):
            "You've spent \(DurationFormat.short(request.used)) here today. Your daily limit is \(DurationFormat.short(limit.seconds))."
        case .focus:
            "Your focus session is still running. Get back to it — this will still be here when you're done."
        }
    }
}

private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .fullScreenUI
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
