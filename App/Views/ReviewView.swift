import SwiftUI
import Charts
import ProductiumCore

// v1.3 Review: one page to look at every day. Your Week (the recap, any time) on top, then today, the numbers at a
// glance (tomorrow's plan included), this week against your last 4, where the time went, screen time per app, goals,
// how you work, mood, Life Metrics, pinned charts, the leaderboard and the Weekly Note. No drilling in to see a stat.

struct ReviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var m = model
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        RecapBanner().id("recap")
                        TodaySummaryCard().id("today")
                        GlanceGrid().id("stats")
                        ScoreWeekCard().id("week")
                        WhereTimeWentCard().id("time")
                        ScreenTimeCard().id("screen")
                        GoalsCard().id("goals")
                        HowYouWorkCard().id("work")
                        MoodMapCard().id("mood")
                        MetricsSection().id("metrics")
                        PinnedList().id("pinned")
                        LeaderboardCard().id("leaderboard")
                        WeeklyNoteCard().id("note")
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 32)
                }
                .onChange(of: model.scrollTarget) { _, t in if let t { proxy.scrollTo(t, anchor: .top) } }
            }
            .background(Theme.background)
            .refreshable { await model.insightPass(force: true) }
            .navigationTitle("Review")
            .usageMeter()
            .fullScreenCover(isPresented: $m.showRecap) { RecapView() }
        }
    }
}

// MARK: - Your Week (opens the recap)

struct RecapBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let cal = Calendar.current
        let end = Date()
        let start = cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: end)) ?? end
        Button { model.showRecap = true } label: {
            HStack(spacing: 14) {
                Image(systemName: "sparkles").font(.system(size: 26, weight: .semibold))
                    .frame(width: 52, height: 52)
                    .background(.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your Week").font(.title3.weight(.bold))
                    Text("\(start.formatted(.dateTime.month(.abbreviated).day())) – \(end.formatted(.dateTime.month(.abbreviated).day()))")
                        .font(.subheadline).opacity(0.85)
                }
                Spacer()
                Image(systemName: "play.circle.fill").font(.system(size: 30))
            }
            .foregroundStyle(.white)
            .padding(16)
            .background(LinearGradient(colors: [.indigo, .purple, .pink], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        }
        .buttonStyle(TilePress())
        .padding(.top, 4)
        .accessibilityHint("Plays your week's recap")
    }
}

// MARK: - Today: rings beside your usual, the score in one line, what changed

struct TodaySummaryCard: View {
    @Environment(AppModel.self) private var model
    @State private var showingDay = false

    var body: some View {
        let cal = Calendar.current
        let now = Date()
        let today = model.rings(now)
        let usual = model.usualRings(now)
        let score = model.dayScore(now)
        let vs = model.scoreVsUsual(now)
        let hours = DayCompare.hours(now, entries: model.state.entries, tree: model.state.categories, now: now,
                                     book: model.state.dayRules, calendar: cal)
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Today")
            Card {
                HStack(spacing: 18) {
                    ActivityRings(rings: today, lineWidth: 14).frame(width: 120, height: 120)
                    RingLegendRows(rings: today, usual: usual)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .onTapGesture { showingDay = true }
                Divider()
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(score.score)").font(.system(.largeTitle, design: .rounded).weight(.bold)).monospacedDigit()
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Day Score").font(.subheadline.weight(.semibold))
                        Text(parts(score)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let vs {
                        VStack(alignment: .trailing, spacing: 0) {
                            Text("\(vs.1)").font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary)
                            Text(vs.2).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                if let line = model.whatChanged(now) {
                    Label(line, systemImage: "arrow.up.arrow.down").font(.footnote).fixedSize(horizontal: false, vertical: true)
                }
                if hours.best != nil || hours.worst != nil {
                    HStack(spacing: 14) {
                        if let h = hours.best { Label("Best \(hourLabel(h))", systemImage: "sun.max.fill").foregroundStyle(.orange) }
                        if let h = hours.worst { Label("Hardest \(hourLabel(h))", systemImage: "cloud.fill").foregroundStyle(.gray) }
                    }
                    .font(.footnote)
                }
                ForEach(model.state.patterns) { p in
                    Label(p.text, systemImage: "lightbulb").font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .sheet(isPresented: $showingDay) { RingDaySheet(day: now) }
    }

    private func parts(_ s: DayScore) -> String {
        "Tracked \(Int(s.tracked.rounded())) · Work \(Int(s.work.rounded())) · Deadlines \(Int(s.deadlines.rounded()))"
            + (s.scrollingMinutes > 0 ? " · Scrolling \(Int(s.scrolling.rounded()))" : "")
    }

    private func hourLabel(_ h: Int) -> String {
        let d = Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: Date()) ?? Date()
        return "\(d.formatted(.dateTime.hour()))–\(d.addingTimeInterval(3600).formatted(.dateTime.hour()))"
    }
}

// MARK: - At a glance: the numbers to check through the day

struct GlanceGrid: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let cal = Calendar.current
        let now = Date()
        let rings = model.rings(now)
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)) ?? now
        let planned = model.plannedShare(tomorrow)
        let apps = model.appMinutesToday()
        let screen = apps.reduce(0) { $0 + $1.minutes }
        let week = (0..<7).compactMap { cal.date(byAdding: .day, value: -$0, to: cal.startOfDay(for: now)) }.map(model.dayScore)
        let due = week.reduce(0) { $0 + $1.deadlinesDue }, met = week.reduce(0) { $0 + $1.deadlinesMet }
        let slept = model.state.health.first { cal.isDateInToday($0.day) }?.sleepMinutes
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("At a Glance")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                StatTile(title: "Tomorrow Planned", symbol: "calendar.badge.clock", color: .indigo, value: "\(planned.percent)", unit: "%",
                         caption: planned.awakeMinutes == 0 ? "Nothing planned yet"
                            : "\(durationLabel(planned.plannedMinutes)) of \(durationLabel(planned.awakeMinutes)) awake",
                         progress: planned.fraction)
                StatTile(title: "Work", symbol: "pencil.line", color: RingStyle.work, value: durationLabel(rings.workMinutes),
                         caption: rings.workGoal == 0 ? "Nothing asked today" : "of \(durationLabel(rings.workGoal)) asked",
                         progress: rings.workGoal == 0 ? nil : rings.work)
                StatTile(title: "Tracked", symbol: "checkmark.circle.fill", color: RingStyle.tracked, value: rings.trackedLabel,
                         caption: rings.trackedSubtitle, progress: rings.tracked)
                StatTile(title: "Unproductive", symbol: "hourglass", color: RingStyle.limit(rings.limit),
                         value: durationLabel(rings.limitMinutes), caption: "limit \(durationLabel(rings.limitGoal))", progress: rings.limit)
                StatTile(title: "Screen Time", symbol: "iphone", color: .teal, value: screen > 0 ? durationLabel(screen) : "–",
                         caption: apps.first.map { "Most: \($0.app), \(durationLabel($0.minutes))" } ?? "Set up “Opened an App”")
                StatTile(title: "Deadlines", symbol: "flag.fill", color: .orange, value: due == 0 ? "None" : "\(met) of \(due)",
                         caption: due == 0 ? "Nothing was due this week" : "met in the last 7 days")
                if let slept {
                    StatTile(title: "Sleep", symbol: "bed.double.fill", color: Theme.sleep, value: durationLabel(slept),
                             caption: "last night, need \(durationLabel(model.state.prefs.sleepNeedMinutes))",
                             progress: Double(slept) / Double(max(1, model.state.prefs.sleepNeedMinutes)))
                }
                if let m = model.todayMood {
                    StatTile(title: "Mood", symbol: "face.smiling", color: .pink, value: MoodButtons.faces.first { $0.0 == m.mood }?.1 ?? "🙂",
                             caption: "at \(m.at.hm)")
                }
            }
        }
    }
}

// MARK: - Where the time went, by period

struct WhereTimeWentCard: View {
    @Environment(AppModel.self) private var model
    @State private var period: MetricPeriod = .day
    @State private var drill: String?

    var body: some View {
        let cal = Calendar.current
        let now = Date()
        let (range, previous) = ranges(now, cal)
        let ring = RingModel.make(entries: model.state.entries, tree: model.state.categories, range: range, now: now, forecast: [:],
                                  previous: previous, book: model.state.dayRules, calendar: cal)
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Where Your Time Went")
            Card {
                Picker("Period", selection: $period) {
                    Text("Day").tag(MetricPeriod.day)
                    Text("Week").tag(MetricPeriod.week)
                    Text("Month").tag(MetricPeriod.month)
                }
                .pickerStyle(.segmented)
                HStack(alignment: .firstTextBaseline) {
                    Text(durationLabel(ring.trackedMinutes)).font(.system(.title2, design: .rounded).weight(.semibold)).monospacedDigit()
                    Text("tracked").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    if ring.untrackedMinutes > 0 {
                        Text("\(durationLabel(ring.untrackedMinutes)) untracked").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                TimeBreakdown(ring: ring, tree: model.state.categories) { drill = $0 }
                Text("▲▼ against the \(period == .day ? "day" : period.rawValue) before. Tap one for its entries.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
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

// MARK: - Screen time per app (the automations), and the week from screenshots

struct ScreenTimeCard: View {
    @Environment(AppModel.self) private var model
    @State private var expanded = false

    var body: some View {
        let cal = Calendar.current
        let apps = model.appMinutesToday()
        let total = apps.reduce(0) { $0 + $1.minutes }
        let days = (1...7).compactMap { cal.date(byAdding: .day, value: -$0, to: cal.startOfDay(for: Date())) }
        let week = ScreenSeries.summary(ScreenSeries.daily(screen: model.state.screen, averages: model.state.screenAverages, days: days, calendar: cal))
        let groups = group(apps)
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Screen Time")
            Card {
                if apps.isEmpty {
                    Text("Productium counts your screen time per app once the “Opened an App” automation is set up. Scrolling apps go under Scrolling, messaging under Messaging.")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    HStack(alignment: .firstTextBaseline) {
                        Text(durationLabel(total)).font(.system(.title2, design: .rounded).weight(.semibold)).monospacedDigit()
                        Text("today").font(.subheadline).foregroundStyle(.secondary)
                    }
                    GeometryReader { g in
                        HStack(spacing: 2) {
                            ForEach(groups, id: \.title) { grp in
                                Rectangle().fill(grp.color)
                                    .frame(width: max(2, (g.size.width - CGFloat(groups.count) * 2) * CGFloat(grp.minutes) / CGFloat(max(1, total))))
                            }
                        }
                        .clipShape(Capsule())
                    }
                    .frame(height: 12)
                    HStack(spacing: 14) {
                        ForEach(groups, id: \.title) { grp in
                            Label("\(grp.title) \(durationLabel(grp.minutes))", systemImage: grp.symbol)
                                .font(.caption).foregroundStyle(grp.color)
                        }
                    }
                    ForEach(Array(apps.prefix(expanded ? 30 : 5).enumerated()), id: \.offset) { _, a in
                        let kind = model.appKind(a.app)
                        HStack(spacing: 12) {
                            IconTile(symbol: kindSymbol(kind), color: kindColor(kind))
                            VStack(alignment: .leading, spacing: 0) {
                                Text(a.app).font(.subheadline)
                                Text(kindName(kind)).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(durationLabel(a.minutes)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    if apps.count > 5 {
                        Button(expanded ? "Show Less" : "Show All \(apps.count) Apps") { withAnimation { expanded.toggle() } }
                            .font(.subheadline).buttonStyle(.borderless)
                    }
                }
                if let week {
                    Divider()
                    Label(week.line, systemImage: "calendar").font(.footnote).foregroundStyle(.secondary)
                }
                NavigationLink { ScreenTimeSettings() } label: {
                    HStack { Text("Scrolling Apps & Automations"); Spacer(); Image(systemName: "chevron.right").foregroundStyle(.tertiary) }
                        .font(.subheadline)
                }
                .foregroundStyle(.primary)
            }
        }
    }

    private struct KindTotal { let title: String; let symbol: String; let color: Color; let minutes: Int }

    private func group(_ apps: [(app: String, minutes: Int)]) -> [KindTotal] {
        var m: [CategoryID?: Int] = [:]
        for a in apps { m[model.appKind(a.app), default: 0] += a.minutes }
        return [CategoryTree.scrolling, CategoryTree.messaging, nil].compactMap { k in
            guard let mins = m[k], mins > 0 else { return nil }
            return KindTotal(title: kindName(k), symbol: kindSymbol(k), color: kindColor(k), minutes: mins)
        }
    }

    private func kindName(_ k: CategoryID?) -> String {
        k == CategoryTree.scrolling ? "Scrolling" : k == CategoryTree.messaging ? "Messaging" : "Other apps"
    }
    private func kindSymbol(_ k: CategoryID?) -> String {
        k == CategoryTree.scrolling ? "hourglass" : k == CategoryTree.messaging ? "message.fill" : "app.fill"
    }
    private func kindColor(_ k: CategoryID?) -> Color {
        k.map { Theme.color(category: $0, tree: model.state.categories) } ?? Color(.systemGray)
    }
}

// MARK: - The Weekly Note

struct WeeklyNoteCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Weekly Note")
            Card {
                if let at = model.state.reviewAt {
                    Text(at.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())).font(.caption).foregroundStyle(.secondary)
                }
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
}

// MARK: - Pinned charts

struct PinnedList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.state.pinnedCharts.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("Pinned")
                Card {
                    ForEach(Array(model.state.pinnedCharts.enumerated()), id: \.element.id) { i, p in
                        if i > 0 { Divider() }
                        NavigationLink {
                            ScrollView { LiveChart(query: p.query, title: p.title, pinnedId: p.id).padding(16) }
                                .background(Theme.background)
                                .navigationTitle(p.title)
                        } label: {
                            HStack { Text(p.title).font(.subheadline); Spacer(); Image(systemName: "chevron.right").foregroundStyle(.tertiary) }
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
        }
    }
}

// MARK: - I3: goals

struct GoalsCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let cal = Calendar.current
        let week = (0..<7).compactMap { cal.date(byAdding: .day, value: -$0, to: cal.startOfDay(for: Date())) }
        TitledCard("Goals") {
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

// MARK: - G8 / C2: the week against your last 4

struct ScoreWeekCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let days = (0..<7).reversed().compactMap { cal.date(byAdding: .day, value: -$0, to: today) }
        let scores = days.map { ($0, model.dayScore($0)) }
        let before = (7..<35).compactMap { cal.date(byAdding: .day, value: -$0, to: today) }.map(model.dayScore)
        let mood = MoodMap.make(model.state.moods, since: Date().addingTimeInterval(-30 * 86400), isSchoolDay: model.isSchoolDay, calendar: cal)
        TitledCard("This Week", detail: "vs your last 4 weeks") {
            Chart(scores, id: \.0) { d, s in
                BarMark(x: .value("Day", d, unit: .day), y: .value("Score", s.score), width: .ratio(0.55))
                    .foregroundStyle(LinearGradient(colors: [.indigo, .blue], startPoint: .bottom, endPoint: .top))
                    .cornerRadius(5)
                    .annotation(position: .top) { Text("\(s.score)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }
            }
            .chartYScale(domain: 0...115)
            .chartYAxis(.hidden)
            .frame(height: 120)
            HStack(spacing: 4) {
                ForEach(days, id: \.self) { d in
                    VStack(spacing: 2) {
                        ActivityRings(rings: model.rings(d), lineWidth: 4).frame(width: 38, height: 38)
                        Text(d.formatted(.dateTime.weekday(.narrow))).font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            let week = totals(scores.map { $0.1 })
            let avg = totals(before).map { $0 / 4 }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow { stat("Tracked", durationLabel(week[0]), durationLabel(avg[0])); stat("Work", durationLabel(week[1]), durationLabel(avg[1])) }
                GridRow {
                    stat("Deadlines", week[3] == 0 ? "none due" : "\(week[2]) met, \(week[3] - week[2]) missed",
                         avg[3] == 0 ? nil : "\(avg[2]) of \(avg[3])")
                    stat("Scrolling", durationLabel(week[4]), durationLabel(avg[4]))
                }
            }
            if let n = mood.noticed { Label(n, systemImage: "face.smiling").font(.subheadline) }
        }
    }

    /// Tracked, work, deadlines met, deadlines due, scrolling.
    private func totals(_ xs: [DayScore]) -> [Int] {
        [xs.reduce(0) { $0 + $1.wakingMinutes - $1.untrackedMinutes }, xs.reduce(0) { $0 + $1.workMinutes },
         xs.reduce(0) { $0 + $1.deadlinesMet }, xs.reduce(0) { $0 + $1.deadlinesDue }, xs.reduce(0) { $0 + $1.scrollingMinutes }]
    }

    private func stat(_ t: String, _ v: String, _ usual: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(t).font(.caption).foregroundStyle(.secondary)
            Text(v).font(.subheadline.weight(.semibold)).monospacedDigit()
            if let usual { Text("usual \(usual)").font(.caption2).foregroundStyle(.secondary) }
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
            TitledCard("Mood by Time of Day", detail: "Last 30 days") {
                let cells = map.cells.flatMap { wd, hs in hs.map { MoodCell(weekday: wd, hour: $0.key, mood: $0.value) } }
                // Each cell spans its hour explicitly: with an automatic width, two cells at the same hour (any two days)
                // make Charts divide by a zero spacing and crash.
                // Rows in the calendar's week order, top to bottom; every cell spans its hour and its whole row.
                let order = (0..<7).map { cal.shortWeekdaySymbols[(cal.firstWeekday - 1 + $0) % 7] }
                let row: (Int) -> Double = { wd in Double(6 - (wd - cal.firstWeekday + 7) % 7) }
                Chart(cells.filter { (6...23).contains($0.hour) }) { c in
                    RectangleMark(xStart: .value("Hour", c.hour), xEnd: .value("Hour", c.hour + 1),
                                  yStart: .value("Day", row(c.weekday) + 0.06), yEnd: .value("Day", row(c.weekday) + 0.94))
                        .foregroundStyle(by: .value("Mood", c.mood))
                }
                .chartForegroundStyleScale(domain: 1.0...5.0, range: Gradient(colors: [Color.red.opacity(0.6), Color.yellow, Color.green]))
                .chartXScale(domain: 6...24)
                .chartYScale(domain: 0.0...7.0)
                .chartYAxis {
                    AxisMarks(position: .leading, values: (0..<7).map { Double($0) + 0.5 }) { v in
                        AxisValueLabel { Text(order[6 - Int(v.as(Double.self) ?? 0)]) }
                    }
                }
                .frame(height: 170)
                if let n = map.noticed { Text(n).font(.subheadline) }
            }
        }
    }
}

struct MoodCell: Identifiable {
    let weekday: Int, hour: Int, mood: Double
    var id: Int { weekday * 100 + hour }
}

// MARK: - How you work: follow-through and good hours, learned from each finished day's log

struct HowYouWorkCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let l = model.state.learned
        TitledCard("How You Work") {
            if l.adherenceSamples < 3 {
                Text("Learning from your log: \(l.adherenceSamples) planned session\(l.adherenceSamples == 1 ? "" : "s") read so far. Each finished day adds more.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                LabeledContent("Planned sessions done", value: "\(Int((l.adherence * 100).rounded()))%")
                let hours = l.goodHours()
                if !hours.isEmpty {
                    LabeledContent("Best hours", value: hours.sorted().map(hourLabel).joined(separator: ", "))
                }
                LabeledContent("Focus block", value: durationLabel(Int(l.focusMinutes)))
                Text("Plans put work in your best hours and size the day to what you usually finish.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func hourLabel(_ h: Int) -> String {
        let d = Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: Date()) ?? Date()
        return d.formatted(.dateTime.hour())
    }
}

// MARK: - Leaderboard: friends added by link, compared on the day score (or vs their own usual)

struct LeaderboardCard: View {
    @Environment(AppModel.self) private var model
    @State private var groupId: String?
    @State private var metric: Leaderboard.Metric = .score
    @State private var adding = false
    @State private var confirmLeave = false

    var body: some View {
        let lb = model.state.leaderboard
        let group = lb.groups.first { $0.id == groupId } ?? lb.groups.first
        TitledCard("Leaderboard", detail: group?.name) {
            if lb.groups.isEmpty || model.pendingInvite != nil {
                Text(model.pendingInvite != nil ? "Pick the name your friends will see to join."
                     : "Compare your days with friends. Only your day scores and a name are shared, never what you did.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button(model.pendingInvite != nil ? "Join" : "Start or Join a Group") { adding = true }
                    .buttonStyle(.borderedProminent)
            }
            if let g = group {
                if lb.groups.count > 1 {
                    Picker("Group", selection: Binding(get: { g.id }, set: { groupId = $0 })) {
                        ForEach(lb.groups) { Text($0.name).tag($0.id) }
                    }
                    .pickerStyle(.menu)
                }
                Picker("Measure", selection: $metric) {
                    ForEach(Leaderboard.Metric.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                let rows = lb.boards[g.id].map { Leaderboard.rows($0, metric: metric, you: g.memberId, today: Date(), calendar: .current) } ?? []
                if rows.isEmpty {
                    Text("Loading…").font(.subheadline).foregroundStyle(.secondary)
                } else {
                    ForEach(rows) { r in
                        HStack {
                            Text(r.rank > 0 ? "\(r.rank)" : "–").font(.subheadline.monospacedDigit()).frame(width: 22, alignment: .leading)
                                .foregroundStyle(.secondary)
                            Text(r.isYou ? "\(r.name) (you)" : r.name).font(r.isYou ? .subheadline.weight(.semibold) : .subheadline)
                            Spacer()
                            Text(r.label).font(.subheadline.monospacedDigit().weight(.semibold))
                        }
                        .accessibilityElement(children: .combine)
                    }
                    Text(metric == .vsUsual ? "Last 7 days' average score minus each person's own usual." : "Last 7 days.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    if let url = Leaderboard.invite(g, scheme: AppInfo.scheme) {
                        ShareLink(item: url, message: Text("Join \(g.name) on Productium")) { Label("Invite", systemImage: "person.badge.plus") }
                    }
                    Spacer()
                    Menu {
                        Button("Start or Join Another Group") { adding = true }
                        Button("Leave \(g.name)", role: .destructive) { confirmLeave = true }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
                .font(.subheadline)
                .confirmationDialog("Leave \(g.name)? Your row is removed for everyone.", isPresented: $confirmLeave, titleVisibility: .visible) {
                    Button("Leave", role: .destructive) { Task { await model.leaveLeaderboard(g.id) } }
                }
            }
        }
        .task { await model.refreshLeaderboards() }
        .sheet(isPresented: $adding) { JoinLeaderboardSheet() }
    }
}

struct JoinLeaderboardSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var groupName = ""
    @State private var link = ""
    @State private var working = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Your name", text: $name).textContentType(.nickname)
                } header: { Text("Shown to your friends") }
                if model.pendingInvite == nil {
                    Section {
                        TextField("Paste an invite link", text: $link).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Join") { run { await model.joinLeaderboard(link) } }
                            .disabled(link.isEmpty || name.trimmed.isEmpty)
                    } header: { Text("Join") }
                    Section {
                        TextField("Group name", text: $groupName)
                        Button("Start Group") { run { await model.createLeaderboard(named: groupName.trimmed) != nil } }
                            .disabled(groupName.trimmed.isEmpty || name.trimmed.isEmpty)
                    } header: { Text("Start a new group") } footer: {
                        Text("You'll get a link to send. Anyone with it can see the group's scores and join.")
                    }
                } else {
                    Button("Join") { run { await model.joinLeaderboard(model.pendingInvite ?? "") } }
                        .disabled(name.trimmed.isEmpty)
                }
            }
            .disabled(working)
            .navigationTitle("Leaderboard")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear { name = model.state.leaderboard.displayName }
        }
    }

    private func run(_ action: @escaping () async -> Bool) {
        model.state.leaderboard.displayName = String(name.trimmed.prefix(40))
        working = true
        Task {
            let ok = await action()
            working = false
            if ok { dismiss() }
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
