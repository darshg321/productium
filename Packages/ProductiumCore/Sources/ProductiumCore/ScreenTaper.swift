import Foundation

/// Gradual, adaptive reduction of distracting-app time.
///
/// * Baseline = median of the first week of real usage, measured, not guessed.
/// * Each week (Monday: "fresh start", Dai, Milkman & Riis 2014) the daily limit steps
///   down ~10%, faster if the student is comfortably under, held if they're mostly
///   over. An unreachable limit gets ignored and breeds "what-the-hell" relapse
///   (Polivy & Herman 1985; Cochran & Tesser 1996). Shaping works through
///   attainable steps (Bandura 1977, self-efficacy).
/// * Limits and friction do reduce use, and the reduction persists (Allcott, Gentzkow & Song 2022;
///   Grüning et al. 2023).
/// * It stops at the student's floor goal, not at zero.
public struct ScreenTaper: Codable, Hashable, Sendable {
    public var baselineMinutes: Int?
    public var targetMinutes: Int?
    public var lastStepWeekStart: Date?
    public var history: [Step]
    /// "Just 15 more minutes" unlocks allowed per day. Tapers too.
    public var unlocksPerDay: Int

    public struct Step: Codable, Hashable, Sendable {
        public var weekStart: Date
        public var target: Int
        public var note: String
    }

    public init() {
        baselineMinutes = nil
        targetMinutes = nil
        lastStepWeekStart = nil
        history = []
        unlocksPerDay = 4
    }

    public static func median(_ xs: [Int]) -> Int? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// Call daily. Returns a note when the target changed.
    @discardableResult
    public mutating func update(days: [ScreenDay], now: Date, goalMinutes: Int, calendar cal: Calendar) -> String? {
        let today = cal.startOfDay(for: now)
        let past = days.filter { $0.day < today }.sorted { $0.day < $1.day }
        guard let weekStart = cal.dateInterval(of: .weekOfYear, for: now)?.start else { return nil }

        if baselineMinutes == nil {
            guard past.count >= 5, let med = Self.median(past.suffix(7).map(\.distractingMinutes)) else { return nil }
            baselineMinutes = med
            targetMinutes = max(goalMinutes, med)
            lastStepWeekStart = weekStart
            let note = "Baseline set at \(minutesLabel(med))/day. Nothing changes yet. Next week's limit will be a little lower."
            history.append(Step(weekStart: weekStart, target: targetMinutes!, note: note))
            return note
        }
        guard var target = targetMinutes, lastStepWeekStart.map({ $0 < weekStart }) ?? true else { return nil }

        let week = past.filter { $0.day >= cal.date(byAdding: .day, value: -7, to: weekStart)! && $0.day < weekStart }
        guard week.count >= 4 else { lastStepWeekStart = weekStart; return nil }
        let over = week.filter { Double($0.distractingMinutes) > Double(target) * 1.15 }.count
        let under = week.filter { $0.distractingMinutes <= target }.count
        let avg = week.map(\.distractingMinutes).reduce(0, +) / week.count

        let note: String
        if over >= 5 && Double(avg) > Double(target) * 1.5 {
            target = min(baselineMinutes ?? target, Int(Double(target) * 1.1))
            note = "Last week was hard, so the limit is a bit looser: \(minutesLabel(target)). Steady beats strict."
        } else if over >= 4 {
            note = "Holding at \(minutesLabel(target)) for another week. You're close."
        } else {
            let rate = under >= 6 ? 0.15 : 0.10
            let step = min(30, max(5, Int(Double(target) * rate)))
            target = max(goalMinutes, target - step)
            unlocksPerDay = max(1, unlocksPerDay - (under >= 6 ? 1 : 0))
            note = target == goalMinutes
                ? "You've reached your goal of \(minutesLabel(goalMinutes))/day."
                : "New daily limit: \(minutesLabel(target)) (−\(step) min). Last week you stayed under on \(under) days."
        }
        targetMinutes = target
        lastStepWeekStart = weekStart
        history.append(Step(weekStart: weekStart, target: target, note: note))
        return note
    }

    /// Before a baseline exists, monitor only: limits feel arbitrary without one.
    public var dailyLimit: Int? { targetMinutes }
}
