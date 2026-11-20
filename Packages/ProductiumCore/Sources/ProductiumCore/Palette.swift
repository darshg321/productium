import Foundation

public enum Palette {
    public static let names = ["red", "orange", "yellow", "green", "mint", "teal", "cyan", "blue", "indigo",
                               "purple", "pink", "brown", "gray"]

    public static let categories = ["study", "break", "free", "meal", "routine", "wind_down", "sleep", "event", "activity"]
        + CommitmentKind.allCases.map(\.rawValue)

    public static func normalise(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("#") {
            let hex = s.dropFirst()
            return hex.count == 6 && hex.allSatisfy(\.isHexDigit) ? s : nil
        }
        let word = s.replacingOccurrences(of: "grey", with: "gray")
        if names.contains(word) { return word }
        let synonyms: [String: String] = [
            "light blue": "cyan", "sky": "cyan", "sky blue": "cyan", "navy": "indigo", "dark blue": "indigo",
            "violet": "purple", "lavender": "purple", "magenta": "pink", "rose": "pink", "aqua": "cyan",
            "turquoise": "teal", "lime": "green", "light green": "mint", "dark green": "green", "gold": "yellow",
            "amber": "orange", "maroon": "red", "crimson": "red", "tan": "brown", "beige": "brown",
            "silver": "gray", "black": "gray", "white": "gray",
        ]
        if let m = synonyms[word] { return m }
        return names.first { word.contains($0) }
    }

    public static func category(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let r = s.range(of: ":") {
            let head = s[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
            let tail = s[r.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !tail.isEmpty else { return nil }
            if head == "subject" { return "subject:\(tail)" }
            if head == "task" || head == "kind" {
                let k = TaskKind(rawValue: tail) ?? TaskKind(rawValue: String(tail.dropLast()))
                return k.map { "task:\($0.rawValue)" }
            }
            return nil
        }
        let w = s.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        let singular = w.hasSuffix("s") ? String(w.dropLast()) : w
        let map: [String: String] = [
            "study": "study", "work": "study", "focus": "study", "review": "study", "study block": "study",
            "break": "break", "free": "free", "free time": "free", "gap": "free", "meal": "meal", "dinner": "meal",
            "routine": "routine", "commute": "routine", "travel": "routine", "wind down": "wind_down", "winddown": "wind_down",
            "sleep": "sleep", "bed": "sleep", "event": "event", "appointment": "event", "activity": "activity",
            "activitie": "activity", "commitment": "activity", "class": "school", "classe": "school", "period": "school",
        ]
        if let m = map[w] ?? map[singular] { return m }
        if let k = CommitmentKind(rawValue: w) ?? CommitmentKind(rawValue: singular) { return k.rawValue }
        if let k = TaskKind(rawValue: w) ?? TaskKind(rawValue: singular) { return "task:\(k.rawValue)" }
        return nil
    }

    static func key(for kind: BlockKind) -> String? {
        switch kind {
        case .work, .review: return "study"
        case .breakTime: return "break"
        case .free, .gap: return "free"
        case .meal: return "meal"
        case .routine: return "routine"
        case .windDown: return "wind_down"
        case .sleep: return "sleep"
        case .event: return "event"
        case .commitment: return "activity"
        }
    }

    public static func color(for item: WorkItem, parent: WorkItem? = nil, colors: [String: String]) -> String? {
        item.color ?? parent?.color
            ?? item.subject.flatMap { colors["subject:\($0.lowercased().trimmingCharacters(in: .whitespaces))"] }
            ?? parent?.subject.flatMap { colors["subject:\($0.lowercased().trimmingCharacters(in: .whitespaces))"] }
            ?? colors["task:\(item.kind.rawValue)"]
    }

    public static func paint(_ blocks: [PlannedBlock], items: [WorkItem],
                             events: [FixedEvent], colors: [String: String]) -> [PlannedBlock] {
        let byId = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let evs = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return blocks.map { b in
            var out = b
            switch b.kind {
            case .work, .review:
                let item = b.itemId.flatMap { byId[$0] }
                out.color = item.flatMap { color(for: $0, parent: $0.parentId.flatMap { byId[$0] }, colors: colors) } ?? colors["study"]
            case .commitment:
                out.color = colors["activity"]
            case .event:
                out.color = b.sourceId.flatMap { evs[$0]?.color } ?? colors["event"]
            default:
                out.color = key(for: b.kind).flatMap { colors[$0] }
            }
            return out
        }
    }
}
