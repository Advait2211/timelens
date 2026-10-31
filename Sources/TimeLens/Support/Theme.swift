import AppKit
import SwiftUI
import TimeLensCore

/// Colors and shared view styling.
///
/// Each category owns one slot of the validated categorical palette, in palette order, so a
/// category is the same color on every chart; "Other" is gray. Heatmaps use the blue
/// sequential ramp. Productive / distracting is the blue ↔ red diverging pair with a gray
/// midpoint.
enum Theme {
    static let series: [Color] = [
        Color(light: 0x2A78D6, dark: 0x3987E5), // blue
        Color(light: 0xEB6834, dark: 0xD95926), // orange
        Color(light: 0x1BAF7A, dark: 0x199E70), // aqua
        Color(light: 0xEDA100, dark: 0xC98500), // yellow
        Color(light: 0xE87BA4, dark: 0xD55181), // magenta
        Color(light: 0x008300, dark: 0x008300), // green
        Color(light: 0x6250D6, dark: 0x9085E9), // violet
        Color(light: 0xE34948, dark: 0xE66767), // red
    ]
    static let other = Color(light: 0xA9A8A2, dark: 0x6B6A65)

    static func color(_ category: UsageCategory) -> Color {
        switch category {
        case .development: series[0]
        case .social: series[1]
        case .productivity: series[2]
        case .entertainment: series[3]
        case .communication: series[4]
        case .learning: series[5]
        case .creativity: series[6]
        case .games: series[7]
        case .other: other
        }
    }

    static func color(_ rating: Rating) -> Color {
        switch rating {
        case .productive: Color(light: 0x2A78D6, dark: 0x3987E5)
        case .neutral: Color(light: 0xC3C2B7, dark: 0x52514E)
        case .distracting: Color(light: 0xE34948, dark: 0xE66767)
        }
    }

    /// Steps of the blue sequential ramp for heatmaps. In dark mode low values recede toward
    /// the surface, so the ramp runs the other way.
    static let heatSteps: [Color] = [
        Color(light: 0xCDE2FB, dark: 0x0D366B),
        Color(light: 0x9EC5F4, dark: 0x184F95),
        Color(light: 0x6DA7EC, dark: 0x256ABF),
        Color(light: 0x3987E5, dark: 0x3987E5),
        Color(light: 0x256ABF, dark: 0x6DA7EC),
        Color(light: 0x184F95, dark: 0x9EC5F4),
    ]

    /// The heat step for a share of the busiest cell (square-root scale: usage is lopsided).
    static func heat(_ fraction: Double) -> Color {
        guard fraction > 0 else { return track }
        let step = Int((fraction.squareRoot() * Double(heatSteps.count)).rounded(.up)) - 1
        return heatSteps[min(max(step, 0), heatSteps.count - 1)]
    }

    static let good = Color(light: 0x0CA30C, dark: 0x0CA30C)
    static let warning = Color(light: 0xFAB219, dark: 0xFAB219)
    static let critical = Color(light: 0xD03B3B, dark: 0xD03B3B)
    static let deltaGoodText = Color(light: 0x006300, dark: 0x0CA30C)
    static let deltaBadText = Color(light: 0xB02E2E, dark: 0xE66767)

    static let accent = Color(light: 0x2A78D6, dark: 0x3987E5)
    static let cardBackground = Color(nsColor: .controlBackgroundColor)
    static let cardBorder = Color.primary.opacity(0.07)
    static let track = Color.primary.opacity(0.07)
    static let gridline = Color(light: 0xE1E0D9, dark: 0x2C2C2A)
    static let muted = Color(light: 0x898781, dark: 0x898781)

    static let cardRadius: CGFloat = 14
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                           green: CGFloat((hex >> 8) & 0xff) / 255,
                           blue: CGFloat(hex & 0xff) / 255,
                           alpha: 1)
        })
    }
}

/// The rounded container every dashboard section sits in.
struct Card<Content: View, Accessory: View>: View {
    var title: String?
    var subtitle: String?
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    init(_ title: String? = nil, subtitle: String? = nil, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.headline)
                        if let subtitle {
                            Text(subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    accessory
                }
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.cardBorder))
    }
}

extension Card where Accessory == EmptyView {
    init(_ title: String? = nil, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title, subtitle: subtitle, accessory: { EmptyView() }, content: content)
    }
}

/// A small colored key beside a text label — identity never rides on text color.
struct SeriesKey: View {
    let color: Color
    var shape: Shape = .square

    enum Shape { case square, line, dash }

    var body: some View {
        switch shape {
        case .square:
            RoundedRectangle(cornerRadius: 2.5).fill(color).frame(width: 9, height: 9)
        case .line:
            Capsule().fill(color).frame(width: 12, height: 3)
        case .dash:
            HStack(spacing: 2) {
                Capsule().fill(color).frame(width: 4, height: 2)
                Capsule().fill(color).frame(width: 4, height: 2)
            }
        }
    }
}

struct KeyLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
            configuration.title
        }
    }
}

/// A legend of categories, wrapping as needed.
struct CategoryLegend: View {
    let categories: [UsageCategory]

    var body: some View {
        FlowLayout(spacing: 12, lineSpacing: 4) {
            ForEach(categories) { category in
                Label { Text(category.title) } icon: { SeriesKey(color: Theme.color(category)) }
                    .labelStyle(KeyLabelStyle())
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// Light / dark choice in Settings. "System" follows macOS.
enum AppearancePreference: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    func apply() {
        NSApp.appearance = switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    static var saved: AppearancePreference {
        UserDefaults.standard.string(forKey: "appearance").flatMap(AppearancePreference.init) ?? .system
    }
}
