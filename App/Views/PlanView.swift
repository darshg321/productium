import SwiftUI
import ProductiumCore

struct PlanView: View {
    @Environment(AppModel.self) private var model
    @Binding var showAdd: Bool
    @State private var mode = 0
    @State private var day = Calendar.current.startOfDay(for: Date())

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $mode) {
                    Text("Days").tag(0)
                    Text("Tasks").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 8)
                if mode == 0 { days } else { TaskList() }
            }
            .navigationTitle("Plan")
            .overlay(alignment: .bottomTrailing) { AddButton(show: $showAdd) }
        }
    }

    private var days: some View {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let dates = (0..<14).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
        return VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(dates, id: \.self) { d in
                        let load = model.state.plan.blocks(on: d, calendar: cal).filter(\.isStudy).reduce(0) { $0 + $1.minutes }
                        Button { day = d } label: {
                            VStack(spacing: 4) {
                                Text(d.formatted(.dateTime.weekday(.abbreviated))).font(.caption)
                                Text(d.formatted(.dateTime.day())).font(.headline)
                                Capsule().fill(Theme.accent.opacity(load == 0 ? 0.1 : min(1, 0.25 + Double(load) / 240)))
                                    .frame(width: 18, height: 4)
                            }
                            .frame(width: 46, height: 64)
                            .background(cal.isDate(d, inSameDayAs: day) ? Theme.accent.opacity(0.15) : .clear,
                                        in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
            DayTimeline(day: day)
        }
    }
}

/// A day as a list of blocks with a coloured rail. Fixed time (school, routines) is dimmed
/// so the eye lands on study and free time.
struct DayTimeline: View {
    @Environment(AppModel.self) private var model
    let day: Date

    var body: some View {
        let blocks = model.state.plan.blocks(on: day, calendar: .current).filter { $0.kind != .sleep && $0.kind != .breakTime }
        let wake = model.state.plan.wakePlans.first { Calendar.current.isDate($0.day, inSameDayAs: day) }
        List {
            if let w = wake {
                HStack {
                    Image(systemName: "alarm").foregroundStyle(.secondary)
                    VStack(alignment: .leading) {
                        Text("Wake \(w.wake.hm)" + (w.leaveBy.map { " · leave \($0.hm)" } ?? "")).font(.subheadline)
                        Text(w.reason).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(blocks) { b in
                HStack(spacing: 12) {
                    VStack(alignment: .trailing) {
                        Text(b.start.hm).font(.subheadline.monospacedDigit())
                        Text(b.end.hm).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                    }
                    .frame(width: 62, alignment: .trailing)
                    RoundedRectangle(cornerRadius: 2).fill(Theme.color(for: b.kind)).frame(width: 4)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(b.title).font(.subheadline.weight(b.isStudy ? .semibold : .regular))
                            .foregroundStyle(b.isStudy || b.kind == .free ? .primary : .secondary)
                        if let h = b.hint, b.isStudy { Text(h).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                        if b.borrowsSleep { Label("Borrows sleep", systemImage: "moon.zzz").font(.caption2).foregroundStyle(.orange) }
                        if b.usesFreeTime { Label("Uses free time (busy week)", systemImage: "exclamationmark.triangle").font(.caption2).foregroundStyle(.orange) }
                    }
                }
                .listRowSeparator(.hidden)
                .padding(.vertical, 2)
            }
            if let sleep = model.state.plan.blocks.first(where: { $0.kind == .sleep && Calendar.current.isDate($0.start, inSameDayAs: day) }) {
                HStack {
                    Image(systemName: "bed.double").foregroundStyle(.secondary)
                    Text("Sleep \(sleep.start.hm) · \(minutesLabel(sleep.minutes))").font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.plain)
    }
}

struct TaskList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let open = model.state.items.filter { !$0.isDone && $0.parentId == nil }.sorted { $0.due < $1.due }
        let now = Date()
        let week = now.addingTimeInterval(7 * 86400)
        List {
            section("Overdue", open.filter { $0.due < now })
            section("This week", open.filter { $0.due >= now && $0.due < week })
            section("Later", open.filter { $0.due >= week })
            let done = model.state.items.filter { $0.isDone && $0.parentId == nil && ($0.doneAt ?? .distantPast) > now.addingTimeInterval(-7 * 86400) }
            if !done.isEmpty {
                Section("Done this week") {
                    ForEach(done) { i in Text(i.title).strikethrough().foregroundStyle(.secondary) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if open.isEmpty {
                ContentUnavailableView("Nothing due", systemImage: "checkmark.circle",
                                       description: Text("Tap + and type something like “bio quiz thursday”."))
            }
        }
    }

    @ViewBuilder private func section(_ title: String, _ items: [WorkItem]) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { item in
                    NavigationLink { TaskDetailView(itemId: item.id) } label: { TaskRow(item: item) }
                        .swipeActions(edge: .leading) {
                            Button { model.complete(item.id) } label: { Label("Done", systemImage: "checkmark") }.tint(.green)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { model.delete(item.id) } label: { Label("Delete", systemImage: "trash") }
                        }
                }
            }
        }
    }
}

struct TaskRow: View {
    @Environment(AppModel.self) private var model
    let item: WorkItem

    var body: some View {
        let children = model.state.items.filter { $0.parentId == item.id }
        let total = Double(item.estimateMinutes) * model.state.learned.estimateFactor(for: item.kind)
        let progress = children.isEmpty ? min(1, Double(item.completedMinutes) / max(1, total))
            : Double(children.filter(\.isDone).count) / Double(children.count)
        let short = model.state.plan.shortfalls[item.id] ?? 0
        HStack(spacing: 12) {
            Image(systemName: item.kind.symbol).foregroundStyle(Theme.accent).frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.subheadline.weight(.medium)).lineLimit(2)
                HStack(spacing: 6) {
                    Text("\(item.due.relativeDay) \(item.due.hm)")
                    if let s = item.subject { Text("· \(s)") }
                    if item.source == .calendar { Image(systemName: "calendar").imageScale(.small) }
                }
                .font(.caption).foregroundStyle(.secondary)
                ProgressView(value: progress).tint(short > 0 ? .orange : Theme.accent)
            }
        }
        .padding(.vertical, 4)
    }
}
