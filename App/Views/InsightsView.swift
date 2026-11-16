import SwiftUI
import Charts
import DeviceActivity
import ProductiumCore

/// Where the time went. Seeing your own data is itself an intervention: monitoring goal
/// progress improves attainment (Harkin et al. 2016). Few numbers, one chart at a time.
struct InsightsView: View {
    @Environment(AppModel.self) private var model
    @State private var view: Pane = .time
    @State private var range = 7
    @State private var showCoach = false
    @State private var exportURLs: [URL] = []

    enum Pane: String, CaseIterable, Identifiable {
        case time = "Time", day = "Day", sleep = "Sleep", mood = "Mood", screen = "Screen", habits = "You"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ReviewCard(showCoach: $showCoach)
                    Picker("", selection: $view) { ForEach(Pane.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented)
                    if view != .day && view != .habits {
                        Picker("", selection: $range) { Text("7 days").tag(7); Text("30 days").tag(30) }
                            .pickerStyle(.segmented).frame(width: 200)
                    }
                    let days = model.dayTotals(last: range, includeToday: view == .screen)
                    switch view {
                    case .time: TimeChart(days: days)
                    case .day: DayRibbon()
                    case .sleep: SleepChart(days: days, need: model.state.prefs.sleepNeedMinutes)
                    case .mood: MoodChart(days: days)
                    case .screen: ScreenChart(days: days)
                    case .habits: HabitsPane()
                    }
                }
                .padding()
            }
            .navigationTitle("Insights")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showCoach = true } label: { Image(systemName: "bubble.left.and.text.bubble.right") }
                        .accessibilityLabel("Ask")
                    if !exportURLs.isEmpty {
                        ShareLink(items: exportURLs) { Image(systemName: "square.and.arrow.up") }
                    } else {
                        Button { exportURLs = (try? model.exportFiles()) ?? [] } label: { Image(systemName: "square.and.arrow.up") }
                            .accessibilityLabel("Export")
                    }
                    NavigationLink { SettingsView() } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showCoach) { CoachView() }
        }
    }
}

struct ReviewCard: View {
    @Environment(AppModel.self) private var model
    @Binding var showCoach: Bool

    var body: some View {
        if let r = model.state.review {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle("This week")
                    Text(r.headline).font(.headline)
                    ForEach(r.wins, id: \.self) { Label($0, systemImage: "checkmark.seal").font(.subheadline) }
                    ForEach(r.suggestions, id: \.self) { Label($0, systemImage: "arrow.turn.down.right").font(.subheadline).foregroundStyle(.secondary) }
                    if r.changes != nil {
                        Button("Apply suggested tweaks") { model.applyReviewChanges() }.buttonStyle(.bordered)
                    }
                }
            }
        } else if model.busy.contains("review") {
            Card { HStack { ProgressView(); Text("Writing your weekly review…").foregroundStyle(.secondary) } }
        }
    }
}

struct TimeChart: View {
    let days: [DayTotals]
    private let cats: [TimeCategory] = [.sleep, .school, .activities, .study, .commute, .routine, .screen, .free]

    var body: some View {
        let n = max(1, days.count)
        VStack(alignment: .leading, spacing: 14) {
            Chart {
                ForEach(days, id: \.day) { d in
                    ForEach(cats, id: \.self) { c in
                        BarMark(x: .value("Day", d.day, unit: .day), y: .value("Hours", Double(d.minutes[c] ?? 0) / 60))
                            .foregroundStyle(by: .value("Category", c.label))
                    }
                }
            }
            .chartForegroundStyleScale(domain: cats.map(\.label), range: cats.map { Theme.color(for: $0) })
            .chartYScale(domain: 0...24)
            .frame(height: 260)
            Card {
                VStack(spacing: 8) {
                    ForEach(cats, id: \.self) { c in
                        let avg = days.reduce(0) { $0 + ($1.minutes[c] ?? 0) } / n
                        HStack {
                            Circle().fill(Theme.color(for: c)).frame(width: 8, height: 8)
                            Text(c.label).font(.subheadline)
                            Spacer()
                            Text("\(minutesLabel(avg))/day").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Text("Travel and routines fill in automatically from what Productium has learned. Check-ins correct them.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// A single day reconstructed: observed (solid) vs. inferred (faded).
struct DayRibbon: View {
    @Environment(AppModel.self) private var model
    @State private var offset = 0

    var body: some View {
        let day = Calendar.current.date(byAdding: .day, value: -offset, to: Calendar.current.startOfDay(for: Date()))!
        let segs = model.segments(on: day).filter { $0.category != .sleep || $0.minutes < 600 }
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { offset += 1 } label: { Image(systemName: "chevron.left") }
                Spacer()
                Text(day.formatted(.dateTime.weekday(.wide).month().day())).font(.headline)
                Spacer()
                Button { offset = max(0, offset - 1) } label: { Image(systemName: "chevron.right") }.disabled(offset == 0)
            }
            Chart(segs, id: \.start) { s in
                BarMark(xStart: .value("Start", s.start), xEnd: .value("End", s.end), y: .value("", "day"))
                    .foregroundStyle(Theme.color(for: s.category).opacity(s.inferred ? 0.45 : 1))
            }
            .chartYAxis(.hidden)
            .frame(height: 60)
            ForEach(model.segments(on: day).filter { $0.minutes >= 10 }, id: \.start) { s in
                HStack {
                    Text(s.start.hm).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                    Circle().fill(Theme.color(for: s.category)).frame(width: 8, height: 8)
                    Text(s.label).font(.subheadline)
                    if s.inferred { Text("assumed").font(.caption2).foregroundStyle(.tertiary) }
                    Spacer()
                    Text(minutesLabel(s.minutes)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct SleepChart: View {
    let days: [DayTotals]
    let need: Int

    var body: some View {
        let slept = days.compactMap(\.sleep)
        VStack(alignment: .leading, spacing: 12) {
            if slept.isEmpty {
                ContentUnavailableView("No sleep data", systemImage: "bed.double", description: Text("Turn on Health in Settings. An Apple Watch or the iPhone sleep schedule both work."))
            } else {
                Text("Average \(minutesLabel(slept.reduce(0, +) / slept.count))").font(.title2.weight(.semibold))
                Chart {
                    ForEach(days, id: \.day) { d in
                        if let s = d.sleep {
                            BarMark(x: .value("Day", d.day, unit: .day), y: .value("Hours", Double(s) / 60))
                                .foregroundStyle(s >= need - 30 ? Color.blue.opacity(0.6) : Color.orange.opacity(0.7))
                        }
                    }
                    RuleMark(y: .value("Need", Double(need) / 60)).lineStyle(StrokeStyle(dash: [4])).foregroundStyle(.secondary)
                }
                .frame(height: 220)
                Text("Teens need 8–10 hours. Regular bed and wake times matter almost as much as the total.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct MoodChart: View {
    @Environment(AppModel.self) private var model
    let days: [DayTotals]

    var body: some View {
        let summary = Insights.summarize(days, learned: model.state.learned)
        VStack(alignment: .leading, spacing: 12) {
            Chart {
                ForEach(days, id: \.day) { d in
                    BarMark(x: .value("Day", d.day, unit: .day), y: .value("Study (h)", Double(d.doneStudy) / 60))
                        .foregroundStyle(Theme.accent.opacity(0.25))
                    if let m = d.mood {
                        LineMark(x: .value("Day", d.day, unit: .day), y: .value("Mood", m)).interpolationMethod(.catmullRom)
                        PointMark(x: .value("Day", d.day, unit: .day), y: .value("Mood", m))
                    }
                }
            }
            .chartYScale(domain: 0...5)
            .frame(height: 220)
            Text("Line: mood (1–5) · bars: hours studied").font(.caption).foregroundStyle(.secondary)
            ForEach(summary.patterns, id: \.self) { Label($0, systemImage: "lightbulb").font(.subheadline) }
            if summary.patterns.isEmpty {
                Text("Patterns show up after a week or two of check-ins.").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

struct ScreenChart: View {
    @Environment(AppModel.self) private var model
    let days: [DayTotals]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.state.integrations.screenTime {
                Card {
                    DeviceActivityReport(.init("Total Activity"), filter: DeviceActivityFilter(
                        segment: .daily(during: Calendar.current.dateInterval(of: .day, for: Date())!)))
                        .frame(minHeight: 160)
                }
                let t = model.state.taper
                if let target = t.targetMinutes {
                    Text("Daily limit \(minutesLabel(target)), down from \(minutesLabel(t.baselineMinutes ?? target))")
                        .font(.headline)
                } else {
                    Text("Measuring your baseline for a week. No limits yet.").font(.headline)
                }
                Chart {
                    ForEach(days, id: \.day) { d in
                        if let s = d.screen {
                            BarMark(x: .value("Day", d.day, unit: .day), y: .value("Minutes", s))
                                .foregroundStyle(Theme.color(for: .screen).opacity(0.7))
                        }
                        if let target = d.screenTarget {
                            LineMark(x: .value("Day", d.day, unit: .day), y: .value("Limit", target)).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(height: 200)
                ForEach(t.history.suffix(3).reversed(), id: \.weekStart) { s in
                    Text(s.note).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                ContentUnavailableView("Screen Time is off", systemImage: "hourglass",
                                       description: Text("Turn it on in Settings to measure scrolling and taper it gradually."))
            }
        }
    }
}

struct HabitsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = Insights.summarize(model.dayTotals(last: 14), learned: model.state.learned)
        let l = model.state.learned
        VStack(alignment: .leading, spacing: 14) {
            Card {
                VStack(alignment: .leading, spacing: 6) {
                    SectionTitle("Follow-through")
                    Text(s.followThrough.map { "\(Int($0 * 100))%" } ?? "–").font(.largeTitle.weight(.semibold))
                    Text("of planned study done in the last 2 weeks. Plans scale to what you actually do (currently \(Int(l.loadFactor * 100))% load).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    SectionTitle("When you get work done")
                    Chart(Array(6..<24), id: \.self) { h in
                        BarMark(x: .value("Hour", h), y: .value("Reliability", l.hourReliability(h)))
                            .foregroundStyle(Theme.accent.opacity(0.3 + 0.7 * l.hourReliability(h)))
                    }
                    .chartYAxis(.hidden)
                    .frame(height: 120)
                    Text("Chronotype: \((l.inferredChronotype ?? model.state.prefs.chronotype).rawValue). Focus block: \(Int(l.focusMinutes)) min.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    SectionTitle("Learned routines")
                    ForEach(model.state.routines) { r in
                        HStack {
                            Text(r.name).font(.subheadline)
                            Spacer()
                            Text(r.isLearned ? "\(r.minutes) min · \(r.samples.count) days" : "\(r.defaultMinutes) min (guess)")
                                .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !s.estimateFactors.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle("How long things really take")
                        ForEach(s.estimateFactors.keys.sorted(), id: \.self) { k in
                            HStack {
                                Text(k.capitalized).font(.subheadline)
                                Spacer()
                                Text("×\(String(format: "%.1f", s.estimateFactors[k] ?? 1)) your estimate").font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }
}

struct CoachView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if model.state.chat.isEmpty {
                            Text("Ask about your week, how to study for something, or whether to stay up for a deadline.")
                                .foregroundStyle(.secondary).padding(.top, 40)
                        }
                        ForEach(Array(model.state.chat.enumerated()), id: \.offset) { i, m in
                            HStack {
                                if m.role == "user" { Spacer(minLength: 40) }
                                Text(m.content)
                                    .padding(12)
                                    .background(m.role == "user" ? Theme.accent.opacity(0.15) : Color(.secondarySystemBackground),
                                                in: RoundedRectangle(cornerRadius: 16))
                                if m.role != "user" { Spacer(minLength: 40) }
                            }
                            .id(i)
                        }
                        if model.busy.contains("coach") { ProgressView().padding() }
                    }
                    .padding()
                }
                .onChange(of: model.state.chat.count) { _, n in withAnimation { proxy.scrollTo(n - 1) } }
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    TextField("Ask…", text: $text, axis: .vertical).lineLimit(1...4).textFieldStyle(.roundedBorder)
                    Button {
                        let q = text
                        text = ""
                        Task { await model.ask(q) }
                    } label: { Image(systemName: "arrow.up.circle.fill").font(.title) }
                        .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || model.busy.contains("coach"))
                }
                .padding()
                .background(.bar)
            }
            .navigationTitle("Ask")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }
}
