// The control menu's quality badge ("HP · 4:4:4 · 60 fps · 58 Mbps" with a
// green / yellow / red dot) and the optional stats overlay (the menu's Stats
// tile): fps, Mbps, decode time, loss and BWE with a 30 s sparkline of Mbps
// and fps. Both read LiveStatsModel, which changes at most once a second.
import SwiftUI

extension StreamQuality {
    var color: Color {
        switch self {
        case .good: .green
        case .fair: .yellow
        case .poor: .red
        }
    }
}

/// The badge in the expanded menu's header.
struct QualityBadge: View {
    let stats: LiveStatsModel

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(stats.quality?.color ?? Color.secondary)
                .frame(width: 8, height: 8)
                .shadow(color: (stats.quality?.color ?? .clear).opacity(0.6), radius: 3)
            Text(stats.badgeText)
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(QualityBadgeText.accessibilityText(stats.latest, chroma: stats.chroma))
    }
}

/// The floating stats panel (top-leading, over the session; not interactive,
/// so touches pass through to the Mac).
struct StatsOverlay: View {
    let stats: LiveStatsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(stats.quality?.color ?? Color.secondary).frame(width: 7, height: 7)
                Text("\(QualityBadgeText.codec)\(stats.chroma.map { " · \($0.rawValue)" } ?? "")")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                GridRow {
                    metric("fps", stats.latest.map { String(format: "%.0f", $0.fps) }, color: Self.fpsColor)
                    metric("Mbps", stats.latest.map { String(format: "%.1f", $0.mbps) }, color: Self.mbpsColor)
                }
                GridRow {
                    metric("decode", stats.latest?.decodeMs.map { String(format: "%.1f ms", $0) })
                    metric("loss", stats.latest?.lossPercent.map { String(format: "%.1f%%", $0) })
                }
                GridRow {
                    metric("BWE", stats.latest?.bweMbps.map { String(format: "%.0f Mbps", $0) })
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                }
            }
            Sparkline(samples: stats.history.elements)
                .frame(width: 196, height: 34)
        }
        .padding(12)
        .menuGlass(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Stream statistics")
        .accessibilityValue(accessibilityValue)
    }

    static let fpsColor = Color.green
    static let mbpsColor = Color.cyan

    private func metric(_ name: String, _ value: String?, color: Color? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if let color { Circle().fill(color).frame(width: 5, height: 5) }
            Text(name).font(.caption2).foregroundStyle(.secondary)
            Text(value ?? "–").font(.caption.weight(.semibold).monospacedDigit())
        }
    }

    private var accessibilityValue: String {
        guard let s = stats.latest else { return "Waiting for data" }
        var parts = [String(format: "%.0f frames per second", s.fps), String(format: "%.1f megabits per second", s.mbps)]
        if let d = s.decodeMs { parts.append(String(format: "decode %.1f milliseconds", d)) }
        if let l = s.lossPercent { parts.append(String(format: "loss %.1f percent", l)) }
        if let b = s.bweMbps { parts.append(String(format: "bandwidth estimate %.0f megabits per second", b)) }
        return parts.joined(separator: ", ")
    }
}

/// Mbps and fps over the last 30 s, each scaled to its own peak.
struct Sparkline: View {
    let samples: [StatsSample]

    var body: some View {
        Canvas { ctx, size in
            guard samples.count > 1 else { return }
            let slots = CGFloat(LiveStatsModel.historySeconds - 1)
            let step = size.width / slots
            let x0 = size.width - CGFloat(samples.count - 1) * step
            func path(_ value: (StatsSample) -> Double, floor: Double) -> Path {
                let peak = max(floor, samples.map(value).max() ?? 0) * 1.1
                var p = Path()
                for (i, s) in samples.enumerated() {
                    let pt = CGPoint(x: x0 + CGFloat(i) * step,
                                     y: size.height - CGFloat(value(s) / peak) * (size.height - 2) - 1)
                    if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                }
                return p
            }
            let style = StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
            ctx.stroke(path({ $0.fps }, floor: 30), with: .color(StatsOverlay.fpsColor.opacity(0.9)), style: style)
            ctx.stroke(path({ $0.mbps }, floor: 5), with: .color(StatsOverlay.mbpsColor), style: style)
        }
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
