import Foundation

public struct DayTotals: Codable, Hashable, Sendable {
    public var day: Date
    public var minutes: [TimeCategory: Int]
    public var plannedStudy: Int
    public var doneStudy: Int
    public var mood: Double?
    public var sleep: Int?
    public var screen: Int?
    public var screenTarget: Int?
    public var steps: Int?

    public init(day: Date, minutes: [TimeCategory: Int], plannedStudy: Int, doneStudy: Int, mood: Double?,
                sleep: Int?, screen: Int?, screenTarget: Int?, steps: Int?) {
        self.day = day
        self.minutes = minutes
        self.plannedStudy = plannedStudy
        self.doneStudy = doneStudy
        self.mood = mood
        self.sleep = sleep
        self.screen = screen
        self.screenTarget = screenTarget
        self.steps = steps
    }
}

public struct PeriodSummary: Codable, Hashable, Sendable {
    public var days: Int
    public var averageMinutes: [TimeCategory: Int]
    public var followThrough: Double?
    public var averageSleep: Int?
    public var averageMood: Double?
    public var averageScreen: Int?
    public var bestHours: [Int]
    public var estimateFactors: [String: Double]
    public var patterns: [String]
}

public enum Insights {
    public static func dayTotals(_ inputs: DayInputs, plannedStudy: Int, moods: [MoodEntry], screenTarget: Int?,
                                 calendar cal: Calendar, now: Date) -> DayTotals {
        let segs = TimelineBuilder.segments(inputs, calendar: cal, now: now)
        let totals = TimelineBuilder.totals(segs, screen: inputs.screen)
        let dayMoods = moods.filter { cal.isDate($0.at, inSameDayAs: inputs.day) }.map { Double($0.mood) }
        let done = inputs.outcomes.filter { cal.isDate($0.plannedStart, inSameDayAs: inputs.day) }
            .reduce(0) { $0 + ($1.status == .skipped ? 0 : $1.actualMinutes) }
        return DayTotals(day: cal.startOfDay(for: inputs.day), minutes: totals, plannedStudy: plannedStudy, doneStudy: done,
                         mood: dayMoods.isEmpty ? nil : dayMoods.reduce(0, +) / Double(dayMoods.count),
                         sleep: inputs.health?.sleepMinutes, screen: inputs.screen?.distractingMinutes,
                         screenTarget: screenTarget, steps: inputs.health?.steps)
    }

    public static func summarize(_ days: [DayTotals], learned: LearnedModel) -> PeriodSummary {
        let n = max(1, days.count)
        var avg: [TimeCategory: Int] = [:]
        for c in TimeCategory.allCases { avg[c] = days.reduce(0) { $0 + ($1.minutes[c] ?? 0) } / n }
        let planned = days.reduce(0) { $0 + $1.plannedStudy }
        let done = days.reduce(0) { $0 + $1.doneStudy }
        func mean(_ xs: [Int]) -> Int? { xs.isEmpty ? nil : xs.reduce(0, +) / xs.count }
        let moods = days.compactMap(\.mood)
        let hours = (0..<24).filter { learned.hourSuccess[$0] + learned.hourFail[$0] > 6 }
            .sorted { learned.hourReliability($0) > learned.hourReliability($1) }
        var factors: [String: Double] = [:]
        for (k, v) in learned.estimateRatio where v.weight > LearnedModel.priorWeight { factors[k] = (v.mean * 100).rounded() / 100 }

        var patterns: [String] = []
        let sleepMood = days.compactMap { d -> (Double, Double)? in
            guard let s = d.sleep, let m = d.mood else { return nil }; return (Double(s), m)
        }
        if let r = Wellbeing.correlation(sleepMood), r > 0.3 { patterns.append("Your mood tends to be better after longer sleep.") }
        let screenMood = days.compactMap { d -> (Double, Double)? in
            guard let s = d.screen, let m = d.mood else { return nil }; return (Double(s), m)
        }
        if let r = Wellbeing.correlation(screenMood), r < -0.3 { patterns.append("Days with more scrolling tend to be lower-mood days.") }
        let stepsMood = days.compactMap { d -> (Double, Double)? in
            guard let s = d.steps, let m = d.mood else { return nil }; return (Double(s), m)
        }
        if let r = Wellbeing.correlation(stepsMood), r > 0.3 { patterns.append("You feel better on days you move more.") }
        for (k, f) in factors where f > 1.4 {
            patterns.append("\(k.capitalized)s take you about \(Int(((f - 1) * 100).rounded()))% longer than estimated. Plans already account for it.")
        }

        return PeriodSummary(days: days.count, averageMinutes: avg,
                             followThrough: planned > 0 ? Double(done) / Double(planned) : nil,
                             averageSleep: mean(days.compactMap(\.sleep)),
                             averageMood: moods.isEmpty ? nil : moods.reduce(0, +) / Double(moods.count),
                             averageScreen: mean(days.compactMap(\.screen)),
                             bestHours: Array(hours.prefix(3)).sorted(), estimateFactors: factors,
                             patterns: Array(patterns.prefix(3)))
    }
}
