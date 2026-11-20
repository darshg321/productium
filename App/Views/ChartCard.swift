import SwiftUI
import Charts
import ProductiumCore

/// One chart for a `QueryResult` (F3): ring, bar, stacked bar, line, heatmap, number or table. The numbers are the
/// engine's, never the model's. `onPin` is nil when it's already pinned (or in a place that can't pin).
struct ChartCard: View {
    let result: QueryResult
    var title: String?
    var onPin: (() -> Void)?
    var onUnpin: (() -> Void)?

    private var rows: [QueryResult.Row] { Array(result.rows.prefix(12)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title ?? result.range.start.formatted(.dateTime.month(.abbreviated).day()) + " – "
                     + result.range.end.addingTimeInterval(-1).formatted(.dateTime.month(.abbreviated).day()))
                    .font(.footnote.weight(.semibold))
                Spacer()
                if let onPin { Button { onPin() } label: { Label("Pin to Review", systemImage: "pin") }.labelStyle(.iconOnly) }
                if let onUnpin { Button { onUnpin() } label: { Label("Unpin", systemImage: "pin.slash") }.labelStyle(.iconOnly) }
            }
            chart
            Text(coverage).font(.caption2).foregroundStyle(.secondary)
            ForEach(result.problems, id: \.self) { p in
                Label(p, systemImage: "exclamationmark.triangle").font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder private var chart: some View {
        if rows.isEmpty && result.chart != "number" {
            Text("Nothing in that range.").font(.subheadline).foregroundStyle(.secondary)
        } else {
            switch result.chart {
            case "number": big
            case "ring":
                Chart(rows, id: \.key) { r in
                    SectorMark(angle: .value("Value", r.value), innerRadius: .ratio(0.6), angularInset: 1)
                        .foregroundStyle(by: .value("Name", r.label))
                }
                .frame(height: 180)
            case "line":
                Chart(rows, id: \.key) { r in
                    LineMark(x: .value("When", r.label), y: .value("Value", r.value))
                    PointMark(x: .value("When", r.label), y: .value("Value", r.value))
                }
                .frame(height: 160)
            case "stackedBar":
                Chart(rows, id: \.key) { r in
                    BarMark(x: .value("Value", r.value)).foregroundStyle(by: .value("Name", r.label))
                }
                .frame(height: 60)
            case "heatmap":
                let top = max(1, rows.map(\.value).max() ?? 1)
                Chart(rows, id: \.key) { r in
                    RectangleMark(x: .value("When", r.label), y: .value("", ""))
                        .foregroundStyle(Color.accentColor.opacity(0.15 + 0.85 * r.value / top))
                }
                .frame(height: 70)
            case "table": table
            default:
                Chart(rows, id: \.key) { r in
                    BarMark(x: .value("Name", r.label), y: .value("Value", r.value))
                    if let p = r.previous {
                        RuleMark(x: .value("Name", r.label), yStart: .value("Before", 0), yEnd: .value("Before", p))
                            .foregroundStyle(.secondary.opacity(0.4)).lineStyle(StrokeStyle(lineWidth: 2, dash: [3]))
                    }
                }
                .frame(height: 160)
            }
        }
    }

    private var big: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(format(result.total)).font(.system(size: 40, weight: .bold, design: .rounded))
            if let p = result.previousTotal { Text("before: \(format(p))").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var table: some View {
        VStack(spacing: 4) {
            ForEach(rows, id: \.key) { r in
                HStack { Text(r.label).font(.subheadline); Spacer(); Text(format(r.value)).font(.subheadline.monospacedDigit()) }
            }
        }
    }

    private var coverage: String {
        let c = result.coverage
        var s = "\(c.daysWithData) of \(c.days) days have this"
        if c.assumedMinutes > 0 { s += ", \(minutesLabel(c.assumedMinutes)) of it assumed" }
        if c.untrackedMinutes > 0 { s += ", \(minutesLabel(c.untrackedMinutes)) untracked in the range" }
        return s
    }

    private func format(_ v: Double) -> String {
        switch result.measure {
        case "share": return "\(Int((v * 100).rounded()))%"
        case "count": return "\(Int(v.rounded()))"
        case "firstStart", "lastEnd": return String(format: "%d:%02d", Int(v) / 60 % 24, Int(v) % 60)
        default: return minutesLabel(Int(v.rounded()))
        }
    }
}

/// Re-runs a stored query live (pinned charts and charts in the thread).
struct LiveChart: View {
    @Environment(AppModel.self) private var model
    let query: TimeQuery
    var title: String?
    var pinnedId: UUID?

    var body: some View {
        let result = model.run(query)
        if let pinnedId {
            ChartCard(result: result, title: title, onUnpin: { model.unpin(chart: pinnedId) })
        } else {
            ChartCard(result: result, title: title, onPin: { model.pin(query, title: title) })
        }
    }
}
