import SwiftUI
import Charts
import ProductiumCore

// Life Metrics (v1.1 Part G): tiles with a value, an arrow and a verdict. Good / bad is the symbol and the word as
// well as the colour, so it reads in grayscale (Part J). There is no overall score.

private extension MetricArrow {
    var symbol: String {
        switch self {
        case .up: return "arrow.up"
        case .down: return "arrow.down"
        case .flat: return "arrow.right"
        case .none: return "minus"
        }
    }
}

private extension MetricVerdict {
    var color: Color {
        switch self {
        case .better: return .green
        case .worse: return .red
        case .same, .notEnoughData: return .gray
        }
    }
}

private extension MetricPeriod {
    var title: String { rawValue.capitalized }
    var versus: String {
        switch self {
        case .day: return "than yesterday"
        case .week: return "than last week"
        case .month: return "than last month"
        }
    }
}

func metricSymbolColor(_ id: MetricID) -> Color {
    switch id {
    case .sleep, .sleepRegularity, .bedOnTime: return Theme.sleep
    case .focus, .planDone, .tasksDone: return Theme.focus
    case .scrolling, .screenTotal, .pickups, .firstPickup, .scrollOpens, .notifications: return Theme.screen
    default: return .teal
    }
}

struct MetricsSection: View {
    @Environment(AppModel.self) private var model
    let period: MetricPeriod
    @State private var editing = false

    var body: some View {
        let series = model.metricSeries()
        let cal = Calendar.current
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("Life Metrics", action: "Edit") { editing = true }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(model.state.metricTiles, id: \.self) { id in
                    if let s = series[id], Metrics.compare(s, period: period, now: Date(), calendar: cal).current != nil {
                        NavigationLink { MetricDetailView(id: id) } label: {
                            MetricTile(series: s, comparison: Metrics.compare(s, period: period, now: Date(), calendar: cal), period: period)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            let noticed = Noticed.find(series)
            if let n = noticed.first {
                Card { Label(n.text, systemImage: "eye") }
            }
        }
        .sheet(isPresented: $editing) { MetricTilesEditor() }
    }
}

struct MetricTile: View {
    let series: MetricSeries
    let comparison: MetricComparison
    let period: MetricPeriod

    var body: some View {
        let def = series.def
        let spark = Metrics.daily(series, last: 14, now: Date(), calendar: .current)
        let values = spark.compactMap(\.1).filter(\.isFinite)
        // A flat line still needs a non-empty scale.
        let lo = values.min() ?? 0, hi = values.max() ?? 1
        let domain = lo == hi ? (lo - 1)...(hi + 1) : lo...hi
        VStack(alignment: .leading, spacing: 6) {
            Label(def.title, systemImage: def.symbol)
                .font(.footnote.weight(.semibold)).foregroundStyle(metricSymbolColor(def.id)).lineLimit(1)
            if let cur = comparison.current {
                Text(Noticed.amount(cur, def.unit)).font(.system(.title2, design: .rounded).weight(.semibold)).monospacedDigit()
                if comparison.verdict != .notEnoughData {
                    Label("\(comparison.verdict.word) \(period.versus)", systemImage: comparison.arrow.symbol)
                        .font(.caption.weight(.semibold)).foregroundStyle(comparison.verdict.color).lineLimit(1).minimumScaleFactor(0.8)
                }
            }
            Chart {
                ForEach(Array(spark.enumerated()), id: \.offset) { _, p in
                    if let v = p.1, v.isFinite { LineMark(x: .value("Day", p.0, unit: .day), y: .value("Value", v)) }
                }
            }
            .chartXAxis(.hidden).chartYAxis(.hidden)
            .chartYScale(domain: domain)
            .foregroundStyle(metricSymbolColor(def.id))
            .frame(height: 28)
            .accessibilityHidden(true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(def.title), \(comparison.current.map { Noticed.amount($0, def.unit) } ?? "not enough data"), \(comparison.verdict.word)")
    }
}

struct MetricDetailView: View {
    @Environment(AppModel.self) private var model
    let id: MetricID
    @State private var range = 30

    var body: some View {
        let series = model.metricSeries(days: 400)
        let cal = Calendar.current
        ScrollView {
            if let s = series[id] {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Range", selection: $range) {
                        Text("1 week").tag(7); Text("1 month").tag(30); Text("3 months").tag(90); Text("All").tag(365)
                    }
                    .pickerStyle(.segmented)
                    chart(s, cal)
                    comparisons(s, cal)
                    sourceNote(s)
                    related(series)
                }
                .padding(16)
            }
        }
        .background(Theme.background)
        .navigationTitle(MetricDef.of(id).title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var target: Double? {
        switch id {
        case .sleep: return Double(model.state.prefs.sleepNeedMinutes)
        case .scrolling: return model.state.taper.targetMinutes.map(Double.init)
        default: return nil
        }
    }

    /// Changes Productium made and moments worth marking, so you can see whether they helped.
    private var marks: [(Date, String)] {
        let changes = model.state.changes.applied.map { ($0.at, String($0.title.prefix(28))) }
        let moments = model.state.rewards.moments.filter { $0.kind == .milestone || $0.kind == .personalBest }.map { ($0.at, $0.title) }
        return (changes + moments).filter { $0.0 > Date().addingTimeInterval(-Double(range) * 86400) }
    }

    @ViewBuilder private func chart(_ s: MetricSeries, _ cal: Calendar) -> some View {
        let daily = Metrics.daily(s, last: range, now: Date(), calendar: cal)
        let rolling = Metrics.rolling(daily)
        let before = Metrics.daily(s, last: range * 2, now: Date(), calendar: cal).prefix(range).map { p in
            (cal.date(byAdding: .day, value: range, to: p.0) ?? p.0, p.1)
        }
        Card {
            if daily.allSatisfy({ $0.1 == nil }) {
                Text("No data in this range yet.").font(.subheadline).foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(Array(before.enumerated()), id: \.offset) { _, p in
                        if let v = p.1 {
                            LineMark(x: .value("Day", p.0, unit: .day), y: .value("Before", v), series: .value("S", "before"))
                                .foregroundStyle(.gray.opacity(0.35))
                        }
                    }
                    ForEach(Array(daily.enumerated()), id: \.offset) { _, p in
                        if let v = p.1 {
                            BarMark(x: .value("Day", p.0, unit: .day), y: .value("Value", v))
                                .foregroundStyle(metricSymbolColor(id).opacity(0.5))
                        }
                    }
                    ForEach(Array(rolling.enumerated()), id: \.offset) { _, p in
                        if let v = p.1 {
                            LineMark(x: .value("Day", p.0, unit: .day), y: .value("Average", v), series: .value("S", "avg"))
                                .foregroundStyle(metricSymbolColor(id))
                        }
                    }
                    if let t = target {
                        RuleMark(y: .value("Target", t)).foregroundStyle(.secondary).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                    ForEach(Array(marks.enumerated()), id: \.offset) { _, m in
                        RuleMark(x: .value("Mark", m.0, unit: .day)).foregroundStyle(.secondary.opacity(0.6))
                            .annotation(position: .top, alignment: .leading) { Text(m.1).font(.caption2).foregroundStyle(.secondary) }
                    }
                }
                .frame(height: 220)
                Text("Bars: each day. Line: 7-day average. Faint line: the period before.\(target != nil ? " Dashed: your target." : "")")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func comparisons(_ s: MetricSeries, _ cal: Calendar) -> some View {
        Card {
            ForEach(MetricPeriod.allCases, id: \.self) { p in
                let c = Metrics.compare(s, period: p, now: Date(), calendar: cal)
                HStack {
                    Text(p.title).font(.subheadline)
                    Spacer()
                    if let cur = c.current {
                        Text(Noticed.amount(cur, s.def.unit)).monospacedDigit()
                        Image(systemName: c.arrow.symbol)
                        Image(systemName: c.verdict.symbol)
                        Text(c.verdict.word).font(.caption.weight(.semibold))
                    } else {
                        Text("Not enough data").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(c.verdict == .notEnoughData ? Color.secondary : c.verdict.color)
                if let n = c.note { Text(n).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    @ViewBuilder private func sourceNote(_ s: MetricSeries) -> some View {
        if id == .scrolling {
            let cal = Calendar.current
            let today = cal.startOfDay(for: Date())
            let week = (0..<7).reversed().compactMap { cal.date(byAdding: .day, value: -$0, to: today) }
            let points = ScreenSeries.daily(screen: model.state.screen, averages: model.state.screenAverages, days: week, calendar: cal)
            if let sum = ScreenSeries.summary(points) {
                Text(sum.line).font(.subheadline)
            }
            // v1.6 G7: where each day's number came from, and which days have none.
            Card {
                ForEach(Array(zip(week, points)), id: \.0) { day, p in
                    LabeledContent(day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()),
                                   value: p.map { "\(minutesLabel($0.scrolling)) · \($0.source.label)" } ?? "No number")
                        .font(.subheadline)
                }
            }
        }
        let sources = Set(s.points.values.map(\.source))
        if !sources.isEmpty {
            Text("Numbers are " + sources.map(\.label).sorted().joined(separator: ", ") + ". Days with no data aren't counted as zero.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func related(_ series: [MetricID: MetricSeries]) -> some View {
        let mine = Noticed.find(series).filter { $0.x == id || $0.y == id }
        ForEach(mine, id: \.text) { n in
            Card { Label(n.text, systemImage: "eye").font(.subheadline) }
        }
    }
}

struct MetricTilesEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var m = model
        NavigationStack {
            List {
                Section {
                    ForEach(model.state.metricTiles, id: \.self) { id in
                        Label(MetricDef.of(id).title, systemImage: MetricDef.of(id).symbol)
                    }
                    .onMove { model.state.metricTiles.move(fromOffsets: $0, toOffset: $1); model.save() }
                    .onDelete { model.state.metricTiles.remove(atOffsets: $0); model.save() }
                } header: { Text("Shown, in order") }
                Section("Add") {
                    ForEach(MetricID.allCases.filter { !model.state.metricTiles.contains($0) }, id: \.self) { id in
                        Button { model.state.metricTiles.append(id); model.save() } label: {
                            Label(MetricDef.of(id).title, systemImage: "plus.circle")
                        }
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Life Metrics")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
