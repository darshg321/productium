import Foundation

public struct DayRecord: Hashable, Sendable {
    public var day: Date
    public var isSchoolDay: Bool
    public var planned: Int
    public var done: Int
    public var eveningFree: Int?

    public init(day: Date, isSchoolDay: Bool, planned: Int, done: Int, eveningFree: Int? = nil) {
        self.day = day
        self.isSchoolDay = isSchoolDay
        self.planned = planned
        self.done = done
        self.eveningFree = eveningFree
    }

    public var followed: Bool { planned > 0 && Double(done) >= 0.8 * Double(planned) }
}

public enum CapacityLearner {
    public static let window = 21
    public static let priorWeight = 5.0

    static func percentile(_ xs: [Double], _ p: Double) -> Double {
        let s = xs.sorted()
        guard !s.isEmpty else { return 0 }
        let r = p * Double(s.count - 1)
        let lo = Int(r.rounded(.down)), hi = Int(r.rounded(.up))
        return s[lo] + (s[hi] - s[lo]) * (r - Double(lo))
    }

    static func shrink(prior: Double, observed: Double, n: Int, bounds: ClosedRange<Double>) -> Double {
        let v = (prior * priorWeight + observed * Double(n)) / (priorWeight + Double(n))
        return max(bounds.lowerBound, min(bounds.upperBound, (v * 10).rounded() / 10))
    }

    static func set(_ b: inout Beliefs, _ id: String, observed: Double, n: Int, bounds: ClosedRange<Double>,
                    evidence: String, now: Date) {
        guard n > 0, var x = b[id] else { return }
        x.value = shrink(prior: x.prior, observed: observed, n: n, bounds: bounds)
        x.samples = n
        x.source = "learner"
        x.updatedAt = now
        x.evidence = [evidence] + x.evidence.filter { $0.hasPrefix("You said") }
        b[id] = x
    }

    public static func learn(_ beliefs: Beliefs, days: [DayRecord], outcomes: [BlockOutcome] = [], markers: [TimelineEvent] = [],
                             now: Date, calendar cal: Calendar) -> Beliefs {
        var b = beliefs
        let since = cal.date(byAdding: .day, value: -window, to: cal.startOfDay(for: now)) ?? now
        let recent = days.filter { $0.day >= since && $0.day < cal.startOfDay(for: now) && ($0.planned > 0 || $0.done > 0) }

        for (school, id) in [(true, "study.schoolDayCapacity"), (false, "study.freeDayCapacity")] {
            let done = recent.filter { $0.isSchoolDay == school }.map { Double($0.done) }
            guard !done.isEmpty else { continue }
            let p75 = percentile(done, 0.75)
            set(&b, id, observed: p75, n: done.count, bounds: 30...480,
                evidence: "On \(done.count) \(school ? "school" : "free") days you did up to \(Int(p75)) min (75th percentile)", now: now)
        }
        for (school, id) in [(true, "study.schoolDayFreeTime"), (false, "study.freeDayFreeTime")] {
            let free = recent.filter { $0.isSchoolDay == school && $0.followed }.compactMap(\.eveningFree).map(Double.init)
            guard !free.isEmpty else { continue }
            let med = percentile(free, 0.5)
            set(&b, id, observed: med, n: free.count, bounds: 30...360,
                evidence: "On \(free.count) days you followed the plan, you kept about \(Int(med)) min free", now: now)
        }
        let blocks = outcomes.filter { $0.plannedStart >= since && $0.status == .done && $0.actualMinutes >= 10 }.map { Double($0.actualMinutes) }
        if !blocks.isEmpty {
            let med = percentile(blocks, 0.5)
            set(&b, "study.focusMinutes", observed: med, n: blocks.count, bounds: 20...60,
                evidence: "\(blocks.count) finished blocks lasted about \(Int(med)) min", now: now)
        }
        let meals = markers.filter { $0.at >= since && ["dinner", "meal"].contains($0.activity) }.sorted { $0.at < $1.at }
        let starts = meals.filter { $0.phase == .start && (16...22).contains(cal.component(.hour, from: $0.at)) }
        if !starts.isEmpty {
            let mins = starts.map { Double(cal.component(.hour, from: $0.at) * 60 + cal.component(.minute, from: $0.at)) }
            let med = percentile(mins, 0.5)
            set(&b, "routines.dinnerTime", observed: med, n: starts.count, bounds: 16 * 60...22 * 60,
                evidence: "Dinner started around \(TimeOfDay(minutes: Int(med)).label) on \(starts.count) days", now: now)
            let lengths = starts.compactMap { s in meals.first { $0.phase == .end && $0.at > s.at && $0.at < s.at.addingTimeInterval(3 * 3600) }
                .map { $0.at.timeIntervalSince(s.at) / 60 } }
            if !lengths.isEmpty {
                set(&b, "routines.dinnerMinutes", observed: percentile(lengths, 0.5), n: lengths.count, bounds: 10...120,
                    evidence: "Dinner took about \(Int(percentile(lengths, 0.5))) min", now: now)
            }
        }
        return b
    }

    public static func records(days: [Date], planHistory: [String: [PlannedBlock]] = [:], outcomes: [BlockOutcome],
                               progress: [ProgressEntry], isSchoolDay: (Date) -> Bool, eveningFree: (Date) -> Int? = { _ in nil },
                               calendar cal: Calendar) -> [DayRecord] {
        days.map { d in
            let key = dayKey(d, cal)
            let fromHistory = planHistory[key]?.filter(\.isStudy).reduce(0) { $0 + $1.minutes }
            let todays = outcomes.filter { cal.isDate($0.plannedStart, inSameDayAs: d) }
            let planned = fromHistory ?? todays.reduce(0) { $0 + $1.plannedMinutes }
            let done = todays.filter { $0.status != .skipped }.reduce(0) { $0 + $1.actualMinutes } + progress.minutes(on: d, calendar: cal)
            return DayRecord(day: cal.startOfDay(for: d), isSchoolDay: isSchoolDay(d), planned: planned, done: done, eveningFree: eveningFree(d))
        }
    }

    public static func dayKey(_ d: Date, _ cal: Calendar) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
