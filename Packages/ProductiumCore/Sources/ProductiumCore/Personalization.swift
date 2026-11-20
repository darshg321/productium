import Foundation

public struct LearnedModel: Codable, Hashable, Sendable {
    public var estimateRatio: [String: RunningMean]
    public var adherence: Double
    public var adherenceSamples: Int
    public var hourSuccess: [Double]
    public var hourFail: [Double]
    public var focusMinutes: Double
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

    public func estimateFactor(for kind: TaskKind) -> Double {
        let m = estimateRatio[kind.rawValue] ?? RunningMean(mean: Self.priorRatio, weight: Self.priorWeight)
        return min(3.0, max(0.6, m.mean))
    }

    public mutating func recordCompletion(kind: TaskKind, estimated: Int, actual: Int) {
        guard estimated > 0, actual > 0 else { return }
        let ratio = min(4.0, max(0.25, Double(actual) / Double(estimated)))
        var m = estimateRatio[kind.rawValue] ?? RunningMean(mean: Self.priorRatio, weight: Self.priorWeight)
        m.weight = min(m.weight, 12)
        m.mean = (m.mean * m.weight + ratio) / (m.weight + 1)
        m.weight += 1
        estimateRatio[kind.rawValue] = m
    }

    public mutating func record(session outcome: SessionResult, calendar: Calendar) {
        let alpha = adherenceSamples < 10 ? 0.25 : 0.12
        adherence = (1 - alpha) * adherence + alpha * outcome.score
        adherenceSamples += 1

        let hour = calendar.component(.hour, from: outcome.plannedStart)
        hourSuccess[hour] += outcome.score
        hourFail[hour] += 1 - outcome.score
        let total = hourSuccess[hour] + hourFail[hour]
        if total > 30 { hourSuccess[hour] *= 30 / total; hourFail[hour] *= 30 / total }

        switch outcome.status {
        case .done where outcome.actualMinutes >= outcome.plannedMinutes:
            focusMinutes = min(55, focusMinutes + 0.5)
        case .partial:
            focusMinutes = max(20, focusMinutes - 1.5)
        case .skipped, .done:
            break
        }
    }

    public func hourReliability(_ hour: Int) -> Double {
        let h = max(0, min(23, hour))
        return hourSuccess[h] / (hourSuccess[h] + hourFail[h])
    }

    public var loadFactor: Double {
        let confidence = min(1, Double(adherenceSamples) / 14)
        let raw = 0.55 + 0.5 * adherence
        return 1 + (min(1.05, max(0.6, raw)) - 1) * confidence
    }

    public static func chronotype(fromFreeDaySleepMidpointsHours midpoints: [Double]) -> Chronotype? {
        guard midpoints.count >= 3 else { return nil }
        let sorted = midpoints.sorted()
        let median = sorted[sorted.count / 2]
        if median < 3.75 { return .early }
        if median > 5.25 { return .late }
        return .intermediate
    }
}

public enum EnergyModel {
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
        let n = learned.hourSuccess[hour] + learned.hourFail[hour] - 3
        let w = min(0.6, max(0, n / 20))
        return (1 - w) * circadian + w * learned.hourReliability(hour)
    }
}
