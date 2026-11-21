import Foundation

public enum RoutineAnchor: String, Codable, Sendable {
    case afterWake
    case beforeFirstCommitment
    case afterLastCommitment
}

public struct Routine: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var anchor: RoutineAnchor
    public var anchorKind: CommitmentKind?
    public var category: TimeCategory
    public var defaultMinutes: Int
    public var samples: [Int]
    public var stated: Int?
    public var enabled: Bool

    public static let maxSamples = 15

    public init(id: String, name: String, anchor: RoutineAnchor, anchorKind: CommitmentKind? = nil,
                category: TimeCategory, defaultMinutes: Int, samples: [Int] = [], enabled: Bool = true) {
        self.id = id
        self.name = name
        self.anchor = anchor
        self.anchorKind = anchorKind
        self.category = category
        self.defaultMinutes = defaultMinutes
        self.samples = samples
        self.enabled = enabled
    }

    public static let samplesToTrust = 3

    /// What you said is the prior until three real samples exist; then the median takes over.
    public var minutes: Int {
        if samples.count >= Self.samplesToTrust { return samples.median ?? defaultMinutes }
        return stated ?? samples.median ?? defaultMinutes
    }

    public var confidence: BeliefConfidence {
        if let s = stated {
            guard samples.count >= Self.samplesToTrust, let m = samples.median else { return .stated }
            return Double(abs(s - m)) <= max(Double(s) * 0.15, 10) ? .confirmed : .learned
        }
        switch samples.count {
        case 0: return .assumed
        case 1, 2: return .learning
        default: return .learned
        }
    }

    public var disagreement: String? {
        guard let s = stated, samples.count >= Self.samplesToTrust, confidence == .learned, let m = samples.median else { return nil }
        return "You said \(s) min, it's been \(m) min lately"
    }

    public var safeMinutes: Int {
        guard samples.count >= Self.samplesToTrust else { return Int(Double(minutes) * 1.15) + 2 }
        let s = samples.sorted()
        return s[min(s.count - 1, Int(Double(s.count) * 0.8))]
    }

    public var isLearned: Bool { !samples.isEmpty }
    public var isKnown: Bool { stated != nil || !samples.isEmpty }

    @discardableResult
    public mutating func observe(_ m: Int) -> Bool {
        guard m >= 1, m <= 240 else { return false }
        if samples.count >= 3 {
            let med = minutes
            if Double(m) > Double(med) * 2.5 + 10 || Double(m) < Double(med) * 0.3 { return false }
        }
        samples.append(m)
        if samples.count > Self.maxSamples { samples.removeFirst(samples.count - Self.maxSamples) }
        return true
    }

    public static let defaults: [Routine] = [
        Routine(id: "get_ready", name: "Get ready", anchor: .afterWake, category: .routine, defaultMinutes: 40),
        Routine(id: "to_school", name: "To school", anchor: .beforeFirstCommitment, anchorKind: .school, category: .commute, defaultMinutes: 20),
        Routine(id: "from_school", name: "Home from school", anchor: .afterLastCommitment, anchorKind: .school, category: .commute, defaultMinutes: 20),
    ]
}

extension Routine {
    /// v1.2 O4: routines aren't stored. How long getting ready and the trip to and from school take is read from the
    /// log (the median of what you or a sensor logged in that category over the last four weeks, else the default),
    /// and a routine you made an entry for ("get ready 7:00–7:40 every school day") is yours, not the planner's.
    public static func fromLog(_ entries: [Entry], tree: CategoryTree, now: Date, book: DayRuleBook = DayRuleBook(),
                               calendar cal: Calendar, days: Int = 28) -> [Routine] {
        var out = Routine.defaults
        func idx(_ id: String) -> Int { out.firstIndex { $0.id == id }! }
        let series = entries.filter { $0.repeats != nil && $0.source == .you }
        if series.contains(where: { tree.isUnder($0.category, CategoryTree.gettingReady) }) { out[idx("get_ready")].enabled = false }
        if series.contains(where: { tree.isUnder($0.category, CategoryTree.travel) }) {
            out[idx("to_school")].enabled = false
            out[idx("from_school")].enabled = false
        }
        let today = cal.startOfDay(for: now)
        let past = entries.filter { $0.source != .plan }
        for back in stride(from: days, through: 0, by: -1) {
            guard let day = cal.date(byAdding: .day, value: -back, to: today) else { continue }
            let occ = Days.on(day, past, now: now, book: book, calendar: cal)
                .filter { !$0.running && $0.end <= now && cal.isDate($0.start, inSameDayAs: day) }
            // Samples are time that was measured or told, not a series (that's a plan) or a planned session.
            let told = occ.filter { $0.entry.repeats == nil && !$0.isPlannedSession && $0.mark != .skipped }
            for o in told where tree.isUnder(o.category, CategoryTree.gettingReady) { out[idx("get_ready")].observe(o.minutes) }
            let school = occ.filter { tree.isUnder($0.category, CategoryTree.school) }
            guard let first = school.map(\.start).min(), let last = school.map(\.end).max() else { continue }
            let travel = told.filter { tree.isUnder($0.category, CategoryTree.travel) }
            if let t = travel.last(where: { $0.end >= first.addingTimeInterval(-45 * 60) && $0.end <= first.addingTimeInterval(10 * 60) }) {
                out[idx("to_school")].observe(t.minutes)
            }
            if let t = travel.first(where: { $0.start >= last.addingTimeInterval(-5 * 60) && $0.start <= last.addingTimeInterval(30 * 60) }) {
                out[idx("from_school")].observe(t.minutes)
            }
        }
        return out
    }
}

public struct WakePlan: Codable, Hashable, Sendable {
    public var day: Date
    public var wake: Date
    public var leaveBy: Date?
    public var firstCommitment: Date?
    public var reason: String
}

public enum WakePlanner {
    public static func plan(for day: Date, events: [FixedEvent], routines: [Routine],
                            prefs: Preferences, calendar cal: Calendar,
                            isSchoolDay: Bool? = nil) -> WakePlan {
        let isSchool = isSchoolDay ?? prefs.schoolDays.contains(cal.component(.weekday, from: day))
        let fallback = at(day, isSchool ? prefs.schoolDayWake : prefs.freeDayWake, cal)
        guard prefs.autoWake else {
            return WakePlan(day: day, wake: fallback, leaveBy: nil, firstCommitment: nil, reason: "Your set wake time")
        }
        let noon = at(day, TimeOfDay(12), cal)
        let firsts: [(Date, CommitmentKind)] = events.filter { cal.isDate($0.start, inSameDayAs: day) }.map { ($0.start, $0.kind) }
        guard let first = firsts.filter({ $0.0 < noon }).min(by: { $0.0 < $1.0 }) else {
            return WakePlan(day: day, wake: fallback, leaveBy: nil, firstCommitment: nil,
                            reason: isSchool ? "Your school-day wake time" : "Free day: close to your usual time")
        }
        let ready = routines.first { $0.id == "get_ready" && $0.enabled }?.minutes ?? 40
        let commute = routines.first { $0.anchor == .beforeFirstCommitment && $0.enabled && ($0.anchorKind == nil || $0.anchorKind == first.1) }
        let travel = commute?.safeMinutes ?? 15
        let leave = first.0.addingTimeInterval(-Double(travel + 5) * 60)
        var wake = leave.addingTimeInterval(-Double(ready) * 60)
        let earliest = at(day, TimeOfDay(5, 0), cal)
        wake = max(earliest, min(wake, at(day, prefs.freeDayWake, cal)))
        let t = wake.timeIntervalSinceReferenceDate
        wake = Date(timeIntervalSinceReferenceDate: floor(t / 300) * 300)
        let learned = (commute?.isLearned ?? false) ? "your usual \(travel)-min trip" : "an estimated \(travel)-min trip"
        return WakePlan(day: day, wake: wake, leaveBy: leave, firstCommitment: first.0,
                        reason: "Starts \(TimeOfDay(cal.component(.hour, from: first.0), cal.component(.minute, from: first.0)).label), \(learned), \(ready) min to get ready")
    }

    static func at(_ day: Date, _ t: TimeOfDay, _ cal: Calendar) -> Date {
        cal.date(bySettingHour: t.hour, minute: t.minute, second: 0, of: day) ?? day
    }
}
