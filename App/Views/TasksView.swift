import SwiftUI
import ProductiumCore

struct TasksView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("tasks.grouping") private var grouping: TaskGrouping = .due
    @AppStorage("tasks.showDone") private var showDone = false
    @State private var query = ""
    @State private var clearing: WorkItem?

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 60)) { ctx in
                let now = ctx.date
                let sections = TaskBoard.sections(items: model.state.items, grouping: grouping, query: query,
                                                  showDone: showDone, now: now, calendar: model.cal)
                List {
                    if query.isEmpty { Section { TaskSummaryCard(now: now) } }
                    ForEach(sections) { s in
                        Section {
                            ForEach(s.items) { item in TaskRow(item: item, now: now, onClear: { clearing = $0 }) }
                        } header: {
                            sectionHeader(s)
                        }
                    }
                    if sections.isEmpty {
                        Section {
                            if query.isEmpty {
                                ContentUnavailableView {
                                    Label("No Tasks", systemImage: "checklist")
                                } description: {
                                    Text("Tell the box on Today, like “bio quiz thursday on cells”, or send a screenshot of the assignment.")
                                }
                            } else {
                                ContentUnavailableView.search(text: query)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .animation(.default, value: sections.map(\.id))
            }
            .searchable(text: $query, prompt: "Tasks, subjects, topics")
            .navigationTitle("Tasks")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Group By", selection: $grouping) {
                            ForEach(TaskGrouping.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        Toggle("Show Done", isOn: $showDone)
                    } label: {
                        Label("View Options", systemImage: "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .sheet(item: $clearing) { ClearSheet(item: $0) }
        }
    }

    @ViewBuilder private func sectionHeader(_ s: TaskSection) -> some View {
        switch s.tone {
        case .alert where s.id == "past":
            Label(s.title, systemImage: "exclamationmark.circle.fill").foregroundStyle(Theme.alert)
        case .done:
            Label(s.title, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        default:
            HStack {
                Text(s.title)
                Spacer()
                Text("\(s.items.count)").monospacedDigit()
            }
        }
    }
}

struct TaskSummaryCard: View {
    @Environment(AppModel.self) private var model
    let now: Date

    var body: some View {
        let s = TaskBoard.summary(items: model.state.items, plan: model.state.plan,
                                  factor: { model.state.learned.estimateFactor(for: $0) }, now: now, calendar: model.cal)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                stat("Open", "\(s.open)", Theme.focus)
                stat("This Week", "\(s.dueThisWeek)", .orange)
                stat("Past Due", "\(s.pastDue)", s.pastDue > 0 ? Theme.alert : .secondary)
            }
            if s.minutesLeft > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("\(durationLabel(s.minutesLeft)) of work left").font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(durationLabel(s.minutesPlanned)) planned").font(.subheadline).foregroundStyle(.secondary)
                    }
                    ProgressView(value: Double(s.minutesPlanned), total: Double(max(1, s.minutesLeft)))
                        .tint(s.minutesPlanned >= s.minutesLeft ? Theme.focus : .orange)
                    if s.minutesPlanned < s.minutesLeft {
                        Text("Some of it doesn't fit before it's due. Those tasks have a warning sign.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func stat(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(color)
            Text(value).font(.system(.title2, design: .rounded).weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TaskRow: View {
    @Environment(AppModel.self) private var model
    let item: WorkItem
    let now: Date
    var onClear: (WorkItem) -> Void = { _ in }

    var body: some View {
        let steps = model.state.items.filter { $0.parentId == item.id }
        let factor = model.state.learned.estimateFactor(for: item.kind)
        let left = TaskBoard.minutesLeft(item, steps: steps, factor: factor)
        let total = max(1, Int(Double(item.estimateMinutes) * factor))
        let next = TaskBoard.nextSession(for: item, steps: steps, plan: model.state.plan, now: now)
        let short = (model.state.plan.shortfalls[item.id] ?? 0) > 0
        NavigationLink { TaskDetailView(itemId: item.id) } label: {
            HStack(spacing: 12) {
                Button {
                    withAnimation { item.isDone ? model.reopen(item.id) : model.complete(item.id) }
                } label: {
                    Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(item.isDone ? Color.green : Theme.color(for: item, in: model.state))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(item.isDone ? "Mark \(item.title) not done" : "Mark \(item.title) done")

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .strikethrough(item.isDone)
                        .foregroundStyle(item.isDone ? .secondary : .primary)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        Label(item.kind.title, systemImage: item.kind.symbol).labelStyle(.iconOnly)
                            .foregroundStyle(Theme.color(for: item, in: model.state))
                        Text(subtitle(steps: steps))
                            .foregroundStyle(item.isOpen && item.due < now ? Theme.alert : .secondary)
                    }
                    .font(.caption)
                    if item.isOpen {
                        if let n = next {
                            Label("\(n.start.relativeDay.capitalized), \(n.start.hm)", systemImage: "calendar.badge.clock")
                                .font(.caption).foregroundStyle(Theme.focus)
                        } else if left > 0 && item.due > now {
                            Label("Not planned yet", systemImage: "calendar.badge.exclamationmark")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                Spacer(minLength: 0)
                if item.isOpen {
                    VStack(alignment: .trailing, spacing: 4) {
                        if short {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                .accessibilityLabel("Not enough time planned")
                        }
                        if left > 0 {
                            Text(durationLabel(left)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        if steps.isEmpty && item.completedMinutes > 0 {
                            ProgressView(value: min(1, Double(item.completedMinutes) / Double(total)))
                                .frame(width: 44).tint(Theme.focus)
                        }
                    }
                }
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if item.isDone {
                Button { model.reopen(item.id) } label: { Label("Not Done", systemImage: "arrow.uturn.backward") }.tint(.gray)
            } else {
                Button { model.complete(item.id) } label: { Label("Done", systemImage: "checkmark") }.tint(.green)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { model.delete(item.id) } label: { Label("Delete", systemImage: "trash") }
            if item.isOpen {
                Button { onClear(item) } label: { Label("Clear", systemImage: "xmark.circle") }.tint(.orange)
                Button { model.startTask(item) } label: { Label("Start", systemImage: "play.fill") }.tint(Theme.focus)
            }
        }
        .contextMenu {
            if item.isOpen {
                Button { model.startTask(item) } label: { Label("Start", systemImage: "play.fill") }
                Button { model.complete(item.id) } label: { Label("Done", systemImage: "checkmark.circle") }
                Button { onClear(item) } label: { Label("Clear (not doing it)", systemImage: "xmark.circle") }
            }
            Button(role: .destructive) { model.delete(item.id) } label: { Label("Delete (made by mistake)", systemImage: "trash") }
        }
    }

    private func subtitle(steps: [WorkItem]) -> String {
        var parts: [String] = []
        if item.isDone, let d = item.doneAt { parts.append("Done \(d.relativeDay)") }
        else { parts.append("Due \(item.due.relativeDay) \(item.due.hm)") }
        if let s = item.subject, !s.isEmpty { parts.append(s.capitalized) }
        if !steps.isEmpty { parts.append("\(steps.filter(\.isDone).count)/\(steps.count) steps") }
        if item.isOpen, let p = item.putOffLabel { parts.append(p) }
        return parts.joined(separator: " · ")
    }
}
