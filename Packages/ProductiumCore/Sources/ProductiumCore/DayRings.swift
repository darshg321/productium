import Foundation

// v1.3 Part D: three concentric rings like the Fitness app, each a goal that closes: Work (minutes worked on tasks vs
// what today's plan asked), Tracked (share of waking time that's an entry) and Limit (unproductive minutes vs your
// limit; good when it's not closed). Shown on Home, in Review's Day and week strip, and in the Now Live Activity.

public struct DayRings: Codable, Hashable, Sendable {
    public var workMinutes: Int
    /// What today's plan asked (`Accountability.asked`); 0 when nothing was asked.
    public var workGoal: Int
    public var wakingMinutes: Int
    public var trackedMinutes: Int
    /// Waking stretches over 15 min with nothing logged (the Tracked ring's subtitle).
    public var gaps: Int
    public var limitMinutes: Int
    public var limitGoal: Int

    public init(workMinutes: Int, workGoal: Int, wakingMinutes: Int, trackedMinutes: Int, gaps: Int, limitMinutes: Int, limitGoal: Int) {
        self.workMinutes = workMinutes
        self.workGoal = workGoal
        self.wakingMinutes = wakingMinutes
        self.trackedMinutes = trackedMinutes
        self.gaps = gaps
        self.limitMinutes = limitMinutes
        self.limitGoal = limitGoal
    }

    /// Progress past 1 is a second lap (drawn darker, as in Fitness).
    public var work: Double { workGoal == 0 ? (workMinutes > 0 ? 1 : 0) : Double(workMinutes) / Double(workGoal) }
    public var tracked: Double { wakingMinutes == 0 ? 0 : min(1, Double(trackedMinutes) / Double(wakingMinutes)) }
    public var limit: Double { limitGoal == 0 ? 0 : Double(limitMinutes) / Double(limitGoal) }

    public var workClosed: Bool { workGoal > 0 && workMinutes >= workGoal }
    /// Tracked closes when no waking minute is missing (a few stray minutes at the edges don't count).
    public var trackedClosed: Bool { wakingMinutes >= 60 && wakingMinutes - trackedMinutes <= 5 }
    public var limitClosed: Bool { limitGoal > 0 && limitMinutes >= limitGoal }

    /// The words beside each ring (never colour alone, D3).
    public var workLabel: String { workGoal == 0 ? "\(minutesLabel(workMinutes)) · nothing asked" : "\(minutesLabel(workMinutes)) of \(minutesLabel(workGoal))" }
    public var trackedLabel: String { "\(Int((tracked * 100).rounded()))%" }
    public var trackedSubtitle: String {
        gaps == 0 ? "No gap over \(TrackPrompts.goalMinutes) min" : "\(gaps) gap\(gaps == 1 ? "" : "s") over \(TrackPrompts.goalMinutes) min"
    }
    public var limitLabel: String { "\(limitMinutes) of \(limitGoal) min" }

    public static let defaultLimit = 60

    /// The limit: a daily at-most goal on unproductive time or scrolling, else this week's taper limit, else an hour.
    public static func limit(goals: [Goal], taper: ScreenTaper, tree: CategoryTree) -> Int {
        let g = goals.first { g in
            guard g.active, g.period == .day, g.direction == .atMost else { return false }
            switch g.measure {
            case .category(let c): return tree.isUnder(c, CategoryTree.unproductive)
            case .group(let grp): return grp == .unproductive
            default: return false
            }
        }
        return g?.target ?? taper.targetMinutes ?? defaultLimit
    }

    public static func make(_ day: Date, asked: [UUID: Int], entries: [Entry], items: [WorkItem], tree: CategoryTree, limit: Int,
                            now: Date, book: DayRuleBook = DayRuleBook(), calendar cal: Calendar) -> DayRings {
        let slices = TimeLog.past(entries, in: Days.dayInterval(day, cal), now: now, book: book, calendar: cal)
        let acct = Accountability.account(day, asked: asked, slices: slices, items: items, now: now, calendar: cal)
        let under = { (s: LogSlice, c: CategoryID) in s.entry.map { tree.isUnder($0.category, c) } ?? false }
        let asleep = slices.filter { under($0, CategoryTree.sleep) }.reduce(0) { $0 + $1.minutes }
        let total = slices.reduce(0) { $0 + $1.minutes }
        let untracked = slices.filter { $0.entry == nil }.reduce(0) { $0 + $1.minutes }
        let waking = max(0, total - asleep)
        let unproductive = slices.filter { under($0, CategoryTree.unproductive) }.reduce(0) { $0 + $1.minutes }
        let gaps = Goals.gaps(slices).count
        return DayRings(workMinutes: acct.did, workGoal: acct.asked, wakingMinutes: waking, trackedMinutes: max(0, waking - untracked),
                        gaps: gaps, limitMinutes: unproductive, limitGoal: limit)
    }

    /// Your usual day of this kind: the median of each ring over the last 4 days of the same kind (school / free).
    public static func usual(before day: Date, isSchoolDay: (Date) -> Bool, rings: (Date) -> DayRings, calendar cal: Calendar) -> DayRings? {
        let school = isSchoolDay(day)
        var days: [DayRings] = []
        var d = cal.startOfDay(for: day)
        for _ in 0..<28 where days.count < 4 {
            guard let prev = cal.date(byAdding: .day, value: -1, to: d) else { break }
            d = prev
            if isSchoolDay(d) == school { days.append(rings(d)) }
        }
        guard days.count >= 2 else { return nil }
        func median(_ xs: [Int]) -> Int { let s = xs.sorted(); return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2 }
        return DayRings(workMinutes: median(days.map(\.workMinutes)), workGoal: median(days.map(\.workGoal)),
                        wakingMinutes: median(days.map(\.wakingMinutes)), trackedMinutes: median(days.map(\.trackedMinutes)),
                        gaps: median(days.map(\.gaps)), limitMinutes: median(days.map(\.limitMinutes)), limitGoal: days[0].limitGoal)
    }

    /// The categories behind a ring, as a plain list sorted by minutes (tapping a ring opens its day).
    public static func breakdown(_ day: Date, entries: [Entry], tree: CategoryTree, now: Date, book: DayRuleBook = DayRuleBook(),
                                 calendar cal: Calendar) -> [(id: CategoryID, name: String, minutes: Int)] {
        let ring = RingModel.make(entries: entries, tree: tree, range: Days.dayInterval(day, cal), now: now, forecast: [:], book: book, calendar: cal)
        return ring.categories.filter { $0.minutes > 0 }.sorted { $0.minutes > $1.minutes }.map { ($0.id, $0.name, $0.minutes) }
    }
}

/// v1.3 C2: Review → Day: what changed today against your usual day, and the best and worst hour.
public enum DayCompare {
    /// Minutes per level-2 category (School › Math, Work › Studying), up to `now`.
    public static func minutes(_ day: Date, entries: [Entry], tree: CategoryTree, now: Date, book: DayRuleBook = DayRuleBook(),
                               calendar cal: Calendar) -> [CategoryID: Int] {
        var out: [CategoryID: Int] = [:]
        for s in TimeLog.past(entries, in: Days.dayInterval(day, cal), now: now, book: book, calendar: cal) where s.entry != nil {
            out[RingModel.level2(s.category, tree), default: 0] += s.minutes
        }
        return out
    }

    /// The two biggest differences from the median of `usual` days (≥ 15 min; sleep and school aren't news).
    public static func changes(today: [CategoryID: Int], usual: [[CategoryID: Int]], tree: CategoryTree) -> [(name: String, minutes: Int)] {
        guard !usual.isEmpty else { return [] }
        let ids = Set(today.keys).union(usual.flatMap(\.keys))
            .filter { !tree.isUnder($0, CategoryTree.sleep) && !tree.isUnder($0, CategoryTree.school) }
        let diffs = ids.map { id -> (String, Int) in
            let xs = usual.map { $0[id] ?? 0 }.sorted()
            let median = xs.count % 2 == 1 ? xs[xs.count / 2] : (xs[xs.count / 2 - 1] + xs[xs.count / 2]) / 2
            return (tree.node(id)?.name ?? id, (today[id] ?? 0) - median)
        }
        return diffs.filter { abs($0.1) >= 15 }.sorted { (abs($0.1), $1.0) > (abs($1.1), $0.0) }.prefix(2).map { ($0.0, $0.1) }
    }

    /// "Studying +40 min, Scrolling −25 min".
    public static func line(_ changes: [(name: String, minutes: Int)]) -> String? {
        changes.isEmpty ? nil : changes.map { "\($0.name) \($0.minutes >= 0 ? "+" : "−")\(abs($0.minutes)) min" }.joined(separator: ", ")
    }

    /// The hour with the most productive time, and the one with the most unproductive (else untracked) time.
    public static func hours(_ day: Date, entries: [Entry], tree: CategoryTree, now: Date, book: DayRuleBook = DayRuleBook(),
                             calendar cal: Calendar) -> (best: Int?, worst: Int?) {
        let slices = TimeLog.past(entries, in: Days.dayInterval(day, cal), now: now, book: book, calendar: cal)
        var good: [Int: Double] = [:], bad: [Int: Double] = [:], lost: [Int: Double] = [:]
        for s in slices {
            var t = s.start
            while t < s.end {
                let h = cal.component(.hour, from: t)
                let next = min(s.end, cal.date(bySetting: .minute, value: 0, of: t.addingTimeInterval(3600)) ?? s.end)
                let m = max(0, next.timeIntervalSince(t) / 60)
                if s.entry == nil { if (7...22).contains(h) { lost[h, default: 0] += m } }
                else if tree.group(s.category) == .productive && !tree.isUnder(s.category, CategoryTree.school) { good[h, default: 0] += m }
                else if tree.group(s.category) == .unproductive { bad[h, default: 0] += m }
                t = next > t ? next : s.end
            }
        }
        func top(_ d: [Int: Double]) -> Int? { d.filter { $0.value >= 20 }.max { ($0.value, -$0.key) < ($1.value, -$1.key) }?.key }
        return (top(good), top(bad) ?? top(lost))
    }
}
