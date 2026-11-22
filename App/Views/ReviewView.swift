import SwiftUI
import Charts
import ProductiumCore

// v1.3 C2: Review is opened once a day and once a week, so it has two segments and nothing else.
// Day: the score and its parts against your usual day of this kind, today's rings beside your usual day's, the best and
// worst hour, and what changed it. Week: this week against the last 4 (score per day, the rings per day, the four
// numbers that matter), goals, how you work, the leaderboard, pinned charts, the Weekly Note, then "More stats".

enum ReviewSegment: String, CaseIterable {
    case day, week
}

struct ReviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var m = model
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Picker("Review", selection: $m.reviewSegment) {
                            Text("Day").tag(ReviewSegment.day)
                            Text("Week").tag(ReviewSegment.week)
                        }
                        .pickerStyle(.segmented)
                        if model.reviewSegment == .day {
                            DayReviewCard().id("today")
                        } else {
                            ScoreWeekCard().id("week")
                            GoalsCard().id("goals")
                            HowYouWorkCard().id("work")
                            LeaderboardCard().id("leaderboard")
                            PinnedList().id("pinned")
                            note.id("note")
                            NavigationLink { MoreStatsView() } label: {
                                Label("More Stats", systemImage: "chart.xyaxis.line").frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, 4).id("metrics")
                        }
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

// MARK: - C2 Day

struct DayReviewCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let cal = Calendar.current
        let now = Date()
        let today = model.rings(now)
        let usual = model.usualRings(now)
        let hours = DayCompare.hours(now, entries: model.state.entries, tree: model.state.categories, now: now,
                                     book: model.state.dayRules, calendar: cal)
        Card {
            CardHeader(title: "Today", symbol: "checkmark.seal.fill", color: .green)
            DayScoreView(score: model.dayScore(now), usual: model.scoreVsUsual(now).map { ($0.1, $0.2, $0.3) })
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 4) {
                    ActivityRings(rings: today, lineWidth: 12).frame(width: 110, height: 110)
                    Text("Today").font(.caption.weight(.semibold))
                }
                if let usual {
                    VStack(spacing: 4) {
                        ActivityRings(rings: usual, lineWidth: 12).frame(width: 110, height: 110).opacity(0.75)
                        Text(model.isSchoolDay(now) ? "Usual school day" : "Usual day off").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            RingLegendRows(rings: today, usual: usual)
            if let line = model.whatChanged(now) {
                Label(line, systemImage: "arrow.up.arrow.down").font(.subheadline).fixedSize(horizontal: false, vertical: true)
            }
            if let h = hours.best { Label("Best hour: \(hourLabel(h))", systemImage: "sun.max").font(.subheadline) }
            if let h = hours.worst { Label("Hardest hour: \(hourLabel(h))", systemImage: "cloud").font(.subheadline) }
            ForEach(model.state.patterns) { p in
                Label(p.text, systemImage: "lightbulb").font(.subheadline).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func hourLabel(_ h: Int) -> String {
        let d = Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: Date()) ?? Date()
        let e = d.addingTimeInterval(3600)
        return "\(d.formatted(.dateTime.hour()))–\(e.formatted(.dateTime.hour()))"
    }
}

// MARK: - C2 Week: pinned charts, and what moved out of Review

struct PinnedList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.state.pinnedCharts.isEmpty {
            Card {
                CardHeader(title: "Pinned", symbol: "pin.fill", color: .orange)
                ForEach(model.state.pinnedCharts) { p in
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

/// Life Metrics, mood by time of day, and where the time went by period: one tap below Week.
struct MoreStatsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                RingSection()
                MoodMapCard().id("mood")
                MetricsSection()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .background(Theme.background)
        .navigationTitle("More Stats")
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
        Card {
            CardHeader(title: "This Week", symbol: "chart.bar.fill", color: .indigo, detail: "vs your last 4 weeks")
            Chart(scores, id: \.0) { d, s in
                BarMark(x: .value("Day", d, unit: .day), y: .value("Score", s.score))
                    .foregroundStyle(Theme.focus)
            }
            .chartYScale(domain: 0...100)
            .frame(height: 110)
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
            Card {
                CardHeader(title: "Mood by Time of Day", symbol: "face.smiling", color: .pink, detail: "Last 30 days")
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
        Card {
            CardHeader(title: "How You Work", symbol: "clock.badge.checkmark", color: Theme.focus)
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
        Card {
            CardHeader(title: "Leaderboard", symbol: "trophy.fill", color: .yellow, detail: group?.name)
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
