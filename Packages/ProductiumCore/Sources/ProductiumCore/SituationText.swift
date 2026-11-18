import Foundation

// v1.1 A5: the box writes day rules and situations as compact JSON in strings (the response schema is strict, so a
// free-form object can't be declared). This reads that JSON leniently: dates as YYYY-MM-DD, activities and tasks by
// the ids in the context, times as HH:mm.

public struct GapNote: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var at: Date
    /// What the student said.
    public var said: String
    /// What the model wanted to do that the app can't.
    public var wanted: String
    public init(id: UUID = UUID(), at: Date, said: String, wanted: String) {
        self.id = id
        self.at = at
        self.said = said
        self.wanted = wanted
    }
}

public enum SituationText {
    static let dateKeys: Set<String> = ["from", "until", "on", "except", "anchor", "dates"]

    /// Replaces YYYY-MM-DD strings with the numbers `JSONDecoder` reads as dates, and activity / task ids
    /// (`a1b2c3`) with full UUIDs.
    static func fix(_ v: JSONValue, key: String?, tz: TimeZone, commitments: [Commitment], items: [WorkItem]) -> JSONValue {
        switch v {
        case .object(let o):
            return .object(Dictionary(uniqueKeysWithValues: o.map { ($0.key, fix($0.value, key: $0.key, tz: tz, commitments: commitments, items: items)) }))
        case .array(let a):
            return .array(a.map { fix($0, key: key, tz: tz, commitments: commitments, items: items) })
        case .string(let str):
            if let k = key, dateKeys.contains(k), let d = AIMapper.parseDate(str, timeZone: tz) {
                var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
                return .number(cal.startOfDay(for: d).timeIntervalSinceReferenceDate)
            }
            if key == "commitment", let c = commitments.first(where: { Ref.matches(str, prefix: "a", full: $0.id.uuidString) }) {
                return .string(c.id.uuidString)
            }
            if key == "hold" || key == "boost" || key == "task", let i = items.first(where: { Ref.matches(str, prefix: "t", full: $0.id.uuidString) }) {
                return .string(i.id.uuidString)
            }
            return v
        default: return v
        }
    }

    static func json(_ raw: String) -> JSONValue? {
        StructuredRepair.parse(raw)
    }

    public static func rule(_ raw: String?, tz: TimeZone, commitments: [Commitment], items: [WorkItem]) -> DayRule? {
        guard let raw, let j = json(raw) else { return nil }
        return try? fix(j, key: nil, tz: tz, commitments: commitments, items: items).decode(DayRule.self)
    }

    public static func effect(_ raw: String, tz: TimeZone, commitments: [Commitment], items: [WorkItem]) -> Effect? {
        guard let j = json(raw) else { return nil }
        return try? fix(j, key: nil, tz: tz, commitments: commitments, items: items).decode(Effect.self)
    }

    /// The prompt's grammar for rules and effects. Kept next to the parser it describes.
    public static let grammar = """
    Day rules (scope, rule) are JSON: {"weekdays":[2,4]} 1=Sun · {"dates":{"from":"YYYY-MM-DD","until":"YYYY-MM-DD"}} · {"on":[dates]} \
    · {"except":[dates]} · {"dateParity":"odd"} · {"weekParity":{"anchor":date,"odd":false}} · {"nthOf":{"sequence":"school","mod":2,"eq":0}} \
    (A=0, B=1) · {"label":"exam-week"} · {"all":[…]} · {"any":[…]} · {"not":{…}}.
    Effects (JSON strings): {"busy":{"start":"HH:mm","end":"HH:mm","title":"…"}} · {"free":{"start","end"}} · {"replace":{"commitment":id,\
    "with":[{"title","start","end"}]}} · {"setInput":{"path":"…","value":n}} · {"place":{"task":id,"start","end"}} (study it exactly then) · {"hold":taskId} · {"boost":taskId} · {"mute":"all"|"bedtime"} \
    · {"note":"…"} (matters, but nothing the app can change).
    """
}
