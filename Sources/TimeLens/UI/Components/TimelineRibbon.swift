import SwiftUI
import TimeLensCore

/// A run of time in the ribbon.
struct RibbonBlock: Identifiable, Hashable {
    let id: Int
    let start: Double
    let end: Double
    let color: Color
    let label: String
    let detail: String
}

/// The day as one strip: every app session placed at its real time, colored by category,
/// with gaps where you were away. Drag-free zoom: pick a window of hours.
struct TimelineRibbon: View {
    let blocks: [RibbonBlock]
    /// The visible window, seconds since 1970.
    let window: ClosedRange<Double>
    var height: CGFloat = 44
    var now: Double?
    @State private var hovered: RibbonBlock?
    @State private var hoverX: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                let width = proxy.size.width
                let span = max(window.upperBound - window.lowerBound, 1)
                ZStack(alignment: .topLeading) {
                    Canvas { context, size in
                        let track = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 6)
                        context.fill(track, with: .color(Theme.track))
                        for block in blocks where block.end > window.lowerBound && block.start < window.upperBound {
                            let x0 = CGFloat((max(block.start, window.lowerBound) - window.lowerBound) / span) * size.width
                            let x1 = CGFloat((min(block.end, window.upperBound) - window.lowerBound) / span) * size.width
                            let rect = CGRect(x: x0, y: 0, width: max(x1 - x0 - 0.5, 0.75), height: size.height)
                            context.fill(Path(rect), with: .color(block.color.opacity(hovered == nil || hovered == block ? 1 : 0.45)))
                        }
                        if let now, now > window.lowerBound, now < window.upperBound {
                            let x = CGFloat((now - window.lowerBound) / span) * size.width
                            context.fill(Path(CGRect(x: x - 1, y: -2, width: 2, height: size.height + 4)), with: .color(.primary))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .onContinuousHover { phase in
                        switch phase {
                        case let .active(location):
                            let time = window.lowerBound + Double(location.x / max(width, 1)) * span
                            hovered = blocks.first { $0.start <= time && $0.end >= time }
                            hoverX = location.x
                        case .ended:
                            hovered = nil
                        }
                    }
                }
            }
            .frame(height: height)

            // Hour ticks.
            GeometryReader { proxy in
                let span = max(window.upperBound - window.lowerBound, 1)
                ZStack(alignment: .topLeading) {
                    ForEach(hourTicks, id: \.self) { tick in
                        let x = CGFloat((tick - window.lowerBound) / span) * proxy.size.width
                        Text(Date(timeIntervalSince1970: tick).formatted(.dateTime.hour()))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .position(x: x, y: 6)
                    }
                }
            }
            .frame(height: 12)

            Group {
                if let hovered {
                    HStack(spacing: 6) {
                        SeriesKey(color: hovered.color)
                        Text(hovered.label).fontWeight(.medium)
                        Text(hovered.detail).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Hover the strip to see what you were doing").foregroundStyle(.tertiary)
                }
            }
            .font(.caption)
            .lineLimit(1)
        }
    }

    private var hourTicks: [Double] {
        let span = window.upperBound - window.lowerBound
        let step: Double = span > 12 * 3600 ? 3 * 3600 : span > 4 * 3600 ? 3600 : 1800
        var ticks: [Double] = []
        var tick = (window.lowerBound / step).rounded(.up) * step
        // Align to local hours, not UTC.
        let offset = Double(TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: tick)))
        tick = ((window.lowerBound + offset) / step).rounded(.up) * step - offset
        while tick <= window.upperBound {
            if tick > window.lowerBound + step * 0.3, tick < window.upperBound - step * 0.3 { ticks.append(tick) }
            tick += step
        }
        return ticks
    }
}
