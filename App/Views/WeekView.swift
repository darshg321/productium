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
                AgendaList(day: day)
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
                    VStack(spacing: 3) {
                        Text(d.formatted(.dateTime.weekday(.narrow))).font(.caption2.weight(.semibold))
                        Text(d.formatted(.dateTime.day())).font(.headline.monospacedDigit())
                            .padding(6)
                            .overlay { if today { Circle().strokeBorder(on ? Color(.systemBackground) : Color.primary, lineWidth: 1.5) } }
                        Image(systemName: "flag.fill").font(.system(size: 8)).opacity(due ? 1 : 0)
                    }
                    .foregroundStyle(on ? Color(.systemBackground) : .primary)
                    .frame(maxWidth: .infinity, minHeight: 66)
                    .background(on ? Color.primary : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(d.formatted(.dateTime.weekday(.wide).month().day()) + (today ? ", today" : "") + (due ? ", something due" : ""))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            Button { shift(1) } label: { Image(systemName: "chevron.right") }
                .accessibilityLabel("Next week")
        }
        .font(.subheadline)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Theme.card)
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

struct AgendaList: View {
    @Environment(AppModel.self) private var model
    let day: Date

    var body: some View {
        let cal = Calendar.current
        let rows = Agenda.rows(day: day, plan: model.state.plan, items: model.state.items, now: Date(), calendar: cal)
        let overdue = model.state.items.filter { $0.isOpen && $0.parentId == nil && $0.due < Date() }
        ScrollViewReader { proxy in
            List {
                if !overdue.isEmpty {
                    Label("\(overdue.count) overdue. See the Tasks tab.", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.semibold))
                        .listRowBackground(Theme.card)
                }
                if rows.isEmpty {
                    Text("Nothing planned for this day.").foregroundStyle(.secondary)
                }
                ForEach(rows) { r in AgendaRowView(row: r).id(r.id) }
            }
            .listStyle(.plain)
            .onAppear { scrollToNext(proxy, rows) }
            .onChange(of: day) { _, _ in scrollToNext(proxy, Agenda.rows(day: day, plan: model.state.plan, items: model.state.items, now: Date(), calendar: cal)) }
        }
    }

    private func scrollToNext(_ proxy: ScrollViewProxy, _ rows: [AgendaRow]) {
        let target = rows.first { $0.kind == .now }?.id ?? rows.first { $0.kind == .study }?.id
        if let target { DispatchQueue.main.async { proxy.scrollTo(target, anchor: .top) } }
    }
}

struct AgendaRowView: View {
    @Environment(AppModel.self) private var model
    let row: AgendaRow
    @State private var open = false

    private func time(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }
    private var span: String { row.end.map { "\(time(row.start))–\(time($0))" } ?? time(row.start) }

    var body: some View {
        switch row.kind {
        case .study:
            if let id = row.itemId {
                NavigationLink { TaskDetailView(itemId: id) } label: { study }
            } else { study }
        case .fixed:
            if row.children.isEmpty { quiet("building.2", row.title, span) } else {
                DisclosureGroup(isExpanded: $open) {
                    ForEach(row.children) { c in
                        HStack { Text(c.title).font(.footnote); Spacer(); Text("\(time(c.start))–\(time(c.end ?? c.start))").font(.footnote.monospacedDigit()) }
                            .foregroundStyle(.secondary)
                    }
                } label: { quiet("building.2", row.title, span) }
            }
        case .breakTime: quiet("cup.and.saucer", "Break", span).opacity(0.8)
        case .windDown: quiet("moon", "Wind down", span)
        case .free:
            HStack(spacing: 10) {
                Image(systemName: "sun.max").frame(width: 22)
                Text("Free").font(.subheadline)
                Spacer()
                Text("\(span) · \(durationLabel(row.minutes ?? 0))").font(.subheadline.monospacedDigit())
            }
            .foregroundStyle(.secondary)
            .padding(.vertical, 2)
        case .due:
            if let id = row.itemId {
                NavigationLink { TaskDetailView(itemId: id) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "flag.fill").frame(width: 22)
                        Text("Due: \(row.title)").font(.subheadline.weight(.semibold)).lineLimit(2)
                        Spacer()
                        Text(time(row.start)).font(.subheadline.monospacedDigit())
                    }
                }
            }
        case .now:
            HStack(spacing: 8) {
                Image(systemName: "arrowtriangle.right.fill").font(.caption)
                Text("Now · \(time(row.start))").font(.caption.weight(.bold))
                Rectangle().frame(height: 1)
            }
            .foregroundStyle(.primary)
            .accessibilityLabel("Now, \(time(row.start))")
        case .wake:
            Button { open.toggle() } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 10) {
                        Image(systemName: "alarm").frame(width: 22)
                        Text("Wake up").font(.subheadline)
                        Spacer()
                        Text(time(row.start)).font(.subheadline.monospacedDigit())
                    }
                    if open, let why = row.detail, !why.isEmpty { Text(why).font(.footnote).foregroundStyle(.secondary).padding(.leading, 32) }
                }
            }
            .buttonStyle(.plain)
        case .leave:
            plain("figure.walk", "Leave by", time(row.start))
        case .bed:
            plain("bed.double", "Bed", time(row.start))
        }
    }

    private var study: some View {
        HStack(spacing: 12) {
            Image(systemName: "pencil.line").font(.title3).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).font(.headline).lineLimit(2)
                Text("\(span) · \(durationLabel(row.minutes ?? 0))").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    private func quiet(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).frame(width: 22)
            Text(title).font(.subheadline).lineLimit(1)
            Spacer()
            Text(detail).font(.subheadline.monospacedDigit())
        }
        .foregroundStyle(.secondary)
    }

    private func plain(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).frame(width: 22)
            Text(title).font(.subheadline)
            Spacer()
            Text(detail).font(.subheadline.monospacedDigit())
        }
    }
}
