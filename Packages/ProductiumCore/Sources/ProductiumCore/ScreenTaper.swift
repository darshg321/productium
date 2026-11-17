import Foundation

public struct ScreenTaper: Codable, Hashable, Sendable {
    public var baselineMinutes: Int?
    public var targetMinutes: Int?
    public var lastStepWeekStart: Date?
    public var history: [Step]
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

    public var goalMinutes: Int {
        guard let b = baselineMinutes else { return 45 }
        return max(30, Int((Double(b) / 2 / 5).rounded()) * 5)
    }

    @discardableResult
    public mutating func update(days: [ScreenDay], now: Date, calendar cal: Calendar) -> String? {
        let goalMinutes = self.goalMinutes
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

    public var dailyLimit: Int? { targetMinutes }
}
