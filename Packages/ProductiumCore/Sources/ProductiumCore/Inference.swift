import Foundation

// v1.2 Part N: the phone's data, turned into inferences. Each either logs time by itself (sure), asks one sharp
// question (fairly sure), or becomes a hint in the next "What are you up to?" (a guess). Most of all it notices when
// the plan and the evidence disagree ("You're home, but school's on until 3"). Answers teach the bands per kind.

/// N1: one thing the phone noticed.
public struct Signal: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case visit, motion, steps, pickup, charger, alarmStopped, focus, workout, sleep
    }
    public var kind: Kind
    public var start: Date
    public var end: Date?
    /// Steps in a bucket; minutes snoozed for an alarm; nothing for most.
    public var value: Double?
    /// The motion kind, the Focus name, the workout type, "plugged" / "unplugged".
    public var label: String?
    public var placeId: UUID?
    public var source: String

    public init(_ kind: Kind, start: Date, end: Date? = nil, value: Double? = nil, label: String? = nil, placeId: UUID? = nil,
                source: String) {
        self.kind = kind
        self.start = start
        self.end = end
        self.value = value
        self.label = label
        self.placeId = placeId
        self.source = source
    }
}

/// A workout from Health (M8).
public struct WorkoutSample: Codable, Hashable, Sendable {
    public var start: Date
    public var end: Date
    public var type: String
    public init(start: Date, end: Date, type: String) { self.start = start; self.end = end; self.type = type }
}

/// The alarm's stop button (AlarmKit's intent) or the Shortcuts "alarm stopped" automation (N4).
public struct AlarmStop: Codable, Hashable, Sendable {
    public var ringAt: Date?
    public var stoppedAt: Date
    public init(ringAt: Date?, stoppedAt: Date) { self.ringAt = ringAt; self.stoppedAt = stoppedAt }
    /// Minutes in bed after the alarm first rang (a metric).
    public var snoozeMinutes: Int? { ringAt.map { max(0, Int(stoppedAt.timeIntervalSince($0) / 60)) } }
}

public struct StepBucket: Codable, Hashable, Sendable {
    public var start: Date
    public var end: Date
    public var steps: Int
    public init(start: Date, end: Date, steps: Int) { self.start = start; self.end = end; self.steps = steps }
}

public enum Signals {
    /// Everything into one stream, sorted by time.
    public static func make(visits: [PlaceVisit], book: PlaceBook, motion: [MotionSpan], steps: [StepBucket] = [],
                            pickups: [Date] = [], charger: [(Date, Bool)] = [], alarms: [AlarmStop] = [],
                            focus: [(Date, String, Bool)] = [], workouts: [WorkoutSample] = [], nights: [HealthDay] = []) -> [Signal] {
        var out: [Signal] = []
        out += visits.map { Signal(.visit, start: $0.arrival, end: $0.departure, placeId: book.place(for: $0)?.id, source: "location") }
        out += motion.map { Signal(.motion, start: $0.start, end: $0.end, label: $0.kind.rawValue, source: "motion") }
        out += steps.map { Signal(.steps, start: $0.start, end: $0.end, value: Double($0.steps), source: "pedometer") }
        out += pickups.map { Signal(.pickup, start: $0, source: "phone") }
        out += charger.map { Signal(.charger, start: $0.0, label: $0.1 ? "plugged" : "unplugged", source: "shortcut") }
        out += alarms.map { Signal(.alarmStopped, start: $0.ringAt ?? $0.stoppedAt, end: $0.stoppedAt, value: $0.snoozeMinutes.map(Double.init),
                                   source: "alarm") }
        out += focus.map { Signal(.focus, start: $0.0, label: "\($0.1)\($0.2 ? "" : " off")", source: "shortcut") }
        out += workouts.map { Signal(.workout, start: $0.start, end: $0.end, label: $0.type, source: "health") }
        out += nights.compactMap { d in
            guard let b = d.bedtime, let w = d.wake, d.sleepSource == .health else { return nil }
            return Signal(.sleep, start: b, end: w, label: d.sleepDevice, source: "health")
        }
        return out.sorted { $0.start < $1.start }
    }
}

public struct Inference: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case contradiction, leftEarly, missingUsual, walk, commute, wake, arrival, workout, scrolling
    }
    public enum Band: String, Codable, Sendable { case auto, ask, hint }
    /// Stable: the kind and what it's about, so the same evidence never asks twice.
    public var id: String
    public var kind: Kind
    public var interval: DateInterval
    public var evidence: [String]
    public var confidence: Double
    /// What a yes does (the box's own ops): an entry, a skip, a change.
    public var proposal: [BoxOp]
    public var question: String?
    /// One-tap answers for a question; the first is the proposal.
    public var answers: [String]
    public var band: Band = .hint
}

/// N6: confirm rate per kind (and place) moves a kind between bands. 5 yeses move it up one; 3 noes move it down one.
public struct InferenceLearner: Codable, Hashable, Sendable {
    public var confirmed: [String: Int] = [:]
    public var rejected: [String: Int] = [:]
    public init() {}

    public static let auto = 0.8, ask = 0.5

    static func key(_ k: Inference.Kind, _ place: UUID?) -> String { k.rawValue + (place.map { "@\($0.uuidString.prefix(8))" } ?? "") }

    public mutating func answered(_ k: Inference.Kind, place: UUID? = nil, yes: Bool) {
        if yes { confirmed[Self.key(k, place), default: 0] += 1 } else { rejected[Self.key(k, place), default: 0] += 1 }
    }

    public func adjusted(_ base: Double, _ k: Inference.Kind, place: UUID? = nil) -> Double {
        let keys = [Self.key(k, nil)] + (place.map { [Self.key(k, $0)] } ?? [])
        let yes = keys.reduce(0) { $0 + (confirmed[$1] ?? 0) }, no = keys.reduce(0) { $0 + (rejected[$1] ?? 0) }
        return max(0, min(1, base + 0.045 * Double(yes) - 0.11 * Double(no)))
    }

    public func band(_ confidence: Double) -> Inference.Band {
        confidence >= Self.auto ? .auto : confidence >= Self.ask ? .ask : .hint
    }
}

public struct InferenceInput: Sendable {
    public var now: Date
    public var calendar: Calendar
    public var signals: [Signal]
    public var entries: [Entry]
    public var tree: CategoryTree
    public var book: PlaceBook
    public var dayRules: DayRuleBook
    public var learner: InferenceLearner
    /// Inferences already asked or applied (their ids), so nothing repeats.
    public var done: Set<String>

    public init(now: Date, calendar: Calendar, signals: [Signal], entries: [Entry], tree: CategoryTree = CategoryTree(),
                book: PlaceBook = PlaceBook(), dayRules: DayRuleBook = DayRuleBook(), learner: InferenceLearner = InferenceLearner(),
                done: Set<String> = []) {
        self.now = now
        self.calendar = calendar
        self.signals = signals
        self.entries = entries
        self.tree = tree
        self.book = book
        self.dayRules = dayRules
        self.learner = learner
        self.done = done
    }
}

public enum InferenceEngine {
    /// N2: one detector per row of N.1, over today (and the last few hours of yesterday).
    public static func run(_ x: InferenceInput) -> [Inference] {
        var out: [Inference] = []
        out += contradictions(x)
        out += missingUsual(x)
        out += walks(x)
        out += commutes(x)
        out += wake(x)
        out += arrival(x)
        out += workouts(x)
        return out.filter { !x.done.contains($0.id) }.map { i in
            var i = i
            i.confidence = x.learner.adjusted(i.confidence, i.kind)
            i.band = x.learner.band(i.confidence)
            return i
        }
    }

    static func hm(_ d: Date, _ cal: Calendar) -> String { DateFormatter.local("H:mm", cal).string(from: d) }
    static func stamp(_ d: Date, _ cal: Calendar) -> String { QuickParse.stamp(d, cal) }
    static func clock12(_ d: Date, _ cal: Calendar) -> String {
        let h = cal.component(.hour, from: d), m = cal.component(.minute, from: d)
        return m == 0 ? "\(h % 12 == 0 ? 12 : h % 12)" : "\(h % 12 == 0 ? 12 : h % 12):\(String(format: "%02d", m))"
    }

    /// The place a category usually happens at (≥3 entries there, ≥60%); School also from the timetable's visits.
    static func usualPlace(_ category: CategoryID, _ x: InferenceInput) -> Place? {
        let at = x.entries.filter { $0.placeId != nil && x.tree.isUnder($0.category, category) }
        let counts = Dictionary(grouping: at, by: { $0.placeId! }).mapValues(\.count)
        if let best = counts.max(by: { $0.value < $1.value }), best.value >= 3, Double(best.value) / Double(at.count) >= 0.6 {
            return x.book.places.first { $0.id == best.key }
        }
        // No tagged entries (a timetable is a series): the place you're at most during its occurrences.
        guard category == CategoryTree.school || x.tree.isUnder(category, CategoryTree.school) else { return nil }
        let cal = x.calendar
        var minutes: [UUID: Double] = [:]
        for d in 1...14 {
            guard let day = cal.date(byAdding: .day, value: -d, to: cal.startOfDay(for: x.now)) else { continue }
            for o in Days.on(day, x.entries.filter { $0.source != .plan }, now: x.now, book: x.dayRules, calendar: cal)
            where x.tree.isUnder(o.category, CategoryTree.school) {
                for s in x.signals where s.kind == .visit {
                    guard let p = s.placeId else { continue }
                    let ov = min(o.end, s.end ?? x.now).timeIntervalSince(max(o.start, s.start))
                    if ov > 0 { minutes[p, default: 0] += ov / 60 }
                }
            }
        }
        guard let best = minutes.max(by: { $0.value < $1.value }), best.value >= 3 * 60 else { return nil }
        return x.book.places.first { $0.id == best.key }
    }

    /// Where you were (a visit at a named place) over an interval, and for how long.
    static func atOther(_ iv: DateInterval, not place: UUID, _ x: InferenceInput) -> (Place, DateInterval)? {
        for s in x.signals where s.kind == .visit {
            guard let pid = s.placeId, pid != place, let p = x.book.places.first(where: { $0.id == pid }), p.name != nil else { continue }
            let a = max(iv.start, s.start), b = min(iv.end, s.end ?? x.now)
            if b.timeIntervalSince(a) >= 20 * 60 { return (p, DateInterval(start: a, end: b)) }
        }
        return nil
    }

    // MARK: Plan vs reality

    static func contradictions(_ x: InferenceInput) -> [Inference] {
        let cal = x.calendar
        let today = Days.on(x.now, x.entries.filter { $0.source != .plan }, now: x.now, book: x.dayRules, calendar: cal)
            .filter { $0.busy && !$0.running && $0.mark != .skipped && $0.entry.repeats != nil }
        var out: [Inference] = []
        // School as one block: from the first period to the last.
        let school = today.filter { x.tree.isUnder($0.category, CategoryTree.school) }
        var groups: [(String, CategoryID, DateInterval, [DayEntry])] = []
        if let s = school.map(\.start).min(), let e = school.map(\.end).max() {
            groups.append(("School", CategoryTree.school, DateInterval(start: s, end: e), school))
        }
        for o in today where !x.tree.isUnder(o.category, CategoryTree.school) {
            groups.append((o.title, o.category, DateInterval(start: o.start, end: o.end), [o]))
        }
        let key = DayKeys.key(x.now, cal)
        for (title, cat, iv, occ) in groups where iv.start < x.now {
            guard let usual = usualPlace(cat, x) else { continue }
            let soFar = DateInterval(start: iv.start, end: min(iv.end, x.now))
            if let (other, stay) = atOther(soFar, not: usual.id, x) {
                let isSchool = cat == CategoryTree.school
                let skip: [BoxOp] = isSchool ? [BoxOp(.entry, .skip, BoxFields(day: key, category: CategoryTree.school))]
                                             : occ.map { BoxOp(.entry, .skip, ref: $0.ref) }
                let until = clock12(iv.end, cal)
                out.append(Inference(id: "contradiction|\(title)|\(key)", kind: .contradiction, interval: stay,
                                     evidence: ["at \(other.title) \(hm(stay.start, cal))–\(hm(stay.end, cal))",
                                                "\(title) planned \(hm(iv.start, cal))–\(hm(iv.end, cal))"],
                                     confidence: 0.6, proposal: skip,
                                     question: "You're at \(other.title.lowercased() == "home" ? "home" : other.title), but \(title.lowercased())'s on until \(until). What happened?",
                                     answers: isSchool ? ["Sick", "No school today", "Skipped"] : ["Not today", "Something else"]))
                continue
            }
            // Left early: the visit at the usual place ended well before the end.
            if x.now > iv.start.addingTimeInterval(60 * 60), let v = x.signals.last(where: { $0.kind == .visit && $0.placeId == usual.id
                && $0.start < iv.end && ($0.end ?? .distantFuture) > iv.start }), let left = v.end,
               left < iv.end.addingTimeInterval(-30 * 60), left < x.now.addingTimeInterval(-10 * 60) {
                let rest = occ.filter { $0.start >= left.addingTimeInterval(-10 * 60) }
                out.append(Inference(id: "leftEarly|\(title)|\(key)", kind: .leftEarly, interval: DateInterval(start: left, end: iv.end),
                                     evidence: ["left \(usual.title) at \(hm(left, cal))", "\(title) until \(hm(iv.end, cal))"],
                                     confidence: 0.55, proposal: rest.map { BoxOp(.entry, .skip, ref: $0.ref) },
                                     question: "Left \(title.lowercased()) at \(clock12(left, cal)): done for the day?",
                                     answers: ["Yes", "No, still there"]))
            }
        }
        return out
    }

    static func missingUsual(_ x: InferenceInput) -> [Inference] {
        let cal = x.calendar
        let occ = Days.on(x.now, x.entries.filter { $0.source != .plan && $0.repeats != nil }, now: x.now, book: x.dayRules, calendar: cal)
            .filter { !x.tree.isUnder($0.category, CategoryTree.school) && $0.mark == nil && $0.start < x.now.addingTimeInterval(-30 * 60)
                && $0.end > x.now.addingTimeInterval(-3 * 3600) }
        return occ.compactMap { o in
            guard let p = usualPlace(o.category, x) else { return nil }
            let visited = x.signals.contains { $0.kind == .visit && $0.placeId == p.id && $0.start < o.end && ($0.end ?? x.now) > o.start }
            guard !visited else { return nil }
            return Inference(id: "missing|\(o.id)", kind: .missingUsual, interval: DateInterval(start: o.start, end: o.end),
                             evidence: ["no visit to \(p.title) since \(hm(o.start, cal))"], confidence: 0.5,
                             proposal: [BoxOp(.entry, .skip, ref: o.ref)], question: "No \(o.title.lowercased()) today?",
                             answers: ["Not today", "I'm there"])
        }
    }

    // MARK: Movement (N5)

    static func walks(_ x: InferenceInput) -> [Inference] {
        let cal = x.calendar
        let since = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: x.now)) ?? x.now
        var out: [Inference] = []
        let schoolPlace = usualPlace(CategoryTree.school, x)
        for s in x.signals where s.kind == .motion && (s.label == MotionKind.walking.rawValue || s.label == MotionKind.running.rawValue)
            && s.start >= since {
            guard let end = s.end, end.timeIntervalSince(s.start) >= 8 * 60, end <= x.now else { continue }
            let mins = end.timeIntervalSince(s.start) / 60
            let steps = x.signals.filter { $0.kind == .steps && $0.start >= s.start.addingTimeInterval(-60) && ($0.end ?? $0.start) <= end.addingTimeInterval(60) }
                .reduce(0.0) { $0 + ($1.value ?? 0) }
            let cadence = steps / mins
            // Ends at school before the first class: the walk to school.
            let toSchool = schoolPlace.map { p in x.signals.contains { $0.kind == .visit && $0.placeId == p.id && abs($0.start.timeIntervalSince(end)) < 15 * 60 } } ?? false
            let running = s.label == MotionKind.running.rawValue
            let title = toSchool ? "Walk to school" : running ? "Run" : "Walk"
            let path = toSchool ? "Travel › Walk to school" : running ? "Exercise › Run" : "Exercise › Walk"
            let conf = cadence >= 90 ? 0.85 : cadence >= 60 || steps == 0 ? 0.65 : 0.4
            out.append(Inference(id: "walk|\(Int(s.start.timeIntervalSince1970))", kind: .walk, interval: DateInterval(start: s.start, end: end),
                                 evidence: ["\(running ? "running" : "walking") \(hm(s.start, cal))–\(hm(end, cal))"]
                                    + (steps > 0 ? ["\(Int(steps)) steps (\(Int(cadence))/min)"] : []),
                                 confidence: conf,
                                 proposal: [BoxOp(.entry, .add, BoxFields(title: title, start: stamp(s.start, cal), end: stamp(end, cal), category: path))],
                                 question: "\(title) \(clock12(s.start, cal))–\(clock12(end, cal))?", answers: ["Yes", "Something else"]))
        }
        return out
    }

    static func commutes(_ x: InferenceInput) -> [Inference] {
        let cal = x.calendar
        let since = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: x.now)) ?? x.now
        let visits = x.signals.filter { $0.kind == .visit }
        return x.signals.filter { $0.kind == .motion && $0.label == MotionKind.automotive.rawValue && $0.start >= since }.compactMap { s in
            guard let end = s.end, end.timeIntervalSince(s.start) >= 5 * 60, end <= x.now else { return nil }
            let from = visits.last { ($0.end ?? .distantFuture) <= s.start.addingTimeInterval(10 * 60) && ($0.end ?? .distantFuture) >= s.start.addingTimeInterval(-30 * 60) }
            let to = visits.first { $0.start >= end.addingTimeInterval(-10 * 60) && $0.start <= end.addingTimeInterval(30 * 60) }
            let toName = to?.placeId.flatMap { id in x.book.places.first { $0.id == id }?.name }
            let fromName = from?.placeId.flatMap { id in x.book.places.first { $0.id == id }?.name }
            let title = toName.map { "Drive to \($0)" } ?? "Drive"
            return Inference(id: "commute|\(Int(s.start.timeIntervalSince1970))", kind: .commute, interval: DateInterval(start: s.start, end: end),
                             evidence: ["in a vehicle \(hm(s.start, cal))–\(hm(end, cal))"] + [fromName.map { "from \($0)" }, toName.map { "to \($0)" }].compactMap { $0 },
                             confidence: from != nil && to != nil ? 0.85 : 0.6,
                             proposal: [BoxOp(.entry, .add, BoxFields(title: title, start: stamp(s.start, cal), end: stamp(end, cal), category: CategoryTree.travel))],
                             question: "\(title) \(clock12(s.start, cal))–\(clock12(end, cal))?", answers: ["Yes", "Something else"])
        }
    }

    // MARK: Wake (N4)

    /// The first wake signal this morning sets the night's end: the alarm stopped, Health's wake, the first pickup, the
    /// charger unplugged, or the first motion after a long stillness, whichever came first after 4:00.
    static func wake(_ x: InferenceInput) -> [Inference] {
        let cal = x.calendar
        let day = cal.startOfDay(for: x.now)
        let from = day.addingTimeInterval(4 * 3600), to = min(x.now, day.addingTimeInterval(13 * 3600))
        guard to > from else { return [] }
        var candidates: [(Date, String, Double)] = []
        for s in x.signals {
            switch s.kind {
            case .alarmStopped:
                if let e = s.end, e >= from, e <= to {
                    let snooze = s.value.map { $0 >= 1 ? ", \(Int($0)) min after it first rang" : "" } ?? ""
                    candidates.append((e, "woke \(hm(e, cal)), alarm stopped\(snooze)", 0.9))
                }
            case .sleep: if let e = s.end, e >= from, e <= to { candidates.append((e, "woke \(hm(e, cal)) (Health)", 0.95)) }
            case .pickup: if s.start >= from && s.start <= to { candidates.append((s.start, "first pickup \(hm(s.start, cal))", 0.6)) }
            case .charger: if s.label == "unplugged", s.start >= from, s.start <= to { candidates.append((s.start, "charger unplugged \(hm(s.start, cal))", 0.6)) }
            case .motion:
                if s.label != MotionKind.stationary.rawValue, s.start >= from, s.start <= to,
                   x.signals.contains(where: { $0.kind == .motion && $0.label == MotionKind.stationary.rawValue && ($0.end ?? $0.start) >= s.start.addingTimeInterval(-120)
                       && ($0.end ?? $0.start).timeIntervalSince($0.start) >= 4 * 3600 }) {
                    candidates.append((s.start, "first movement \(hm(s.start, cal))", 0.55))
                }
            default: break
            }
        }
        guard let first = candidates.min(by: { $0.0 < $1.0 }) else { return [] }
        // The sleep entry this morning (measured nights already end right).
        let night = Days.expand(x.entries, in: DateInterval(start: day.addingTimeInterval(-8 * 3600), end: day.addingTimeInterval(13 * 3600)),
                                now: x.now, book: x.dayRules, calendar: cal)
            .filter { x.tree.isUnder($0.category, CategoryTree.sleep) && $0.end > from && $0.source != .health }
            .max { $0.minutes < $1.minutes }
        guard let n = night, abs(n.end.timeIntervalSince(first.0)) >= 5 * 60 else { return [] }
        let conf = candidates.filter { abs($0.0.timeIntervalSince(first.0)) < 15 * 60 }.map(\.2).max() ?? first.2
        let op: BoxOp = n.source == .plan
            ? BoxOp(.entry, .add, BoxFields(title: "Sleep", start: stamp(n.start, cal), end: stamp(first.0, cal), category: CategoryTree.sleep))
            : BoxOp(.entry, .change, ref: n.ref, BoxFields(end: stamp(first.0, cal)))
        return [Inference(id: "wake|\(DayKeys.key(day, cal))", kind: .wake, interval: DateInterval(start: n.start, end: first.0),
                          evidence: [first.1], confidence: conf, proposal: [op],
                          question: "Up at \(clock12(first.0, cal))?", answers: ["Yes", "Something else"])]
    }

    // MARK: Arrival, workouts

    static func arrival(_ x: InferenceInput) -> [Inference] {
        guard TimeLog.running(x.entries) == nil,
              let v = x.signals.last(where: { $0.kind == .visit && $0.end == nil && $0.start > x.now.addingTimeInterval(-30 * 60) }),
              let pid = v.placeId, let p = x.book.places.first(where: { $0.id == pid }) else { return [] }
        let there = x.entries.filter { $0.placeId == pid && $0.repeats == nil && $0.source == .you }
        let byTitle = Dictionary(grouping: there, by: { CategoryRules.key($0.title) })
        guard let top = byTitle.max(by: { $0.value.count < $1.value.count }), top.value.count >= 4 else { return [] }
        let share = Double(top.value.count) / Double(there.count)
        let latest = top.value.max { $0.start < $1.start }!
        return [Inference(id: "arrival|\(Int(v.start.timeIntervalSince1970))", kind: .arrival, interval: DateInterval(start: v.start, end: x.now),
                          evidence: ["at \(p.title) since \(hm(v.start, x.calendar))", "\(latest.title) \(top.value.count) of \(there.count) times here"],
                          confidence: share >= 0.8 ? 0.8 : 0.55,
                          proposal: [BoxOp(.entry, .start, BoxFields(title: latest.title, start: stamp(v.start, x.calendar), category: latest.category))],
                          question: "At \(p.title): start \(latest.title)?", answers: ["Start it", "Something else"])]
    }

    static func workouts(_ x: InferenceInput) -> [Inference] {
        let cal = x.calendar
        let since = cal.date(byAdding: .day, value: -2, to: cal.startOfDay(for: x.now)) ?? x.now
        return x.signals.filter { $0.kind == .workout && $0.start >= since }.compactMap { s in
            guard let end = s.end, end <= x.now else { return nil }
            let type = s.label ?? "Workout"
            return Inference(id: "workout|\(Int(s.start.timeIntervalSince1970))", kind: .workout, interval: DateInterval(start: s.start, end: end),
                             evidence: ["\(type) in Health \(hm(s.start, cal))–\(hm(end, cal))"], confidence: 0.95,
                             proposal: [BoxOp(.entry, .add, BoxFields(title: type, start: stamp(s.start, cal), end: stamp(end, cal),
                                                                      category: "Work › Extracurricular › \(type)"))],
                             question: nil, answers: [])
        }
    }
}

// MARK: - N3 / N7: answers

public enum InferenceAnswers {
    /// The ops an answer makes. "No school today" / "Sick" / "Skipped" skip today's School; "Sick" also logs the time
    /// at home as Sick. A yes is the proposal; "Something else" makes nothing (the typed answer goes to the box).
    public static func ops(for answer: String, _ i: Inference, calendar cal: Calendar) -> [BoxOp] {
        let a = answer.lowercased()
        switch i.kind {
        case .contradiction:
            if a.contains("something") { return [] }
            var ops = i.proposal
            if a.contains("sick") {
                ops.append(BoxOp(.entry, .add, BoxFields(title: "Sick", start: QuickParse.stamp(i.interval.start, cal),
                                                         end: QuickParse.stamp(i.interval.end, cal), category: CategoryTree.other,
                                                         note: "Home sick")))
            }
            return ops
        default:
            let yes = ["yes", "start it", "not today"].contains(a)
            return yes ? i.proposal : []
        }
    }

    /// Questions for the notifications (N7): one at a time, contradictions first.
    public static func next(_ inferences: [Inference]) -> Inference? {
        inferences.filter { $0.band == .ask && $0.question != nil }
            .sorted { ($0.kind == .contradiction ? 0 : 1, $0.interval.start) < ($1.kind == .contradiction ? 0 : 1, $1.interval.start) }
            .first
    }
}

/// What Part N remembers: the learner, what was already asked or applied, and the answers (for the Weekly Note).
public struct InferenceState: Codable, Hashable, Sendable {
    public struct Answer: Codable, Hashable, Sendable {
        public var id: String
        public var kind: Inference.Kind
        public var answer: String
        public var at: Date
        public init(id: String, kind: Inference.Kind, answer: String, at: Date) { self.id = id; self.kind = kind; self.answer = answer; self.at = at }
    }
    public var learner = InferenceLearner()
    /// Inference ids already asked, applied or answered, with when (pruned after 3 days).
    public var done: [String: Date] = [:]
    public var answers: [Answer] = []
    /// The question asked now (its notification id is `q.<id>`).
    public var pending: [Inference] = []
    /// Alarm stops (N4), for the wake signal and the snooze metric.
    public var alarmStops: [AlarmStop] = []
    public init() {}

    public mutating func prune(now: Date) {
        done = done.filter { now.timeIntervalSince($0.value) < 3 * 86400 }
        answers = Array(answers.filter { now.timeIntervalSince($0.at) < 30 * 86400 }.suffix(60))
        pending.removeAll { now.timeIntervalSince($0.interval.end) > 12 * 3600 }
        alarmStops = Array(alarmStops.filter { now.timeIntervalSince($0.stoppedAt) < 60 * 86400 }.suffix(60))
    }
}
