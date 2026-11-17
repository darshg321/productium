import Foundation

// MARK: - Brain dump: one box for everything
//
// The student types (or pastes a screenshot of) anything: new deadlines, what they did,
// what changed, how they feel, a question. Claude returns a list of operations plus a reply.
// There are only three operations over a registry of what the AI may change (see
// Capabilities.swift): `upsert` an entity, `delete` one, or `set` a knob. Compound changes,
// like splitting an activity into periods, are registered macros. `DumpApplier` turns them
// into state changes on the device, deterministically and testably, and reports what it
// changed so the UI can show it with an Undo.

public struct DumpApp: Codable, Hashable, Sendable {
    public var name: String
    public var minutes: Int
    public var distracting: Bool?

    public init(name: String, minutes: Int, distracting: Bool? = nil) {
        self.name = name
        self.minutes = minutes
        self.distracting = distracting
    }
}

/// One piece of a `split`: "Period 1 8:30-9:20".
public struct DumpPart: Codable, Hashable, Sendable {
    public var title: String
    public var start: String
    public var end: String
    public var weekdays: [Int]?
    public var color: String?

    public init(title: String, start: String, end: String, weekdays: [Int]? = nil, color: String? = nil) {
        self.title = title
        self.start = start
        self.end = end
        self.weekdays = weekdays
        self.color = color
    }
}

/// One operation from the model.
public struct DumpOp: Codable, Hashable, Sendable {
    /// upsert | delete | set | a macro name (split).
    public var op: String
    public var entity: String?
    /// A reference from the context ("t3f9a2", "a81c0d", "e…", "d…"; a routine's key), exact, so
    /// nothing gets duplicated. Omitted to create.
    public var id: String?
    /// The entity's fields (see the registry). Free-form: unknown names are ignored.
    public var fields: [String: JSONValue]?
    /// For `set`: the knob and its new value as text.
    public var knob: String?
    public var value: String?

    public init(_ op: String, entity: String? = nil, id: String? = nil, fields: [String: JSONValue]? = nil,
                knob: String? = nil, value: String? = nil) {
        self.op = op
        self.entity = entity
        self.id = id
        self.fields = fields
        self.knob = knob
        self.value = value
    }

    public static func upsert(_ entity: String, id: String? = nil, _ fields: [String: JSONValue] = [:]) -> DumpOp {
        DumpOp("upsert", entity: entity, id: id, fields: fields)
    }
    public static func delete(_ entity: String, id: String) -> DumpOp { DumpOp("delete", entity: entity, id: id) }
    public static func set(_ knob: String, _ value: String) -> DumpOp { DumpOp("set", knob: knob, value: value) }
}

/// What the model may say besides operations: lines for about-me.md, and timestamped observations.
public struct DumpEvidence: Codable, Hashable, Sendable {
    /// "left home", "arrived at school", "worked on Waterloo drafts", "at CS club"…
    public var what: String
    /// Local date-times (YYYY-MM-DDTHH:mm). One, or a start and an end.
    public var start: String?
    public var end: String?
    /// Minutes, when they said a duration rather than times ("worked ~200 min").
    public var minutes: Int?
    /// The task it was about (an id), for work done.
    public var task: String?
    /// "travel" | "study" | "activity" | "sleep" | "other": what kind of time it was.
    public var kind: String?

    public init(what: String, start: String? = nil, end: String? = nil, minutes: Int? = nil, task: String? = nil, kind: String? = nil) {
        self.what = what
        self.start = start
        self.end = end
        self.minutes = minutes
        self.task = task
        self.kind = kind
    }
}

public struct DumpResult: Codable, Hashable, Sendable {
    public var ops: [DumpOp]
    public var reply: String
    /// New or changed lines for about-me.md (only what the student literally said).
    public var facts: [AboutMeFact]
    /// Timestamped observations, routed to markers, routines and work done.
    public var evidence: [DumpEvidence]

    public init(ops: [DumpOp], reply: String, facts: [AboutMeFact] = [], evidence: [DumpEvidence] = []) {
        self.ops = ops
        self.reply = reply
        self.facts = facts
        self.evidence = evidence
    }

    enum CodingKeys: String, CodingKey { case ops, reply, facts, evidence }

    /// Lenient: a reply with no operations, or operations with no reply, still counts. One
    /// malformed operation is dropped rather than losing the whole message.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reply = (try? c.decodeIfPresent(String.self, forKey: .reply)) ?? ""
        let raw = (try? c.decodeIfPresent([JSONValue].self, forKey: .ops)) ?? []
        ops = raw.compactMap { try? $0.decode(DumpOp.self) }.filter { !$0.op.isEmpty }
        facts = ((try? c.decodeIfPresent([JSONValue].self, forKey: .facts)) ?? [])
            .compactMap { try? $0.decode(AboutMeFact.self) }.filter { !$0.text.isEmpty }
        evidence = ((try? c.decodeIfPresent([JSONValue].self, forKey: .evidence)) ?? [])
            .compactMap { try? $0.decode(DumpEvidence.self) }.filter { !$0.what.isEmpty }
        guard !reply.isEmpty || !raw.isEmpty || !facts.isEmpty || !evidence.isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "nothing in the answer"))
        }
    }
}

extension DumpResult {
    /// Reads the Inbox answer out of a reply, whatever shape it came back in: the schema's
    /// `{ops, reply}`, a list of operations, one operation on its own, the reply under another name,
    /// or plain prose (shown as the reply, changing nothing). Nil only when there's nothing to
    /// show and nothing to do.
    public static func read(_ res: AIResponse) -> DumpResult? {
        for c in res.candidates {
            let fitted = StructuredRepair.coerce(normalise(c), to: Schemas.dump)
            if var r = try? fitted.decode(DumpResult.self) {
                r.reply = r.reply.trimmingCharacters(in: .whitespacesAndNewlines)
                return r
            }
        }
        // No JSON at all, just sentences: the model answered in words. That's a reply.
        let prose = res.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard res.candidates.isEmpty, prose.filter(\.isLetter).count >= 3, !prose.contains("{"), !prose.contains("```"),
              !["null", "none", "undefined"].contains(prose.lowercased()) else { return nil }
        return DumpResult(ops: [], reply: String(prose.prefix(600)))
    }

    static let opKeys: Set<String> = ["op", "entity", "id", "fields", "knob", "value"]

    /// An operation with its fields beside it instead of under `fields`: move them under.
    static func normaliseOp(_ v: JSONValue) -> JSONValue {
        guard case .object(var o) = v else { return v }
        let plainKeys = Dictionary(o.keys.map { (StructuredRepair.plain($0), $0) }, uniquingKeysWith: { a, _ in a })
        if plainKeys["op"] == nil, let k = plainKeys["operation"] ?? plainKeys["type"] ?? plainKeys["action"] {
            o["op"] = o.removeValue(forKey: k)
        }
        var fields: [String: JSONValue] = [:]
        if let k = plainKeys["fields"], case .object(let f)? = o[k] { fields = f }
        for (k, val) in o where !opKeys.contains(StructuredRepair.plain(k)) && plainKeys["fields"] != k
            && !(k == "operation" || k == "type" || k == "action") {
            fields[k] = val
            o[k] = nil
        }
        if !fields.isEmpty { o[plainKeys["fields"] ?? "fields"] = .object(fields) }
        return .object(o)
    }

    static func normalise(_ v: JSONValue) -> JSONValue {
        if case .array(let a) = v, a.allSatisfy({ if case .object(let o) = $0 { return o["reply"] == nil }; return false }) {
            return .object(["ops": .array(a.map(normaliseOp)), "reply": .string("")])
        }
        guard case .object(var o) = v else { return v }
        let plain = Dictionary(o.keys.map { (StructuredRepair.plain($0), $0) }, uniquingKeysWith: { a, _ in a })
        func value(_ names: [String]) -> JSONValue? { names.lazy.compactMap { plain[$0].flatMap { o[$0] } }.first }
        if plain["reply"] == nil,
           let r = value(["message", "response", "answer", "text", "summary", "content", "output"]), case .string = r {
            o["reply"] = r
        }
        if plain["ops"] == nil {
            if let a = value(["operations", "actions", "action", "changes"]) {
                o["ops"] = a
            } else if case .string(let t)? = value(["op", "operation"]), DumpOpKind(loose: t) != nil {
                // One operation on its own, with the reply (if any) beside its fields.
                var single = o
                single["reply"] = nil
                o = ["ops": .array([.object(single)]), "reply": o["reply"] ?? .string("")]
            }
        }
        let key = plain["ops"] ?? "ops"
        switch o[key] {
        case .array(let a)?: o[key] = .array(a.map(normaliseOp))
        case .object?: o[key] = .array([normaliseOp(o[key]!)])
        default: break
        }
        return .object(o)
    }
}

/// The three operations, plus the registered macros.
public enum DumpOpKind: String, CaseIterable, Sendable {
    case upsert, delete, set, split

    /// The schema's names plus the near misses a model produces ("create", "update", "remove").
    public init?(loose raw: String) {
        let w = raw.lowercased().filter(\.isLetter)
        if let exact = DumpOpKind(rawValue: w) { self = exact; return }
        switch w {
        case "add", "create", "update", "edit", "change", "insert", "new", "modify", "put", "save", "log": self = .upsert
        case "remove", "del", "drop", "cancel": self = .delete
        case "setknob", "setting", "settings", "assign": self = .set
        case "splitactivity", "divide": self = .split
        default: return nil
        }
    }
}

/// The slice of app state the brain dump may change.
public struct DumpState: Sendable {
    public var items: [WorkItem]
    public var commitments: [Commitment]
    public var exceptions: [DayException]
    public var oneOffs: [FixedEvent]
    public var markers: [TimelineEvent]
    public var routines: [Routine]
    public var moods: [MoodEntry]
    public var screen: [ScreenDay]
    public var prefs: Preferences
    /// Tier 2: how the app behaves. Only the reflection may propose changes (see Capabilities).
    public var policy: BehaviourPolicy

    public init(items: [WorkItem], commitments: [Commitment], exceptions: [DayException], oneOffs: [FixedEvent],
                markers: [TimelineEvent], routines: [Routine], moods: [MoodEntry], screen: [ScreenDay], prefs: Preferences,
                policy: BehaviourPolicy = BehaviourPolicy()) {
        self.items = items
        self.commitments = commitments
        self.exceptions = exceptions
        self.oneOffs = oneOffs
        self.markers = markers
        self.routines = routines
        self.moods = moods
        self.screen = screen
        self.prefs = prefs
        self.policy = policy
    }
}

/// An entity's fields, read from an operation. Internal: the applier's handlers read these.
struct DumpFields: Codable, Hashable, Sendable {
    var target: String?
    var title: String?
    var kind: String?
    var subject: String?
    var due: String?
    var estimateMinutes: Int?
    var importance: Int?
    var difficulty: Int?
    var doneMinutes: Int?
    var done: Bool?
    var topics: [String]?
    var notes: String?
    var parent: String?
    var color: String?
    var weekdays: [Int]?
    var start: String?
    var end: String?
    var bufferMinutes: Int?
    var validFrom: String?
    var validUntil: String?
    var parts: [DumpPart]?
    var date: String?
    var cancelled: Bool?
    var wake: String?
    var activity: String?
    var category: String?
    var phase: String?
    var at: String?
    var minutes: Int?
    var enabled: Bool?
    var mood: Int?
    var energy: Int?
    var note: String?
    var screenMinutes: Int?
    var distractingMinutes: Int?
    var apps: [DumpApp]?

    /// The id of the thing (from the op) and its name when there's no id.
    var id: String?

    init() {}

    static let schema: JSONValue = {
        let s = Schemas.str, i = Schemas.int, b: JSONValue = .object(["type": .string("boolean")])
        let part = Schemas.obj(["title": s, "start": s, "end": s, "weekdays": Schemas.arr(i), "color": s],
                               required: ["title", "start", "end"])
        return Schemas.obj([
            "target": s, "title": s, "kind": s, "subject": s, "due": s, "estimateMinutes": i, "importance": i,
            "difficulty": i, "doneMinutes": i, "done": b, "topics": Schemas.arr(s), "notes": s, "parent": s, "color": s,
            "weekdays": Schemas.arr(i), "start": s, "end": s, "bufferMinutes": i, "validFrom": s, "validUntil": s,
            "parts": Schemas.arr(part), "date": s, "cancelled": b, "wake": s, "activity": s, "category": s, "phase": s,
            "at": s, "minutes": i, "enabled": b, "mood": i, "energy": i, "note": s, "screenMinutes": i,
            "distractingMinutes": i,
            "apps": Schemas.arr(Schemas.obj(["name": s, "minutes": i, "distracting": b], required: ["name", "minutes"])),
        ], required: [])
    }()

    /// Fields fitted to their types ("90" → 90, "2, 4" → [2, 4]); unknown names are dropped.
    static func read(_ op: DumpOp) -> DumpFields {
        let raw: JSONValue = .object(op.fields ?? [:])
        var f = (try? StructuredRepair.coerce(raw, to: schema).decode(DumpFields.self)) ?? DumpFields()
        f.id = op.id.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        return f
    }
}
