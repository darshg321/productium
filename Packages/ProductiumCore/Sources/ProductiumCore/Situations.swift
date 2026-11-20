import Foundation

// v1.1 A.2: a situation is the student's words, the days they apply to (a DayRule) and overrides on the planner's
// inputs. Every day is worked out from the same few inputs (wake, busy time, fixed blocks, free windows,
// capacity, free-time target, tasks waiting), so overriding those, over any days, can express anything the app
// could act on, without code for each case.

public struct BlockSpec: Codable, Hashable, Sendable {
    public var title: String
    public var start: TimeOfDay
    public var end: TimeOfDay
    public init(title: String, start: TimeOfDay, end: TimeOfDay) {
        self.title = title
        self.start = start
        self.end = end
    }

    enum K: String, CodingKey { case title, start, end }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        start = try Effect.time(c, .start)
        end = try Effect.time(c, .end)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(title, forKey: .title)
        try c.encode(start.label, forKey: .start)
        try c.encode(end.label, forKey: .end)
    }
}

public enum Effect: Hashable, Sendable {
    /// Busy time the timetable doesn't have ("dentist 9-10", "grandma visiting 10-6").
    case busy(start: TimeOfDay, end: TimeOfDay, title: String)
    /// Time the timetable says is busy but isn't (a spare, a cancelled class).
    case free(start: TimeOfDay, end: TimeOfDay)
    /// That day's periods for an activity (A/B timetables, a moved class).
    case replace(commitment: UUID, with: [BlockSpec])
    /// One planner input (see `SituationInputs`), within its range.
    case setInput(path: String, value: Double)
    /// Pause a task on these days / put it first on these days.
    case hold(item: UUID), boost(item: UUID)
    /// Study this task at exactly this time on these days ("do the essay Saturday 10 to 12"). A fixed study block: the
    /// rest of the plan works around it, and its minutes count toward the task.
    case place(item: UUID, start: TimeOfDay, end: TimeOfDay)
    /// No reminders of this kind (nil: none at all). Wake alarms are left alone: change `wake` instead.
    case mute(nudges: NudgeKind?)
    /// Matters but changes no input ("my parents take my phone at 10"): goes into every AI context.
    case note(String)
}

public struct Situation: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// The student's own words.
    public var said: String
    public var scope: DayRule
    public var effects: [Effect]
    /// Last day it applies (inclusive). Expired situations stay (archived) for the insight pass.
    public var expires: Date?
    public var source: Writer
    public var createdAt: Date

    public init(id: UUID = UUID(), said: String, scope: DayRule, effects: [Effect], expires: Date? = nil,
                source: Writer = .box, createdAt: Date = Date()) {
        self.id = id
        self.said = said
        self.scope = scope
        self.effects = effects
        self.expires = expires
        self.source = source
        self.createdAt = createdAt
    }

    public func isActive(on day: Date, calendar cal: Calendar) -> Bool {
        guard let e = expires else { return true }
        return cal.startOfDay(for: day) <= cal.startOfDay(for: e)
    }

    public var notes: [String] { effects.compactMap { if case .note(let n) = $0 { return n } else { return nil } } }
}

/// Every planner input a situation may set, with its range. The AI is shown this list (A5), so it can't invent one.
public enum SituationInputs {
    public struct Spec: Hashable, Sendable {
        public var path: String
        public var range: ClosedRange<Double>
        public var note: String
    }

    public static let fixed: [Spec] = [
        Spec(path: "planner.capacity", range: 0...2, note: "multiplies the day's study time; 0 = no study that day"),
        Spec(path: "planner.freeTimeMultiplier", range: 0.5...3, note: "multiplies the day's free-time target"),
        Spec(path: "planner.maxBlockMinutes", range: 15...120, note: "longest study block that day"),
        Spec(path: "wake", range: 240...720, note: "wake-up, minutes after midnight (7:30 = 450)"),
        Spec(path: "windDownMinutes", range: 0...120, note: "wind-down before bed that day"),
        Spec(path: "routines.dinnerMinutes", range: 0...120, note: "dinner length that day; 0 = none"),
    ]

    /// For the box prompt: every path with its range.
    public static var promptText: String {
        fixed.map { "\($0.path) \(Knobs.format($0.range.lowerBound))-\(Knobs.format($0.range.upperBound))" }.joined(separator: ", ")
            + ", routines.<get_ready|to_school|from_school>.minutes 0-240 or .enabled 0|1. capacity 0 = no study, wake is minutes after midnight"
    }

    /// `routines.<id>.minutes` (0-240) and `routines.<id>.enabled` (0 or 1) for every routine.
    public static func spec(_ path: String) -> Spec? {
        if let s = fixed.first(where: { $0.path == path }) { return s }
        let parts = path.split(separator: ".")
        guard parts.count == 3, parts[0] == "routines" else { return nil }
        switch parts[2] {
        case "minutes": return Spec(path: path, range: 0...240, note: "how long that routine takes that day")
        case "enabled": return Spec(path: path, range: 0...1, note: "1 on, 0 off that day")
        default: return nil
        }
    }

    public static func clamped(_ path: String, _ v: Double) -> Double? {
        guard let s = spec(path), v.isFinite else { return nil }
        return max(s.range.lowerBound, min(s.range.upperBound, v))
    }
}

/// What the active situations change on one day, resolved (later situations win on the same input).
public struct DayOverrides: Hashable, Sendable {
    public var inputs: [String: Double] = [:]
    public var busy: [(start: TimeOfDay, end: TimeOfDay, title: String, situation: UUID)] = []
    public var free: [(start: TimeOfDay, end: TimeOfDay)] = []
    public var replace: [UUID: [BlockSpec]] = [:]
    public var held: Set<UUID> = []
    public var boosted: Set<UUID> = []
    public var places: [(item: UUID, start: TimeOfDay, end: TimeOfDay, situation: UUID)] = []
    public var muteAll = false
    public var muted: Set<NudgeKind> = []
    public var notes: [String] = []
    public var situations: [UUID] = []
    /// Which situation (its words) set each input, for the plan's reasons.
    public var inputBy: [String: String] = [:]

    public var isEmpty: Bool { situations.isEmpty }

    public static func == (a: DayOverrides, b: DayOverrides) -> Bool {
        a.inputs == b.inputs && a.busy.map { "\($0.start.label)-\($0.end.label) \($0.title)" } == b.busy.map { "\($0.start.label)-\($0.end.label) \($0.title)" }
            && a.free.map { "\($0.start.label)-\($0.end.label)" } == b.free.map { "\($0.start.label)-\($0.end.label)" }
            && a.places.map { "\($0.item)\($0.start.label)\($0.end.label)" } == b.places.map { "\($0.item)\($0.start.label)\($0.end.label)" }
            && a.replace == b.replace && a.held == b.held && a.boosted == b.boosted && a.muteAll == b.muteAll
            && a.muted == b.muted && a.notes == b.notes && a.situations == b.situations
    }

    public func hash(into h: inout Hasher) {
        h.combine(inputs); h.combine(situations); h.combine(held); h.combine(muted)
    }

    public func input(_ path: String) -> Double? { inputs[path] }

    /// The routines as they are that day (`routines.<id>.minutes` / `.enabled`).
    public func routines(_ base: [Routine]) -> [Routine] {
        base.map { r in
            var r = r
            if let m = inputs["routines.\(r.id).minutes"] {
                r.stated = Int(m.rounded())
                r.samples = []
            }
            if let e = inputs["routines.\(r.id).enabled"] { r.enabled = e >= 0.5 }
            return r
        }
    }

    /// The activities as they are that day: a replaced timetable becomes its periods and its span.
    public func commitments(_ base: [Commitment]) -> [Commitment] {
        guard !replace.isEmpty else { return base }
        return base.map { c in
            guard let blocks = replace[c.id], let first = blocks.map(\.start).min(), let last = blocks.map(\.end).max() else { return c }
            var c = c
            c.periods = blocks.map { ActivityPeriod(title: $0.title, start: $0.start, end: $0.end) }
            c.start = first
            c.end = last
            return c
        }
    }
}

public final class SituationResolver {
    public let situations: [Situation]
    public let evaluator: DayRuleEvaluator
    let cal: Calendar
    private var memo: [String: DayOverrides] = [:]

    public init(situations: [Situation], book: DayRuleBook = DayRuleBook(), calendar: Calendar) {
        self.situations = situations.sorted { $0.createdAt < $1.createdAt }
        self.evaluator = DayRuleEvaluator(book: book, calendar: calendar)
        self.cal = calendar
    }

    public func day(_ raw: Date) -> DayOverrides {
        let d = cal.startOfDay(for: raw)
        let k = CapacityLearner.dayKey(d, cal)
        if let m = memo[k] { return m }
        var o = DayOverrides()
        for s in situations where s.isActive(on: d, calendar: cal) && evaluator.matches(s.scope, on: d) {
            o.situations.append(s.id)
            for e in s.effects {
                switch e {
                case let .busy(start, end, title): if end > start { o.busy.append((start, end, title, s.id)) }
                case let .free(start, end): if end > start { o.free.append((start, end)) }
                case let .replace(c, blocks): o.replace[c] = blocks.filter { $0.end > $0.start }
                case let .setInput(path, v):
                    if let v = SituationInputs.clamped(path, v) { o.inputs[path] = v; o.inputBy[path] = s.said }
                case .hold(let i): o.held.insert(i); o.boosted.remove(i)
                case .boost(let i): o.boosted.insert(i); o.held.remove(i)
                case let .place(i, st, en): if en > st { o.places.append((i, st, en, s.id)) }
                case .mute(let k): if let k { o.muted.insert(k) } else { o.muteAll = true }
                case .note(let n): o.notes.append(n)
                }
            }
        }
        memo[k] = o
        return o
    }

    /// The activities as they are on `day`: a rule that doesn't match drops the activity (or one of its periods),
    /// then the day's replaced timetables are swapped in.
    public func commitments(_ base: [Commitment], on day: Date) -> [Commitment] {
        let d = cal.startOfDay(for: day)
        var out: [Commitment] = []
        for var c in base {
            if let w = c.when, !evaluator.matches(w, on: d) { continue }
            if let ps = c.periods, ps.contains(where: { $0.when != nil }) {
                c.periods = ps.filter { $0.when.map { evaluator.matches($0, on: d) } ?? true }
            }
            out.append(c)
        }
        return self.day(d).commitments(out)
    }

    /// Notes from situations that are still active (or start later): they go into every AI context.
    public func activeNotes(from now: Date) -> [String] {
        situations.filter { $0.isActive(on: now, calendar: cal) }.flatMap { s in s.notes.map { "\($0) (\(s.scope.text(cal)))" } }
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

extension Effect {
    /// One short phrase, for the box's context and receipts.
    public var summary: String {
        switch self {
        case let .busy(s, e, t): return "busy \(s.label)–\(e.label) \(t)"
        case let .free(s, e): return "free \(s.label)–\(e.label)"
        case let .replace(c, with): return "timetable for \(Ref.activity(c)): " + with.map { "\($0.title) \($0.start.label)–\($0.end.label)" }.joined(separator: ", ")
        case let .setInput(p, v): return "\(p) = \(Knobs.format(v))"
        case .hold(let i): return "pause task \(Ref.task(i))"
        case .boost(let i): return "prioritise task \(Ref.task(i))"
        case let .place(i, s, e): return "study \(Ref.task(i)) \(s.label)–\(e.label)"
        case .mute(let k): return k.map { "no \($0.rawValue) reminders" } ?? "no reminders"
        case .note(let n): return "note: \(n)"
        }
    }
}

// Compact JSON the AI can write: {"busy":{"start":"9:00","end":"10:00","title":"Dentist"}}, {"setInput":{"path":"wake","value":450}},
// {"hold":"<uuid>"}, {"mute":"all"} / {"mute":"bedtime"}, {"note":"…"}.
extension Effect: Codable {
    enum K: String, CodingKey { case busy, free, replace, setInput, hold, boost, mute, note, place }
    enum F: String, CodingKey { case start, end, title, commitment, with, path, value, task }

    static func time<Key: CodingKey>(_ c: KeyedDecodingContainer<Key>, _ k: Key) throws -> TimeOfDay {
        if let s = try? c.decode(String.self, forKey: k), let t = ClockText.timeOfDay(s) { return t }
        if let t = try? c.decode(TimeOfDay.self, forKey: k) { return t }
        throw DecodingError.dataCorruptedError(forKey: k, in: c, debugDescription: "expected HH:mm")
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        guard let k = c.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "empty effect"))
        }
        switch k {
        case .busy:
            let f = try c.nestedContainer(keyedBy: F.self, forKey: k)
            self = .busy(start: try Effect.time(f, .start), end: try Effect.time(f, .end),
                         title: (try? f.decode(String.self, forKey: .title)) ?? "Busy")
        case .free:
            let f = try c.nestedContainer(keyedBy: F.self, forKey: k)
            self = .free(start: try Effect.time(f, .start), end: try Effect.time(f, .end))
        case .replace:
            let f = try c.nestedContainer(keyedBy: F.self, forKey: k)
            self = .replace(commitment: try f.decode(UUID.self, forKey: .commitment), with: try f.decode([BlockSpec].self, forKey: .with))
        case .setInput:
            let f = try c.nestedContainer(keyedBy: F.self, forKey: k)
            self = .setInput(path: try f.decode(String.self, forKey: .path), value: try f.decode(Double.self, forKey: .value))
        case .place:
            let f = try c.nestedContainer(keyedBy: F.self, forKey: k)
            self = .place(item: try f.decode(UUID.self, forKey: .task), start: try Effect.time(f, .start), end: try Effect.time(f, .end))
        case .hold: self = .hold(item: try c.decode(UUID.self, forKey: k))
        case .boost: self = .boost(item: try c.decode(UUID.self, forKey: k))
        case .mute:
            let s = try c.decode(String.self, forKey: k)
            if s == "all" { self = .mute(nudges: nil) }
            else if let n = NudgeKind(rawValue: s) { self = .mute(nudges: n) }
            else { throw DecodingError.dataCorruptedError(forKey: k, in: c, debugDescription: "unknown reminder kind \(s)") }
        case .note: self = .note(try c.decode(String.self, forKey: k))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        switch self {
        case let .busy(s, e, t):
            var f = c.nestedContainer(keyedBy: F.self, forKey: .busy)
            try f.encode(s.label, forKey: .start); try f.encode(e.label, forKey: .end); try f.encode(t, forKey: .title)
        case let .free(s, e):
            var f = c.nestedContainer(keyedBy: F.self, forKey: .free)
            try f.encode(s.label, forKey: .start); try f.encode(e.label, forKey: .end)
        case let .replace(id, blocks):
            var f = c.nestedContainer(keyedBy: F.self, forKey: .replace)
            try f.encode(id, forKey: .commitment); try f.encode(blocks, forKey: .with)
        case let .setInput(p, v):
            var f = c.nestedContainer(keyedBy: F.self, forKey: .setInput)
            try f.encode(p, forKey: .path); try f.encode(v, forKey: .value)
        case let .place(i, s, e):
            var f = c.nestedContainer(keyedBy: F.self, forKey: .place)
            try f.encode(i, forKey: .task); try f.encode(s.label, forKey: .start); try f.encode(e.label, forKey: .end)
        case .hold(let i): try c.encode(i, forKey: .hold)
        case .boost(let i): try c.encode(i, forKey: .boost)
        case .mute(let k): try c.encode(k?.rawValue ?? "all", forKey: .mute)
        case .note(let n): try c.encode(n, forKey: .note)
        }
    }
}
