import Foundation

public enum BeliefConfidence: String, Codable, CaseIterable, Sendable, Comparable {
    case assumed, stated, learning, learned, confirmed

    public var title: String {
        switch self {
        case .assumed: return "Assumed"
        case .stated: return "You said"
        case .learning: return "Learning"
        case .learned: return "Learned"
        case .confirmed: return "Confirmed"
        }
    }

    static let order: [BeliefConfidence] = [.assumed, .learning, .stated, .learned, .confirmed]
    public static func < (a: BeliefConfidence, b: BeliefConfidence) -> Bool {
        order.firstIndex(of: a)! < order.firstIndex(of: b)!
    }
}

public struct Belief: Codable, Hashable, Identifiable, Sendable {
    public var group: String
    public var key: String
    public var label: String
    public var value: Double
    public var unit: String
    public var stated: Double?
    public var samples: Int
    public var evidence: [String]
    public var source: String
    public var updatedAt: Date
    public var bindsTo: String?
    public var prior: Double

    public init(group: String, key: String, label: String, value: Double, unit: String, stated: Double? = nil, samples: Int = 0,
                evidence: [String] = [], source: String = "prior", updatedAt: Date = .distantPast, bindsTo: String? = nil,
                prior: Double? = nil) {
        self.group = group
        self.key = key
        self.label = label
        self.value = value
        self.unit = unit
        self.stated = stated
        self.samples = samples
        self.evidence = evidence
        self.source = source
        self.updatedAt = updatedAt
        self.bindsTo = bindsTo
        self.prior = prior ?? value
    }

    public var id: String { "\(group).\(key)" }

    public var effective: Double {
        if let s = stated, samples < 3 { return s }
        return value
    }

    public var confidence: BeliefConfidence {
        if let s = stated {
            guard samples >= 3 else { return .stated }
            let tolerance = max(abs(s) * 0.15, unit == "min" ? 10 : 0.1)
            return abs(s - value) <= tolerance ? .confirmed : .learned
        }
        switch samples {
        case 0: return .assumed
        case 1, 2: return .learning
        default: return .learned
        }
    }

    public var disagreement: String? {
        guard let s = stated, samples >= 3, confidence == .learned else { return nil }
        return "You said \(Belief.format(s, unit)), it's been \(Belief.format(value, unit)) lately"
    }

    public var display: String { Belief.format(effective, unit) }

    public static func format(_ v: Double, _ unit: String) -> String {
        switch unit {
        case "min":
            let m = Int(v.rounded())
            return m >= 60 ? (m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min") : "\(m) min"
        case "time":
            let m = Int(v.rounded())
            return TimeOfDay(minutes: m).label
        case "×": return String(format: "%.1f×", v)
        case "": return v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
        default: return (v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)) + " " + unit
        }
    }
}

public struct BeliefGroup: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var createdBy: String
    public var createdAt: Date
    public var note: String?
    public init(id: String, title: String, createdBy: String = "app", createdAt: Date = .distantPast, note: String? = nil) {
        self.id = id
        self.title = title
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.note = note
    }
}

public struct Beliefs: Codable, Hashable, Sendable {
    public var items: [Belief]
    public var groups: [BeliefGroup]

    public static let builtInGroups = [
        BeliefGroup(id: "routines", title: "Routines"), BeliefGroup(id: "sleep", title: "Sleep"),
        BeliefGroup(id: "study", title: "Study"), BeliefGroup(id: "places", title: "Places"),
        BeliefGroup(id: "scrolling", title: "Scrolling"), BeliefGroup(id: "patterns", title: "Patterns"),
    ]

    public static let priors: [Belief] = [
        Belief(group: "study", key: "schoolDayCapacity", label: "Study on a school day", value: 180, unit: "min"),
        Belief(group: "study", key: "freeDayCapacity", label: "Study on a free day", value: 300, unit: "min"),
        Belief(group: "study", key: "schoolDayFreeTime", label: "Free time you keep on a school day", value: 60, unit: "min"),
        Belief(group: "study", key: "freeDayFreeTime", label: "Free time you keep on a free day", value: 180, unit: "min"),
        Belief(group: "study", key: "focusMinutes", label: "Focus length", value: 40, unit: "min", bindsTo: "planner.maxBlockMinutes"),
        Belief(group: "study", key: "breakMinutes", label: "Break length", value: 10, unit: "min"),
        Belief(group: "routines", key: "dinnerTime", label: "Dinner", value: 18 * 60 + 30, unit: "time"),
        Belief(group: "routines", key: "dinnerMinutes", label: "Dinner length", value: 30, unit: "min"),
        Belief(group: "sleep", key: "chronotype", label: "Chronotype (hours later than average)", value: Chronotype.late.shiftHours, unit: "h"),
    ]

    public init(items: [Belief] = Beliefs.priors, groups: [BeliefGroup] = Beliefs.builtInGroups) {
        self.items = items
        self.groups = groups
    }

    public subscript(_ id: String) -> Belief? {
        get { items.first { $0.id == id } ?? Beliefs.priors.first { $0.id == id } }
        set {
            guard let newValue else { items.removeAll { $0.id == id }; return }
            if let i = items.firstIndex(where: { $0.id == id }) { items[i] = newValue } else { items.append(newValue) }
        }
    }

    public func value(_ id: String) -> Double { self[id]?.effective ?? 0 }
    public func minutes(_ id: String) -> Int { Int(value(id).rounded()) }

    public mutating func state(_ id: String, _ v: Double, now: Date) -> Bool {
        guard var b = self[id] else { return false }
        b.stated = v
        b.source = "you"
        b.updatedAt = now
        b.evidence.insert("You said \(Belief.format(v, b.unit))", at: 0)
        self[id] = b
        return true
    }

    public mutating func reset(_ id: String) {
        guard var b = self[id] else { return }
        b.value = b.prior
        b.stated = nil
        b.samples = 0
        b.evidence = []
        b.source = "prior"
        self[id] = b
    }

    public func group(_ id: String) -> [Belief] { items.filter { $0.group == id } }

    public static func routines(_ rs: [Routine]) -> [Belief] {
        rs.map { r in
            Belief(group: "routines", key: r.id, label: r.name, value: Double(r.minutes), unit: "min",
                   samples: r.samples.count, evidence: r.samples.suffix(5).map { "Took \($0) min" },
                   source: r.samples.isEmpty ? "prior" : "check-ins", prior: Double(r.defaultMinutes))
        }
    }

    public func summary(routines rs: [Routine]) -> String {
        let all = Beliefs.routines(rs) + items
        return "What the app believes: " + all.map { "\($0.label) \($0.display) (\($0.confidence.title.lowercased()))" }
            .joined(separator: "; ")
    }
}
