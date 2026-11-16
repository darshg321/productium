import Foundation

/// When (rarely) is it worth giving up sleep for schoolwork?
///
/// The evidence is lopsided. In high schoolers, extra study time bought with sleep
/// led to *more* academic problems the next day (Gillen-O'Neel, Huynh & Fuligni 2013).
/// Sleep consolidates newly learned material (Diekelmann & Born 2010), and
/// chronic restriction builds cumulative deficits that people don't notice
/// (Van Dongen et al. 2003). So the policy is:
///
/// * Never for memory work (tests, quizzes): you'd be trading away the very
///   process that stores what you studied.
/// * Only for production work (essay, application, project) that is high stakes
///   (importance ≥ 4), due within 72 h, and that can't fit anywhere else after
///   free time has already been squeezed.
/// * At most 60 min per night, never under the sleep floor (default 7 h),
///   never two nights in a row, at most two nights in any 7-day plan.
/// * Not on a night before a test or quiz, and not after an already-short night.
public enum SleepPolicy {
    public static let maxBorrowPerNight = 60
    public static let maxNightsPerWeek = 2
    public static let maxHoursAheadOfDeadline: TimeInterval = 72 * 3600
    public static let shortNightThreshold = 90

    public struct NightContext: Sendable {
        public var dayIndex: Int
        public var workEnd: Date
        public var alreadyBorrowed: Int
        public var memoryDueNextDay: Bool
        public var borrowedNightIndices: Set<Int>
        public var lastNightDebtMinutes: Int

        public init(dayIndex: Int, workEnd: Date, alreadyBorrowed: Int, memoryDueNextDay: Bool,
                    borrowedNightIndices: Set<Int>, lastNightDebtMinutes: Int) {
            self.dayIndex = dayIndex
            self.workEnd = workEnd
            self.alreadyBorrowed = alreadyBorrowed
            self.memoryDueNextDay = memoryDueNextDay
            self.borrowedNightIndices = borrowedNightIndices
            self.lastNightDebtMinutes = lastNightDebtMinutes
        }
    }

    /// Minutes of sleep that may be borrowed on this night for this item (0 = no).
    public static func allowance(item: WorkItem, now: Date, night: NightContext, prefs: Preferences) -> Int {
        guard prefs.allowSleepTradeoffs else { return 0 }
        guard item.kind.isProduction, item.importance >= 4 else { return 0 }
        guard item.due.timeIntervalSince(now) <= maxHoursAheadOfDeadline else { return 0 }
        guard night.workEnd < item.due else { return 0 }
        guard !night.memoryDueNextDay else { return 0 }
        if night.dayIndex == 0 && night.lastNightDebtMinutes >= shortNightThreshold { return 0 }

        let others = night.borrowedNightIndices.subtracting([night.dayIndex])
        if others.contains(night.dayIndex - 1) || others.contains(night.dayIndex + 1) { return 0 }
        if night.alreadyBorrowed == 0 && others.count >= maxNightsPerWeek { return 0 }

        let headroom = max(0, prefs.sleepNeedMinutes - prefs.sleepFloorMinutes)
        return max(0, min(maxBorrowPerNight, headroom) - night.alreadyBorrowed)
    }

    public static func recoveryAdvice(minutes: Int) -> String {
        "Borrowed \(minutes) min of sleep. Repay it: lights out on time tomorrow, and if you're wiped after school a ≤20-min nap helps without grogginess."
    }
}
