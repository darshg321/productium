import Foundation

/// Everything the app learns about this student instead of asking them.
/// Each estimate starts from a population prior taken from the research, then
/// shrinks toward the student's own data as it comes in, so a new user gets
/// sensible defaults and a long-time user gets a plan fitted to them.
public struct LearnedModel: Codable, Hashable, Sendable {
    /// Planning-fallacy correction per task kind: actual / estimated minutes.
    /// Prior 1.3: people underestimate durations (Buehler, Griffin & Ross 1994).
    public var estimateRatio: [String: RunningMean]
    /// Exponentially weighted share of planned blocks the student completes.
    public var adherence: Double
    public var adherenceSamples: Int
    /// Beta(success, fail) per hour of day: when this student actually does the work.
    public var hourSuccess: [Double]
    public var hourFail: [Double]
    /// Focus block length learned from completed vs. abandoned blocks.
    public var focusMinutes: Double
    /// Learned from HealthKit sleep midpoint on free days (MCTQ approach).
    public var inferredChronotype: Chronotype?

    public static let priorRatio = 1.3
    public static let priorWeight = 3.0

    public init() {
        estimateRatio = [:]
        adherence = 0.75
        adherenceSamples = 0
        hourSuccess = Array(repeating: 2, count: 24)
        hourFail = Array(repeating: 1, count: 24)
        focusMinutes = 40
        inferredChronotype = nil
    }

    public struct RunningMean: Codable, Hashable, Sendable {
        public var mean: Double
        public var weight: Double
        public init(mean: Double, weight: Double) { self.mean = mean; self.weight = weight }
    }

    /// Multiplier the planner applies to the student's estimate for this kind.
    public func estimateFactor(for kind: TaskKind) -> Double {
        let m = estimateRatio[kind.rawValue] ?? RunningMean(mean: Self.priorRatio, weight: Self.priorWeight)
        return min(3.0, max(0.6, m.mean))
    }

    /// When an item is finished: how long did it really take compared with the estimate?
    public mutating func recordCompletion(kind: TaskKind, estimated: Int, actual: Int) {
        guard estimated > 0, actual > 0 else { return }
        let ratio = min(4.0, max(0.25, Double(actual) / Double(estimated)))
        var m = estimateRatio[kind.rawValue] ?? RunningMean(mean: Self.priorRatio, weight: Self.priorWeight)
        // Recent tasks count more than old ones, but no single task swings it.
        m.weight = min(m.weight, 12)
        m.mean = (m.mean * m.weight + ratio) / (m.weight + 1)
        m.weight += 1
        estimateRatio[kind.rawValue] = m
    }

    /// Called after every planned study block resolves (done / partial / skipped).
    public mutating func record(outcome: BlockOutcome, calendar: Calendar) {
        let alpha = adherenceSamples < 10 ? 0.25 : 0.12
        adherence = (1 - alpha) * adherence + alpha * outcome.score
        adherenceSamples += 1

        let hour = calendar.component(.hour, from: outcome.plannedStart)
        hourSuccess[hour] += outcome.score
        hourFail[hour] += 1 - outcome.score
        // Forget slowly so a changed routine (new semester) shows up.
        let total = hourSuccess[hour] + hourFail[hour]
        if total > 30 { hourSuccess[hour] *= 30 / total; hourFail[hour] *= 30 / total }

        // Block length: abandoned blocks shrink it, completed ones grow it slowly.
        // Systematic short breaks beat self-regulated marathons (Biwer et al. 2023).
        switch outcome.status {
        case .done where outcome.actualMinutes >= outcome.plannedMinutes:
            focusMinutes = min(55, focusMinutes + 0.5)
        case .partial:
            focusMinutes = max(20, focusMinutes - 1.5)
        case .skipped, .done:
            break
        }
    }

    /// Mean success probability at this hour (0…1).
    public func hourReliability(_ hour: Int) -> Double {
        let h = max(0, min(23, hour))
        return hourSuccess[h] / (hourSuccess[h] + hourFail[h])
    }

    /// Plan less when the student completes less. Overplanning is the main way
    /// planners fail: missed plans erode self-efficacy, which leads to dropping
    /// the plan entirely. The planned load follows real capacity, floored at 60%.
    public var loadFactor: Double {
        let confidence = min(1, Double(adherenceSamples) / 14)
        let raw = 0.55 + 0.5 * adherence  // adherence 0.9 gives ≈1.0, 0.5 gives 0.8
        return 1 + (min(1.05, max(0.6, raw)) - 1) * confidence
    }

    /// Chronotype from the midpoint of sleep on free days (Roenneberg et al. 2003, MCTQ).
    public static func chronotype(fromFreeDaySleepMidpointsHours midpoints: [Double]) -> Chronotype? {
        guard midpoints.count >= 3 else { return nil }
        let sorted = midpoints.sorted()
        let median = sorted[sorted.count / 2]
        // Adolescent MSF is typically ~4.5–5.5 h (Roenneberg et al. 2004).
        if median < 3.75 { return .early }
        if median > 5.25 { return .late }
        return .intermediate
    }
}

/// Alertness over the day: a circadian curve, shifted by chronotype,
/// then mixed with the student's observed per-hour reliability.
public enum EnergyModel {
    /// Rough relative alertness 0…1 for an intermediate chronotype: rises after
    /// waking, post-lunch dip ~14:00, second peak late afternoon/early evening,
    /// falls toward night (synchrony effect, May, Hasher & Stoltzfus 1993; Schmidt et al. 2007).
    static func baseCurve(_ hour: Double) -> Double {
        let morningPeak = exp(-pow((hour - 10.5) / 2.2, 2))
        let eveningPeak = 0.9 * exp(-pow((hour - 17.5) / 2.5, 2))
        let dip = 0.25 * exp(-pow((hour - 14.0) / 1.2, 2))
        let night = hour >= 22 || hour < 6 ? 0.35 : 0
        return max(0.05, min(1, 0.25 + 0.75 * max(morningPeak, eveningPeak) - dip - night))
    }

    public static func alertness(hour: Int, chronotype: Chronotype, learned: LearnedModel?) -> Double {
        let shifted = Double(hour) - chronotype.shiftHours
        let circadian = baseCurve(shifted)
        guard let learned else { return circadian }
        let n = learned.hourSuccess[hour] + learned.hourFail[hour] - 3 // minus prior
        let w = min(0.6, max(0, n / 20))   // trust observed behaviour more over time
        return (1 - w) * circadian + w * learned.hourReliability(hour)
    }
}
