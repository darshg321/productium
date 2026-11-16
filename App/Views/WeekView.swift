import SwiftUI
import ProductiumCore

/// The next seven days, one line each: the day drawn as a strip, and what's due under it.
struct WeekView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    Text("This week").font(.display(34, .bold)).padding(.top, 16)
                    let overdue = model.state.items.filter { !$0.isDone && $0.parentId == nil && $0.due < Date() }
                    if !overdue.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Past due").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.signal)
                            ForEach(overdue) { DueLine(item: $0) }
                        }
                    }
                    ForEach(days, id: \.self) { d in DayRow(day: d) }
                    Text("To change anything here, tell the box on Today.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var days: [Date] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }
}

struct DayRow: View {
    @Environment(AppModel.self) private var model
    let day: Date

    var body: some View {
        let cal = Calendar.current
        let due = model.state.items.filter { !$0.isDone && cal.isDate($0.due, inSameDayAs: day) }.sorted { $0.due < $1.due }
        let study = model.state.plan.blocks(on: day, calendar: cal).filter(\.isStudy).reduce(0) { $0 + $1.minutes }
        VStack(alignment: .leading, spacing: 8) {
            NavigationLink { DayDetail(day: day) } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(cal.isDateInToday(day) ? "Today" : day.formatted(.dateTime.weekday(.wide)))
                            .font(.display(18, .semibold)).foregroundStyle(.primary)
                        Text(day.formatted(.dateTime.day())).font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        if study > 0 { Text("\(minutesLabel(study)) of work").font(.subheadline).foregroundStyle(.secondary) }
                    }
                    DayStrip(blocks: model.state.plan.blocks(on: day, calendar: cal), day: day)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            ForEach(due) { DueLine(item: $0) }
        }
    }
}

/// A day from 06:00 to midnight as one horizontal bar, each block its own width.
struct DayStrip: View {
    let blocks: [PlannedBlock]
    let day: Date
    var height: CGFloat = 10

    var body: some View {
        GeometryReader { g in
            let start = Calendar.current.date(bySettingHour: 6, minute: 0, second: 0, of: day) ?? day
            let span: TimeInterval = 18 * 3600
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.fog.opacity(0.35))
                ForEach(blocks.filter { $0.end > start }) { b in
                    let x = max(0, b.start.timeIntervalSince(start)) / span
                    let w = (min(b.end, start.addingTimeInterval(span)).timeIntervalSince(max(b.start, start))) / span
                    Rectangle().fill(Theme.color(for: b.kind))
                        .frame(width: max(1, g.size.width * w))
                        .offset(x: g.size.width * x)
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

struct DueLine: View {
    @Environment(AppModel.self) private var model
    let item: WorkItem

    var body: some View {
        let steps = model.state.items.filter { $0.parentId == item.id }
        NavigationLink { TaskDetailView(itemId: item.id) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: item.kind.symbol).font(.caption).foregroundStyle(.secondary).frame(width: 18)
                Text(item.title).font(.subheadline).foregroundStyle(.primary).lineLimit(2)
                Spacer()
                if !steps.isEmpty {
                    Text("\(steps.filter(\.isDone).count) of \(steps.count) steps").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(item.due.hm).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if (model.state.plan.shortfalls[item.id] ?? 0) > 0 {
                    Image(systemName: "exclamationmark").font(.caption.weight(.bold)).foregroundStyle(Theme.signal)
                        .accessibilityLabel("Not enough time planned")
                }
            }
        }
        .buttonStyle(.plain)
    }
}

struct DayDetail: View {
    @Environment(AppModel.self) private var model
    let day: Date

    var body: some View {
        let cal = Calendar.current
        let wake = model.state.plan.wakePlans.first { cal.isDate($0.day, inSameDayAs: day) }
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(day.formatted(.dateTime.weekday(.wide).month().day())).font(.display(26, .bold))
                if let w = wake {
                    Text("Up at \(w.wake.hm)" + (w.leaveBy.map { ", out the door by \($0.hm)" } ?? "") + ".")
                        .font(.subheadline)
                    Text(w.reason).font(.footnote).foregroundStyle(.secondary)
                }
                let start = cal.isDateInToday(day) ? Date() : (wake?.wake ?? cal.startOfDay(for: day))
                DayRuler(from: start, blocks: model.state.plan.blocks.filter {
                    $0.end > start && (cal.isDate($0.start, inSameDayAs: day) || ($0.kind == .sleep && cal.isDate($0.start, inSameDayAs: day)))
                })
            }
            .padding(20)
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}
