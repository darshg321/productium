import SwiftUI
import ProductiumCore

/// One screen, no modes (v1.1 Part I): a week strip on top and the selected day on an hour grid below (design S1).
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
                        HStack(spacing: 2) {
                            if let r = rotation(d) { Text("D\(r)").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary) }
                            Circle().fill(Color.orange).frame(width: 5, height: 5).opacity(due ? 1 : 0)
                        }
                        .frame(height: 10)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(d.formatted(.dateTime.weekday(.wide).month().day()) + (today ? ", today" : "")
                                    + (rotation(d).map { ", Day \($0)" } ?? "") + (due ? ", something due" : ""))
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

    /// G2: Day 1 / Day 2 of a rotating timetable.
    private func rotation(_ d: Date) -> Int? {
        Rotation.day(d, entries: model.state.entries, tree: model.state.categories, book: model.state.dayRules, calendar: .current)
    }

    private func shift(_ weeks: Int) {
        let cal = Calendar.current
        withAnimation {
            weekStart = cal.date(byAdding: .weekOfYear, value: weeks, to: weekStart) ?? weekStart
            selected = cal.date(byAdding: .weekOfYear, value: weeks, to: selected) ?? selected
        }
    }
}


// MARK: - Design S1: the day as Calendar draws it, blocks to scale on an hour grid

/// Past (solid tint), assumed (paler, until you say yes or no), running (live), planned (dashed outline), untracked
/// stretches (dashed gray, tap to fill in) and a red now line. Tap a block for the entry sheet; long press for yes/no.
struct DayEntryList: View {
    @Environment(AppModel.self) private var model
    let day: Date
    @State private var editing: DayEntry?
    @State private var filling: LogSlice?
    @State private var sleepSettings = false

    static let hourHeight: CGFloat = 64
    static let gutter: CGFloat = 52

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { ctx in
            let now = ctx.date
            let cal = Calendar.current
            let span = Days.dayInterval(day, cal)
            let rows = model.dayEntries(day).filter { $0.end > span.start && $0.start < span.end && $0.end > $0.start }
            let gaps = day <= now
                ? Goals.gaps(TimeLog.past(model.state.entries, in: span, now: now, book: model.state.dayRules, calendar: cal))
                : []
            let due = model.state.items.filter { $0.isOpen && $0.parentId == nil && cal.isDate($0.due, inSameDayAs: day) }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if !due.isEmpty { dueCard(due).padding(.horizontal, 16).padding(.top, 12) }
                        grid(rows: rows, gaps: gaps, span: span, now: now)
                            .padding(.top, 12)
                            .padding(.bottom, 24)
                    }
                }
                .onAppear { scrollToStart(proxy, rows: rows, span: span, now: now) }
                .onChange(of: day) { _, _ in scrollToStart(proxy, rows: rows, span: span, now: now) }
            }
            .sheet(item: $editing) { EntrySheet(day: $0) }
            .sheet(isPresented: $sleepSettings) {
                NavigationStack {
                    SleepSettings().toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { sleepSettings = false } } }
                }
            }
            .confirmationDialog(filling.map { "\($0.start.hm) – \($0.end.hm)" } ?? "", isPresented: Binding(
                get: { filling != nil }, set: { if !$0 { filling = nil } }), titleVisibility: .visible) {
                if let g = filling {
                    ForEach(model.startButtons(now: now).row.prefix(6)) { b in
                        Button(b.title) { model.logStretch(b.title, DateInterval(start: g.start, end: g.end)) }
                    }
                }
            }
        }
    }

    private func scrollToStart(_ proxy: ScrollViewProxy, rows: [DayEntry], span: DateInterval, now: Date) {
        let cal = Calendar.current
        let anchor = span.contains(now) ? now : (rows.map(\.start).filter { $0 >= span.start }.min() ?? span.start)
        let hour = max(0, cal.component(.hour, from: anchor) - 1)
        DispatchQueue.main.async { proxy.scrollTo(hour, anchor: .top) }
    }

    private func y(_ d: Date, _ span: DateInterval) -> CGFloat {
        CGFloat(min(max(d.timeIntervalSince(span.start), 0), span.duration) / 3600) * Self.hourHeight
    }

    private func grid(rows: [DayEntry], gaps: [LogSlice], span: DateInterval, now: Date) -> some View {
        let hours = Int((span.duration / 3600).rounded())
        let placed = Self.columns(rows)
        return GeometryReader { geo in
            let width = geo.size.width - Self.gutter - 12
            ZStack(alignment: .topLeading) {
                ForEach(0...hours, id: \.self) { h in
                    HStack(alignment: .center, spacing: 6) {
                        Text(label(h, span)).font(.caption2).foregroundStyle(.secondary)
                            .frame(width: Self.gutter - 10, alignment: .trailing)
                        Rectangle().fill(Color(.separator)).frame(height: 0.5)
                    }
                    .frame(height: 12)
                    .padding(.top, max(0, CGFloat(h) * Self.hourHeight - 6))
                    .id(h)
                }
                ForEach(gaps, id: \.start) { g in
                    Button { filling = g } label: {
                        Text("\(minutesLabel(g.minutes)) untracked")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .frame(width: width, height: max(y(g.end, span) - y(g.start, span) - 2, 20), alignment: .topLeading)
                            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(Color(.systemGray3), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3])))
                    }
                    .buttonStyle(.plain)
                    .offset(x: Self.gutter, y: y(g.start, span) + 1)
                    .accessibilityLabel("\(minutesLabel(g.minutes)) untracked from \(g.start.hm). Fill in.")
                }
                ForEach(placed) { p in
                    let w = width / CGFloat(p.of)
                    let top = y(p.entry.start, span)
                    EntryBlock(entry: p.entry, now: now, height: max(y(p.entry.end, span) - top - 2, 20))
                        .frame(width: w - 2)
                        .offset(x: Self.gutter + w * CGFloat(p.column), y: top + 1)
                        .onTapGesture {
                            // G3: the planned night opens the sleep settings it comes from.
                            if p.entry.source == .plan && model.state.categories.isUnder(p.entry.category, CategoryTree.sleep) {
                                sleepSettings = true
                            } else {
                                editing = p.entry
                            }
                        }
                        .contextMenu { menu(p.entry, span: span, now: now) }
                }
                if span.contains(now) {
                    HStack(spacing: 0) {
                        Circle().fill(Color.red).frame(width: 9, height: 9)
                        Rectangle().fill(Color.red).frame(height: 1.5)
                    }
                    .offset(x: Self.gutter - 5, y: y(now, span) - 4.5)
                    .allowsHitTesting(false)
                }
            }
        }
        .frame(height: CGFloat(hours) * Self.hourHeight)
        .padding(.trailing, 12)
    }

    @ViewBuilder
    private func menu(_ d: DayEntry, span: DateInterval, now: Date) -> some View {
        if d.assumed && d.end <= now {
            Button("It Happened", systemImage: "checkmark") { model.confirm(d) }
            Button("Everything Until Here Happened", systemImage: "checkmark.circle") {
                model.confirmAll(in: DateInterval(start: span.start, end: d.end))
            }
        } else if d.isPlannedSession, let t = d.taskId, let item = model.state.items.first(where: { $0.id == t }) {
            Button("Start", systemImage: "play.fill") { model.startTask(item) }
        }
        Button("Edit", systemImage: "pencil") { editing = d }
        if d.end <= now && !d.running {
            Button("Didn't Happen", systemImage: "xmark", role: .destructive) { model.reject(d) }
        } else {
            Button("Remove", systemImage: "trash", role: .destructive) { model.remove(d) }
        }
    }

    private func label(_ h: Int, _ span: DateInterval) -> String {
        let d = span.start.addingTimeInterval(Double(h) * 3600)
        let hour = Calendar.current.component(.hour, from: d)
        if hour == 12 { return "Noon" }
        return d.formatted(.dateTime.hour())
    }

    /// Overlapping blocks share the width side by side, as in Calendar.
    struct Placed: Identifiable {
        let entry: DayEntry
        let column: Int
        let of: Int
        var id: String { entry.id }
    }

    static func columns(_ rows: [DayEntry]) -> [Placed] {
        let sorted = rows.filter { $0.mark != .skipped }.sorted { ($0.start, $1.end) < ($1.start, $0.end) }
        var out: [Placed] = []
        var cluster: [(entry: DayEntry, column: Int)] = []
        var ends: [Date] = []
        var clusterEnd = Date.distantPast
        func flush() {
            out += cluster.map { Placed(entry: $0.entry, column: $0.column, of: max(ends.count, 1)) }
            cluster = []
            ends = []
        }
        for e in sorted {
            if e.start >= clusterEnd { flush() }
            if let c = ends.firstIndex(where: { $0 <= e.start }) {
                ends[c] = e.end
                cluster.append((e, c))
            } else {
                ends.append(e.end)
                cluster.append((e, ends.count - 1))
            }
            clusterEnd = max(clusterEnd, e.end)
        }
        flush()
        return out
    }

    private func dueCard(_ due: [WorkItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(due.enumerated()), id: \.element.id) { i, t in
                if i > 0 { Divider().padding(.leading, 52) }
                HStack(spacing: 12) {
                    IconTile(symbol: "flag.fill", color: .orange)
                    Text("\(t.title) Due").lineLimit(1)
                    Spacer()
                    Text(t.due.hm).monospacedDigit().foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14).frame(minHeight: 46)
            }
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// One block on the day grid: a tinted card with a colour bar, like a Calendar event.
struct EntryBlock: View {
    @Environment(AppModel.self) private var model
    let entry: DayEntry
    let now: Date
    let height: CGFloat

    var body: some View {
        let tree = model.state.categories
        let task = entry.taskId.flatMap { id in model.state.items.first { $0.id == id } }
        // Task time looks like the task does in Tasks (its colour), not like its category.
        let colour = task.map { Theme.color(for: $0, in: model.state) } ?? Theme.color(category: entry.category, tree: tree)
        let planned = entry.isPlannedSession || (entry.source == .plan && entry.start > now)
        let pale = entry.assumed && entry.end <= now
        let title = entry.title
        HStack(spacing: 0) {
            Rectangle().fill(colour).frame(width: 4)
            VStack(alignment: .leading, spacing: 1) {
                if height < 36 {
                    Text(title).font(.caption.weight(.semibold)) + Text(" · \(detail)").font(.caption)
                } else {
                    HStack(alignment: .firstTextBaseline) {
                        Text(title).font(.subheadline.weight(.semibold))
                        Spacer(minLength: 4)
                        if entry.running {
                            Text(timerInterval: entry.start...Date.distantFuture, countsDown: false)
                                .font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(colour)
                        }
                    }
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, height < 36 ? 2 : 4)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(height: height, alignment: .top)
        .background {
            if planned {
                Theme.card
            } else {
                colour.opacity(pale ? 0.10 : 0.2)
            }
        }
        .overlay {
            if planned {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(colour, style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(entry.start.hm) to \(entry.end.hm), \(detail)")
        .accessibilityHint(pale ? "Assumed. Touch and hold to say if it happened." : "")
    }

    private var detail: String {
        var parts: [String] = []
        if entry.running { parts.append("Now") }
        else if entry.isPlannedSession { parts.append(entry.end < now ? "Not started" : "\(minutesLabel(entry.minutes)) planned") }
        else if entry.mark == .confirmed { parts.append(minutesLabel(entry.minutes)) }
        else if entry.assumed && entry.end <= now { parts.append("Assumed") }
        else if entry.source == .plan { parts.append("Planned") }
        else { parts.append(minutesLabel(entry.minutes)) }
        if let p = model.placeName(entry.entry.placeId) { parts.append(p) }
        return parts.joined(separator: " · ")
    }
}
