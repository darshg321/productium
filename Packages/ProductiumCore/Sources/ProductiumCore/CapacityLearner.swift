import Foundation

// MARK: - Learned capacities
//
// Instead of steppers the student has to guess (most study on a school day, protected free time,
// focus and break length, dinner), the app learns them from what actually happens and the planner
// reads them as beliefs. With few days, each estimate is shrunk toward its prior, so one odd week
// can't swing the plan.

/// One past day, as the learner sees it.
public struct DayRecord: Hashable, Sendable {
    public var day: Date
    public var isSchoolDay: Bool
    /// Study planned for the day (the plan as it was), and study actually done (blocks, focus,
    /// progress logged through the box).
    public var planned: Int
    public var done: Int
    /// Free minutes after school/activities ended (evening free time), if known.
    public var eveningFree: Int?

    public init(day: Date, isSchoolDay: Bool, planned: Int, done: Int, eveningFree: Int? = nil) {
        self.day = day
        self.isSchoolDay = isSchoolDay
        self.planned = planned
        self.done = done
        self.eveningFree = eveningFree
    }

    /// Followed the plan: did at least 80% of what was planned.
    public var followed: Bool { planned > 0 && Double(done) >= 0.8 * Double(planned) }
}

public enum CapacityLearner {
    /// Days of history used.
    public static let window = 21
    /// How many days the prior is worth.
    public static let priorWeight = 5.0

    static func percentile(_ xs: [Double], _ p: Double) -> Double {
        let s = xs.sorted()
        guard !s.isEmpty else { return 0 }
        let r = p * Double(s.count - 1)
        let lo = Int(r.rounded(.down)), hi = Int(r.rounded(.up))
        return s[lo] + (s[hi] - s[lo]) * (r - Double(lo))
    }

    /// Shrinks an observation toward the prior by how many samples back it, then bounds it.
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
        // The learner's line replaces its previous one; "You said…" lines stay.
        x.evidence = [evidence] + x.evidence.filter { $0.hasPrefix("You said") }
        b[id] = x
    }

    /// Learns every capacity it has data for. `outcomes` give focus length; `markers` give dinner.
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
        // Dinner: when dinner check-ins start, and how long they run.
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

    /// Day records from what's stored: planned study from the plan history (or, failing that, the
    /// outcomes' planned minutes), done from outcomes plus progress logged that day.
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
