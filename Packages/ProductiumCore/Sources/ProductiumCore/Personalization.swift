import Foundation

public struct LearnedModel: Codable, Hashable, Sendable {
    public var estimateRatio: [String: RunningMean]
    public var adherence: Double
    public var adherenceSamples: Int
    public var hourSuccess: [Double]
    public var hourFail: [Double]
    public var focusMinutes: Double
    public var inferredChronotype: Chronotype?
    /// The last finished day `AdherenceLearner` has read ("yyyy-MM-dd"), so each day is learned once.
    public var learnedThrough: String?

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
        let onTime = outcome.onTimeScore ?? outcome.score
        hourSuccess[hour] += onTime
        hourFail[hour] += 1 - onTime
        capHour(hour)

        switch outcome.status {
        case .done where outcome.actualMinutes >= outcome.plannedMinutes:
            focusMinutes = min(55, focusMinutes + 0.5)
        case .partial:
            focusMinutes = max(20, focusMinutes - 1.5)
        case .skipped, .done:
            break
        }
    }

    /// Work you did at an hour nothing was planned for: evidence the hour works for you (success only, half weight
    /// per 30 minutes, so planned sessions still count most).
    public mutating func recordWork(hour: Int, minutes: Int) {
        guard (0..<24).contains(hour), minutes >= 10 else { return }
        hourSuccess[hour] += 0.5 * min(1, Double(minutes) / 30)
        capHour(hour)
    }

    private mutating func capHour(_ hour: Int) {
        let total = hourSuccess[hour] + hourFail[hour]
        if total > 30 { hourSuccess[hour] *= 30 / total; hourFail[hour] *= 30 / total }
    }

    /// Hours with enough evidence that usually work (≥60%), most reliable first: Review and the weekly note.
    public func goodHours(limit: Int = 3) -> [Int] {
        Array((0..<24).filter { hourSuccess[$0] + hourFail[$0] > 6 && hourReliability($0) >= 0.6 }
            .sorted { hourReliability($0) > hourReliability($1) }.prefix(limit))
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

/// Follow-through and good hours from the log (v1.2: there is no "how did it go?" button; the log is the answer).
/// Each finished day is read once: its planned work sessions (`planHistory`, as they stood when the day ended) against
/// the time you logged on each task (any time that day), plus the hours the work actually happened in.
public enum AdherenceLearner {
    public struct Day: Sendable {
        public var sessions: [SessionResult]
        /// hour → minutes of work outside every planned session's window.
        public var offPlan: [Int: Int]
    }

    /// A session's hour: work from 30 min before it to 30 min after it counts as "at that hour". Work later than that
    /// (19:00 planned, done at 21:10) still makes the session done, but teaches 21:00, not 19:00.
    static let early: TimeInterval = 30 * 60
    static let late: TimeInterval = 30 * 60

    /// Work time actually done (not planned, not typed in ahead without a yes), clipped to `day`.
    static func work(_ entries: [Entry], day: DateInterval, tree: CategoryTree, now: Date) -> [(task: UUID?, start: Date, end: Date)] {
        entries.compactMap { e in
            guard e.source != .plan, e.repeats == nil,
                  e.taskId != nil || tree.isUnder(e.category, CategoryTree.work),
                  !(e.source == .you && e.createdAt < e.start.addingTimeInterval(-60) && !e.marks.values.contains(.confirmed))
            else { return nil }
            let s = max(e.start, day.start), t = min(e.end ?? now, day.end, now)
            return t > s ? (e.taskId, s, t) : nil
        }
    }

    public static func judge(day: Date, blocks: [PlannedBlock], entries: [Entry], items: [WorkItem], tree: CategoryTree,
                             now: Date, calendar cal: Calendar) -> Day {
        let start = cal.startOfDay(for: day)
        let range = DateInterval(start: start, end: cal.date(byAdding: .day, value: 1, to: start)!)
        let done = work(entries, day: range, tree: tree, now: now)
        let study = blocks.filter { $0.isStudy && $0.minutes > 0 && range.contains($0.start) }.sorted { $0.start < $1.start }
        func overlap(_ a: Date, _ b: Date, _ c: Date, _ d: Date) -> Int { max(0, Int(min(b, d).timeIntervalSince(max(a, c)) / 60)) }
        // The day's minutes on each task, handed out to its sessions in order ("asked vs did, in any order").
        var left: [UUID: Int] = [:]
        for w in done { if let t = w.task { left[t, default: 0] += Int(w.end.timeIntervalSince(w.start) / 60) } }
        let kinds = Dictionary(items.map { ($0.id, $0.kind) }, uniquingKeysWith: { a, _ in a })
        var sessions: [SessionResult] = []
        for b in study {
            let task = b.itemId
            let actual = task.map { t in min(b.minutes, left[t] ?? 0) } ?? 0
            if let t = task { left[t] = (left[t] ?? 0) - actual }
            let wStart = b.start.addingTimeInterval(-early), wEnd = b.end.addingTimeInterval(late)
            let inWindow = done.filter { $0.task == task && task != nil }.reduce(0) { $0 + overlap($1.start, $1.end, wStart, wEnd) }
            let status: OutcomeStatus = Double(actual) >= 0.8 * Double(b.minutes) ? .done
                : actual >= max(10, b.minutes / 4) ? .partial : .skipped
            var r = SessionResult(itemId: task, kind: task.flatMap { kinds[$0] }, plannedStart: b.start, plannedMinutes: b.minutes,
                                  actualMinutes: actual, status: status)
            r.onTimeScore = min(1, Double(inWindow) / (0.8 * Double(b.minutes)))
            sessions.append(r)
        }
        // Work outside every session window: which hours you choose to work in.
        var offPlan: [Int: Int] = [:]
        let windows = study.map { ($0.start.addingTimeInterval(-early), $0.end.addingTimeInterval(late)) }
        for w in done {
            var t = w.start
            while t < w.end {
                let hourEnd = min(w.end, cal.dateInterval(of: .hour, for: t)?.end ?? w.end)
                let covered = windows.reduce(0) { $0 + overlap(t, hourEnd, $1.0, $1.1) }
                let mins = Int(hourEnd.timeIntervalSince(t) / 60) - covered
                if mins > 0 { offPlan[cal.component(.hour, from: t), default: 0] += mins }
                t = hourEnd
            }
        }
        return Day(sessions: sessions, offPlan: offPlan)
    }

    /// Reads every finished day since the last run (at most `maxDays` back) into `learned`. Returns the sessions read.
    @discardableResult
    public static func learn(_ learned: inout LearnedModel, history: [String: [PlannedBlock]], entries: [Entry],
                             items: [WorkItem], tree: CategoryTree, now: Date, calendar cal: Calendar, maxDays: Int = 14) -> [SessionResult] {
        let today = cal.startOfDay(for: now)
        var out: [SessionResult] = []
        for back in stride(from: maxDays, through: 1, by: -1) {
            guard let day = cal.date(byAdding: .day, value: -back, to: today) else { continue }
            let key = CapacityLearner.dayKey(day, cal)
            if let through = learned.learnedThrough, key <= through { continue }
            let d = judge(day: day, blocks: history[key] ?? [], entries: entries, items: items, tree: tree, now: now, calendar: cal)
            for s in d.sessions { learned.record(session: s, calendar: cal) }
            for (h, m) in d.offPlan { learned.recordWork(hour: h, minutes: m) }
            learned.learnedThrough = key
            out += d.sessions
        }
        return out
    }
}
