import Foundation

// MARK: - The task list

public enum TaskGrouping: String, Codable, CaseIterable, Sendable {
    case due, subject, kind

    public var title: String {
        switch self {
        case .due: return "Due Date"
        case .subject: return "Subject"
        case .kind: return "Type"
        }
    }
}

public struct TaskSection: Identifiable, Hashable, Sendable {
    public enum Tone: String, Sendable { case alert, normal, done }
    public var id: String
    public var title: String
    public var tone: Tone
    public var items: [WorkItem]
}

public struct TaskSummary: Hashable, Sendable {
    public var open: Int
    public var pastDue: Int
    public var dueThisWeek: Int
    /// Work left on open tasks, corrected by how long things really take.
    public var minutesLeft: Int
    /// Minutes of that which the plan has a slot for.
    public var minutesPlanned: Int
}

/// Sorting, grouping and searching tasks. Steps of a project live under the project, so the
/// list only shows top-level tasks; a search that matches a step shows its project.
public enum TaskBoard {
    public static func sections(items: [WorkItem], grouping: TaskGrouping, query: String = "", showDone: Bool,
                                now: Date, calendar cal: Calendar) -> [TaskSection] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let stepsByParent = Dictionary(grouping: items.filter { $0.parentId != nil }, by: { $0.parentId! })
        let top = items.filter { $0.parentId == nil }.filter { q.isEmpty || matches($0, q, steps: stepsByParent[$0.id] ?? []) }
        let open = top.filter { !$0.isDone }.sorted { ($0.due, $1.importance, $0.title) < ($1.due, $0.importance, $1.title) }
        let recentDone = top.filter { $0.isDone && ($0.doneAt ?? $0.due) > now.addingTimeInterval(-14 * 86400) }
            .sorted { ($0.doneAt ?? $0.due) > ($1.doneAt ?? $1.due) }

        var out: [TaskSection] = []
        switch grouping {
        case .due:
            let today = cal.startOfDay(for: now)
            let tomorrow = cal.date(byAdding: .day, value: 1, to: today)!
            let dayAfter = cal.date(byAdding: .day, value: 2, to: today)!
            let week = cal.date(byAdding: .day, value: 7, to: today)!
            let buckets: [(String, String, TaskSection.Tone, (WorkItem) -> Bool)] = [
                ("past", "Past Due", .alert, { $0.due < now }),
                ("today", "Today", .normal, { $0.due >= now && $0.due < tomorrow }),
                ("tomorrow", "Tomorrow", .normal, { $0.due >= tomorrow && $0.due < dayAfter }),
                ("week", "Next 7 Days", .normal, { $0.due >= dayAfter && $0.due < week }),
                ("later", "Later", .normal, { $0.due >= week }),
            ]
            for (id, title, tone, f) in buckets {
                let xs = open.filter(f)
                if !xs.isEmpty { out.append(TaskSection(id: id, title: title, tone: tone, items: xs)) }
            }
        case .subject:
            let groups = Dictionary(grouping: open, by: { $0.subject?.trimmingCharacters(in: .whitespaces).capitalized ?? "" })
            for (name, xs) in groups.sorted(by: { ($0.value.first?.due ?? .distantFuture) < ($1.value.first?.due ?? .distantFuture) }) {
                out.append(TaskSection(id: "s." + name, title: name.isEmpty ? "No Subject" : name,
                                       tone: xs.contains { $0.due < now } ? .alert : .normal, items: xs))
            }
        case .kind:
            let groups = Dictionary(grouping: open, by: \.kind)
            for kind in TaskKind.allCases {
                guard let xs = groups[kind] else { continue }
                out.append(TaskSection(id: "k." + kind.rawValue, title: kind.plural,
                                       tone: xs.contains { $0.due < now } ? .alert : .normal, items: xs))
            }
        }
        if showDone && !recentDone.isEmpty {
            out.append(TaskSection(id: "done", title: "Done", tone: .done, items: recentDone))
        }
        return out
    }

    static func matches(_ item: WorkItem, _ q: String, steps: [WorkItem]) -> Bool {
        let hay = ([item.title, item.subject ?? "", item.kind.rawValue, item.notes ?? ""] + item.topics + steps.map(\.title))
            .joined(separator: " ").lowercased()
        return q.split(separator: " ").allSatisfy { hay.contains($0) }
    }

    /// Minutes still to do: the estimate (corrected by `factor`) minus what's logged.
    /// A project with steps counts its open steps instead.
    public static func minutesLeft(_ item: WorkItem, steps: [WorkItem], factor: Double) -> Int {
        guard !item.isDone else { return 0 }
        let open = steps.filter { !$0.isDone }
        if !steps.isEmpty {
            return open.reduce(0) { $0 + max(0, Int(Double($1.estimateMinutes) * factor) - $1.completedMinutes) }
        }
        return max(0, Int(Double(item.estimateMinutes) * factor) - item.completedMinutes)
    }

    /// The next planned study session for the task or any of its steps.
    public static func nextSession(for item: WorkItem, steps: [WorkItem], plan: Plan, now: Date) -> PlannedBlock? {
        let ids = Set([item.id] + steps.map(\.id))
        return plan.blocks.first { $0.isStudy && $0.end > now && $0.itemId.map(ids.contains) == true }
    }

    public static func summary(items: [WorkItem], plan: Plan, factor: (TaskKind) -> Double, now: Date,
                               calendar cal: Calendar) -> TaskSummary {
        let top = items.filter { $0.parentId == nil && !$0.isDone }
        let steps = Dictionary(grouping: items.filter { $0.parentId != nil }, by: { $0.parentId! })
        let week = cal.date(byAdding: .day, value: 7, to: cal.startOfDay(for: now))!
        let left = top.reduce(0) { $0 + minutesLeft($1, steps: steps[$1.id] ?? [], factor: factor($1.kind)) }
        let openIds = Set(items.filter { !$0.isDone }.map(\.id))
        let planned = plan.blocks.filter { $0.isStudy && $0.end > now && $0.itemId.map(openIds.contains) == true }
            .reduce(0) { $0 + Int($1.end.timeIntervalSince(max($1.start, now)) / 60) }
        return TaskSummary(open: top.count, pastDue: top.filter { $0.due < now }.count,
                           dueThisWeek: top.filter { $0.due >= now && $0.due < week }.count,
                           minutesLeft: left, minutesPlanned: min(left, planned))
    }
}

extension TaskKind {
    public var title: String {
        switch self {
        case .assignment: return "Assignment"
        case .quiz: return "Quiz"
        case .test: return "Test"
        case .project: return "Project"
        case .essay: return "Essay"
        case .application: return "Application"
        case .reading: return "Reading"
        case .practice: return "Practice"
        case .chore: return "Chore"
        case .other: return "Other"
        }
    }

    public var plural: String {
        switch self {
        case .quiz: return "Quizzes"
        case .other: return "Other"
        case .reading: return "Reading"
        case .practice: return "Practice"
        default: return title + "s"
        }
    }
}

// MARK: - The day timeline

public enum TimelineLayout {
    /// Side-by-side columns for overlapping intervals: (column, columns in its cluster) per input,
    /// in input order. Intervals that only touch don't overlap.
    public static func lanes(_ xs: [(start: Date, end: Date)]) -> [(lane: Int, of: Int)] {
        let order = xs.indices.sorted { (xs[$0].start, xs[$0].end) < (xs[$1].start, xs[$1].end) }
        var result = Array(repeating: (lane: 0, of: 1), count: xs.count)
        var cluster: [Int] = []
        var laneEnds: [Date] = []
        var clusterEnd = Date.distantPast
        func close() {
            for i in cluster { result[i].of = max(1, laneEnds.count) }
            cluster = []
            laneEnds = []
        }
        for i in order {
            let x = xs[i]
            if x.start >= clusterEnd { close() }
            if let free = laneEnds.firstIndex(where: { $0 <= x.start }) {
                laneEnds[free] = x.end
                result[i].lane = free
            } else {
                laneEnds.append(x.end)
                result[i].lane = laneEnds.count - 1
            }
            cluster.append(i)
            clusterEnd = max(clusterEnd, x.end)
        }
        close()
        return result
    }
}
