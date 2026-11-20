import Foundation

// The AI writes day rules as compact JSON in a string (the response schema is strict, so a free-form object can't be
// declared). This reads that JSON leniently: dates as YYYY-MM-DD, tasks by the ids in the context.

public enum DayRuleText {
    static let dateKeys: Set<String> = ["from", "until", "on", "except", "anchor", "dates"]

    static func fix(_ v: JSONValue, key: String?, tz: TimeZone, items: [WorkItem]) -> JSONValue {
        switch v {
        case .object(let o):
            return .object(Dictionary(uniqueKeysWithValues: o.map { ($0.key, fix($0.value, key: $0.key, tz: tz, items: items)) }))
        case .array(let a):
            return .array(a.map { fix($0, key: key, tz: tz, items: items) })
        case .string(let str):
            if let k = key, dateKeys.contains(k), let d = AIMapper.parseDate(str, timeZone: tz) {
                var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
                return .number(cal.startOfDay(for: d).timeIntervalSinceReferenceDate)
            }
            return v
        default: return v
        }
    }

    public static func rule(_ raw: String?, tz: TimeZone, items: [WorkItem] = []) -> DayRule? {
        guard let raw, let j = StructuredRepair.parse(raw) else { return nil }
        return try? fix(j, key: nil, tz: tz, items: items).decode(DayRule.self)
    }

    /// The prompt's grammar for day rules. Kept next to the parser it describes.
    public static let grammar = """
    Day rules (scope, rule) are JSON: {"weekdays":[2,4]} 1=Sun · {"dates":{"from":"YYYY-MM-DD","until":"YYYY-MM-DD"}} · {"on":[dates]} \
    · {"except":[dates]} · {"dateParity":"odd"} · {"weekParity":{"anchor":date,"odd":false}} · {"nthOf":{"sequence":"school","mod":2,"eq":0}} \
    (A=0, B=1) · {"label":"exam-week"} · {"all":[…]} · {"any":[…]} · {"not":{…}}.
    """
}
