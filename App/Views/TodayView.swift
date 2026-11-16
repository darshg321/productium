import SwiftUI
import ProductiumCore

/// One screen, one question: what now? Everything else is a glance or one tap away.
struct TodayView: View {
    @Environment(AppModel.self) private var model
    @Binding var showAdd: Bool
    @Binding var showGap: Bool

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                let now = ctx.date
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header(now)
                        if !model.pendingOutcomes.isEmpty { PendingOutcomes() }
                        checkIns(now)
                        NowCard(now: now, showGap: $showGap)
                        warnings
                        nudges(now)
                        if model.supportSuggested { supportCard }
                        UpNext(now: now)
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 90)
                }
            }
            .overlay(alignment: .bottomTrailing) { AddButton(show: $showAdd) }
            .refreshable { await model.refresh() }
            .navigationBarHidden(true)
        }
    }

    private func header(_ now: Date) -> some View {
        let study = model.todayBlocks(now).filter(\.isStudy)
        let remaining = study.filter { $0.end > now }.reduce(0) { $0 + $1.minutes }
        let bed = model.state.plan.blocks.first { $0.kind == .sleep && $0.start > now }
        return VStack(alignment: .leading, spacing: 4) {
            Text(now.formatted(.dateTime.weekday(.wide))).font(.largeTitle.bold())
            HStack(spacing: 6) {
                if remaining > 0 { Text("\(minutesLabel(remaining)) of focus left") } else { Text("Nothing left to do today") }
                if let bed { Text("·"); Text("bed \(bed.start.hm)") }
            }
            .font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.top, 12)
    }

    /// The single most useful one-tap check-in for right now (only while learning),
    /// and the daily mood tap.
    @ViewBuilder private func checkIns(_ now: Date) -> some View {
        let todays = model.state.markers.filter { Calendar.current.isDateInToday($0.at) }
        let suggestion = model.state.integrations.location ? nil
            : CheckInSuggester.suggestion(now: now, todaysEvents: todays, commitments: model.state.commitments,
                                          routines: model.state.routines, calendar: Calendar.current)
        if model.todayMood == nil || suggestion != nil {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    if let s = suggestion {
                        Button { model.logMarker(s); model.toast = "Logged · \(s)" } label: {
                            Label(s, systemImage: "location.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent.opacity(0.85))
                    }
                    if model.todayMood == nil {
                        Text("How are you today?").font(.subheadline).foregroundStyle(.secondary)
                        MoodPicker(selected: nil) { model.logMood($0, energy: nil, note: nil) }
                    }
                }
            }
        }
    }

    @ViewBuilder private var warnings: some View {
        ForEach(model.activeWarnings.prefix(2), id: \.message) { w in
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: w.level == .critical ? "exclamationmark.circle.fill" : "info.circle")
                    .foregroundStyle(w.level == .critical ? .orange : .secondary)
                Text(w.message).font(.footnote)
                Spacer(minLength: 0)
                Button { model.state.dismissed.insert(w.message); model.save() } label: {
                    Image(systemName: "xmark").font(.caption).foregroundStyle(.tertiary)
                }
                .accessibilityLabel("Dismiss")
            }
            .padding(12)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    @ViewBuilder private func nudges(_ now: Date) -> some View {
        let health = model.state.health.first { Calendar.current.isDateInToday($0.day) }
        let screen = model.state.screen.first { Calendar.current.isDateInToday($0.day) }
        let list = Wellbeing.nudges(now: now, todayMood: model.todayMood, health: health, screen: screen,
                                    screenLimit: model.state.taper.dailyLimit, calendar: Calendar.current)
        ForEach(list, id: \.text) { n in
            Label(n.text, systemImage: n.symbol).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4)
        }
    }

    private var supportCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("It's been a heavy couple of weeks", systemImage: "heart").font(.headline)
                Text(Wellbeing.crisisText).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Now

struct NowCard: View {
    @Environment(AppModel.self) private var model
    let now: Date
    @Binding var showGap: Bool

    var body: some View {
        let current = model.state.plan.current(at: now)
        let next = model.state.plan.next(after: now)
        Card(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                if let b = current {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(label(b.kind), systemImage: Theme.symbol(for: b.kind))
                                .font(.caption.weight(.semibold)).foregroundStyle(Theme.color(for: b.kind))
                            Text(b.title).font(.title2.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                            if let h = b.hint { Text(h).font(.subheadline).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        ProgressRing(progress: progress(b), text: "\(max(0, Int(b.end.timeIntervalSince(now) / 60)))m")
                    }
                    if b.isStudy {
                        Button { model.startFocus(b) } label: {
                            Text("Start focus").font(.headline).frame(maxWidth: .infinity, minHeight: 48)
                        }
                        .buttonStyle(.borderedProminent)
                    } else if b.kind == .gap || (b.kind == .free && b.end.timeIntervalSince(now) < 20 * 60) {
                        Button { showGap = true } label: {
                            Label("\(max(1, Int(b.end.timeIntervalSince(now) / 60))) min: quick review instead of scrolling",
                                  systemImage: "sparkles").frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                    }
                } else {
                    Text("Free").font(.title2.weight(.semibold))
                    Text("Nothing scheduled right now. It's yours.").foregroundStyle(.secondary)
                }
                if let n = next {
                    Divider()
                    HStack {
                        Text("Next").foregroundStyle(.secondary)
                        Text(n.title).lineLimit(1)
                        Spacer()
                        Text(n.start.hm).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }
            }
        }
    }

    private func progress(_ b: PlannedBlock) -> Double {
        let total = b.end.timeIntervalSince(b.start)
        return total > 0 ? min(1, max(0, now.timeIntervalSince(b.start) / total)) : 0
    }

    private func label(_ k: BlockKind) -> String {
        switch k {
        case .work: return "Focus"
        case .review: return "Review"
        case .breakTime: return "Break"
        case .gap: return "Short window"
        case .free: return "Free"
        case .commitment, .event: return "Scheduled"
        case .meal: return "Meal"
        case .routine: return "Routine"
        case .windDown: return "Wind down"
        case .sleep: return "Sleep"
        }
    }
}

struct ProgressRing: View {
    var progress: Double
    var text: String
    var size: CGFloat = 64
    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 6)
            Circle().trim(from: 0, to: progress).stroke(Theme.accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(text).font(.system(.callout, design: .rounded).weight(.semibold)).monospacedDigit()
        }
        .frame(width: size, height: size)
        .animation(.linear, value: progress)
    }
}

// MARK: - Pending outcomes (one tap each)

struct PendingOutcomes: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle("How did these go?")
                ForEach(model.pendingOutcomes.prefix(4)) { b in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(b.title).font(.subheadline).lineLimit(1)
                            Text("\(b.start.relativeDay) \(b.start.hm)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        outcomeButton("checkmark", .green, b, .done)
                        outcomeButton("circle.lefthalf.filled", .orange, b, .partial)
                        outcomeButton("xmark", .secondary, b, .skipped)
                    }
                }
            }
        }
    }

    private func outcomeButton(_ symbol: String, _ color: Color, _ b: PlannedBlock, _ s: OutcomeStatus) -> some View {
        Button { withAnimation { model.logOutcome(blockId: b.id, status: s) } } label: {
            Image(systemName: symbol).font(.body.weight(.semibold)).foregroundStyle(color)
                .frame(width: 40, height: 40).background(.background, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(s.rawValue)
    }
}

// MARK: - Up next

struct UpNext: View {
    @Environment(AppModel.self) private var model
    let now: Date

    var body: some View {
        let rest = model.todayBlocks(now).filter { $0.start > now && $0.kind != .breakTime }
        if !rest.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                SectionTitle("Later today").padding(.bottom, 8)
                ForEach(rest) { b in
                    HStack(spacing: 12) {
                        Text(b.start.hm).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                        RoundedRectangle(cornerRadius: 2).fill(Theme.color(for: b.kind)).frame(width: 3, height: 22)
                        Text(b.title).font(.subheadline).foregroundStyle(b.isStudy ? .primary : .secondary).lineLimit(1)
                        Spacer()
                        if b.borrowsSleep { Image(systemName: "moon.zzz").foregroundStyle(.orange).font(.caption) }
                        Text(minutesLabel(b.minutes)).font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 7)
                }
            }
        }
    }
}
