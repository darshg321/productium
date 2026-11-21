import Foundation

// v1.2 Part I: goals to aim at, computed from the log. The first one is built in: no untracked waking stretch over
// 30 minutes (it's what makes every other number trustworthy). Others are time in a category or group, per day or
// week, at least or at most, or a count of tasks finished. Progress is counted, never a streak.

public struct Goal: Codable, Hashable, Identifiable, Sendable {
    public enum Measure: Codable, Hashable, Sendable {
        case category(CategoryID)
        case group(CategoryGroup)
        case tasksDone
        /// Built in: untracked waking stretches longer than 30 minutes (target 0, at most).
        case trackingGaps
    }
    public enum Period: String, Codable, Sendable { case day, week }
    public enum Direction: String, Codable, Sendable { case atLeast, atMost }
    public enum Origin: String, Codable, Sendable { case you, ai, builtIn }

    public var id: UUID
    public var title: String
    public var measure: Measure
    public var period: Period
    /// Minutes, or a count (tasks, gaps).
    public var target: Int
    public var direction: Direction
    public var origin: Origin
    public var createdAt: Date
    public var active: Bool

    public init(id: UUID = UUID(), title: String, measure: Measure, period: Period, target: Int, direction: Direction = .atLeast,
                origin: Origin = .you, createdAt: Date, active: Bool = true) {
        self.id = id
        self.title = title
        self.measure = measure
        self.period = period
        self.target = max(0, target)
        self.direction = direction
        self.origin = origin
        self.createdAt = createdAt
        self.active = active
    }

    public static let trackingGapsId = Planner.stableUUID("goal|tracking-gaps")
    public static let trackingGaps = Goal(id: trackingGapsId, title: "No untracked stretch over 30 min", measure: .trackingGaps,
                                          period: .day, target: 0, direction: .atMost, origin: .builtIn,
                                          createdAt: Date(timeIntervalSinceReferenceDate: 0))

    public var isCount: Bool {
        switch measure { case .tasksDone, .trackingGaps: return true; default: return false }
    }

    public var ref: String { "g" + Ref.short(id.uuidString) }
}

public struct GoalProgress: Hashable, Sendable {
    public var goal: Goal
    public var value: Int
    public var range: DateInterval
    /// At least: reached. At most: still under (only final once the period ends).
    public var met: Bool
    public var periodOver: Bool
    /// 0…1 toward the target (at most: how much of the allowance is used).
    public var fraction: Double

    /// "Study 1h 10 of 2h", "Scrolling 40m of 1h max", "2 of 3 tasks", "0 gaps over 30 min".
    public var line: String {
        let g = goal
        switch g.measure {
        case .trackingGaps: return value == 0 ? "No untracked gaps over 30 min" : "\(value) untracked gap\(value == 1 ? "" : "s") over 30 min"
        case .tasksDone: return "\(value) of \(g.target) tasks"
        default:
            let name = g.title
            return g.direction == .atLeast ? "\(name) \(minutesLabel(value)) of \(minutesLabel(g.target))"
                                           : "\(name) \(minutesLabel(value)) of \(minutesLabel(g.target)) max"
        }
    }
}

public enum Goals {
    /// The goals in force: the built-in one plus yours and the AI's that are active.
    public static func all(_ goals: [Goal]) -> [Goal] {
        [Goal.trackingGaps] + goals.filter { $0.active && $0.measure != .trackingGaps }
    }

    public static func range(_ p: Goal.Period, now: Date, calendar cal: Calendar) -> DateInterval {
        switch p {
        case .day: return Days.dayInterval(now, cal)
        case .week:
            let start = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? cal.startOfDay(for: now)
            return DateInterval(start: start, duration: 7 * 86400)
        }
    }

    /// Untracked stretches over 30 minutes while awake: time nothing explains (school, sleep, sensors and assumed
    /// time all count as tracked). Sleep, measured or planned, isn't waking time, so it never counts.
    public static func gaps(_ slices: [LogSlice], limit: Int = TrackPrompts.goalMinutes) -> [LogSlice] {
        slices.filter { $0.entry == nil && $0.minutes > limit }
    }

    public static func progress(_ g: Goal, entries: [Entry], tree: CategoryTree, items: [WorkItem], now: Date,
                                book: DayRuleBook = DayRuleBook(), calendar cal: Calendar, at day: Date? = nil) -> GoalProgress {
        let r = range(g.period, now: day ?? now, calendar: cal)
        let over = now >= r.end
        let value: Int
        switch g.measure {
        case .trackingGaps:
            value = gaps(TimeLog.past(entries, in: r, now: now, book: book, calendar: cal)).count
        case .tasksDone:
            value = items.filter { $0.isDone && ($0.doneAt.map { r.contains($0) } ?? false) }.count
        case .category(let c):
            value = TimeLog.past(entries, in: r, now: now, book: book, calendar: cal)
                .filter { $0.entry.map { tree.isUnder($0.category, c) } ?? false }.reduce(0) { $0 + $1.minutes }
        case .group(let grp):
            value = TimeLog.past(entries, in: r, now: now, book: book, calendar: cal)
                .filter { $0.entry.map { tree.group($0.category) == grp } ?? false }.reduce(0) { $0 + $1.minutes }
        }
        let met = g.direction == .atLeast ? value >= g.target : value <= g.target
        let fraction = g.target == 0 ? (met ? 1 : 0) : min(1, Double(value) / Double(g.target))
        return GoalProgress(goal: g, value: value, range: r, met: met, periodOver: over, fraction: fraction)
    }

    /// Days in `days` the goal was met (a count that can't break, I.1: "hit Study 2h on 18 days this month").
    public static func daysMet(_ g: Goal, days: [Date], entries: [Entry], tree: CategoryTree, items: [WorkItem], now: Date,
                               book: DayRuleBook = DayRuleBook(), calendar cal: Calendar) -> Int {
        guard g.period == .day else { return 0 }
        return days.filter { d in
            let r = Days.dayInterval(d, cal)
            guard r.end <= now || cal.isDate(d, inSameDayAs: now) else { return false }
            let p = progress(g, entries: entries, tree: tree, items: items, now: min(now, r.end), book: book, calendar: cal, at: d)
            return p.met && (g.direction == .atLeast || r.end <= now)
        }.count
    }

    /// For the running entry's notification and the Live Activity: the goal its category counts toward.
    public static func line(for e: Entry, goals: [Goal], entries: [Entry], tree: CategoryTree, items: [WorkItem], now: Date,
                            book: DayRuleBook = DayRuleBook(), calendar cal: Calendar) -> String? {
        let hit = goals.filter { $0.active }.first { g in
            switch g.measure {
            case .category(let c): return tree.isUnder(e.category, c)
            case .group(let grp): return tree.group(e.category) == grp
            default: return false
            }
        }
        return hit.map { progress($0, entries: entries, tree: tree, items: items, now: now, book: book, calendar: cal).line }
    }

    /// I2: after 14 days of entries, starting goals just above what you already do (achievable beats a stretch):
    /// the median day of Work › Studying plus 10%, and Scrolling capped at its median (rounded to 15 minutes).
    public static func suggest(entries: [Entry], tree: CategoryTree, existing: [Goal], now: Date, book: DayRuleBook = DayRuleBook(),
                               calendar cal: Calendar) -> [Goal] {
        let today = cal.startOfDay(for: now)
        let days = (1...14).compactMap { cal.date(byAdding: .day, value: -$0, to: today) }
        let firstEntry = entries.filter { $0.source == .you || $0.source == .sensor || $0.source == .health }.map(\.start).min()
        guard let first = firstEntry, first <= days.last! else { return [] }
        func perDay(_ c: CategoryID) -> [Int] {
            days.map { d in
                TimeLog.past(entries, in: Days.dayInterval(d, cal), now: now, book: book, calendar: cal)
                    .filter { $0.entry.map { tree.isUnder($0.category, c) } ?? false }.reduce(0) { $0 + $1.minutes }
            }.sorted()
        }
        func round15(_ m: Double) -> Int { max(15, Int((m / 15).rounded()) * 15) }
        var out: [Goal] = []
        let has = { (c: CategoryID) in existing.contains { if case .category(let x) = $0.measure { return x == c }; return false } }
        let study = perDay(CategoryTree.studying)
        if !has(CategoryTree.studying), let m = study.dropFirst(study.count / 2).first, m > 0 {
            out.append(Goal(title: "Studying", measure: .category(CategoryTree.studying), period: .day, target: round15(Double(m) * 1.1),
                            origin: .ai, createdAt: now))
        }
        let scroll = perDay(CategoryTree.scrolling)
        if !has(CategoryTree.scrolling), let m = scroll.dropFirst(scroll.count / 2).first, m >= 30 {
            out.append(Goal(title: "Scrolling", measure: .category(CategoryTree.scrolling), period: .day, target: round15(Double(m)),
                            direction: .atMost, origin: .ai, createdAt: now))
        }
        return out
    }

    /// I2: the insight pass may move a goal it suggested by at most 10%; yours are never touched.
    public static func nudge(_ g: inout Goal, to target: Int) -> Bool {
        guard g.origin == .ai else { return false }
        let lo = Int((Double(g.target) * 0.9).rounded()), hi = Int((Double(g.target) * 1.1).rounded())
        let t = min(hi, max(lo, target))
        guard t != g.target else { return false }
        g.target = t
        return true
    }

    /// Which way is better for a category in the forecast (G.0a) and the verdicts: productive groups and at-least
    /// goals up, unproductive, at-most goals and Untracked down, everything else neither.
    public static func direction(_ category: CategoryID, tree: CategoryTree, goals: [Goal]) -> Goal.Direction? {
        if category == CategoryTree.untracked { return .atMost }
        for g in goals where g.active {
            if case .category(let c) = g.measure, tree.isUnder(category, c) || category == c { return g.direction }
        }
        switch tree.group(category) {
        case .productive: return tree.isUnder(category, CategoryTree.school) ? nil : .atLeast
        case .unproductive: return .atMost
        default: return nil
        }
    }
}
