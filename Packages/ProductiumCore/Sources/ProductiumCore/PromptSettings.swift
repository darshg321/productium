import Foundation

// v1.3 Part E: every kind of prompt in one list (Settings → Notifications), each with a severity. Replaces the
// separate notification toggles and the alarm toggles; `NudgePlanner` and `AlarmPlanner` read it. Nothing becomes
// an Alarm unless alarms are allowed (the J rule: `Integrations.alarms`).

public enum Severity: String, Codable, CaseIterable, Comparable, Sendable {
    case off, quiet, liveActivity, notification, alarm

    var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    public static func < (a: Severity, b: Severity) -> Bool { a.rank < b.rank }

    public var title: String {
        switch self {
        case .off: return "Off"
        case .quiet: return "Quiet"
        case .liveActivity: return "Live Activity"
        case .notification: return "Notification"
        case .alarm: return "Alarm"
        }
    }

    public var detail: String {
        switch self {
        case .off: return "Nothing"
        case .quiet: return "Only in the app"
        case .liveActivity: return "On the Lock Screen, in the Now activity"
        case .notification: return "A normal notification"
        case .alarm: return "Full screen with sound, even on silent"
        }
    }
}

public enum PromptKind: String, Codable, CaseIterable, Sendable {
    case wake, bedtime, leave, sessionStart, missedStart, deadline, untracked, assumed, questions, sleepCheck
    case scrollCheckIns, checkIn, reminders, movement, daylight, celebrations, weeklyNote

    public var title: String {
        switch self {
        case .wake: return "Wake Up"
        case .bedtime: return "Bedtime and Wind-Down"
        case .leave: return "Leave for School"
        case .sessionStart: return "Session Start"
        case .missedStart: return "Missed Start"
        case .deadline: return "Deadline Soon"
        case .untracked: return "Untracked Time"
        case .assumed: return "Assumed Time"
        case .questions: return "Questions"
        case .sleepCheck: return "Sleep Check"
        case .scrollCheckIns: return "Scrolling Check-Ins"
        case .checkIn: return "Evening Check-In"
        case .reminders: return "Your Reminders"
        case .movement: return "Stand-Up Breaks"
        case .daylight: return "Morning Light"
        case .celebrations: return "Celebrations"
        case .weeklyNote: return "Weekly Note"
        }
    }

    public var symbol: String {
        switch self {
        case .wake: return "sunrise"
        case .bedtime: return "moon.zzz"
        case .leave: return "figure.walk.departure"
        case .sessionStart: return "play.circle"
        case .missedStart: return "exclamationmark.circle"
        case .deadline: return "calendar.badge.exclamationmark"
        case .untracked: return "questionmark.circle"
        case .assumed: return "checkmark.circle.badge.questionmark"
        case .questions: return "bubble.left.and.text.bubble.right"
        case .sleepCheck: return "bed.double"
        case .scrollCheckIns: return "hourglass"
        case .checkIn: return "text.bubble"
        case .reminders: return "bell"
        case .movement: return "figure.stand"
        case .daylight: return "sun.max"
        case .celebrations: return "sparkles"
        case .weeklyNote: return "doc.text"
        }
    }

    public var defaultSeverity: Severity {
        switch self {
        case .wake: return .alarm
        case .untracked, .assumed, .questions: return .liveActivity
        case .celebrations, .weeklyNote: return .quiet
        default: return .notification
        }
    }

    /// Which prompt kind a notification belongs to (nil: always sent, e.g. the running entry when Live Activities are off).
    public init?(_ k: NudgeKind) {
        switch k {
        case .leadUp, .start, .sessionEnd: self = .sessionStart
        case .followUp: self = .missedStart
        case .windDown, .bedtime, .stillUp: self = .bedtime
        case .leaveSoon, .leaveNow: self = .leave
        case .deadline: self = .deadline
        case .checkIn: self = .checkIn
        case .morning: self = .wake
        case .intention: self = .reminders
        case .daylight: self = .daylight
        case .untracked: self = .untracked
        case .sleepConfirm: self = .sleepCheck
        case .question: self = .questions
        case .running: return nil
        }
    }
}

public struct PromptSettings: Codable, Hashable, Sendable {
    /// Only what differs from the defaults is stored, keyed by `PromptKind.rawValue`.
    public var severity: [String: Severity]

    public init(_ severity: [PromptKind: Severity] = [:]) {
        self.severity = Dictionary(severity.map { ($0.key.rawValue, $0.value) }, uniquingKeysWith: { $1 })
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = (try? c.decodeIfPresent([String: String].self, forKey: .severity)) ?? [:]
        severity = raw.compactMapValues(Severity.init(rawValue:))
    }

    enum CodingKeys: String, CodingKey { case severity }

    public subscript(_ k: PromptKind) -> Severity {
        get { severity[k.rawValue] ?? k.defaultSeverity }
        set {
            severity[k.rawValue] = newValue == k.defaultSeverity ? nil : newValue
        }
    }

    /// What actually happens: an Alarm without alarms allowed is a notification; the Now activity, once it has ended
    /// (iOS ends it after 8 h), falls back to a notification too.
    public func effective(_ k: PromptKind, alarmsAllowed: Bool, liveActivity: Bool = true) -> Severity {
        let s = self[k]
        if s == .alarm && !alarmsAllowed { return .notification }
        if s == .liveActivity && !liveActivity { return .notification }
        return s
    }

    /// Sends a notification (an Alarm also gets one, as before).
    public func notifies(_ k: PromptKind, liveActivity: Bool = true) -> Bool {
        effective(k, alarmsAllowed: true, liveActivity: liveActivity) >= .notification
    }

    public func rings(_ k: PromptKind, alarmsAllowed: Bool) -> Bool { effective(k, alarmsAllowed: alarmsAllowed) == .alarm }

    /// Notifications whose kind is set to Alarm also ring (the kinds `NudgePlanner.alarms` doesn't already cover).
    public func alarms(from xs: [PlannedNudge], alarmsAllowed: Bool) -> [PlannedAlarm] {
        let covered: Set<PromptKind> = [.wake, .bedtime, .leave, .missedStart]
        return xs.compactMap { n in
            guard let k = PromptKind(n.kind), !covered.contains(k), rings(k, alarmsAllowed: alarmsAllowed) else { return nil }
            return PlannedAlarm(key: "prompt.\(n.id)", kind: .prompt, at: n.at, title: n.title, blockId: n.blockId)
        }
    }

    /// Keeps only the notifications whose kind is set to notify.
    public func filter(_ xs: [PlannedNudge], liveActivity: Bool = true) -> [PlannedNudge] {
        xs.filter { n in PromptKind(n.kind).map { notifies($0, liveActivity: liveActivity) } ?? true }
    }

    /// The v1.2 toggles as severities (the schema 4 → 5 migration).
    public static func migrated(from n: NudgeSettings, wakeAlarms: Bool) -> PromptSettings {
        var p = PromptSettings()
        p[.wake] = wakeAlarms ? .alarm : .notification
        for k in [PromptKind.bedtime, .leave, .missedStart] { p[k] = n.alarms ? .alarm : .notification }
        if !n.deadlines { p[.deadline] = .off }
        if !n.scrollCheckIns { p[.scrollCheckIns] = .off }
        if !n.movement { p[.movement] = .off }
        if !n.daylight { p[.daylight] = .off }
        return p
    }
}
