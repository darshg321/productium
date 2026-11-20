import Foundation

// v1.2: did the day get done, and how good was it?
//
// Work: the planner spreads each task's time before its due date; that day's share is what the day asks for. Time
// counts for a task whenever you tracked it, in any order: doing tomorrow's essay instead of today's reading still
// counts as work done today. A day is only *short* when the total task time is less than it asked for.
//
// Deadlines: a task is *missed* only when its due time passes and it isn't done. Moving it ("reading tomorrow",
// "the brag sheet can be due tomorrow") isn't missing it; not finishing it by the due it ends up with is.

public struct TaskAccount: Hashable, Sendable {
    public var taskId: UUID
    public var asked: Int
    public var did: Int
    public var deferred: Bool
}

public struct DayAccount: Hashable, Sendable {
    /// Task minutes the day's plan asked for (deferred tasks left out) and task minutes you tracked.
    public var asked: Int
    public var did: Int
    public var deferred: Int
    /// Minutes the day asked for that weren't done on any task.
    public var short: Int
    public var tasks: [TaskAccount]
    /// Tasks due that day: done by their due, or not.
    public var deadlinesMet: [UUID]
    public var deadlinesMissed: [UUID]
    public var met: Bool { short == 0 }
    /// Tasks that were behind, named only when the day as a whole was short.
    public var behind: [UUID] { met ? [] : tasks.filter { !$0.deferred && $0.did < $0.asked }.map(\.taskId) }
}

public enum Accountability {
    public static func day(_ day: Date, asked: [UUID: Int], entries: [Entry], items: [WorkItem], now: Date,
                           book: DayRuleBook = DayRuleBook(), calendar cal: Calendar) -> DayAccount {
        account(day, asked: asked, slices: TimeLog.past(entries, in: Days.dayInterval(day, cal), now: now, book: book, calendar: cal),
                items: items, now: now, calendar: cal)
    }

    static func account(_ day: Date, asked: [UUID: Int], slices: [LogSlice], items: [WorkItem], now: Date,
                        calendar cal: Calendar) -> DayAccount {
        let range = Days.dayInterval(day, cal)
        var did: [UUID: Int] = [:]
        for s in slices { if let t = s.entry?.taskId { did[t, default: 0] += s.minutes } }
        let byId = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var tasks: [TaskAccount] = []
        for id in Set(asked.keys).union(did.keys).sorted(by: { $0.uuidString < $1.uuidString }) {
            let item = byId[id]
            var a = asked[id] ?? 0
            let d = did[id] ?? 0
            if let item, item.isDone, let at = item.doneAt, at < range.end { a = min(a, d) }
            let deferred = item?.notBefore.map { $0 >= range.end } ?? false
            tasks.append(TaskAccount(taskId: id, asked: a, did: d, deferred: deferred && d < a))
        }
        let askedTotal = tasks.filter { !$0.deferred }.reduce(0) { $0 + $1.asked }
        let didTotal = tasks.reduce(0) { $0 + $1.did }
        let deferred = tasks.filter(\.deferred).reduce(0) { $0 + $1.asked - $1.did }
        let due = items.filter { $0.due >= range.start && $0.due < range.end && $0.due <= now }
        let met = due.filter { $0.isDone && ($0.doneAt ?? .distantFuture) <= $0.due }.map(\.id)
        let missed = due.filter { !met.contains($0.id) }.map(\.id)
        return DayAccount(asked: askedTotal, did: didTotal, deferred: deferred, short: max(0, askedTotal - didTotal),
                          tasks: tasks, deadlinesMet: met, deadlinesMissed: missed)
    }

    /// What a day's plan asks for, per task: the snapshot to keep in `AppState.dayPlans` at the day's first plan.
    public static func asked(by plan: Plan, on day: Date, calendar cal: Calendar) -> [UUID: Int] {
        plan.blocks.filter { $0.isStudy && cal.isDate($0.start, inSameDayAs: day) }
            .reduce(into: [UUID: Int]()) { if let id = $1.itemId { $0[id, default: 0] += $1.minutes } }
    }
}

/// The day's score, 0–100, from the four things v1.2 cares about. Shown with its parts, never alone, so it's
/// always clear what moved it; Review compares it with your usual (G.0a).
///
/// - Tracked (30): waking minutes accounted for (assumed time counts; Untracked doesn't).
/// - Work (40): task minutes done vs what the day asked for (any order). Nothing asked: full marks.
/// - Deadlines (30): tasks due that day done by their due. None due: full marks.
/// - Scrolling: minus 1 for every 6 minutes, at most minus 30.
public struct DayScore: Hashable, Sendable {
    public var wakingMinutes: Int
    public var untrackedMinutes: Int
    public var workMinutes: Int
    public var askedMinutes: Int
    public var deadlinesDue: Int
    public var deadlinesMet: Int
    public var scrollingMinutes: Int

    public static let trackedPoints = 30.0, workPoints = 40.0, deadlinePoints = 30.0
    public static let scrollingMinutesPerPoint = 6.0, maxScrollingPenalty = 30.0

    public var tracked: Double { Self.trackedPoints * (wakingMinutes == 0 ? 1 : Double(wakingMinutes - untrackedMinutes) / Double(wakingMinutes)) }
    public var work: Double { Self.workPoints * (askedMinutes == 0 ? 1 : min(1, Double(workMinutes) / Double(askedMinutes))) }
    public var deadlines: Double { Self.deadlinePoints * (deadlinesDue == 0 ? 1 : Double(deadlinesMet) / Double(deadlinesDue)) }
    public var scrolling: Double { -min(Self.maxScrollingPenalty, Double(scrollingMinutes) / Self.scrollingMinutesPerPoint) }
    public var score: Int { Int(max(0, min(100, tracked + work + deadlines + scrolling)).rounded()) }

    public static func make(_ day: Date, asked: [UUID: Int], entries: [Entry], items: [WorkItem], tree: CategoryTree,
                            now: Date, book: DayRuleBook = DayRuleBook(), calendar cal: Calendar) -> DayScore {
        let slices = TimeLog.past(entries, in: Days.dayInterval(day, cal), now: now, book: book, calendar: cal)
        let acct = Accountability.account(day, asked: asked, slices: slices, items: items, now: now, calendar: cal)
        let asleep = slices.filter { $0.entry.map { tree.isUnder($0.category, CategoryTree.sleep) } ?? false }.reduce(0) { $0 + $1.minutes }
        let total = slices.reduce(0) { $0 + $1.minutes }
        let untracked = slices.filter { $0.entry == nil }.reduce(0) { $0 + $1.minutes }
        let scrolling = slices.filter { $0.entry.map { tree.isUnder($0.category, CategoryTree.scrolling) } ?? false }.reduce(0) { $0 + $1.minutes }
        return DayScore(wakingMinutes: max(0, total - asleep), untrackedMinutes: untracked, workMinutes: acct.did,
                        askedMinutes: acct.asked, deadlinesDue: acct.deadlinesMet.count + acct.deadlinesMissed.count,
                        deadlinesMet: acct.deadlinesMet.count, scrollingMinutes: scrolling)
    }
}
