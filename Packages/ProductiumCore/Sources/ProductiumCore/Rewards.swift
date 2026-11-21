import Foundation

// v1.1 Part F: celebrations for what the student is trying to do, never for using Productium. Deterministic and
// budgeted: at most one big moment a day and a few medium ones a week (celebrations that fire on every tap stop
// working); a small one sometimes becomes medium by surprise, seeded per day so tests are reproducible. Copy says
// what happened, from data. No points, no streaks that can break, no punishment.

public enum RewardIntensity: Int, Codable, Comparable, Sendable {
    case small, medium, big
    public static func < (a: RewardIntensity, b: RewardIntensity) -> Bool { a.rawValue < b.rawValue }
}

public enum RewardKind: String, Codable, Sendable {
    case focusDone, itemDone, planFinished, bedtimeKept, scrollClosedEarly, metricImproved, milestone, personalBest
    /// v1.2 I4: a goal closed; a weekly one; an upper limit kept through the day.
    case goalClosed, weeklyGoal, limitKept
    /// v1.2 G1b: the day beat your usual similar day.
    case beatUsual
    /// v1.2 I0: a whole day with no untracked stretch over 30 minutes.
    case trackedDay
}

public enum RewardEvent: Sendable {
    /// A focus session ended with Done or Got Some Done. `percentBefore/After`: the task's progress.
    case focusEnded(status: OutcomeStatus, minutes: Int, title: String?, percentBefore: Int?, percentAfter: Int?,
                    freeAfterMinutes: Int?, totalFocusMinutesBefore: Int)
    /// A task or step was finished. `stepsLeft` for a step; `daysEarly` if finished a day or more before it was due.
    case itemDone(title: String, isStep: Bool, stepsLeft: Int, daysEarly: Int)
    /// Everything planned for today is done.
    case planFinished(freeMinutesLeft: Int?)
    /// Last night's bedtime was kept (shown the next morning).
    case bedtimeKept(sleptMinutes: Int?)
    /// A scrolling app was closed before that app's usual session length.
    case scrollClosedEarly(app: String, minutes: Int, usualMinutes: Int)
    /// A Life Metric turned better for the period (Part G).
    case metricImproved(MetricID, MetricPeriod, String)
    /// A personal best for a finished week ("lowest scrolling week").
    case personalBest(String)
    /// v1.2 I4: a goal reached ("Studying 2h") — `daysThisMonth` counts, never a streak.
    case goalClosed(title: String, weekly: Bool, daysThisMonth: Int?)
    /// v1.2 I4: an at-most goal kept for the day (checked at bedtime).
    case limitKept(title: String, minutes: Int, limit: Int)
    /// v1.2 G1b: at bedtime, the day's score beat your usual similar day's.
    case beatUsual(score: Int, usual: Int, label: String, differences: [String])
    /// v1.2 I0: no untracked stretch over 30 minutes all day. `daysThisMonth` counts, never a streak.
    case trackedDay(daysThisMonth: Int)
    /// Never rewarded, listed so the rule is tested: using Productium is not the goal.
    case appOpened, tabChanged, timeInApp(minutes: Int)
}

public struct RewardMoment: Codable, Hashable, Sendable {
    public var kind: RewardKind
    public var intensity: RewardIntensity
    public var title: String
    public var detail: String?
    public var at: Date
    public var surprise: Bool
}

public enum CelebrationLevel: String, Codable, CaseIterable, Sendable {
    case full, subtle, off

    public var title: String {
        switch self {
        case .full: return "Full"
        case .subtle: return "Subtle"
        case .off: return "Off"
        }
    }
}

public struct RewardSettings: Codable, Hashable, Sendable {
    public var level: CelebrationLevel
    /// 0...1: how often a small moment may become medium. The insight pass may lower it (F6).
    public var surpriseRate: Double
    /// A short sound with a celebration. Off unless chosen.
    public var sound: Bool

    public init(level: CelebrationLevel = .full, surpriseRate: Double = Rewards.defaultSurpriseRate, sound: Bool = false) {
        self.level = level
        self.surpriseRate = surpriseRate
        self.sound = sound
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        level = (try? c.decodeIfPresent(CelebrationLevel.self, forKey: .level)) ?? .full
        surpriseRate = (try? c.decodeIfPresent(Double.self, forKey: .surpriseRate)) ?? Rewards.defaultSurpriseRate
        sound = (try? c.decodeIfPresent(Bool.self, forKey: .sound)) ?? false
    }
}

public struct RewardLog: Codable, Hashable, Sendable {
    public var moments: [RewardMoment]
    public init(moments: [RewardMoment] = []) { self.moments = moments }

    mutating func add(_ m: RewardMoment, now: Date) {
        moments.append(m)
        let cutoff = now.addingTimeInterval(-120 * 86400)
        moments.removeAll { $0.at < cutoff }
    }
}

public enum Rewards {
    public static let bigPerDay = 1
    public static let mediumPerWeek = 3
    public static let scrollNotesPerDay = 3
    public static let defaultSurpriseRate = 0.15
    /// Focus-hour milestones: further apart as they go, so they stay rare.
    public static let focusHourLadder = [1, 5, 10, 25, 50, 100, 250, 500, 1000]

    /// The moment for an event, recorded in the log, or nil (nothing to celebrate, over budget, or turned off).
    public static func respond(to event: RewardEvent, log: inout RewardLog, settings: RewardSettings, now: Date,
                               calendar cal: Calendar) -> RewardMoment? {
        guard settings.level != .off, var m = draft(event, now: now) else { return nil }
        let today = log.moments.filter { cal.isDate($0.at, inSameDayAs: now) }
        if m.kind == .scrollClosedEarly, today.filter({ $0.kind == .scrollClosedEarly }).count >= scrollNotesPerDay { return nil }
        // At most one "day's plan finished" a day, however often the plan is edited and re-finished.
        if m.kind == .planFinished, today.contains(where: { $0.kind == .planFinished }) { return nil }
        // One of each a day: closing the same goal twice, or beating your usual twice, isn't news.
        if [.goalClosed, .weeklyGoal, .limitKept, .beatUsual, .trackedDay].contains(m.kind),
           today.contains(where: { $0.kind == m.kind && $0.title == m.title }) { return nil }

        if m.intensity == .small, m.kind != .scrollClosedEarly,
           unit(seed: "\(AlarmPlanner.dayKey(now, cal))|\(today.count)|\(m.kind.rawValue)") < settings.surpriseRate {
            m.intensity = .medium
            m.surprise = true
        }
        let bigToday = today.filter { $0.intensity == .big }.count
        let weekAgo = now.addingTimeInterval(-7 * 86400)
        let mediumWeek = log.moments.filter { $0.at > weekAgo && $0.intensity == .medium }.count
        let rare = m.kind == .milestone || m.kind == .personalBest
        if m.intensity == .big && bigToday >= bigPerDay { m.intensity = .medium }
        // Milestones and records are rare by construction, so they keep at least a medium moment.
        if m.intensity == .medium && mediumWeek >= mediumPerWeek && !rare {
            m.intensity = .small
            m.surprise = false
        }
        if settings.level == .subtle { m.intensity = min(m.intensity, .small) }
        log.add(m, now: now)
        return m
    }

    static func draft(_ e: RewardEvent, now: Date) -> RewardMoment? {
        func moment(_ k: RewardKind, _ i: RewardIntensity, _ t: String, _ d: String? = nil) -> RewardMoment {
            RewardMoment(kind: k, intensity: i, title: t, detail: d, at: now, surprise: false)
        }
        switch e {
        case .appOpened, .tabChanged, .timeInApp:
            return nil
        case let .focusEnded(status, minutes, title, before, after, freeAfter, totalBefore):
            guard status != .skipped, minutes >= 5 else { return nil }
            let totalAfter = totalBefore + minutes
            if let rung = focusHourLadder.first(where: { totalBefore < $0 * 60 && totalAfter >= $0 * 60 }) {
                return moment(.milestone, .big, "\(rung) focus hour\(rung == 1 ? "" : "s")",
                              "Every one of them was time you chose to sit down and work.")
            }
            var lines: [String] = []
            if let title, let b = before, let a = after, a > b { lines.append("\(title) \(b)% → \(a)%") }
            else if let title { lines.append("\(minutesLabel(minutes)) on \(title)") }
            else { lines.append("\(minutesLabel(minutes)) of focus") }
            let next = freeAfter.flatMap { $0 >= 30 ? "After this: \(minutesLabel($0)) free" : nil }
            return moment(.focusDone, .small, lines[0], next)
        case let .itemDone(title, isStep, stepsLeft, daysEarly):
            let detail: String?
            if isStep { detail = stepsLeft > 0 ? "\(stepsLeft) step\(stepsLeft == 1 ? "" : "s") left" : "That was the last step" }
            else if daysEarly >= 1 { detail = "\(daysEarly) day\(daysEarly == 1 ? "" : "s") early" }
            else { detail = nil }
            return moment(.itemDone, .small, "\(title) done", detail)
        case .planFinished(let free):
            return moment(.planFinished, .big, "All of today's plan done",
                          free.flatMap { $0 >= 15 ? "\(minutesLabel($0)) free from now" : nil })
        case .bedtimeKept(let slept):
            return moment(.bedtimeKept, .small, "In bed on time", slept.map { "\(minutesLabel($0)) of sleep" })
        case let .scrollClosedEarly(app, minutes, usual):
            guard usual - minutes >= 2 else { return nil }
            return moment(.scrollClosedEarly, .small, "Back in \(minutes) min",
                          "\(usual - minutes) min shorter than your usual \(app)")
        case let .metricImproved(_, period, text):
            return moment(.metricImproved, .medium, text, period == .week ? "Better than last week" : nil)
        case .personalBest(let text):
            return moment(.personalBest, .big, text, "Your best week so far")
        case let .goalClosed(title, weekly, days):
            return moment(weekly ? .weeklyGoal : .goalClosed, weekly ? .big : .medium, "\(title) goal reached",
                          days.flatMap { $0 > 1 ? "\($0) days this month" : nil })
        case let .limitKept(title, minutes, limit):
            return moment(.limitKept, .medium, "\(title) kept under \(minutesLabel(limit))", "\(minutesLabel(minutes)) today")
        case let .beatUsual(score, usual, label, diffs):
            guard score > usual else { return nil }
            return moment(.beatUsual, .medium, "You beat your \(label.lowercased()): \(score) vs \(usual)",
                          diffs.isEmpty ? nil : diffs.prefix(2).joined(separator: ", "))
        case .trackedDay(let days):
            return moment(.trackedDay, .medium, "Every stretch of today accounted for",
                          days > 1 ? "\(days) days like this this month" : nil)
        }
    }

    /// Deterministic 0..<1 from a string (FNV-1a), so the same day and event give the same surprise.
    static func unit(seed: String) -> Double {
        var h: UInt64 = 0xcbf29ce484222325
        for b in seed.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        h ^= h >> 33; h &*= 0xff51afd7ed558ccd; h ^= h >> 33
        return Double(h >> 11) / Double(UInt64(1) << 53)
    }

}

/// v1.1 F6: do celebrations change anything for this student? After four weeks of moments, compare the focus on the
/// day after a medium / big moment with the day after none. No difference: turn the celebrations down one step.
public enum RewardImpact {
    public static let minWeeks = 4
    public static let minDaysEach = 5
    /// Minutes of focus the day after must beat the other days by for celebrations to count as working.
    public static let minDifference = 10.0

    public struct Result: Hashable, Sendable {
        public var withMoments: Double
        public var without: Double
        public var daysWith: Int
        public var daysWithout: Int
        public var works: Bool { withMoments - without >= RewardImpact.minDifference }
    }

    public static func evaluate(log: RewardLog, entries: [Entry], tree: CategoryTree = CategoryTree(), now: Date,
                                calendar cal: Calendar) -> Result? {
        guard let first = log.moments.map(\.at).min(),
              now.timeIntervalSince(first) >= Double(minWeeks) * 7 * 86400 else { return nil }
        let celebrated = Set(log.moments.filter { $0.intensity >= .medium }.map { cal.startOfDay(for: $0.at) })
        let today = cal.startOfDay(for: now)
        var with: [Double] = [], without: [Double] = []
        var day = cal.startOfDay(for: first)
        while let next = cal.date(byAdding: .day, value: 1, to: day), next < today {
            let after = Double(WorkDone.minutes(on: next, entries: entries, tree: tree, now: now, progress: [], calendar: cal))
            if celebrated.contains(day) { with.append(after) } else { without.append(after) }
            day = next
        }
        guard with.count >= minDaysEach, without.count >= minDaysEach else { return nil }
        return Result(withMoments: with.reduce(0, +) / Double(with.count), without: without.reduce(0, +) / Double(without.count),
                      daysWith: with.count, daysWithout: without.count)
    }

    /// The change to make, if any: one step down (full → subtle), never to off, and only when there's no effect.
    public static func turnDown(_ r: Result?, settings: RewardSettings) -> CelebrationLevel? {
        guard let r, !r.works, settings.level == .full else { return nil }
        return .subtle
    }
}
