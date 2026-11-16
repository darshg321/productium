import Foundation

// MARK: - Routines the app learns (commute, getting ready…)

public enum RoutineAnchor: String, Codable, Sendable {
    /// Starts at wake-up (getting ready).
    case afterWake
    /// Ends when the day's first commitment of `anchorKind` starts (walk to school).
    case beforeFirstCommitment
    /// Starts when the day's last commitment of `anchorKind` ends (walk home).
    case afterLastCommitment
}

/// A repeated activity whose duration the app learns from a few check-ins and
/// then fills in by itself, so the student never logs "walked to school" again.
public struct Routine: Codable, Identifiable, Hashable, Sendable {
    public var id: String          // stable key: "get_ready", "to_school", "from_school"
    public var name: String
    public var anchor: RoutineAnchor
    public var anchorKind: CommitmentKind?
    public var category: TimeCategory
    public var defaultMinutes: Int
    /// The most recent observed durations (newest last), capped at `maxSamples`.
    public var samples: [Int]
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

    /// Median: robust to the one day you stopped for coffee.
    public var minutes: Int {
        guard !samples.isEmpty else { return defaultMinutes }
        let s = samples.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// Upper estimate (~80th percentile) for planning "leave by": arriving late costs
    /// more than arriving a few minutes early.
    public var safeMinutes: Int {
        guard samples.count >= 3 else { return Int(Double(minutes) * 1.15) + 2 }
        let s = samples.sorted()
        return s[min(s.count - 1, Int(Double(s.count) * 0.8))]
    }

    public var isLearned: Bool { !samples.isEmpty }

    /// Adds an observation. Obvious outliers (forgot to tap "at school" until lunch)
    /// are rejected once there's enough history to know what's normal.
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

// MARK: - Wake-up planning

public struct WakePlan: Codable, Hashable, Sendable {
    public var day: Date
    public var wake: Date
    public var leaveBy: Date?
    public var firstCommitment: Date?
    public var reason: String
}

public enum WakePlanner {
    /// Work back from the first commitment: start − commute (safe estimate) −
    /// getting ready − 5 min slack. Without a morning commitment, use the free-day wake
    /// time. Keeping that close to school days limits social jet lag (Wittmann et al. 2006).
    public static func plan(for day: Date, commitments: [Commitment], events: [FixedEvent], routines: [Routine],
                            prefs: Preferences, calendar cal: Calendar) -> WakePlan {
        let weekday = cal.component(.weekday, from: day)
        let isSchool = prefs.schoolDays.contains(weekday)
        let fallback = at(day, isSchool ? prefs.schoolDayWake : prefs.freeDayWake, cal)
        guard prefs.autoWake else {
            return WakePlan(day: day, wake: fallback, leaveBy: nil, firstCommitment: nil, reason: "Your set wake time")
        }
        let noon = at(day, TimeOfDay(12), cal)
        var firsts: [(Date, CommitmentKind)] = commitments.filter { c in
            c.weekdays.contains(weekday)
                && (c.validFrom.map { cal.startOfDay(for: $0) <= day } ?? true)
                && (c.validUntil.map { day <= $0 } ?? true)
        }.map { (at(day, $0.start, cal), $0.kind) }
        firsts += events.filter { cal.isDate($0.start, inSameDayAs: day) }.map { ($0.start, $0.kind) }
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
