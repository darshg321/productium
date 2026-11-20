import Foundation

// v1.2 Part 0: something the planner must do differently for a while ("exam week: 45 minute blocks", "Mum takes the
// phone at 10 on school nights" → no study after 21:45). Most instructions don't need one: they're time (an entry,
// a skip), a task field (`maxMinutesPerDay`, `notBefore`, `difficulty`), or something to remember (About Me).
// A Rule is only for how the planner fills the days, which nothing else can say.

/// What a rule changes on the days it applies. nil = no change.
public struct PlannerLimits: Codable, Hashable, Sendable {
    /// Wake at this time (replaces the day's computed wake).
    public var wake: TimeOfDay?
    public var windDownMinutes: Int?
    /// Multiplies the day's study capacity (0.5 = half as much work, 0 = none).
    public var capacityFactor: Double?
    public var maxBlockMinutes: Int?
    /// No task sessions end after this time.
    public var noStudyAfter: TimeOfDay?
    /// No reminders of these kinds; `muteAll` silences every reminder that day.
    public var mute: [NudgeKind]?
    public var muteAll: Bool?

    public init(wake: TimeOfDay? = nil, windDownMinutes: Int? = nil, capacityFactor: Double? = nil,
                maxBlockMinutes: Int? = nil, noStudyAfter: TimeOfDay? = nil, mute: [NudgeKind]? = nil, muteAll: Bool? = nil) {
        self.wake = wake
        self.windDownMinutes = windDownMinutes
        self.capacityFactor = capacityFactor
        self.maxBlockMinutes = maxBlockMinutes
        self.noStudyAfter = noStudyAfter
        self.mute = mute
        self.muteAll = muteAll
    }

    public var isEmpty: Bool { self == PlannerLimits() }

    /// Field by field, `o` wins where it sets something.
    public func overlaid(by o: PlannerLimits) -> PlannerLimits {
        PlannerLimits(wake: o.wake ?? wake, windDownMinutes: o.windDownMinutes ?? windDownMinutes,
                      capacityFactor: o.capacityFactor ?? capacityFactor, maxBlockMinutes: o.maxBlockMinutes ?? maxBlockMinutes,
                      noStudyAfter: o.noStudyAfter ?? noStudyAfter,
                      mute: o.mute.map { Array(Set((mute ?? []) + $0)).sorted { $0.rawValue < $1.rawValue } } ?? mute,
                      muteAll: o.muteAll ?? muteAll)
    }

    /// Kept to values the planner can use. Sleep below the floor is applied (with a warning), so wake isn't clamped.
    public var clamped: PlannerLimits {
        var l = self
        l.windDownMinutes = windDownMinutes.map { max(0, min(180, $0)) }
        l.capacityFactor = capacityFactor.map { max(0, min(2, $0)) }
        l.maxBlockMinutes = maxBlockMinutes.map { max(10, min(240, $0)) }
        return l
    }
}

public struct Rule: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// In the AI's words, readable on its own in Settings → What Productium Thinks.
    public var text: String
    /// What you actually said.
    public var said: String?
    /// Inclusive day range; nil ends are open.
    public var from: Date?
    public var until: Date?
    /// Which days inside the range (school nights, B days). nil = every day.
    public var days: DayRule?
    public var limits: PlannerLimits
    public var createdAt: Date

    public init(id: UUID = UUID(), text: String, said: String? = nil, from: Date? = nil, until: Date? = nil,
                days: DayRule? = nil, limits: PlannerLimits, createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.said = said
        self.from = from
        self.until = until
        self.days = days
        self.limits = limits
        self.createdAt = createdAt
    }

    public var ref: String { EntryRef.rule(id) }

    public func applies(on day: Date, _ ev: DayRuleEvaluator) -> Bool {
        let cal = ev.calendar
        let d = cal.startOfDay(for: day)
        if let from, d < cal.startOfDay(for: from) { return false }
        if let until, d > cal.startOfDay(for: until) { return false }
        return days.map { ev.matches($0, on: d) } ?? true
    }

    /// Ended rules drop out of the context and Settings; they stay in the backup.
    public func isActive(at now: Date, calendar cal: Calendar) -> Bool {
        until.map { cal.startOfDay(for: $0) >= cal.startOfDay(for: now) } ?? true
    }
}

public enum Rules {
    /// The limits in force on a day: rules applied oldest first, so a newer rule wins field by field.
    public static func limits(_ rules: [Rule], on day: Date, _ ev: DayRuleEvaluator) -> PlannerLimits {
        rules.filter { $0.applies(on: day, ev) }.sorted { $0.createdAt < $1.createdAt }
            .reduce(PlannerLimits()) { $0.overlaid(by: $1.limits.clamped) }
    }

    public static func active(_ rules: [Rule], at now: Date, calendar cal: Calendar) -> [Rule] {
        rules.filter { $0.isActive(at: now, calendar: cal) }.sorted { $0.createdAt < $1.createdAt }
    }
}

/// A day the planner muted reminders on (read by `NudgePlanner`).
public struct NudgeMute: Codable, Hashable, Sendable {
    public var day: Date
    /// nil: every reminder that day.
    public var kind: NudgeKind?
    public init(day: Date, kind: NudgeKind?) {
        self.day = day
        self.kind = kind
    }
}
