import SwiftUI
import ProductiumCore

// v1.3 Part D: three rings like the Fitness app. Work (blue), Tracked (green), Limit (teal → red as it fills; good when
// it's not closed). Rounded caps, the track at 20%, past 100% a darker second lap with a shadow under its end. Each ring
// has its word and number beside it (never colour alone) and the rings differ by position, so they read in grayscale.

enum RingStyle {
    static let work = Color.blue
    static let tracked = Color.green
    static func limit(_ p: Double) -> Color { p >= 1 ? .red : p >= 0.8 ? .orange : .teal }
}

struct ActivityRings: View {
    let rings: DayRings
    var lineWidth: CGFloat = 16

    var body: some View {
        GeometryReader { g in
            let w = min(g.size.width, g.size.height)
            let step = lineWidth * 1.15
            ZStack {
                RingArc(progress: rings.work, color: RingStyle.work, lineWidth: lineWidth).frame(width: w, height: w)
                RingArc(progress: rings.tracked, color: RingStyle.tracked, lineWidth: lineWidth).frame(width: w - 2 * step, height: w - 2 * step)
                RingArc(progress: rings.limit, color: RingStyle.limit(rings.limit), lineWidth: lineWidth)
                    .frame(width: w - 4 * step, height: w - 4 * step)
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Work \(rings.workLabel). Tracked \(rings.trackedLabel), \(rings.trackedSubtitle). Limit \(rings.limitLabel).")
    }
}

struct RingArc: View {
    let progress: Double
    let color: Color
    let lineWidth: CGFloat

    var body: some View {
        let lap = progress > 1 ? progress.truncatingRemainder(dividingBy: 1) : 0
        ZStack {
            Circle().stroke(color.opacity(0.2), lineWidth: lineWidth)
            Circle().trim(from: 0, to: min(1, max(0, progress)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if progress > 1 {
                // The second lap, darker, with the end cap's shadow so the overlap is drawn, not just coloured.
                Circle().trim(from: 0, to: max(0.001, lap))
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .brightness(-0.2)
                    .rotationEffect(.degrees(-90))
                    .shadow(color: .black.opacity(0.45), radius: lineWidth * 0.2)
            }
        }
        .padding(lineWidth / 2)
    }
}

/// The word and number beside each ring.
struct RingLegendRows: View {
    let rings: DayRings
    var usual: DayRings?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("Work", "pencil.line", RingStyle.work, rings.workLabel, usual.map { "usual \(minutesLabel($0.workMinutes))" })
            row("Tracked", "checkmark.circle", RingStyle.tracked, "\(rings.trackedLabel) · \(rings.trackedSubtitle)",
                usual.map { "usual \($0.trackedLabel)" })
            row("Limit", "hourglass", RingStyle.limit(rings.limit), rings.limitLabel, usual.map { "usual \($0.limitMinutes) min" })
        }
    }

    private func row(_ name: String, _ symbol: String, _ color: Color, _ value: String, _ note: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(color).frame(width: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(name).font(.caption.weight(.semibold)).foregroundStyle(color)
                Text(value).font(.subheadline.monospacedDigit())
                if let note { Text(note).font(.caption2).foregroundStyle(.secondary) }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Home: today's rings. Tapping opens the day's categories as a plain sorted list.
struct RingsCard: View {
    @Environment(AppModel.self) private var model
    let now: Date
    @State private var showingDay = false

    var body: some View {
        let r = model.rings(now)
        Card {
            CardHeader(title: "Today", symbol: "circle.circle", color: .blue, chevron: true)
            HStack(spacing: 18) {
                ActivityRings(rings: r, lineWidth: 14).frame(width: 130, height: 130)
                RingLegendRows(rings: r)
            }
            if let f = model.forecast {
                Text(model.verdict(f).line).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { showingDay = true }
        .sheet(isPresented: $showingDay) { RingDaySheet(day: now) }
    }
}

/// A ring's day: where the time went, sorted, as bars (easier to read than a second donut).
struct RingDaySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let day: Date
    @State private var drill: String?

    var body: some View {
        let cal = Calendar.current
        let rows = DayRings.breakdown(day, entries: model.state.entries, tree: model.state.categories, now: Date(),
                                      book: model.state.dayRules, calendar: cal)
        let most = max(1, rows.map(\.minutes).max() ?? 1)
        NavigationStack {
            List {
                Section {
                    ActivityRings(rings: model.rings(day), lineWidth: 18).frame(height: 170).frame(maxWidth: .infinity)
                    RingLegendRows(rings: model.rings(day), usual: model.usualRings(day))
                }
                Section("Where the Time Went") {
                    ForEach(rows, id: \.id) { r in
                        Button { drill = r.id } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Label(r.name, systemImage: Theme.symbol(category: r.id, tree: model.state.categories))
                                    Spacer()
                                    Text(durationLabel(r.minutes)).monospacedDigit().foregroundStyle(.secondary)
                                }
                                .font(.subheadline)
                                GeometryReader { g in
                                    Capsule().fill(Theme.color(category: r.id, tree: model.state.categories))
                                        .frame(width: max(4, g.size.width * CGFloat(r.minutes) / CGFloat(most)), height: 6)
                                }
                                .frame(height: 6)
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
            .navigationTitle(day.formatted(.dateTime.weekday(.wide).month().day()))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: Binding(get: { drill.map(Drill.init) }, set: { drill = $0?.id })) { d in
                DrillSheet(id: d.id, range: Days.dayInterval(day, cal), title: day.formatted(.dateTime.weekday(.abbreviated)))
            }
        }
    }
}
