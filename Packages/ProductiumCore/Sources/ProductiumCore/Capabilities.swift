import Foundation

// MARK: - What the AI may change, and how risky each change is
//
// Instead of a growing list of hand-written action types, the AI has three operations over a
// typed registry: `upsert(entity, id?, fields)`, `delete(entity, id)` and `set(knob, value)`.
// Every entity and knob declares its fields, bounds and a risk tier:
//
//   0 · data       tasks, events, markers, progress, colours, stated facts. The box applies them at
//                  once, with Undo.
//   1 · learned    routine durations, sleep need, capacities. The box only from the student's explicit
//                  statement (marked "stated"); otherwise the learners.
//   2 · behaviour  planner and nudge policy. Only the reflection job (Opus) may propose these, and
//                  nothing changes until the student approves (see Proposals.swift).
//
// Adding a behaviour later means registering a knob here, not writing a new action.

public enum RiskTier: Int, Codable, Comparable, Sendable, CaseIterable {
    case data = 0, learned = 1, behaviour = 2
    public static func < (a: RiskTier, b: RiskTier) -> Bool { a.rawValue < b.rawValue }

    public var title: String {
        switch self {
        case .data: return "Data"
        case .learned: return "Learned value"
        case .behaviour: return "Behaviour"
        }
    }
}

/// Who is making a change. The box may write tiers 0 and 1; tier 2 goes through a proposal the
/// student approves, and only the reflection may propose it.
public enum Writer: String, Codable, Sendable {
    case student, box, reflection

    public func mayApply(_ t: RiskTier) -> Bool {
        switch self {
        case .student: return true
        case .box: return t < .behaviour
        // Reflection changes are applied only from an approved proposal (Proposals.swift).
        case .reflection: return true
        }
    }

    public func mayWrite(_ s: AboutMeSection) -> Bool {
        switch self {
        case .student: return true
        case .box: return s == .stated
        case .reflection: return s != .stated
        }
    }
}

public typealias AboutMeWriter = Writer

// MARK: Tier 2: how the app behaves

/// Policy knobs the planner and nudges read. Defaults are neutral (they change nothing), so a new
/// student gets the planner as designed; reflection may propose bounded drift from there.
public struct BehaviourPolicy: Codable, Hashable, Sendable {
    /// Multiplies the learned daily study capacity (how hard to push).
    public var capacityMultiplier: Double
    /// The longest a study block may be, on top of the learned focus length.
    public var maxBlockMinutes: Int
    /// Multiplies the protected free time per day.
    public var freeTimeMultiplier: Double
    /// Moves the "not started yet?" follow-ups later (or earlier) than the nudge level's default.
    public var followUpShiftMinutes: Int

    public init(capacityMultiplier: Double = 1, maxBlockMinutes: Int = 55, freeTimeMultiplier: Double = 1,
                followUpShiftMinutes: Int = 0) {
        self.capacityMultiplier = capacityMultiplier
        self.maxBlockMinutes = maxBlockMinutes
        self.freeTimeMultiplier = freeTimeMultiplier
        self.followUpShiftMinutes = followUpShiftMinutes
    }
}

// MARK: The registry

public struct FieldSpec: Hashable, Sendable {
    public var name: String
    /// How the value looks, for the prompt ("YYYY-MM-DDTHH:mm", "1-5", "true|false").
    public var format: String
    public init(_ name: String, _ format: String) { self.name = name; self.format = format }
}

public struct EntitySpec: Hashable, Sendable {
    public var name: String
    public var tier: RiskTier
    /// The context's reference letter ("t" for tasks), or nil when ids are keys (routines).
    public var refPrefix: String?
    public var canDelete: Bool
    public var fields: [FieldSpec]
    public var note: String
}

public struct KnobSpec: Hashable, Sendable {
    public var key: String
    public var tier: RiskTier
    public var format: String
    /// Hard range and the biggest change one proposal may make (tier 2).
    public var range: ClosedRange<Double>?
    public var maxStep: Double?
    /// Things reflection may never touch, whoever asks (sleep need, the floor, the trade-off switch).
    public var reflectionForbidden: Bool
    public var note: String

    public init(_ key: String, _ tier: RiskTier, _ format: String, range: ClosedRange<Double>? = nil, maxStep: Double? = nil,
                reflectionForbidden: Bool = false, note: String = "") {
        self.key = key
        self.tier = tier
        self.format = format
        self.range = range
        self.maxStep = maxStep
        self.reflectionForbidden = reflectionForbidden
        self.note = note
    }
}

public struct MacroSpec: Hashable, Sendable {
    public var name: String
    public var entity: String
    public var fields: [FieldSpec]
    public var note: String
}

public enum Registry {
    static let colorFormat = "a colour name, #RRGGBB, or default"

    public static let entities: [EntitySpec] = [
        EntitySpec(name: "task", tier: .data, refPrefix: "t", canDelete: true, fields: [
            FieldSpec("title", "text"),
            FieldSpec("kind", TaskKind.allCases.map(\.rawValue).joined(separator: "|")),
            FieldSpec("subject", "text"), FieldSpec("due", "YYYY-MM-DDTHH:mm (no time: tests 08:00, submissions 23:59)"),
            FieldSpec("estimateMinutes", "realistic minutes"), FieldSpec("importance", "1-5"), FieldSpec("difficulty", "1-3"),
            FieldSpec("doneMinutes", "minutes done so far in total (absolute, never added)"),
            FieldSpec("done", "true|false"), FieldSpec("topics", "list"), FieldSpec("notes", "text"),
            FieldSpec("color", colorFormat), FieldSpec("parent", "a task id, for a step"),
        ], note: "homework, tests, projects. One per deadline on an assignment sheet."),
        EntitySpec(name: "activity", tier: .data, refPrefix: "a", canDelete: true, fields: [
            FieldSpec("title", "text"), FieldSpec("kind", CommitmentKind.allCases.map(\.rawValue).joined(separator: "|")),
            FieldSpec("weekdays", "1=Sun..7=Sat"), FieldSpec("start", "HH:mm"), FieldSpec("end", "HH:mm"),
            FieldSpec("bufferMinutes", "travel before/after, default 10; 0 between periods"),
            FieldSpec("validFrom", "YYYY-MM-DD"), FieldSpec("validUntil", "YYYY-MM-DD"), FieldSpec("color", colorFormat),
        ], note: "weekly: school, classes, clubs, jobs."),
        EntitySpec(name: "event", tier: .data, refPrefix: "e", canDelete: true, fields: [
            FieldSpec("title", "text"), FieldSpec("date", "YYYY-MM-DD"), FieldSpec("start", "HH:mm"), FieldSpec("end", "HH:mm"),
            FieldSpec("kind", CommitmentKind.allCases.map(\.rawValue).joined(separator: "|")), FieldSpec("color", colorFormat),
        ], note: "busy time on one date. Calendar (cal) events are read-only."),
        EntitySpec(name: "day_change", tier: .data, refPrefix: "d", canDelete: true, fields: [
            FieldSpec("date", "YYYY-MM-DD"), FieldSpec("activity", "an activity id, or \"school\" for all of school"),
            FieldSpec("cancelled", "true|false"), FieldSpec("start", "HH:mm"), FieldSpec("end", "HH:mm"),
            FieldSpec("wake", "HH:mm (alone: sleeping in)"), FieldSpec("note", "text"),
        ], note: "one date differs from the usual week. \"Didn't go to school\" is a day_change, not a marker."),
        EntitySpec(name: "marker", tier: .data, refPrefix: nil, canDelete: false, fields: [
            FieldSpec("activity", "short key: to_school, from_school, school, study, sleep, wake, get_ready…"),
            FieldSpec("phase", "start|end"), FieldSpec("at", "YYYY-MM-DDTHH:mm"), FieldSpec("note", "their words"),
        ], note: "something that happened. \"Woke at 9\" = sleep end 09:00."),
        EntitySpec(name: "mood", tier: .data, refPrefix: nil, canDelete: false, fields: [
            FieldSpec("mood", "1-5"), FieldSpec("energy", "1-5"), FieldSpec("note", "their words"),
        ], note: "only if they say how they feel."),
        EntitySpec(name: "screen_time", tier: .data, refPrefix: nil, canDelete: false, fields: [
            FieldSpec("date", "YYYY-MM-DD"), FieldSpec("screenMinutes", "total"),
            FieldSpec("distractingMinutes", "social, video, games, feeds"),
            FieldSpec("apps", "[{name, minutes, distracting}]"),
        ], note: "one per day shown in a Screen Time screenshot. Unreadable week view: today, with the daily average."),
        EntitySpec(name: "routine", tier: .learned, refPrefix: nil, canDelete: false, fields: [
            FieldSpec("minutes", "how long it takes, as they said it"), FieldSpec("enabled", "true|false"),
        ], note: "id is the routine's key (get_ready|to_school|from_school). Only when they state it."),
    ]

    public static let macros: [MacroSpec] = [
        MacroSpec(name: "split", entity: "activity", fields: [FieldSpec("parts", "[{title, start, end, weekdays?, color?}]")],
                  note: "one activity into periods: id of the activity and its parts. Parts keep its days unless given weekdays; days no part covers keep the original. Never add periods next to the original."),
    ]

    public static let knobs: [KnobSpec] = [
        // Tier 0: the student's own preferences, changed when they ask.
        KnobSpec("color.<category>", .data, colorFormat, note: "categories: \(Palette.categories.joined(separator: "|")), subject:<name>, task:<kind>"),
        KnobSpec("interests", .data, "comma list"),
        KnobSpec("schoolDays", .data, "weekday numbers, e.g. 2,3,4,5,6"),
        KnobSpec("autoWake", .data, "true|false (work the wake-up back from the first class)"),
        KnobSpec("windDownMinutes", .data, "0-90"),
        KnobSpec("nudgeLevel", .data, "gentle|standard|persistent"),
        KnobSpec("alarms", .data, "true|false"), KnobSpec("scrollCheckIns", .data, "true|false"),
        KnobSpec("arrivingHome", .data, "true|false"), KnobSpec("deadlineNudges", .data, "true|false"),
        // Tier 1: values the app otherwise learns. Only from what the student states.
        KnobSpec("sleepNeedMinutes", .learned, "450-600", reflectionForbidden: true),
        KnobSpec("sleepFloorMinutes", .learned, "360-480", reflectionForbidden: true),
        KnobSpec("allowSleepTradeoffs", .learned, "true|false", reflectionForbidden: true),
        KnobSpec("schoolDayWake", .learned, "HH:mm"), KnobSpec("freeDayWake", .learned, "HH:mm"),
        KnobSpec("dinner", .learned, "HH:mm or none"), KnobSpec("dinnerMinutes", .learned, "10-120"),
        KnobSpec("focusBlockMinutes", .learned, "15-90"), KnobSpec("breakMinutes", .learned, "0-30"),
        KnobSpec("maxStudyMinutesSchoolDay", .learned, "30-480"), KnobSpec("maxStudyMinutesFreeDay", .learned, "30-600"),
        KnobSpec("minFreeMinutesSchoolDay", .learned, "0-300"), KnobSpec("minFreeMinutesFreeDay", .learned, "0-600"),
        KnobSpec("chronotype", .learned, "early|intermediate|late"), KnobSpec("screenTimeGoalMinutes", .learned, "0-600"),
        // Tier 2: behaviour. Proposed by the reflection only, applied after the student approves.
        KnobSpec("planner.capacityMultiplier", .behaviour, "0.6-1.3", range: 0.6...1.3, maxStep: 0.1,
                 note: "how much of the learned study capacity to plan"),
        KnobSpec("planner.maxBlockMinutes", .behaviour, "20-60", range: 20...60, maxStep: 10,
                 note: "longest study block"),
        KnobSpec("planner.freeTimeMultiplier", .behaviour, "0.8-1.5", range: 0.8...1.5, maxStep: 0.1,
                 note: "how much free time to protect"),
        KnobSpec("nudges.followUpShiftMinutes", .behaviour, "-3-10", range: -3...10, maxStep: 5,
                 note: "how much later than usual to ask again if a block hasn't started"),
    ]

    public static func entity(_ name: String?) -> EntitySpec? {
        guard let n = name?.lowercased().filter({ $0.isLetter }), !n.isEmpty else { return nil }
        let aliases = ["item": "task", "assignment": "task", "commitment": "activity", "class": "activity",
                       "dayexception": "day_change", "exception": "day_change", "day": "day_change",
                       "checkin": "marker", "log": "marker", "screentime": "screen_time", "screen": "screen_time"]
        let key = aliases[n] ?? n
        return entities.first { $0.name.filter(\.isLetter) == key.filter(\.isLetter) }
    }

    public static func knob(_ key: String) -> KnobSpec? {
        let k = key.trimmingCharacters(in: .whitespaces)
        if k.lowercased().hasPrefix("color") || k.lowercased().hasPrefix("colour") { return knobs[0] }
        let p = k.lowercased().filter { $0.isLetter || $0 == "." }
        return knobs.first { $0.key.lowercased().filter { $0.isLetter || $0 == "." } == p }
            ?? knobs.first { $0.tier == .behaviour && $0.key.split(separator: ".").last.map { $0.lowercased() == p } == true }
    }

    /// The box's view of the registry (tiers 0 and 1; tier 2 isn't the box's to change).
    public static func promptText(maxTier: RiskTier = .learned) -> String {
        var l: [String] = []
        l.append("Entities (upsert: id to change one, no id to create; fields as below):")
        for e in entities where e.tier <= maxTier {
            let ref = e.refPrefix.map { " (\($0)…)" } ?? ""
            let tier = e.tier == .learned ? " [only when they state it]" : ""
            l.append("- \(e.name)\(ref)\(tier): \(e.note) Fields: " + e.fields.map { "\($0.name) (\($0.format))" }.joined(separator: ", ")
                     + (e.canDelete ? "" : ". Can't be deleted."))
        }
        l.append("Macros:")
        for m in macros { l.append("- \(m.name) (\(m.entity)): \(m.note) Fields: " + m.fields.map { "\($0.name) \($0.format)" }.joined(separator: ", ")) }
        l.append("Knobs (set: knob, value as text):")
        for t in RiskTier.allCases where t <= maxTier {
            let ks = knobs.filter { $0.tier == t }
            guard !ks.isEmpty else { continue }
            let head = t == .data ? "- preferences: " : "- values the app learns, only when they state them: "
            l.append(head + ks.map { "\($0.key) (\($0.format))" + ($0.note.isEmpty ? "" : " \($0.note)") }.joined(separator: ", "))
        }
        return l.joined(separator: "\n")
    }
}

// MARK: Setting a knob

public enum KnobResult: Hashable, Sendable {
    case changed(String)
    case refused(String)
}

public enum Knobs {
    /// The current value of a tier-2 knob.
    public static func value(_ key: String, in p: BehaviourPolicy) -> Double? {
        switch key {
        case "planner.capacityMultiplier": return p.capacityMultiplier
        case "planner.maxBlockMinutes": return Double(p.maxBlockMinutes)
        case "planner.freeTimeMultiplier": return p.freeTimeMultiplier
        case "nudges.followUpShiftMinutes": return Double(p.followUpShiftMinutes)
        default: return nil
        }
    }

    /// Writes a tier-2 knob, clamped to its range and its largest step from the current value.
    static func write(_ key: String, _ v: Double, in p: inout BehaviourPolicy) {
        switch key {
        case "planner.capacityMultiplier": p.capacityMultiplier = (v * 100).rounded() / 100
        case "planner.maxBlockMinutes": p.maxBlockMinutes = Int(v.rounded())
        case "planner.freeTimeMultiplier": p.freeTimeMultiplier = (v * 100).rounded() / 100
        case "nudges.followUpShiftMinutes": p.followUpShiftMinutes = Int(v.rounded())
        default: break
        }
    }

    /// Where a bounded change from `current` toward `target` lands.
    public static func bounded(_ spec: KnobSpec, from current: Double, to target: Double) -> Double {
        var v = target
        if let s = spec.maxStep { v = max(current - s, min(current + s, v)) }
        if let r = spec.range { v = max(r.lowerBound, min(r.upperBound, v)) }
        return v
    }

    /// `set(knob, value)` from `writer`. Tier 2 is refused for anyone but an approved proposal.
    public static func set(_ rawKey: String, _ value: String, by writer: Writer, in s: inout DumpState) -> KnobResult {
        guard let spec = Registry.knob(rawKey) else { return .refused("There's no setting called “\(rawKey)”") }
        guard writer.mayApply(spec.tier) else {
            return .refused("“\(spec.key)” changes how the app behaves, so only the weekly reflection can suggest it, and you approve it")
        }
        if writer == .reflection && spec.reflectionForbidden {
            return .refused("“\(spec.key)” is yours to change, never the reflection's")
        }
        if spec.tier == .behaviour {
            guard let target = Double(value.trimmingCharacters(in: .whitespaces).filter { $0.isNumber || $0 == "." || $0 == "-" }),
                  let cur = Self.value(spec.key, in: s.policy) else { return .refused("“\(value)” isn't a number for \(spec.key)") }
            let v = bounded(spec, from: cur, to: target)
            write(spec.key, v, in: &s.policy)
            return .changed("\(spec.key) → \(Self.value(spec.key, in: s.policy).map(format) ?? value)")
        }
        if spec.key == "color.<category>" {
            let name = String(rawKey.drop { $0 != "." }.dropFirst())
            guard let cat = Palette.category(name) else { return .refused("“\(name)” isn't a category I can colour") }
            let l = value.trimmingCharacters(in: .whitespaces).lowercased()
            if ["", "default", "none", "reset", "auto", "clear"].contains(l) {
                s.prefs.colors[cat] = nil
                return .changed("\(cat.replacingOccurrences(of: "_", with: " ").capitalized) is back to its default colour")
            }
            guard let c = Palette.normalise(value) else {
                return .refused("“\(value)” isn't a colour I know (try \(Palette.names.prefix(6).joined(separator: ", ")), or #RRGGBB)")
            }
            s.prefs.colors[cat] = c
            return .changed("\(cat.replacingOccurrences(of: "_", with: " ").capitalized) is \(c)")
        }
        guard let line = PreferenceKnobs.apply(key: spec.key, value: value, to: &s.prefs) else {
            return .refused("Couldn't set \(spec.key) to “\(value)”")
        }
        return .changed(line)
    }

    static func format(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.2g", v) }
}

/// Tier 0 and 1 knobs that live in `Preferences`.
enum PreferenceKnobs {
    static func plain(_ s: String) -> String { s.lowercased().filter { $0.isLetter } }

    /// Applies one setting. Returns the receipt line, or nil when the key or value isn't usable.
    static func apply(key raw: String, value v: String, to p: inout Preferences) -> String? {
        let key = plain(raw)
        let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = t.lowercased()
        func int(_ lo: Int, _ hi: Int) -> Int? {
            let digits = t.prefix { $0.isNumber || $0 == "-" }
            guard let n = Int(digits) else { return nil }
            // "9h" / "9 hours" for a minutes setting
            let hours = lower.contains("h") && !lower.contains("min") && n <= 12
            return max(lo, min(hi, hours ? n * 60 : n))
        }
        func bool() -> Bool? {
            if ["true", "yes", "on", "1", "enable", "enabled"].contains(lower) { return true }
            if ["false", "no", "off", "0", "disable", "disabled", "none"].contains(lower) { return false }
            return nil
        }
        func time() -> TimeOfDay? { DumpApplier.timeOfDay(t) }
        switch key {
        case "sleepneedminutes": guard let n = int(450, 600) else { return nil }; p.sleepNeedMinutes = n
        case "sleepfloorminutes": guard let n = int(360, 480) else { return nil }; p.sleepFloorMinutes = n
        case "schooldaywake": guard let x = time() else { return nil }; p.schoolDayWake = x
        case "freedaywake": guard let x = time() else { return nil }; p.freeDayWake = x
        case "autowake": guard let b = bool() else { return nil }; p.autoWake = b
        case "winddownminutes": guard let n = int(0, 90) else { return nil }; p.windDownMinutes = n
        case "dinner":
            if ["none", "off", "no", "false", "skip"].contains(lower) { p.dinner = nil } else { guard let x = time() else { return nil }; p.dinner = x }
        case "dinnerminutes": guard let n = int(10, 120) else { return nil }; p.dinnerMinutes = n
        case "focusblockminutes": guard let n = int(15, 90) else { return nil }; p.focusBlockMinutes = n
        case "breakminutes": guard let n = int(0, 30) else { return nil }; p.breakMinutes = n
        case "maxstudyminutesschoolday": guard let n = int(30, 480) else { return nil }; p.maxStudyMinutesSchoolDay = n
        case "maxstudyminutesfreeday": guard let n = int(30, 600) else { return nil }; p.maxStudyMinutesFreeDay = n
        case "minfreeminutesschoolday": guard let n = int(0, 300) else { return nil }; p.minFreeMinutesSchoolDay = n
        case "minfreeminutesfreeday": guard let n = int(0, 600) else { return nil }; p.minFreeMinutesFreeDay = n
        case "allowsleeptradeoffs": guard let b = bool() else { return nil }; p.allowSleepTradeoffs = b
        case "chronotype": guard let c = Chronotype(rawValue: lower) else { return nil }; p.chronotype = c
        case "schooldays":
            let days = Set(t.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.filter { (1...7).contains($0) })
            guard !days.isEmpty || lower == "none" else { return nil }
            p.schoolDays = days
        case "screentimegoalminutes": guard let n = int(0, 600) else { return nil }; p.screenTimeGoalMinutes = n
        case "interests":
            p.interests = t.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        case "nudgelevel":
            guard let l = NudgeLevel(rawValue: lower) else { return nil }; p.nudges.level = l
        case "alarms": guard let b = bool() else { return nil }; p.nudges.alarms = b
        case "scrollcheckins": guard let b = bool() else { return nil }; p.nudges.scrollCheckIns = b
        case "arrivinghome": guard let b = bool() else { return nil }; p.nudges.arrivingHome = b
        case "deadlinenudges": guard let b = bool() else { return nil }; p.nudges.deadlines = b
        default: return nil
        }
        return "\(raw) → \(t)"
    }
}
