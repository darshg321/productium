import SwiftUI
import Charts
import ProductiumCore

// v1.2 G.1: Review, top to bottom. You open it every evening, so insights live here, not on Home.
// 0. Today: untracked stretches to fill, assumed time to confirm, the day score with its parts vs your usual, patterns.
// 1. The ring for a day / week / month, with drill-down and the last period beside each slice.
// 2. Goals. 3. The day score and the four numbers that matter, then Life Metrics. 4. Mood by time of day.
// 5. Where. 6. Pinned charts. 7. The Weekly Note.

struct ReviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    EndOfDayCard()
                    RingSection()
                    GoalsCard()
                    ScoreWeekCard()
                    MetricsSection()
                    MoodMapCard()
                    WhereCard()
                    ForEach(model.state.pinnedCharts) { p in LiveChart(query: p.query, title: p.title, pinnedId: p.id) }
                    note
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .background(Theme.background)
            .refreshable { await model.insightPass(force: true) }
            .navigationTitle("Review")
            .usageMeter()
        }
    }

    @ViewBuilder private var note: some View {
        Card {
            CardHeader(title: "Weekly Note", symbol: "sparkles", color: .teal,
                       detail: model.state.reviewAt.map { $0.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) })
            if let r = model.state.review {
                Text(r.headline).font(.headline).fixedSize(horizontal: false, vertical: true)
                ForEach(r.wins + r.suggestions, id: \.self) { line in
                    Text(line).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                }
            } else if model.busy.contains("review") {
                HStack(spacing: 10) { ProgressView(); Text("Claude is reading your week…").foregroundStyle(.secondary) }
            } else {
                Text("Your first weekly note arrives after a few days of use. Pull down to ask for one now.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            // J2: alarms the insight pass proposed wait here for Allow.
            ForEach(model.approvals.filter { $0.source == .insight }) { a in ApprovalRow(approval: a) }
        }
    }
}

// MARK: - G7: the end-of-day review

struct EndOfDayCard: View {
    @Environment(AppModel.self) private var model
    @State private var editing: DayEntry?

    var body: some View {
        let cal = Calendar.current
        let now = Date()
        let today = Days.dayInterval(now, cal)
        let slices = TimeLog.past(model.state.entries, in: today, now: now, book: model.state.dayRules, calendar: cal)
        let gaps = TimeLog.untracked(slices, atLeast: 15).filter { $0.start >= today.start.addingTimeInterval(6 * 3600) }
        let assumed = TimeLog.assumed(slices).filter { $0.end <= now && !model.state.categories.isUnder($0.category, CategoryTree.sleep) }
        let buttons = model.startButtons(now: now).row.prefix(4)
        let score = model.dayScore(now)
        Card {
            CardHeader(title: "Today", symbol: "checkmark.seal.fill", color: .green,
                       detail: gaps.isEmpty && assumed.isEmpty ? "All accounted for" : nil)
            if !gaps.isEmpty {
                Text("What were these?").font(.subheadline.weight(.semibold))
                ForEach(gaps, id: \.start) { g in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(g.start.hm)–\(g.end.hm) · \(durationLabel(g.minutes))").font(.subheadline)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(Array(buttons)) { b in
                                    Button(b.title) { model.logStretch(b.title, DateInterval(start: g.start, end: g.end)) }
                                        .buttonStyle(.bordered).buttonBorderShape(.capsule).font(.caption)
                                }
                            }
                        }
                    }
                }
                Text("Or tell the box (“3 to 4 I was at the library”).").font(.caption).foregroundStyle(.secondary)
            }
            if !assumed.isEmpty {
                HStack {
                    Text("Did these happen?").font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("Yes to All") { model.confirmAll(in: DateInterval(start: today.start, end: now)) }.font(.subheadline)
                }
                ForEach(assumed) { d in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(d.title).font(.subheadline)
                            Text("\(d.start.hm)–\(d.end.hm)").font(.caption).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { editing = d }
                        Spacer()
                        Button { model.confirm(d) } label: { Image(systemName: "checkmark.circle.fill") }.foregroundStyle(.green)
                            .accessibilityLabel("Yes, \(d.title) happened")
                        Button { model.reject(d) } label: { Image(systemName: "xmark.circle.fill") }.foregroundStyle(.secondary)
                            .accessibilityLabel("No, \(d.title) didn't happen")
                    }
                    .font(.title3).buttonStyle(.borderless)
                }
            }
            DayScoreView(score: score, usual: model.scoreVsUsual(now).map { ($0.1, $0.2, $0.3) })
            ForEach(model.state.patterns) { p in
                Label(p.text, systemImage: "lightbulb").font(.subheadline).fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(item: $editing) { EntrySheet(day: $0) }
    }
}

/// G.0c: the score, never alone: its four parts, and your usual similar day beside it.
struct DayScoreView: View {
    let score: DayScore
    let usual: (Int, String, [String])?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(score.score)").font(.system(.largeTitle, design: .rounded).weight(.bold)).monospacedDigit()
                Text("day score").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                if let u = usual { Text("\(u.1): \(u.0)").font(.subheadline).foregroundStyle(.secondary) }
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                row("Tracked", "\(durationLabel(score.wakingMinutes - score.untrackedMinutes)) of \(durationLabel(score.wakingMinutes)) awake",
                    score.tracked, DayScore.trackedPoints)
                row("Work", score.askedMinutes == 0 ? "\(durationLabel(score.workMinutes)), nothing asked" :
                        "\(durationLabel(score.workMinutes)) of \(durationLabel(score.askedMinutes))", score.work, DayScore.workPoints)
                row("Deadlines", score.deadlinesDue == 0 ? "none due" : "\(score.deadlinesMet) of \(score.deadlinesDue) met",
                    score.deadlines, DayScore.deadlinePoints)
                row("Scrolling", durationLabel(score.scrollingMinutes), score.scrolling, 0)
            }
            if let d = usual?.2, !d.isEmpty { Text(d.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }
        }
        .accessibilityElement(children: .combine)
    }

    private func row(_ name: String, _ detail: String, _ points: Double, _ of: Double) -> some View {
        GridRow {
            Text(name).font(.caption.weight(.semibold))
            Text(detail).font(.caption).foregroundStyle(.secondary)
            Text(of > 0 ? "\(Int(points.rounded()))/\(Int(of))" : "\(Int(points.rounded()))").font(.caption.monospacedDigit())
        }
    }
}

// MARK: - G1 / G5: the ring for a period

struct RingSection: View {
    @Environment(AppModel.self) private var model
    @State private var period: MetricPeriod = .week
    @State private var drill: String?

    var body: some View {
        let cal = Calendar.current
        let now = Date()
        let (range, previous) = ranges(now, cal)
        let ring = RingModel.make(entries: model.state.entries, tree: model.state.categories, range: range, now: now, forecast: [:],
                                  previous: previous, book: model.state.dayRules, calendar: cal)
        Card {
            CardHeader(title: "Where Your Time Went", symbol: "chart.pie.fill", color: .blue)
            Picker("Period", selection: $period) {
                Text("Day").tag(MetricPeriod.day)
                Text("Week").tag(MetricPeriod.week)
                Text("Month").tag(MetricPeriod.month)
            }
            .pickerStyle(.segmented)
            TimeRing(ring: ring, tree: model.state.categories, selection: $drill, centre: durationLabel(ring.trackedMinutes),
                     centreCaption: "tracked")
                .frame(height: 220)
            RingLegend(ring: ring, tree: model.state.categories)
            Text("▲▼ against the \(period == .day ? "day" : period.rawValue) before. Tap a slice for its entries.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .sheet(item: Binding(get: { drill.map(Drill.init) }, set: { drill = $0?.id })) { d in
            DrillSheet(id: d.id, range: range, title: period.rawValue.capitalized)
        }
    }

    private func ranges(_ now: Date, _ cal: Calendar) -> (DateInterval, DateInterval) {
        let unit: Calendar.Component = period == .day ? .day : period == .week ? .weekOfYear : .month
        let r = cal.dateInterval(of: unit, for: now) ?? Days.dayInterval(now, cal)
        let prevStart = cal.date(byAdding: unit, value: -1, to: r.start) ?? r.start
        return (r, DateInterval(start: prevStart, end: r.start))
    }
}

// MARK: - I3: goals

struct GoalsCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let cal = Calendar.current
        let week = (0..<7).compactMap { cal.date(byAdding: .day, value: -$0, to: cal.startOfDay(for: Date())) }
        Card {
            CardHeader(title: "Goals", symbol: "target", color: .orange)
            ForEach(model.goalsAll) { g in
                let p = model.progress(g)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(p.line).font(.subheadline)
                        Spacer()
                        if g.period == .day {
                            let n = Goals.daysMet(g, days: week, entries: model.state.entries, tree: model.state.categories,
                                                  items: model.state.items, now: Date(), book: model.state.dayRules, calendar: cal)
                            Text("\(n) of 7 days").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if g.measure != .trackingGaps {
                        ProgressView(value: p.fraction).tint(g.direction == .atMost ? (p.met ? .green : .orange) : (p.met ? .green : .blue))
                    }
                }
            }
            let suggestions = model.suggestedGoals
            if !suggestions.isEmpty {
                Text("Suggested, just above what you already do:").font(.caption).foregroundStyle(.secondary)
                ForEach(suggestions) { s in
                    HStack {
                        Text("\(s.title) \(s.direction == .atMost ? "under" : "at least") \(durationLabel(s.target)) a \(s.period.rawValue)")
                            .font(.subheadline)
                        Spacer()
                        Button("Add") { model.addGoal(s) }.buttonStyle(.bordered)
                    }
                }
            }
            Text("Set or change one in the box: “my goal is 10 hours of studying a week”.").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: - G8: the week's scores and the four numbers that matter

struct ScoreWeekCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let cal = Calendar.current
        let days = (0..<7).reversed().compactMap { cal.date(byAdding: .day, value: -$0, to: cal.startOfDay(for: Date())) }
        let scores = days.map { ($0, model.dayScore($0)) }
        Card {
            CardHeader(title: "This Week", symbol: "chart.bar.fill", color: .indigo)
            Chart(scores, id: \.0) { d, s in
                BarMark(x: .value("Day", d, unit: .day), y: .value("Score", s.score))
                    .foregroundStyle(Theme.focus)
            }
            .chartYScale(domain: 0...100)
            .frame(height: 110)
            let tracked = scores.reduce(0) { $0 + $1.1.wakingMinutes - $1.1.untrackedMinutes }
            let work = scores.reduce(0) { $0 + $1.1.workMinutes }
            let met = scores.reduce(0) { $0 + $1.1.deadlinesMet }, due = scores.reduce(0) { $0 + $1.1.deadlinesDue }
            let scroll = scores.reduce(0) { $0 + $1.1.scrollingMinutes }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow { stat("Tracked", durationLabel(tracked)); stat("Work", durationLabel(work)) }
                GridRow { stat("Deadlines", due == 0 ? "none due" : "\(met) met, \(due - met) missed"); stat("Scrolling", durationLabel(scroll)) }
            }
        }
    }

    private func stat(_ t: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(t).font(.caption).foregroundStyle(.secondary)
            Text(v).font(.subheadline.weight(.semibold)).monospacedDigit()
        }
    }
}

// MARK: - G6: mood by time of day

struct MoodMapCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let cal = Calendar.current
        let map = MoodMap.make(model.state.moods, since: Date().addingTimeInterval(-30 * 86400), isSchoolDay: model.isSchoolDay, calendar: cal)
        if !map.cells.isEmpty {
            Card {
                CardHeader(title: "Mood by Time of Day", symbol: "face.smiling", color: .pink, detail: "Last 30 days")
                let cells = map.cells.flatMap { wd, hs in hs.map { MoodCell(weekday: wd, hour: $0.key, mood: $0.value) } }
                Chart(cells) { c in
                    RectangleMark(x: .value("Hour", c.hour), y: .value("Day", cal.shortWeekdaySymbols[c.weekday - 1]))
                        .foregroundStyle(by: .value("Mood", c.mood))
                }
                .chartForegroundStyleScale(range: Gradient(colors: [Color.red.opacity(0.6), Color.yellow, Color.green]))
                .chartXScale(domain: 6...23)
                .frame(height: 170)
                if let n = map.noticed { Text(n).font(.subheadline) }
            }
        }
    }
}

// MARK: - E4: where

struct WhereCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let cal = Calendar.current
        let week = DateInterval(start: cal.date(byAdding: .day, value: -7, to: Date()) ?? Date(), end: Date())
        let rows = Where.rows(visits: model.state.trace.visits, book: model.state.placeBook, entries: model.state.entries, range: week, now: Date())
        if !rows.isEmpty {
            Card {
                CardHeader(title: "Where", symbol: "mappin.and.ellipse", color: .red, detail: "Last 7 days")
                Chart(rows.prefix(6)) { r in
                    SectorMark(angle: .value("Minutes", r.minutes), innerRadius: .ratio(0.6), angularInset: 1)
                        .foregroundStyle(by: .value("Place", r.name))
                }
                .frame(height: 150)
                ForEach(rows.prefix(8)) { r in
                    VStack(alignment: .leading, spacing: 2) {
                        LabeledContent(r.name, value: durationLabel(r.minutes))
                        if !r.top.isEmpty {
                            Text(r.top.map { "\(model.state.categories.node($0.0)?.name ?? $0.0) \(durationLabel($0.1))" }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .font(.subheadline)
                }
                Text("Name a place by telling the box where you are: “this is the library”.").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct MoodCell: Identifiable {
    let weekday: Int, hour: Int, mood: Double
    var id: Int { weekday * 100 + hour }
}
