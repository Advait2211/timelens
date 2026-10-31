import SwiftUI

/// How much room a dashboard page has. Pages re-flow at these widths so the window works at
/// any size down to half a laptop screen (Rectangle's "Left Half" / "Right Half").
enum LayoutClass: Int, Comparable {
    /// Under 620 pt of content column — half a 13–15" screen. One column.
    case compact
    /// Pairs of cards sit side by side only when there's room for both.
    case regular
    case wide

    init(width: CGFloat) {
        self = width < 620 ? .compact : width < 960 ? .regular : .wide
    }

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

private struct LayoutClassKey: EnvironmentKey {
    static let defaultValue = LayoutClass.regular
}

extension EnvironmentValues {
    var layoutClass: LayoutClass {
        get { self[LayoutClassKey.self] }
        set { self[LayoutClassKey.self] = newValue }
    }
}

/// Side by side when the page is at least `minimum` wide, stacked otherwise. Side-by-side
/// children share the height of the tallest.
struct AdaptiveStack<Content: View>: View {
    var minimum: LayoutClass = .regular
    var spacing: CGFloat = 18
    @ViewBuilder var content: Content
    @Environment(\.layoutClass) private var layoutClass

    var body: some View {
        if layoutClass >= minimum {
            HStack(alignment: .top, spacing: spacing) { content }
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: spacing) { content }
        }
    }
}

/// Lays children out in rows, wrapping when a row is full — for legends.
struct FlowLayout: Layout {
    var spacing: CGFloat = 14
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        var current: (indices: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = ([index], size.width, size.height)
            } else {
                current = (current.indices + [index], needed, max(current.height, size.height))
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

extension View {
    /// Calls `action` with this view's width whenever it changes.
    func onWidthChange(_ action: @escaping (CGFloat) -> Void) -> some View {
        onGeometryChange(for: CGFloat.self) { $0.size.width } action: { action($0) }
    }
}
