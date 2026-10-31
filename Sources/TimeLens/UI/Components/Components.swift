import AppKit
import SwiftUI
import TimeLensCore

// MARK: Formatting

enum TimeText {
    static func time(_ seconds: Double) -> String {
        Date(timeIntervalSince1970: seconds).formatted(date: .omitted, time: .shortened)
    }

    static func range(_ start: Double, _ end: Double) -> String {
        "\(time(start)) – \(time(end))"
    }

    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    static func percent(_ fraction: Double) -> String {
        let value = fraction * 100
        if value > 0, value < 1 { return "<1%" }
        return "\(Int(value.rounded()))%"
    }

    /// Hour-of-day label, "9 AM" / "21".
    static func hour(_ hour: Int) -> String {
        InsightEngine.hourLabel(hour)
    }

    private static let uses12Hour: Bool = {
        let format = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? ""
        return format.contains("a")
    }()

    /// Axis label that fits under a narrow bar: "12a", "3p" — or "00", "15".
    static func shortHour(_ hour: Int) -> String {
        guard uses12Hour else { return String(format: "%02d", hour) }
        let twelve = hour % 12 == 0 ? 12 : hour % 12
        return "\(twelve)\(hour < 12 ? "a" : "p")"
    }
}

// MARK: Icons

/// An app's icon, or a neutral tile when the app isn't installed.
struct AppIconView: View {
    private var model: AppModel { .shared }
    let app: String
    var size: CGFloat = 24

    var body: some View {
        if let icon = model.directory.icon(app) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(Theme.track)
                .frame(width: size * 0.84, height: size * 0.84)
                .overlay(Image(systemName: "app.dashed").font(.system(size: size * 0.45)).foregroundStyle(.secondary))
                .frame(width: size, height: size)
        }
    }
}

/// A website's icon, fetched from the site itself and cached; a letter tile until then.
struct SiteIconView: View {
    let site: String
    var size: CGFloat = 24
    @State private var image: NSImage?
    @State private var fullBleed = false

    var body: some View {
        Group {
            if let symbol = pseudoSymbol {
                tile { Image(systemName: symbol).font(.system(size: size * 0.48, weight: .semibold)).foregroundStyle(.secondary) }
            } else if let image {
                if fullBleed {
                    Image(nsImage: image).resizable().interpolation(.high)
                        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
                } else {
                    tile { Image(nsImage: image).resizable().interpolation(.high).frame(width: size * 0.62, height: size * 0.62) }
                }
            } else {
                tile {
                    Text(site.first.map { String($0).uppercased() } ?? "?")
                        .font(.system(size: size * 0.46, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .task(id: site) {
            guard pseudoSymbol == nil else { return }
            let host = site.split(separator: ":").first.map(String.init) ?? site
            guard !SiteKey.isLocal(host) else { return }
            if let icon = await FaviconLoader.shared.icon(for: site), let loaded = NSImage(data: icon.data) {
                image = loaded
                fullBleed = icon.kind == .touch
            }
        }
    }

    private var pseudoSymbol: String? {
        switch site {
        case SiteKey.privateSite: "eye.slash.fill"
        case SiteKey.browserPages: "macwindow"
        case SiteKey.localFiles: "doc.fill"
        case "": "globe"
        default: SiteKey.isLocal(site.split(separator: ":").first.map(String.init) ?? site) ? "server.rack" : nil
        }
    }

    private func tile<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
            .fill(Theme.track)
            .overlay(content())
    }
}

/// What a ranked row is about.
enum EntityRef: Hashable {
    case app(String)
    case site(String)
    case category(UsageCategory)
}

struct EntityIcon: View {
    let entity: EntityRef
    var size: CGFloat = 24

    var body: some View {
        switch entity {
        case let .app(id): AppIconView(app: id, size: size)
        case let .site(site): SiteIconView(site: site, size: size)
        case let .category(category):
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(Theme.color(category))
                .overlay(Image(systemName: category.symbol).font(.system(size: size * 0.46, weight: .semibold)).foregroundStyle(.white))
                .frame(width: size, height: size)
        }
    }
}

// MARK: Tiles

/// One headline number: a caption, the value, and a line of context.
struct StatTile: View {
    let title: String
    let symbol: String
    let value: String
    var footnote: String?
    var delta: Double?
    /// Whether a rise is good (focus time) or bad (screen time). nil: neither.
    var higherIsBetter: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 22, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
            HStack(spacing: 6) {
                if let delta { DeltaBadge(change: delta, higherIsBetter: higherIsBetter) }
                Text(footnote ?? " ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.cardBorder))
        .accessibilityElement(children: .combine)
    }
}

/// A row (or rows) of stat tiles that re-flows with the width, preferring even rows.
struct StatGrid<Content: View>: View {
    let count: Int
    var minimumWidth: CGFloat = 150
    @ViewBuilder var content: Content
    @State private var width: CGFloat = 0

    private let spacing: CGFloat = 12

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: columns), spacing: spacing) {
            content
        }
        .onWidthChange { width = $0 }
    }

    private var columns: Int {
        guard width > 0 else { return min(count, 4) }
        let fit = max(1, Int((width + spacing) / (minimumWidth + spacing)))
        if fit >= count { return max(count, 1) }
        let even = (1...fit).reversed().first { count % $0 == 0 } ?? 1
        return even * 2 > fit ? even : fit
    }
}

/// "▲ 12%" — the arrow carries the direction, so color is never alone.
struct DeltaBadge: View {
    let change: Double
    var higherIsBetter: Bool?

    var body: some View {
        let up = change > 0
        let flat = abs(change) < 0.02
        HStack(spacing: 2) {
            Image(systemName: flat ? "equal" : up ? "arrow.up" : "arrow.down")
                .font(.caption2.weight(.bold))
            Text(flat ? "same" : "\(Int((abs(change) * 100).rounded()))%")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
        }
        .foregroundStyle(color(flat: flat, up: up))
        .accessibilityLabel(flat ? "About the same" : "\(up ? "Up" : "Down") \(Int((abs(change) * 100).rounded())) percent")
    }

    private func color(flat: Bool, up: Bool) -> Color {
        guard !flat, let higherIsBetter else { return .secondary }
        return up == higherIsBetter ? Theme.deltaGoodText : Theme.deltaBadText
    }
}

// MARK: Rows

/// An app, site or category with its time, share and a bar.
struct RankedRow: View {
    let entity: EntityRef
    let name: String
    var subtitle: String?
    let seconds: Double
    /// 0–1, against the biggest row, for the bar.
    let fraction: Double
    let share: Double
    let color: Color
    var trailing: String?
    var sparkline: [Double]?

    var body: some View {
        HStack(spacing: 10) {
            EntityIcon(entity: entity, size: 26)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(name).lineLimit(1).truncationMode(.middle)
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    if let sparkline, sparkline.count > 1 {
                        Sparkline(values: sparkline, color: color)
                            .frame(width: 54, height: 16)
                    }
                    Text(DurationFormat.short(seconds))
                        .monospacedDigit()
                        .fontWeight(.medium)
                    Text(trailing ?? TimeText.percent(share))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)
                }
                UsageBar(fraction: fraction, color: color)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

struct UsageBar: View {
    let fraction: Double
    let color: Color
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(color)
                    .frame(width: max(proxy.size.width * min(max(fraction, 0), 1), fraction > 0 ? height : 0))
            }
        }
        .frame(height: height)
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    var message: String?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(.tertiary)
            Text(title).font(.headline).foregroundStyle(.secondary)
            if let message {
                Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .padding()
    }
}

/// A soft rounded block in the menu bar popover.
struct PopoverTile<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// A softly pulsing dot that says the numbers are live.
struct LiveDot: View {
    var color: Color = Theme.good

    var body: some View {
        PulsingDot(color: color)
            .frame(width: 7, height: 7)
            .accessibilityHidden(true)
    }
}

/// The dot itself. Core Animation runs the pulse in the render server; a SwiftUI
/// `repeatForever` animation would redraw the view graph on the main thread every frame.
private struct PulsingDot: NSViewRepresentable {
    let color: Color

    func makeNSView(context: Context) -> DotView { DotView() }

    func updateNSView(_ view: DotView, context: Context) {
        view.color = NSColor(color)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DotView, context: Context) -> CGSize? {
        CGSize(width: 7, height: 7)
    }

    final class DotView: NSView {
        var color: NSColor = .clear {
            didSet { needsDisplay = true }
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

        override var wantsUpdateLayer: Bool { true }

        /// Runs again on appearance changes, so the color follows light and dark mode.
        override func updateLayer() {
            layer?.backgroundColor = color.cgColor
            layer?.cornerRadius = bounds.height / 2
        }

        override func layout() {
            super.layout()
            layer?.cornerRadius = bounds.height / 2
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, let layer, layer.animation(forKey: "pulse") == nil else { return }
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.35
            pulse.duration = 1.1
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(pulse, forKey: "pulse")
        }
    }
}

/// Tells its view when the window it sits in becomes or stops being key. The menu bar popover
/// uses it to know when it's open: MenuBarExtra keeps the popover's views alive after closing.
///
/// Notifications are delivered synchronously, inside `makeKeyAndOrderFront`, so a state change
/// made in `onChange` lands before the window's first frame is drawn.
struct WindowKeyObserver: NSViewRepresentable {
    var onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ObserverView { ObserverView() }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.onChange = onChange
    }

    final class ObserverView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.onChange?(true) }
            })
            observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.onChange?(false) }
            })
            // Backup in case a key change is ever skipped: the popover can't stay frozen while it's
            // on screen.
            observers.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: nil) { [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    guard let window else { return }
                    self?.onChange?(window.occlusionState.contains(.visible))
                }
            })
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}

/// Segmented control for picking between a handful of views of one card.
struct CardPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(options, id: \.0) { option in
                Text(option.1).tag(option.0)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .controlSize(.small)
    }
}
