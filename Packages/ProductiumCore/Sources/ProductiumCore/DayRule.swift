import Foundation

// v1.1 A.1: which days something applies to. Replaces `weekdays: Set<Int>` so that A/B days, alternating weeks,
// rotations, date ranges and named sets of days ("exam-week", "no-school") need no code written per case.

public indirect enum DayRule: Hashable, Sendable {
    /// 1 = Sunday … 7 = Saturday (Calendar's numbering). An empty set matches no day.
    case weekdays(Set<Int>)
    /// Inclusive range; either end open.
    case dates(from: Date?, until: Date?)
    case on([Date])
    /// Every day except these.
    case except([Date])
    /// Odd or even day of the month.
    case dateParity(odd: Bool)
    /// Alternating weeks: the anchor's week is even (odd: false), the week after is odd.
    case weekParity(anchor: Date, odd: Bool)
    /// The n-th day of a named sequence (`DaySequence`), counted from its anchor: A/B days are
    /// `nthOf("school", 2, 0)` and `nthOf("school", 2, 1)`; a 6-day rotation uses mod 6.
    case nthOf(sequence: String, mod: Int, eq: Int)
    /// A named set of days (`DayRuleBook.labels`).
    case label(String)
    case all([DayRule]), any([DayRule]), not(DayRule)

    public static let always: DayRule = .all([])
    public static let never: DayRule = .any([])
}

/// A counted set of days, e.g. school days: `weekdays 2–6 AND NOT label(no-school)`, anchored on the first A day.
/// A cancelled school day (labelled no-school) stops being counted, so the rotation after it shifts by itself.
public struct DaySequence: Codable, Hashable, Sendable {
    public var name: String
    public var rule: DayRule
    public var anchor: Date

    public init(name: String, rule: DayRule, anchor: Date) {
        self.name = name
        self.rule = rule
        self.anchor = anchor
    }
}

/// Every named sequence and label. Lives in `AppState.dayRules`.
public struct DayRuleBook: Codable, Hashable, Sendable {
    public var sequences: [DaySequence]
    /// Label → day keys (`yyyy-MM-dd`). Stored as keys, not dates, so a label never drifts across time zones.
    public var labels: [String: [String]]

    public init(sequences: [DaySequence] = [], labels: [String: [String]] = [:]) {
        self.sequences = sequences
        self.labels = labels
    }

    public mutating func label(_ name: String, _ days: [Date], calendar cal: Calendar) {
        let keys = Set((labels[name] ?? []) + days.map { CapacityLearner.dayKey($0, cal) })
        labels[name] = keys.sorted()
    }

    /// Rebuilds the `no-school` label from cancelled school days, so a rotation counted over school days
    /// (`nthOf("school", …)` over a `school` sequence that excludes `no-school`) shifts by itself.
    public mutating func syncNoSchool(exceptions: [DayException], commitments: [Commitment], calendar cal: Calendar) {
        let schoolIds = Set(commitments.filter { $0.kind == .school }.map(\.id))
        let days = exceptions.filter { $0.cancelled && ($0.kind == .school || ($0.commitmentId.map(schoolIds.contains) ?? false)) }
            .map { CapacityLearner.dayKey($0.day, cal) }
        labels["no-school"] = days.isEmpty ? nil : Array(Set(days)).sorted()
    }

    public mutating func unlabel(_ name: String, _ days: [Date], calendar cal: Calendar) {
        let drop = Set(days.map { CapacityLearner.dayKey($0, cal) })
        labels[name] = labels[name]?.filter { !drop.contains($0) }
        if labels[name]?.isEmpty == true { labels[name] = nil }
    }
}

/// Evaluates rules for one planning run. Pure apart from its memo, so create one per run (or per day range).
public final class DayRuleEvaluator {
    public let calendar: Calendar
    public let book: DayRuleBook
    private let labelSets: [String: Set<String>]
    private let sequences: [String: DaySequence]
    /// Per sequence: index of each matching day counted from the anchor (filled lazily, forward and backward).
    private var counted: [String: [String: Int]] = [:]
    private var frontier: [String: (forward: Date, nextIndex: Int, backward: Date, prevIndex: Int)] = [:]
    private var evaluating: Set<String> = []

    public init(book: DayRuleBook = DayRuleBook(), calendar: Calendar) {
        self.calendar = calendar
        self.book = book
        self.labelSets = book.labels.mapValues(Set.init)
        self.sequences = Dictionary(book.sequences.map { ($0.name, $0) }, uniquingKeysWith: { _, b in b })
    }

    func key(_ d: Date) -> String { CapacityLearner.dayKey(d, calendar) }

    public func matches(_ rule: DayRule, on raw: Date) -> Bool {
        let day = calendar.startOfDay(for: raw)
        switch rule {
        case .weekdays(let w):
            return w.contains(calendar.component(.weekday, from: day))
        case let .dates(from, until):
            if let from, day < calendar.startOfDay(for: from) { return false }
            if let until, day > calendar.startOfDay(for: until) { return false }
            return true
        case .on(let ds):
            let k = key(day)
            return ds.contains { key($0) == k }
        case .except(let ds):
            let k = key(day)
            return !ds.contains { key($0) == k }
        case .dateParity(let odd):
            return (calendar.component(.day, from: day) % 2 == 1) == odd
        case let .weekParity(anchor, odd):
            guard let a = calendar.dateInterval(of: .weekOfYear, for: anchor)?.start,
                  let w = calendar.dateInterval(of: .weekOfYear, for: day)?.start else { return false }
            // Count days, not seconds, so a week with a DST change (an hour short or long) still counts as one week.
            let days = calendar.dateComponents([.day], from: a, to: w).day ?? 0
            let weeks = Int((Double(days) / 7).rounded(.down))
            return (((weeks % 2) + 2) % 2 == 1) == odd
        case let .nthOf(name, mod, eq):
            guard mod > 0, let i = index(in: name, of: day) else { return false }
            return ((i % mod) + mod) % mod == ((eq % mod) + mod) % mod
        case .label(let l):
            return labelSets[l]?.contains(key(day)) ?? false
        case .all(let rs):
            return rs.allSatisfy { matches($0, on: day) }
        case .any(let rs):
            return rs.contains { matches($0, on: day) }
        case .not(let r):
            return !matches(r, on: day)
        }
    }

    /// The day's position in a sequence (0 = the anchor or the first matching day after it), or nil if the day
    /// isn't in the sequence. Days before the anchor count backwards (-1, -2, …).
    public func index(in name: String, of raw: Date) -> Int? {
        guard let seq = sequences[name], !evaluating.contains(name) else { return nil }
        evaluating.insert(name)
        defer { evaluating.remove(name) }
        let day = calendar.startOfDay(for: raw)
        guard matches(seq.rule, on: day) else { return nil }
        let k = key(day)
        if let i = counted[name]?[k] { return i }
        let anchor = calendar.startOfDay(for: seq.anchor)
        var f = frontier[name] ?? (forward: anchor, nextIndex: 0,
                                   backward: calendar.date(byAdding: .day, value: -1, to: anchor)!, prevIndex: -1)
        var map = counted[name] ?? [:]
        // A sequence that never matches would walk forever: stop after ~3 years.
        var steps = 0
        if day >= anchor {
            while f.forward <= day && steps < 1200 {
                if matches(seq.rule, on: f.forward) { map[key(f.forward)] = f.nextIndex; f.nextIndex += 1 }
                f.forward = calendar.date(byAdding: .day, value: 1, to: f.forward)!
                steps += 1
            }
        } else {
            while f.backward >= day && steps < 1200 {
                if matches(seq.rule, on: f.backward) { map[key(f.backward)] = f.prevIndex; f.prevIndex -= 1 }
                f.backward = calendar.date(byAdding: .day, value: -1, to: f.backward)!
                steps += 1
            }
        }
        frontier[name] = f
        counted[name] = map
        return map[k]
    }

    /// The days in `from…to` (inclusive) a rule matches. What a preview shows ("the next 10 school days").
    public func days(_ rule: DayRule, from: Date, count: Int) -> [Date] {
        var out: [Date] = []
        var d = calendar.startOfDay(for: from)
        var guardSteps = 0
        while out.count < count && guardSteps < 1200 {
            if matches(rule, on: d) { out.append(d) }
            d = calendar.date(byAdding: .day, value: 1, to: d)!
            guardSteps += 1
        }
        return out
    }
}

extension DayRule {
    /// Plain words for receipts and the box context: "Mon–Fri", "every other week", "B days".
    public func text(_ cal: Calendar) -> String {
        let names = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let f = DateFormatter.local("EEE d MMM", cal)
        switch self {
        case .weekdays(let w):
            let s = w.sorted()
            if s == [2, 3, 4, 5, 6] { return "Mon–Fri" }
            if s == [1, 7] { return "weekends" }
            if s == Array(1...7) { return "every day" }
            return s.map { names[max(0, min(7, $0))] }.joined(separator: ", ")
        case let .dates(from, until):
            switch (from, until) {
            case let (a?, b?): return "\(f.string(from: a)) to \(f.string(from: b))"
            case let (a?, nil): return "from \(f.string(from: a))"
            case let (nil, b?): return "until \(f.string(from: b))"
            default: return "every day"
            }
        case .on(let ds): return ds.sorted().map { f.string(from: $0) }.joined(separator: ", ")
        case .except(let ds): return "except " + ds.sorted().map { f.string(from: $0) }.joined(separator: ", ")
        case .dateParity(let odd): return odd ? "odd dates" : "even dates"
        case let .weekParity(a, odd): return "every other week (\(odd ? "not " : "")the week of \(f.string(from: a)))"
        case let .nthOf(seq, mod, eq):
            if mod == 2 { return "\(eq == 0 ? "A" : "B") days (\(seq))" }
            return "\(seq) day \(eq + 1) of \(mod)"
        case .label(let l): return l
        case .all(let rs): return rs.isEmpty ? "every day" : rs.map { $0.text(cal) }.joined(separator: " and ")
        case .any(let rs): return rs.isEmpty ? "never" : rs.map { $0.text(cal) }.joined(separator: " or ")
        case .not(let r): return "not \(r.text(cal))"
        }
    }
}

// Compact, stable JSON: {"weekdays":[2,3]}, {"nthOf":{"sequence":"school","mod":2,"eq":1}}, {"not":{…}}.
// Sets are sorted so exports round-trip byte for byte. The AI writes the same shape.
extension DayRule: Codable {
    enum K: String, CodingKey { case weekdays, dates, on, except, dateParity, weekParity, nthOf, label, all, any, not }
    struct Range: Codable { var from: Date?; var until: Date? }
    struct Week: Codable { var anchor: Date; var odd: Bool }
    struct Nth: Codable { var sequence: String; var mod: Int; var eq: Int }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        guard let k = c.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "empty day rule"))
        }
        switch k {
        case .weekdays: self = .weekdays(Set(try c.decode([Int].self, forKey: k)))
        case .dates: let r = try c.decode(Range.self, forKey: k); self = .dates(from: r.from, until: r.until)
        case .on: self = .on(try c.decode([Date].self, forKey: k))
        case .except: self = .except(try c.decode([Date].self, forKey: k))
        case .dateParity:
            let v = try c.decode(String.self, forKey: k)
            self = .dateParity(odd: v.lowercased() == "odd")
        case .weekParity: let w = try c.decode(Week.self, forKey: k); self = .weekParity(anchor: w.anchor, odd: w.odd)
        case .nthOf: let n = try c.decode(Nth.self, forKey: k); self = .nthOf(sequence: n.sequence, mod: n.mod, eq: n.eq)
        case .label: self = .label(try c.decode(String.self, forKey: k))
        case .all: self = .all(try c.decode([DayRule].self, forKey: k))
        case .any: self = .any(try c.decode([DayRule].self, forKey: k))
        case .not: self = .not(try c.decode(DayRule.self, forKey: k))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        switch self {
        case .weekdays(let w): try c.encode(w.sorted(), forKey: .weekdays)
        case let .dates(from, until): try c.encode(Range(from: from, until: until), forKey: .dates)
        case .on(let ds): try c.encode(ds.sorted(), forKey: .on)
        case .except(let ds): try c.encode(ds.sorted(), forKey: .except)
        case .dateParity(let odd): try c.encode(odd ? "odd" : "even", forKey: .dateParity)
        case let .weekParity(a, odd): try c.encode(Week(anchor: a, odd: odd), forKey: .weekParity)
        case let .nthOf(s, m, e): try c.encode(Nth(sequence: s, mod: m, eq: e), forKey: .nthOf)
        case .label(let l): try c.encode(l, forKey: .label)
        case .all(let rs): try c.encode(rs, forKey: .all)
        case .any(let rs): try c.encode(rs, forKey: .any)
        case .not(let r): try c.encode(r, forKey: .not)
        }
    }
}
