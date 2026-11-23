import SwiftUI
import Charts
import ProductiumCore

// v1.3 Review: one page to look at every day. Your Week (the recap, any time) on top, then today, the numbers at a
// glance (tomorrow's plan included), this week against your last 4, where the time went, screen time per app, goals,
// how you work, mood, Life Metrics, pinned charts, the leaderboard and the Weekly Note. No drilling in to see a stat.

struct ReviewView: View {
    @Environment(AppModel.self) private var model
    /// One period for everything below "Over Time" (Where Your Time Went and Life Metrics).
    @State private var period: MetricPeriod = .week
    /// F2: the day the rings show; Today and At a Glance follow it.
    @State private var day = Calendar.current.startOfDay(for: Date())

    var body: some View {
        @Bindable var m = model
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        RecapBanner().id("recap")
                        TodaySummaryCard(day: $day).id("today")
                        GlanceGrid(day: day).id("stats")
                        ScreenTimeCard().id("screen")
                        ScoreWeekCard().id("week")
                        GoalsCard().id("goals")
                        VStack(alignment: .leading, spacing: 12) {
                            SectionHeader("Over Time")
                            Picker("Period", selection: $period) {
                                Text("Day").tag(MetricPeriod.day)
                                Text("Week").tag(MetricPeriod.week)
                                Text("Month").tag(MetricPeriod.month)
                            }
                            .pickerStyle(.segmented)
                        }
                        .id("time")
                        WhereTimeWentCard(period: period)
                        MetricsSection(period: period).id("metrics")
                        MoodMapCard().id("mood")
                        HowYouWorkCard().id("work")
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
            .refreshable { Task { await model.insightPass(force: true) } }
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
            HStack(spacing: 12) {
                IconTile(symbol: "sparkles", color: .purple, size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Your Week").font(.headline)
                    Text("\(start.formatted(.dateTime.month(.abbreviated).day())) – \(end.formatted(.dateTime.month(.abbreviated).day()))")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Plays your week's recap")
    }
}

/// A labelled number: the label above, the number large (Health style). Nothing needs a footnote.
struct LabeledNumber: View {
    let label: String
    let value: String
    var unit: String?
    var color: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(.title2, design: .rounded).weight(.semibold)).monospacedDigit().foregroundStyle(color)
                    .lineLimit(1).minimumScaleFactor(0.7)
                if let unit { Text(unit).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Today: the rings, and the day score beside your usual

struct TodaySummaryCard: View {
    @Environment(AppModel.self) private var model
    @Binding var day: Date
    @State private var showingDay = false

    var body: some View {
        let score = model.dayScore(day)
        let vs = model.scoreVsUsual(day)
        TitledCard(dayTitle(day, now: Date(), today: "Today")) {
            RingPager(day: $day) { d in
                let r = model.rings(d)
                HStack(spacing: 20) {
                    ActivityRings(rings: r, lineWidth: 17).frame(width: 130, height: 130)
                    RingLegendRows(rings: r)
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 140)
            .contentShape(Rectangle())
            .onTapGesture { showingDay = true }
            Divider()
            HStack(alignment: .top) {
                LabeledNumber(label: "Day Score", value: "\(score.score)")
                if let vs { LabeledNumber(label: vs.2.capitalizedFirst, value: "\(vs.1)") }
            }
        }
        .sheet(isPresented: $showingDay) { RingDaySheet(day: day) }
    }
}

// MARK: - At a glance: the numbers to check through the day

struct GlanceGrid: View {
    @Environment(AppModel.self) private var model
    let day: Date

    var body: some View {
        let cal = Calendar.current
        let now = Date()
        let isToday = cal.isDate(day, inSameDayAs: now)
        let suffix = isToday ? " Today" : ""
        let rings = model.rings(day)
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)) ?? now
        let planned = model.plannedShare(tomorrow)
        let screen = isToday ? model.appMinutesToday().reduce(0) { $0 + $1.minutes }
            : Friction.log.minutes(on: day, calendar: cal).values.reduce(0, +)
        let week = (0..<7).compactMap { cal.date(byAdding: .day, value: -$0, to: cal.startOfDay(for: now)) }.compactMap(model.trackedScore)
        let due = week.reduce(0) { $0 + $1.deadlinesDue }, met = week.reduce(0) { $0 + $1.deadlinesMet }
        let slept = model.state.health.first { cal.isDate($0.day, inSameDayAs: day) }?.sleepMinutes
        let mood = model.state.moods.filter { cal.isDate($0.at, inSameDayAs: day) }.max { $0.at < $1.at }
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("At a Glance")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                StatTile(title: "Tomorrow Planned", symbol: "calendar", color: .indigo, value: "\(planned.percent)", unit: "%",
                         progress: planned.fraction)
                StatTile(title: "Work" + suffix, symbol: "pencil.line", color: RingStyle.work, value: minutesLabel(rings.workMinutes),
                         unit: rings.workGoal == 0 ? nil : "/ \(minutesLabel(rings.workGoal))",
                         progress: rings.workGoal == 0 ? nil : rings.work)
                StatTile(title: "Scrolling" + suffix, symbol: "hourglass", color: .pink, value: "\(model.dayScore(day).scrollingMinutes)",
                         unit: "min")
                StatTile(title: "Screen Time" + suffix, symbol: "iphone", color: .teal, value: screen > 0 ? minutesLabel(screen) : "–")
                StatTile(title: "Deadlines Met", symbol: "flag.fill", color: .orange, value: due == 0 ? "–" : "\(met)",
                         unit: due == 0 ? nil : "/ \(due)")
                if let slept {
                    StatTile(title: "Sleep", symbol: "bed.double.fill", color: Theme.sleep, value: minutesLabel(slept))
                }
                if let m = mood {
                    StatTile(title: "Mood", symbol: "face.smiling", color: .yellow,
                             value: MoodButtons.faces.first { $0.0 == m.mood }?.1 ?? "🙂")
                }
            }
        }
    }
}

// MARK: - Where the time went, by period

struct WhereTimeWentCard: View {
    @Environment(AppModel.self) private var model
    let period: MetricPeriod
    @State private var drill: String?

    var body: some View {
        let cal = Calendar.current
        let now = Date()
        let range = range(now, cal)
        let ring = RingModel.make(entries: model.state.entries, tree: model.state.categories, range: range, now: now, forecast: [:],
                                  book: model.state.dayRules, calendar: cal)
        TitledCard("Where Your Time Went") {
            HStack(alignment: .top) {
                LabeledNumber(label: "Tracked", value: minutesLabel(ring.trackedMinutes))
                LabeledNumber(label: "Untracked", value: minutesLabel(ring.untrackedMinutes))
            }
            TimeBreakdown(ring: ring, tree: model.state.categories) { drill = $0 }
        }
        .sheet(item: Binding(get: { drill.map(Drill.init) }, set: { drill = $0?.id })) { d in
            DrillSheet(id: d.id, range: range, title: period.rawValue.capitalized)
        }
    }

    private func range(_ now: Date, _ cal: Calendar) -> DateInterval {
        let unit: Calendar.Component = period == .day ? .day : period == .week ? .weekOfYear : .month
        let r = cal.dateInterval(of: unit, for: now) ?? Days.dayInterval(now, cal)
        // Before you used Productium there's no log: those days aren't Untracked, they're not counted.
        let start = max(r.start, model.trackingStart)
        return DateInterval(start: min(start, r.end), end: r.end)
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
        TitledCard("Screen Time") {
            if !apps.isEmpty {
                HStack(alignment: .top) {
                    LabeledNumber(label: "Today", value: minutesLabel(total))
                    if let s = groups.first(where: { $0.title == "Scrolling" }) {
                        LabeledNumber(label: "Scrolling", value: minutesLabel(s.minutes), color: s.color)
                    }
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
                .frame(height: 10)
                ForEach(Array(apps.prefix(expanded ? 30 : 5).enumerated()), id: \.offset) { _, a in
                    let kind = model.appKind(a.app)
                    HStack(spacing: 12) {
                        IconTile(symbol: kindSymbol(kind), color: kindColor(kind))
                        Text(a.app)
                        Spacer()
                        Text(minutesLabel(a.minutes)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                if apps.count > 5 {
                    Button(expanded ? "Show Less" : "Show All") { withAnimation { expanded.toggle() } }.buttonStyle(.borderless)
                }
            }
            if let week {
                if !apps.isEmpty { Divider() }
                HStack(alignment: .top) {
                    LabeledNumber(label: "Daily Average", value: week.total.map(minutesLabel) ?? "–")
                    LabeledNumber(label: "Scrolling a Day", value: minutesLabel(week.scrolling))
                }
            }
            NavigationLink { ScreenTimeSettings() } label: {
                HStack { Text(apps.isEmpty ? "Set Up Screen Time" : "Scrolling Apps"); Spacer(); Image(systemName: "chevron.right").foregroundStyle(.tertiary) }
            }
            .foregroundStyle(apps.isEmpty ? Color.accentColor : .primary)
        }
    }

    private struct KindTotal { let title: String; let color: Color; let minutes: Int }

    private func group(_ apps: [(app: String, minutes: Int)]) -> [KindTotal] {
        var m: [CategoryID?: Int] = [:]
        for a in apps { m[model.appKind(a.app), default: 0] += a.minutes }
        return [CategoryTree.scrolling, CategoryTree.messaging, nil].compactMap { k in
            guard let mins = m[k], mins > 0 else { return nil }
            return KindTotal(title: kindName(k), color: kindColor(k), minutes: mins)
        }
    }

    private func kindName(_ k: CategoryID?) -> String {
        k == CategoryTree.scrolling ? "Scrolling" : k == CategoryTree.messaging ? "Messaging" : "Other"
    }
    private func kindSymbol(_ k: CategoryID?) -> String {
        k == CategoryTree.scrolling ? "hourglass" : k == CategoryTree.messaging ? "message.fill" : "app.fill"
    }
    private func kindColor(_ k: CategoryID?) -> Color {
        k.map { Theme.color(category: $0, tree: model.state.categories) } ?? Color(.systemGray)
    }
}

// MARK: - The Weekly Note (only once there is one)

struct WeeklyNoteCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let approvals = model.approvals.filter { $0.source == .insight }
        if model.state.review != nil || model.busy.contains("review") || !approvals.isEmpty {
            TitledCard("Weekly Note", detail: model.state.reviewAt.map { $0.formatted(.dateTime.month(.abbreviated).day()) }) {
                if let r = model.state.review {
                    Text(r.headline).font(.headline).fixedSize(horizontal: false, vertical: true)
                    ForEach(r.wins + r.suggestions, id: \.self) { line in
                        Text(line).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(model.state.patterns) { p in
                        Label(p.text, systemImage: "lightbulb").fixedSize(horizontal: false, vertical: true)
                    }
                } else if model.busy.contains("review") {
                    HStack(spacing: 10) { ProgressView(); Text("Reading your week…") }
                }
                // J2: alarms the insight pass proposed wait here for Allow.
                ForEach(approvals) { a in ApprovalRow(approval: a) }
            }
        }
    }
}

// MARK: - Pinned charts

struct PinnedList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.state.pinnedCharts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
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
        let week = (0..<7).compactMap { cal.date(byAdding: .day, value: -$0, to: cal.startOfDay(for: Date())) }.filter(model.isTracked)
        TitledCard("Goals") {
            ForEach(model.goalsAll) { g in
                let p = model.progress(g)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(p.line)
                        Spacer()
                        if g.period == .day {
                            let n = Goals.daysMet(g, days: week, entries: model.state.entries, tree: model.state.categories,
                                                  items: model.state.items, now: Date(), book: model.state.dayRules, calendar: cal)
                            Text("\(n) of \(week.count) days").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    if g.measure != .trackingGaps {
                        ProgressView(value: p.fraction).tint(g.direction == .atMost ? (p.met ? .green : .orange) : (p.met ? .green : .blue))
                    }
                }
            }
            let suggestions = model.suggestedGoals
            if !suggestions.isEmpty {
                Divider()
                Text("Suggested").font(.subheadline.weight(.semibold))
                ForEach(suggestions) { s in
                    HStack {
                        Text("\(s.title) \(s.direction == .atMost ? "under" : "at least") \(durationLabel(s.target)) a \(s.period.rawValue)")
                            .font(.subheadline)
                        Spacer()
                        Button("Add") { model.addGoal(s) }.buttonStyle(.bordered)
                    }
                }
            }
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
        // Days before you used Productium have no bar: there's no log to score.
        let scores = days.compactMap { d in model.trackedScore(d).map { (d, $0) } }
        let week = scores.map(\.1)
        TitledCard("This Week") {
            Text("Day Score").font(.subheadline).foregroundStyle(.secondary)
            Chart(scores, id: \.0) { d, s in
                BarMark(x: .value("Day", d, unit: .day), y: .value("Score", s.score), width: .ratio(0.6))
                    .foregroundStyle(cal.isDate(d, inSameDayAs: today) ? Color.blue : Color.blue.opacity(0.55))
                    .cornerRadius(3)
            }
            .chartYScale(domain: 0...100)
            .chartXScale(domain: days[0]...(cal.date(byAdding: .day, value: 1, to: today) ?? today))
            .chartYAxis {
                AxisMarks(position: .trailing, values: [0, 50, 100]) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    AxisValueLabel()
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true)
                }
            }
            .frame(height: 140)
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    LabeledNumber(label: "Tracked", value: minutesLabel(week.reduce(0) { $0 + $1.wakingMinutes - $1.untrackedMinutes }))
                    LabeledNumber(label: "Work", value: minutesLabel(week.reduce(0) { $0 + $1.workMinutes }))
                }
                GridRow {
                    LabeledNumber(label: "Scrolling", value: minutesLabel(week.reduce(0) { $0 + $1.scrollingMinutes }))
                    let due = week.reduce(0) { $0 + $1.deadlinesDue }
                    LabeledNumber(label: "Deadlines Met", value: due == 0 ? "–" : "\(week.reduce(0) { $0 + $1.deadlinesMet })",
                                  unit: due == 0 ? nil : "/ \(due)")
                }
            }
        }
    }
}

// MARK: - G6: mood by time of day

struct MoodMapCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let cal = Calendar.current
        let map = MoodMap.make(model.state.moods, since: Date().addingTimeInterval(-30 * 86400), isSchoolDay: model.isSchoolDay, calendar: cal)
        if model.state.moods.filter({ $0.at > Date().addingTimeInterval(-30 * 86400) }).count >= 7 {
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
                .chartLegend(.hidden)
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
        if l.adherenceSamples >= 3 {
        TitledCard("How You Work") {
                LabeledContent("Planned sessions done", value: "\(Int((l.adherence * 100).rounded()))%")
                let hours = l.goodHours()
                if !hours.isEmpty {
                    LabeledContent("Best hours", value: hours.sorted().map(hourLabel).joined(separator: ", "))
                }
                LabeledContent("Focus block", value: durationLabel(Int(l.focusMinutes)))
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
    @State private var adding = false
    @State private var confirmLeave = false

    var body: some View {
        let lb = model.state.leaderboard
        let group = lb.groups.first { $0.id == groupId } ?? lb.groups.first
        // One measure (the week's average day score) and one menu for everything else.
        TitledCard("Leaderboard", detail: group?.name) {
            if let g = group, model.pendingInvite == nil {
                let rows = lb.boards[g.id].map { Leaderboard.rows($0, metric: .score, you: g.memberId, today: Date(), calendar: .current) } ?? []
                if rows.isEmpty {
                    ProgressView().frame(maxWidth: .infinity)
                }
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                    if i > 0 { Divider() }
                    HStack(spacing: 12) {
                        Text(r.rank > 0 ? "\(r.rank)" : "–").font(.headline.monospacedDigit()).frame(width: 22)
                            .foregroundStyle(r.rank == 1 ? .orange : .secondary)
                        Text(r.isYou ? "\(r.name) (you)" : r.name).fontWeight(r.isYou ? .semibold : .regular)
                        Spacer()
                        Text(r.label).font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                }
                Divider()
                HStack {
                    if let url = Leaderboard.invite(g, scheme: AppInfo.scheme) {
                        ShareLink(item: url, message: Text("Join \(g.name) on Productium")) { Label("Invite", systemImage: "person.badge.plus") }
                    }
                    Spacer()
                    Menu {
                        if lb.groups.count > 1 {
                            Picker("Group", selection: Binding(get: { g.id }, set: { groupId = $0 })) {
                                ForEach(lb.groups) { Text($0.name).tag($0.id) }
                            }
                        }
                        Button("Start or Join a Group", systemImage: "plus") { adding = true }
                        Button("Leave \(g.name)", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { confirmLeave = true }
                    } label: { Image(systemName: "ellipsis.circle").font(.title3) }
                }
                .confirmationDialog("Leave \(g.name)? Your row is removed for everyone.", isPresented: $confirmLeave, titleVisibility: .visible) {
                    Button("Leave", role: .destructive) { Task { await model.leaveLeaderboard(g.id) } }
                }
            } else {
                Text(model.pendingInvite != nil ? "Pick the name your friends will see." : "Compare day scores with friends. Only your score and a name are shared.")
                Button(model.pendingInvite != nil ? "Join" : "Start or Join a Group") { adding = true }
                    .buttonStyle(.borderedProminent)
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
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
