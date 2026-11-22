import SwiftUI
import ProductiumCore

// v1.3 Part D: three rings drawn like Activity's: Work (red), Tracked (green), Limit (cyan; orange then red as it fills,
// since it's good when it's not closed). Thick, nearly touching, each arc shaded along its length with a darker
// second lap past 100%. Each ring has its word and number beside it (never colour alone).

enum RingStyle {
    static let work = Color(red: 0.98, green: 0.07, blue: 0.31)
    static let tracked = Color(red: 0.45, green: 0.85, blue: 0.0)
    static func limit(_ p: Double) -> Color { p >= 1 ? .red : p >= 0.8 ? .orange : Color(red: 0.0, green: 0.78, blue: 0.9) }
}

struct ActivityRings: View {
    let rings: DayRings
    var lineWidth: CGFloat = 16

    var body: some View {
        GeometryReader { g in
            let w = min(g.size.width, g.size.height)
            let step = lineWidth + max(1.5, lineWidth * 0.08)
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
        let p = max(0, progress)
        let first = min(1, p)
        ZStack {
            Circle().stroke(color.opacity(0.22), lineWidth: lineWidth)
            if p > 0 {
                Circle().trim(from: 0, to: max(0.001, first))
                    .stroke(AngularGradient(colors: [color.opacity(0.75), color], center: .center,
                                            startAngle: .degrees(0), endAngle: .degrees(360 * max(0.01, first))),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            if p > 1 {
                Circle().trim(from: 0, to: max(0.001, min(1, p - 1)))
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .brightness(-0.12)
                    .rotationEffect(.degrees(-90))
                    .shadow(color: .black.opacity(0.35), radius: lineWidth * 0.15)
            }
        }
        .padding(lineWidth / 2)
    }
}

/// The word and the number beside each ring, in its colour (Activity style).
struct RingLegendRows: View {
    let rings: DayRings
    var usual: DayRings?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("Work", RingStyle.work, rings.workGoal == 0 ? minutesLabel(rings.workMinutes)
                : "\(minutesLabel(rings.workMinutes)) / \(minutesLabel(rings.workGoal))")
            row("Tracked", RingStyle.tracked, rings.trackedLabel)
            row("Limit", RingStyle.limit(rings.limit), "\(rings.limitMinutes) / \(rings.limitGoal) min")
        }
    }

    private func row(_ name: String, _ color: Color, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(name).font(.subheadline.weight(.semibold))
            Text(value).font(.system(.title3, design: .rounded).weight(.semibold).monospacedDigit()).foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.7)
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
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("Rings")
            Card {
                HStack(spacing: 18) {
                    ActivityRings(rings: r, lineWidth: 17).frame(width: 130, height: 130)
                    RingLegendRows(rings: r)
                    Spacer(minLength: 0)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { showingDay = true }
            .accessibilityAddTraits(.isButton)
        }
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
