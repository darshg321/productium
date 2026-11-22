import SwiftUI
import ProductiumCore

/// One screen, no modes (v1.1 Part I): a week strip on top and the selected day as an agenda below. Study blocks are
/// the only prominent rows; fixed time is one quiet row each; free time is a gap row; due items sit at their time.
struct ScheduleView: View {
    @Environment(AppModel.self) private var model
    @State private var day = Calendar.current.startOfDay(for: Date())
    @State private var weekStart = ScheduleView.week(of: Date())

    static func week(of d: Date) -> Date {
        let cal = Calendar.current
        return cal.dateInterval(of: .weekOfYear, for: d)?.start ?? cal.startOfDay(for: d)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                WeekStrip(selected: $day, weekStart: $weekStart)
                Divider()
                DayEntryList(day: day)
            }
            .background(Theme.background)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !Calendar.current.isDateInToday(day) {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Today") {
                            withAnimation {
                                day = Calendar.current.startOfDay(for: Date())
                                weekStart = ScheduleView.week(of: day)
                            }
                        }
                    }
                }
            }
            .usageMeter()
        }
    }

    private var title: String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInTomorrow(day) { return "Tomorrow" }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }
}

struct WeekStrip: View {
    @Environment(AppModel.self) private var model
    @Binding var selected: Date
    @Binding var weekStart: Date

    var body: some View {
        let cal = Calendar.current
        let days = (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: weekStart) }
        HStack(spacing: 4) {
            Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel("Previous week")
            ForEach(days, id: \.self) { d in
                let on = cal.isDate(d, inSameDayAs: selected)
                let today = cal.isDateInToday(d)
                let due = model.state.items.contains { $0.isOpen && $0.parentId == nil && cal.isDate($0.due, inSameDayAs: d) }
                Button { withAnimation(.snappy) { selected = d } } label: {
                    VStack(spacing: 4) {
                        Text(d.formatted(.dateTime.weekday(.narrow))).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        Text(d.formatted(.dateTime.day())).font(.title3.weight(on || today ? .semibold : .regular).monospacedDigit())
                            .foregroundStyle(on ? Color(.systemBackground) : (today ? .red : .primary))
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(on ? (today ? Color.red : Color.primary) : Color.clear))
                        Circle().fill(Color.orange).frame(width: 5, height: 5).opacity(due ? 1 : 0)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(d.formatted(.dateTime.weekday(.wide).month().day()) + (today ? ", today" : "") + (due ? ", something due" : ""))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            Button { shift(1) } label: { Image(systemName: "chevron.right") }
                .accessibilityLabel("Next week")
        }
        .font(.subheadline)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Color(.systemBackground))
        .gesture(DragGesture(minimumDistance: 30).onEnded { v in
            if v.translation.width < -40 { shift(1) } else if v.translation.width > 40 { shift(-1) }
        })
    }

    private func shift(_ weeks: Int) {
        let cal = Calendar.current
        withAnimation {
            weekStart = cal.date(byAdding: .weekOfYear, value: weeks, to: weekStart) ?? weekStart
            selected = cal.date(byAdding: .weekOfYear, value: weeks, to: selected) ?? selected
        }
    }
}


// MARK: - v1.2 O11 / B7: a day is its entries, rendered one way

/// Past (solid), assumed (with a dashed mark until you say yes or no), running (live), planned (outlined). Every row
/// opens the same entry sheet. Swipe right = yes, it happened; left = no. "All to Here" confirms the morning at once.
struct DayEntryList: View {
    @Environment(AppModel.self) private var model
    let day: Date
    @State private var editing: DayEntry?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { ctx in
            let now = ctx.date
            let cal = Calendar.current
            let rows = model.dayEntries(day).filter { cal.isDate($0.start, inSameDayAs: day) || $0.start < cal.startOfDay(for: day) }
            let untracked = cal.isDate(day, inSameDayAs: now) || day < now
                ? Goals.gaps(TimeLog.past(model.state.entries, in: Days.dayInterval(day, cal), now: now, book: model.state.dayRules, calendar: cal))
                : []
            let due = model.state.items.filter { $0.isOpen && $0.parentId == nil && cal.isDate($0.due, inSameDayAs: day) }
            List {
                if rows.isEmpty && due.isEmpty { Text("Nothing on this day yet.").foregroundStyle(.secondary) }
                if !due.isEmpty {
                    Section("Due") {
                        ForEach(due) { t in
                            HStack(spacing: 12) {
                                IconTile(symbol: "flag.fill", color: .orange)
                                Text(t.title).lineLimit(1)
                                Spacer()
                                Text(t.due.hm).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if !untracked.isEmpty {
                    Section("Untracked") {
                        ForEach(untracked, id: \.start) { g in
                            HStack(spacing: 12) {
                                IconTile(symbol: "questionmark", color: Color(.systemGray3))
                                Text(minutesLabel(g.minutes))
                                Spacer()
                                Text("\(g.start.hm) – \(g.end.hm)").monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section {
                ForEach(rows) { d in
                    DayEntryRow(entry: d, now: now)
                        .contentShape(Rectangle())
                        .onTapGesture { editing = d }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            if d.assumed && d.end <= now {
                                Button { model.confirm(d) } label: { Label("Yes", systemImage: "checkmark") }.tint(.green)
                                Button { model.confirmAll(in: DateInterval(start: cal.startOfDay(for: day), end: d.end)) } label: {
                                    Label("All to Here", systemImage: "checkmark.circle")
                                }.tint(.teal)
                            } else if d.isPlannedSession, let t = d.taskId, let item = model.state.items.first(where: { $0.id == t }) {
                                Button { model.startTask(item) } label: { Label("Start", systemImage: "play.fill") }.tint(Theme.focus)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if d.end <= now && !d.running {
                                Button(role: .destructive) { model.reject(d) } label: { Label("No", systemImage: "xmark") }
                            } else {
                                Button(role: .destructive) { model.remove(d) } label: { Label("Remove", systemImage: "trash") }
                            }
                        }
                }
                }
            }
            .listStyle(.insetGrouped)
            .sheet(item: $editing) { EntrySheet(day: $0) }
        }
    }
}

struct DayEntryRow: View {
    @Environment(AppModel.self) private var model
    let entry: DayEntry
    let now: Date

    var body: some View {
        let tree = model.state.categories
        let colour = Theme.color(category: entry.category, tree: tree)
        HStack(spacing: 12) {
            IconTile(symbol: Theme.symbol(category: entry.category, tree: tree), color: colour)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).lineLimit(1)
                Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 1) {
                if entry.running {
                    Text(timerInterval: entry.start...Date.distantFuture, countsDown: false).monospacedDigit().foregroundStyle(Color.accentColor)
                } else {
                    Text(entry.start.hm).monospacedDigit()
                }
                Text(entry.running ? "now" : entry.end.hm).font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .opacity(entry.mark == .skipped ? 0.4 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityHint(entry.assumed ? "Assumed. Swipe right if it happened, left if it didn't." : "")
    }

    private var detail: String {
        var parts = [model.state.categories.node(entry.category)?.name ?? model.state.categories.pathText(entry.category)]
        if entry.running { }
        else if entry.isPlannedSession { parts.append(entry.end < now ? "not started" : "planned") }
        else if entry.mark == .confirmed { }
        else if entry.assumed && entry.end <= now { parts.append("assumed") }
        else if entry.source == .plan { parts.append("planned") }
        if entry.entry.open { parts.append("open time") }
        if let p = model.placeName(entry.entry.placeId) { parts.append(p) }
        return parts.joined(separator: " · ")
    }
}
