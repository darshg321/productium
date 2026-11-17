import SwiftUI
import ProductiumCore

/// The plan, two ways: one day as a to-scale timeline (the Calendar app's day view), or the
/// next seven days as a list. Day chips along the top pick the day.
struct ScheduleView: View {
    enum Mode: String, CaseIterable { case day = "Day", week = "Week" }
    @Environment(AppModel.self) private var model
    @AppStorage("schedule.mode") private var mode: Mode = .day
    @State private var day = Calendar.current.startOfDay(for: Date())

    var body: some View {
        NavigationStack {
            Group {
                switch mode {
                case .day:
                    VStack(spacing: 0) {
                        DayChips(selected: $day)
                        Divider()
                        DayTimelinePage(day: day)
                    }
                case .week:
                    WeekList { d in day = d; mode = .day }
                }
            }
            .background(Theme.background)
            .navigationTitle(mode == .day ? dayTitle : "Next 7 Days")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Picker("View", selection: $mode) {
                        ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 130)
                }
                if mode == .day && !Calendar.current.isDateInToday(day) {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Today") { withAnimation { day = Calendar.current.startOfDay(for: Date()) } }
                    }
                }
            }
            .usageMeter()
        }
    }

    private var dayTitle: String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInTomorrow(day) { return "Tomorrow" }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }
}

// MARK: - Day chips

struct DayChips: View {
    @Environment(AppModel.self) private var model
    @Binding var selected: Date

    var body: some View {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let days = (0..<14).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(days, id: \.self) { d in
                        let on = cal.isDate(d, inSameDayAs: selected)
                        let study = model.state.plan.blocks(on: d, calendar: cal).contains(where: \.isStudy)
                        let due = model.state.items.contains { !$0.isDone && $0.parentId == nil && cal.isDate($0.due, inSameDayAs: d) }
                        Button { withAnimation(.snappy) { selected = d } } label: {
                            VStack(spacing: 4) {
                                Text(d.formatted(.dateTime.weekday(.narrow)))
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(on ? Color.white.opacity(0.85) : .secondary)
                                Text(d.formatted(.dateTime.day()))
                                    .font(.headline.monospacedDigit())
                                    .foregroundStyle(on ? .white : cal.isDateInToday(d) ? Color.red : .primary)
                                HStack(spacing: 3) {
                                    Circle().fill(study ? Theme.focus : .clear).frame(width: 5, height: 5)
                                    Circle().fill(due ? Theme.alert : .clear).frame(width: 5, height: 5)
                                }
                            }
                            .frame(width: 44, height: 64)
                            .background(on ? (cal.isDateInToday(d) ? Color.red : Color.accentColor) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .id(d)
                        .accessibilityLabel(d.formatted(.dateTime.weekday(.wide).month().day())
                                            + (study ? ", work planned" : "") + (due ? ", something due" : ""))
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onChange(of: selected) { _, d in withAnimation { proxy.scrollTo(d, anchor: .center) } }
        }
        .background(Theme.card)
    }
}

// MARK: - One day, to scale

struct DayTimelinePage: View {
    @Environment(AppModel.self) private var model
    let day: Date

    var body: some View {
        let cal = Calendar.current
        let window = self.window(cal)
        let blocks = model.state.plan.blocks.filter { $0.end > window.start && $0.start < window.end }
        let due = model.state.items.filter { !$0.isDone && $0.parentId == nil && cal.isDate($0.due, inSameDayAs: day) }
            .sorted { $0.due < $1.due }
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    DaySummaryCard(day: day, due: due)
                    Card {
                        DayTimeline(day: day, start: window.start, end: window.end, blocks: blocks, due: due)
                    }
                }
                .padding(16)
            }
            .onAppear { scroll(proxy, window: window) }
            .onChange(of: day) { _, _ in scroll(proxy, window: self.window(cal)) }
        }
    }

    /// From the planned wake-up (or the first thing planned) to bedtime, on the hour.
    private func window(_ cal: Calendar) -> (start: Date, end: Date) {
        let dayStart = cal.startOfDay(for: day)
        let plan = model.state.plan
        let wake = plan.wakePlans.first { cal.isDate($0.day, inSameDayAs: day) }?.wake
        let first = plan.blocks.filter { cal.isDate($0.start, inSameDayAs: day) && $0.kind != .sleep }.map(\.start).min()
        var start = [wake, first].compactMap { $0 }.min() ?? dayStart.addingTimeInterval(7 * 3600)
        start = cal.dateInterval(of: .hour, for: start)?.start ?? start
        let bed = plan.blocks.first { $0.kind == .sleep && cal.isDate($0.start, inSameDayAs: day) }?.start
        var end = (bed ?? dayStart.addingTimeInterval(22 * 3600)).addingTimeInterval(3600)
        end = cal.dateInterval(of: .hour, for: end)?.end ?? end
        if end.timeIntervalSince(start) < 6 * 3600 { end = start.addingTimeInterval(6 * 3600) }
        return (start, end)
    }

    private func scroll(_ proxy: ScrollViewProxy, window: (start: Date, end: Date)) {
        let cal = Calendar.current
        let target: Date
        if cal.isDateInToday(day) { target = Date().addingTimeInterval(-3600) }
        else if let s = model.state.plan.blocks(on: day, calendar: cal).first(where: \.isStudy) { target = s.start.addingTimeInterval(-3600) }
        else { return }
        let hour = cal.component(.hour, from: max(window.start, min(target, window.end)))
        DispatchQueue.main.async { withAnimation { proxy.scrollTo("hour.\(hour)", anchor: .top) } }
    }
}

/// Wake, leave, work, bed for the day, and what's due.
struct DaySummaryCard: View {
    @Environment(AppModel.self) private var model
    let day: Date
    let due: [WorkItem]

    var body: some View {
        let cal = Calendar.current
        let wake = model.state.plan.wakePlans.first { cal.isDate($0.day, inSameDayAs: day) }
        let study = model.state.plan.blocks(on: day, calendar: cal).filter(\.isStudy).reduce(0) { $0 + $1.minutes }
        let bed = model.state.plan.blocks.first { $0.kind == .sleep && cal.isDate($0.start, inSameDayAs: day) }?.start
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if let w = wake { stat("Up", "alarm.fill", .orange, w.wake.hm) }
                if let l = wake?.leaveBy { stat("Leave", "figure.walk", .green, l.hm) }
                stat("Work", "pencil.line", Theme.focus, study > 0 ? durationLabel(study) : "None")
                if let b = bed { stat("Bed", "moon.fill", Theme.sleep, b.hm) }
            }
            if !due.isEmpty {
                Card {
                    CardHeader(title: "Due", symbol: "flag.fill", color: Theme.alert, detail: "\(due.count)")
                    ForEach(due) { i in
                        NavigationLink { TaskDetailView(itemId: i.id) } label: {
                            HStack(spacing: 10) {
                                IconTile(symbol: i.kind.symbol, color: Theme.color(for: i, in: model.state), size: 24)
                                Text(i.title).font(.subheadline).foregroundStyle(.primary).lineLimit(1)
                                Spacer()
                                Text(i.due.hm).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if let reason = wake?.reason, !reason.isEmpty {
                Text(reason).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func stat(_ title: String, _ symbol: String, _ color: Color, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.caption.weight(.semibold)).foregroundStyle(color)
            Text(value).font(.system(.subheadline, design: .rounded).weight(.semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Hours down the side, blocks to scale, overlapping things side by side, and a red line at now.
struct DayTimeline: View {
    let day: Date
    let start: Date
    let end: Date
    let blocks: [PlannedBlock]
    let due: [WorkItem]
    private let perMinute: CGFloat = 1.2
    private let gutter: CGFloat = 46

    var body: some View {
        let height = y(end)
        let shown = blocks.map { b -> PlannedBlock in
            var c = b
            c.start = max(b.start, start)
            c.end = min(b.end, end)
            return c
        }.filter { $0.end > $0.start }
        let lanes = TimelineLayout.lanes(shown.map { (start: $0.start, end: $0.end) })
        ZStack(alignment: .topLeading) {
            hourGrid
            GeometryReader { g in
                let width = g.size.width - gutter
                ForEach(Array(shown.enumerated()), id: \.element.id) { i, b in
                    let lane = lanes[i]
                    let w = width / CGFloat(lane.of)
                    TimelineBlock(block: b, original: blocks.first { $0.id == b.id } ?? b)
                        .frame(width: max(10, w - 3), height: max(4, y(b.end) - y(b.start) - 2))
                        .offset(x: gutter + CGFloat(lane.lane) * w, y: y(b.start) + 1)
                }
                ForEach(due.filter { $0.due >= start && $0.due <= end }) { item in
                    HStack(spacing: 4) {
                        Image(systemName: "flag.fill").font(.caption2)
                        Text("\(item.title) due").font(.caption2.weight(.semibold)).lineLimit(1)
                    }
                    .foregroundStyle(Theme.alert)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.background, in: Capsule())
                    .overlay(Capsule().stroke(Theme.alert.opacity(0.5)))
                    .offset(x: gutter + 4, y: y(item.due) - 9)
                    .accessibilityLabel("\(item.title) due at \(item.due.hm)")
                }
            }
            if Calendar.current.isDateInToday(day) {
                TimelineView(.periodic(from: .now, by: 60)) { ctx in
                    if ctx.date >= start && ctx.date <= end {
                        HStack(spacing: 0) {
                            Text(ctx.date.hm).font(.caption2.weight(.bold).monospacedDigit()).foregroundStyle(.red)
                                .frame(width: gutter - 4, alignment: .trailing)
                                .padding(.trailing, 4)
                                .background(Theme.card)
                            Circle().fill(.red).frame(width: 7, height: 7)
                            Rectangle().fill(.red).frame(height: 1.5)
                        }
                        .offset(y: y(ctx.date) - 7)
                        .accessibilityHidden(true)
                    }
                }
            }
        }
        .frame(height: height)
    }

    /// One fixed-height row per hour, so each hour has a real position to scroll to.
    private var hourGrid: some View {
        let cal = Calendar.current
        let count = max(1, Int((end.timeIntervalSince(start) / 3600).rounded()))
        let hours = (0..<count).compactMap { cal.date(byAdding: .hour, value: $0, to: start) }
        return VStack(spacing: 0) {
            ForEach(hours, id: \.self) { d in
                HStack(alignment: .center, spacing: 6) {
                    Text(d.formatted(.dateTime.hour()))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: gutter - 6, alignment: .trailing)
                    Rectangle().fill(Color(.separator)).frame(height: 0.5)
                }
                .frame(height: 14)
                .offset(y: -7)
                .frame(height: 60 * perMinute, alignment: .top)
                .id("hour.\(cal.component(.hour, from: d))")
            }
        }
        .accessibilityHidden(true)
    }

    private func y(_ d: Date) -> CGFloat { CGFloat(d.timeIntervalSince(start) / 60) * perMinute }
}

struct TimelineBlock: View {
    let block: PlannedBlock
    let original: PlannedBlock

    var body: some View {
        let color = Theme.color(for: block)
        let tall = block.minutes >= 25
        let content = HStack(alignment: .top, spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3)
            if block.minutes >= 12 {
                VStack(alignment: .leading, spacing: 1) {
                    Text(blockLabel(block))
                        .font((block.isStudy ? Font.caption.weight(.semibold) : .caption))
                        .foregroundStyle(block.isStudy ? .primary : .secondary)
                        .lineLimit(tall ? 2 : 1)
                    if tall {
                        Text("\(original.start.hm) – \(original.end.hm)")
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 3)
            }
            Spacer(minLength: 0)
            if block.borrowsSleep {
                Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(Theme.alert).padding(4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(color.opacity(block.isStudy ? 0.22 : 0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(blockLabel(block)), \(original.start.hm) to \(original.end.hm)")

        if let id = block.itemId, block.isStudy {
            NavigationLink { TaskDetailView(itemId: id) } label: { content }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isButton)
        } else {
            content
        }
    }
}

// MARK: - The week as a list

/// The next seven days as an inset-grouped list: one section per day, the day drawn as
/// a strip, and what's due that day under it. Tapping a day opens it as a timeline.
struct WeekList: View {
    @Environment(AppModel.self) private var model
    var open: (Date) -> Void

    var body: some View {
        List {
            let overdue = model.state.items.filter { !$0.isDone && $0.parentId == nil && $0.due < Date() }
            if !overdue.isEmpty {
                Section {
                    ForEach(overdue) { DueRow(item: $0) }
                } header: {
                    Label("Past Due", systemImage: "exclamationmark.circle.fill").foregroundStyle(Theme.alert)
                }
            }
            ForEach(days, id: \.self) { d in DaySection(day: d, open: open) }
        }
        .listStyle(.insetGrouped)
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
    var open: (Date) -> Void

    var body: some View {
        let cal = Calendar.current
        let due = model.state.items.filter { !$0.isDone && $0.parentId == nil && cal.isDate($0.due, inSameDayAs: day) }.sorted { $0.due < $1.due }
        let blocks = model.state.plan.blocks(on: day, calendar: cal)
        let study = blocks.filter(\.isStudy).reduce(0) { $0 + $1.minutes }
        let start = cal.date(bySettingHour: 6, minute: 0, second: 0, of: day) ?? day
        Section {
            Button { open(day) } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(cal.isDateInToday(day) ? "Today" : cal.isDateInTomorrow(day) ? "Tomorrow" : day.formatted(.dateTime.weekday(.wide)))
                            .font(.headline).foregroundStyle(.primary)
                        Text(day.formatted(.dateTime.month(.abbreviated).day())).font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        if study > 0 {
                            Label(durationLabel(study), systemImage: "pencil.line")
                                .font(.subheadline).foregroundStyle(Theme.focus)
                                .labelStyle(.titleAndIcon)
                        }
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
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
                IconTile(symbol: item.kind.symbol, color: Theme.color(for: item, in: model.state))
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
