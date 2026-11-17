import Foundation

public struct DumpApp: Codable, Hashable, Sendable {
    public var name: String
    public var minutes: Int
    public var category: String?

    public init(name: String, minutes: Int, category: String? = nil) {
        self.name = name
        self.minutes = minutes
        self.category = category
    }
}

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

public struct DumpOp: Codable, Hashable, Sendable {
    public var op: String
    public var entity: String?
    public var id: String?
    public var fields: [String: JSONValue]?
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

public struct DumpEvidence: Codable, Hashable, Sendable {
    public var what: String
    public var start: String?
    public var end: String?
    public var minutes: Int?
    public var task: String?
    public var kind: String?
    public var estimated: Bool?

    public init(what: String, start: String? = nil, end: String? = nil, minutes: Int? = nil, task: String? = nil, kind: String? = nil,
                estimated: Bool? = nil) {
        self.estimated = estimated
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
    public var facts: [AboutMeFact]
    public var evidence: [DumpEvidence]

    public init(ops: [DumpOp], reply: String, facts: [AboutMeFact] = [], evidence: [DumpEvidence] = []) {
        self.ops = ops
        self.reply = reply
        self.facts = facts
        self.evidence = evidence
    }

    enum CodingKeys: String, CodingKey { case ops, reply, facts, evidence }

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
    public static func read(_ res: AIResponse) -> DumpResult? {
        for c in res.candidates {
            let fitted = StructuredRepair.coerce(normalise(c), to: Schemas.dump)
            if var r = try? fitted.decode(DumpResult.self) {
                r.reply = r.reply.trimmingCharacters(in: .whitespacesAndNewlines)
                return r
            }
        }
        let prose = res.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard res.candidates.isEmpty, prose.filter(\.isLetter).count >= 3, !prose.contains("{"), !prose.contains("```"),
              !["null", "none", "undefined"].contains(prose.lowercased()) else { return nil }
        return DumpResult(ops: [], reply: String(prose.prefix(600)))
    }

    static let opKeys: Set<String> = ["op", "entity", "id", "fields", "knob", "value"]

    /// Fields written beside the operation instead of under `fields` are moved under it.
    static func normaliseOp(_ v: JSONValue) -> JSONValue {
        guard case .object(let raw) = v else { return v }
        let hasOp = raw.keys.contains { $0.plainKey == "op" }
        var op: [String: JSONValue] = [:], fields: [String: JSONValue] = [:]
        for (k, val) in raw {
            switch k.plainKey {
            case "fields": if case .object(let f) = val { fields.merge(f) { _, explicit in explicit } }
            case "operation", "type", "action" where !hasOp: op["op"] = val
            case let p where opKeys.contains(p): op[p] = val
            default: fields[k] = fields[k] ?? val
            }
        }
        if !fields.isEmpty { op["fields"] = .object(fields) }
        return .object(op)
    }

    static func normalise(_ v: JSONValue) -> JSONValue {
        if case .array(let a) = v, a.allSatisfy({ if case .object(let o) = $0 { return o["reply"] == nil }; return false }) {
            return .object(["ops": .array(a.map(normaliseOp)), "reply": .string("")])
        }
        guard case .object(var o) = v else { return v }
        let plain = Dictionary(o.keys.map { ($0.plainKey, $0) }, uniquingKeysWith: { a, _ in a })
        func value(_ names: [String]) -> JSONValue? { names.lazy.compactMap { plain[$0].flatMap { o[$0] } }.first }
        if plain["reply"] == nil,
           let r = value(["message", "response", "answer", "text", "summary", "content", "output"]), case .string = r {
            o["reply"] = r
        }
        if plain["ops"] == nil {
            if let a = value(["operations", "actions", "action", "changes"]) {
                o["ops"] = a
            } else if case .string(let t)? = value(["op", "operation"]), DumpOpKind(loose: t) != nil {
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

public enum DumpOpKind: String, CaseIterable, Sendable {
    case upsert, delete, set, split

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
    public var policy: BehaviourPolicy
    public var progress: [ProgressEntry]
    public var aboutMe: AboutMe
    public var beliefs: Beliefs
    public var scrollingApps: [String: Bool] = [:]
    public var screenAverages: [ScreenDay] = []

    public init(items: [WorkItem], commitments: [Commitment], exceptions: [DayException], oneOffs: [FixedEvent],
                markers: [TimelineEvent], routines: [Routine], moods: [MoodEntry], screen: [ScreenDay], prefs: Preferences,
                policy: BehaviourPolicy = BehaviourPolicy(), progress: [ProgressEntry] = [], aboutMe: AboutMe = .empty,
                beliefs: Beliefs = Beliefs(), scrollingApps: [String: Bool] = [:], screenAverages: [ScreenDay] = []) {
        self.scrollingApps = scrollingApps
        self.screenAverages = screenAverages
        self.beliefs = beliefs
        self.progress = progress
        self.aboutMe = aboutMe
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
    var atSchool: Bool?
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
    var periods: [DumpPart]?
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
    var period: String?
    var dateLabelShown: String?
    var partial: Bool?
    var apps: [DumpApp]?

    var id: String?

    init() {}

    static let schema: JSONValue = {
        let s = Schemas.str, i = Schemas.int, b: JSONValue = .object(["type": .string("boolean")])
        let part = Schemas.obj(["title": s, "start": s, "end": s, "weekdays": Schemas.arr(i), "color": s],
                               required: ["title", "start", "end"])
        return Schemas.obj([
            "target": s, "title": s, "kind": s, "subject": s, "due": s, "estimateMinutes": i, "importance": i,
            "difficulty": i, "doneMinutes": i, "done": b, "atSchool": b, "topics": Schemas.arr(s), "notes": s, "parent": s, "color": s,
            "weekdays": Schemas.arr(i), "start": s, "end": s, "bufferMinutes": i, "validFrom": s, "validUntil": s,
            "parts": Schemas.arr(part), "periods": Schemas.arr(part), "date": s, "cancelled": b, "wake": s, "activity": s, "category": s, "phase": s,
            "at": s, "minutes": i, "enabled": b, "mood": i, "energy": i, "note": s, "screenMinutes": i,
            "period": s, "dateLabelShown": s, "partial": b,
            "apps": Schemas.arr(Schemas.obj(["name": s, "minutes": i, "category": s], required: ["name", "minutes"])),
        ], required: [])
    }()

    static func read(_ op: DumpOp) -> DumpFields {
        let raw: JSONValue = .object(op.fields ?? [:])
        var f = (try? StructuredRepair.coerce(raw, to: schema).decode(DumpFields.self)) ?? DumpFields()
        f.id = op.id.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        return f
    }
}
