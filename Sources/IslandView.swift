import SwiftUI

extension Color {
    /// Maps a usage fraction to a hue running from green (0%) through yellow to red (100%).
    static func usage(_ value: Double) -> Color {
        let clamped = min(max(value, 0), 1)
        return Color(hue: (1 - clamped) / 3, saturation: 0.85, brightness: 0.95)
    }
}

/// Formats a fraction as a whole-number percentage, e.g. `0.423` → `"42%"`.
private func percentText(_ value: Double) -> String {
    "\(Int((value * 100).rounded()))%"
}

/// Formats a byte count in GB (or MB below 1 GB), e.g. `"6.1 GB"`, `"512 MB"`.
private func byteText(_ bytes: Double) -> String {
    let gb = bytes / 1_073_741_824
    return gb >= 1 ? String(format: "%.1f GB", gb) : String(format: "%.0f MB", bytes / 1_048_576)
}

private let secondaryText = Color.white.opacity(0.55)
private let panelFill = Color.white.opacity(0.06)

/// The black island around the notch: CPU usage on the left wing, memory used on the right,
/// and a wide details panel that drops down while hovered.
struct IslandView: View {
    /// Expand/collapse animation; the controller applies it so it can act when the collapse finishes.
    static let animation = Animation.spring(response: 0.35, dampingFraction: 0.8)

    let monitor: SystemMonitor
    let state: IslandState

    var body: some View {
        let geometry = state.geometry
        let expanded = state.isExpanded
        let radius: CGFloat = expanded ? 22 : 10

        VStack(spacing: 0) {
            HStack(spacing: 0) {
                WingNumber(value: monitor.cpu)
                Spacer(minLength: 0)
                WingNumber(value: monitor.memoryUsed)
            }
            // Keep the numbers beside the notch even while the island is wider.
            .frame(width: geometry.islandWidth, height: geometry.menuBarHeight)

            if expanded {
                HStack(alignment: .top, spacing: 12) {
                    CPUColumn(monitor: monitor)
                    MemoryColumn(monitor: monitor)
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 14)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(width: expanded ? NotchGeometry.expandedWidth : geometry.islandWidth)
        .background(
            UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius, style: .continuous)
                .fill(.black)
        )
        .background(GeometryReader { proxy in
            Color.clear.onChange(of: proxy.size.height, initial: true) { _, height in
                state.islandHeight = height
            }
        })
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// A coloured percentage shown in one wing of the collapsed island.
private struct WingNumber: View {
    let value: Double

    var body: some View {
        Text(percentText(value))
            .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
            .foregroundStyle(Color.usage(value))
            .frame(width: NotchGeometry.wingWidth)
    }
}

/// Left column of the details panel.
private struct CPUColumn: View {
    let monitor: SystemMonitor

    var body: some View {
        let details = monitor.cpuDetails
        let load = details.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: " / ")

        VStack(alignment: .leading, spacing: 10) {
            MetricHeader(title: "CPU", value: monitor.cpu, history: monitor.cpuHistory)

            VStack(spacing: 4) {
                StatGrid(rows: [
                    ("User", percentText(details.user), nil),
                    ("System", percentText(details.system), nil),
                    ("Idle", percentText(details.idle), nil),
                ])
                StatCell(label: "Load average (1 / 5 / 15 min)", value: load, color: nil)
            }

            Section(title: coreTitle) {
                CoreBars(cores: details.cores)
            }

            Section(title: "Top CPU processes") {
                ProcessList(rows: monitor.topCPU.map { ($0.id, $0.name, String(format: "%.1f%%", $0.cpu * 100)) })
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var coreTitle: String {
        let count = monitor.cpuDetails.cores.count
        guard let types = monitor.coreTypes else { return "\(count) cores" }
        return "\(count) cores (\(types.performance) performance + \(types.efficiency) efficiency)"
    }
}

/// Right column of the details panel.
private struct MemoryColumn: View {
    let monitor: SystemMonitor

    var body: some View {
        let details = monitor.memoryDetails
        let total = monitor.totalMemory

        VStack(alignment: .leading, spacing: 10) {
            MetricHeader(title: "Memory", value: monitor.memoryUsed, history: monitor.memoryHistory)

            VStack(spacing: 4) {
                StatGrid(rows: [
                    ("Used", byteText(total - details.available), nil),
                    ("Available", byteText(details.available), nil),
                    ("Total", byteText(total), nil),
                    ("Pressure", pressure.text, pressure.color),
                ])
                StatCell(label: "Swap used / total", value: "\(byteText(details.swapUsed)) / \(byteText(details.swapTotal))", color: nil)
            }

            Section(title: "Memory breakdown") {
                StatGrid(rows: [
                    ("App", byteText(details.app), nil),
                    ("Wired", byteText(details.wired), nil),
                    ("Compressed", byteText(details.compressed), nil),
                    ("Cached files", byteText(details.cached), nil),
                ])
            }

            Section(title: "Top memory processes") {
                ProcessList(rows: monitor.topMemory.map { ($0.id, $0.name, byteText($0.memory)) })
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var pressure: (text: String, color: Color) {
        switch monitor.memoryDetails.pressure {
        case .normal: return ("Normal", .usage(0))
        case .warning: return ("Warning", .usage(0.6))
        case .critical: return ("Critical", .usage(1))
        }
    }
}

/// Title, large percentage, full-width bar and 60-second sparkline with its average and peak.
private struct MetricHeader: View {
    let title: String
    let value: Double
    let history: [Double]

    var body: some View {
        let color = Color.usage(value)
        let average = history.isEmpty ? 0 : history.reduce(0, +) / Double(history.count)
        let peak = history.max() ?? 0

        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                Text(percentText(value))
                    .font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(color)
                Spacer()
                Text("60 s avg \(percentText(average)) · peak \(percentText(peak))")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(secondaryText)
            }

            UsageBar(value: value, color: color, height: 6)

            ZStack {
                Sparkline(values: history, closed: true)
                    .fill(LinearGradient(colors: [color.opacity(0.35), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                Sparkline(values: history, closed: false)
                    .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }
            .frame(height: 44)
            .background(panelFill)
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }
}

/// Small grey caption above a group of rows.
private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(secondaryText)
            content
        }
    }
}

/// Label/value rows laid out two per line.
private struct StatGrid: View {
    /// Label, value text and an optional value colour.
    let rows: [(String, String, Color?)]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
            ForEach(Array(stride(from: 0, to: rows.count, by: 2)), id: \.self) { start in
                GridRow {
                    ForEach(start..<min(start + 2, rows.count), id: \.self) { index in
                        StatCell(label: rows[index].0, value: rows[index].1, color: rows[index].2)
                    }
                }
            }
        }
    }
}

/// One label/value pair.
private struct StatCell: View {
    let label: String
    let value: String
    let color: Color?

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .foregroundStyle(secondaryText)
            Spacer(minLength: 4)
            Text(value)
                .foregroundStyle(color ?? .white.opacity(0.9))
                .monospacedDigit()
        }
        .font(.system(size: 11))
        .lineLimit(1)
        .frame(maxWidth: .infinity)
    }
}

/// One vertical bar per logical core.
private struct CoreBars: View {
    let cores: [Double]

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(cores.enumerated()), id: \.offset) { _, value in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 2).fill(panelFill)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.usage(value))
                        .frame(height: max(2, 30 * min(max(value, 0), 1)))
                }
                .frame(height: 30)
            }
        }
    }
}

/// Top-processes rows: name on the left, formatted value on the right.
private struct ProcessList: View {
    let rows: [(id: pid_t, name: String, value: String)]

    var body: some View {
        VStack(spacing: 3) {
            if rows.isEmpty {
                Text("Sampling…")
                    .foregroundStyle(secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(rows, id: \.id) { row in
                HStack {
                    Text(row.name)
                        .foregroundStyle(.white.opacity(0.85))
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(row.value)
                        .foregroundStyle(.white.opacity(0.9))
                        .monospacedDigit()
                }
            }
        }
        .font(.system(size: 11))
        .lineLimit(1)
    }
}

/// Horizontal capsule filled to `value`.
private struct UsageBar: View {
    let value: Double
    let color: Color
    let height: CGFloat

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.15))
                Capsule().fill(color).frame(width: proxy.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: height)
    }
}

/// Line (or filled area) through the last `SystemMonitor.historyLength` samples.
///
/// Samples are right-aligned so the newest value always sits at the right edge,
/// even before the history is full.
private struct Sparkline: Shape {
    let values: [Double]
    /// When true, the path is closed along the bottom edge so it can be filled.
    let closed: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1 else { return path }

        let capacity = SystemMonitor.historyLength
        let step = rect.width / CGFloat(capacity - 1)
        let startX = rect.minX + CGFloat(capacity - values.count) * step
        let points = values.enumerated().map { index, value in
            CGPoint(x: startX + CGFloat(index) * step, y: rect.maxY - CGFloat(min(max(value, 0), 1)) * rect.height)
        }

        path.addLines(points)
        if closed, let first = points.first, let last = points.last {
            path.addLine(to: CGPoint(x: last.x, y: rect.maxY))
            path.addLine(to: CGPoint(x: first.x, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}
