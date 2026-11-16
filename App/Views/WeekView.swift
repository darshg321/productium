import SwiftUI
import ProductiumCore

/// The next seven days as an inset-grouped list: one section per day, the day drawn as
/// a strip, and what's due that day under it.
struct WeekView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            List {
                let overdue = model.state.items.filter { !$0.isDone && $0.parentId == nil && $0.due < Date() }
                if !overdue.isEmpty {
                    Section {
                        ForEach(overdue) { DueRow(item: $0) }
                    } header: {
                        Label("Past Due", systemImage: "exclamationmark.circle.fill").foregroundStyle(Theme.alert)
                    }
                }
                ForEach(days, id: \.self) { d in DaySection(day: d) }
                Section {
                } footer: {
                    Text("To change anything here, tell the Inbox on Today.")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Week")
            .usageMeter()
        }
    }

    private var days: [Date] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }
}

struct DaySection: View {
    @Environment(AppModel.self) private var model
    let day: Date

    var body: some View {
        let cal = Calendar.current
        let due = model.state.items.filter { !$0.isDone && cal.isDate($0.due, inSameDayAs: day) }.sorted { $0.due < $1.due }
        let blocks = model.state.plan.blocks(on: day, calendar: cal)
        let study = blocks.filter(\.isStudy).reduce(0) { $0 + $1.minutes }
        let start = cal.date(bySettingHour: 6, minute: 0, second: 0, of: day) ?? day
        Section {
            NavigationLink { DayDetail(day: day) } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(cal.isDateInToday(day) ? "Today" : cal.isDateInTomorrow(day) ? "Tomorrow" : day.formatted(.dateTime.weekday(.wide)))
                            .font(.headline)
                        Text(day.formatted(.dateTime.month(.abbreviated).day())).font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        if study > 0 {
                            Label(durationLabel(study), systemImage: "pencil.line")
                                .font(.subheadline).foregroundStyle(Theme.focus)
                                .labelStyle(.titleAndIcon)
                        }
                    }
                    DayStrip(blocks: blocks, start: start, end: start.addingTimeInterval(18 * 3600))
                }
                .padding(.vertical, 4)
            }
            ForEach(due) { DueRow(item: $0) }
        }
    }
}

struct DueRow: View {
    @Environment(AppModel.self) private var model
    let item: WorkItem

    var body: some View {
        let steps = model.state.items.filter { $0.parentId == item.id }
        let short = (model.state.plan.shortfalls[item.id] ?? 0) > 0
        NavigationLink { TaskDetailView(itemId: item.id) } label: {
            HStack(spacing: 12) {
                IconTile(symbol: item.kind.symbol, color: Theme.color(for: item.kind))
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).lineLimit(2)
                    Text(steps.isEmpty ? "Due \(item.due.relativeDay) at \(item.due.hm)"
                                       : "\(steps.filter(\.isDone).count) of \(steps.count) steps done")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if short {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        .accessibilityLabel("Not enough time planned")
                }
            }
        }
    }
}

struct DayDetail: View {
    @Environment(AppModel.self) private var model
    let day: Date

    var body: some View {
        let cal = Calendar.current
        let wake = model.state.plan.wakePlans.first { cal.isDate($0.day, inSameDayAs: day) }
        let from = cal.isDateInToday(day) ? Date() : (wake?.wake ?? cal.startOfDay(for: day))
        let blocks = model.state.plan.blocks.filter {
            $0.end > from && cal.isDate($0.start, inSameDayAs: day) && $0.kind != .breakTime && $0.minutes >= 10
        }
        let study = blocks.filter(\.isStudy).reduce(0) { $0 + $1.minutes }
        List {
            if let w = wake {
                Section {
                    LabeledContent { Text(w.wake.hm) } label: { SettingsLabel(title: "Wake Up", symbol: "alarm.fill", color: .orange) }
                    if let leave = w.leaveBy {
                        LabeledContent { Text(leave.hm) } label: { SettingsLabel(title: "Out the Door", symbol: "figure.walk", color: .green) }
                    }
                    if study > 0 {
                        LabeledContent { Text(durationLabel(study)) } label: { SettingsLabel(title: "Work Planned", symbol: "pencil.line", color: .blue) }
                    }
                } footer: {
                    Text(w.reason)
                }
            }
            Section("Plan") {
                if blocks.isEmpty { Text("Nothing planned.").foregroundStyle(.secondary) }
                ForEach(blocks.filter { $0.kind != .sleep }) { BlockRow(block: $0, from: from) }
                if let bed = blocks.first(where: { $0.kind == .sleep }) { BlockRow(block: bed) }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
        .navigationBarTitleDisplayMode(.inline)
    }
}
