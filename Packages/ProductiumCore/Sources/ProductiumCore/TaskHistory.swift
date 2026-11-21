import Foundation

// v1.2 Part H: every task ends as done, dropped (cleared, or past due never started) or partly (some time, then
// dropped). The record outlives the task. A new task that's like ones you usually drop gets a one-line warning with
// the facts and extra attention in the plan; a kind you usually finish gets nothing extra.

public struct TaskRecord: Codable, Hashable, Identifiable, Sendable {
    public enum Outcome: String, Codable, Sendable { case done, dropped, partly }
    public var id: UUID
    public var title: String
    public var kind: TaskKind
    public var category: CategoryID?
    public var subject: String?
    public var topics: [String]
    public var estimate: Int
    /// Minutes logged on it (entries with its `taskId`, plus progress).
    public var actual: Int
    public var putOff: Int
    /// Days from created to due.
    public var leadDays: Int
    public var createdAt: Date
    public var due: Date
    public var closedAt: Date
    public var outcome: Outcome
    /// Clear's optional "why": no time / not needed / didn't want to.
    public var why: String?
    /// The hour most of its time was logged in (nil: none logged).
    public var hour: Int?

    public var key: String { CategoryRules.key(title) }
}

public struct TaskHistory: Codable, Hashable, Sendable {
    public var records: [TaskRecord] = []
    public init() {}

    static let keep = 300

    /// The record for a task as it ends. Done = done; cleared or expired with no time = dropped; with time = partly.
    public static func record(_ t: WorkItem, cleared: Bool, why: String? = nil, entries: [Entry], now: Date,
                              calendar cal: Calendar) -> TaskRecord {
        let mine = entries.filter { $0.taskId == t.id && $0.source != .plan && !$0.isRunning && $0.repeats == nil }
        let logged = mine.reduce(0) { $0 + $1.minutes(now: now) }
        let actual = max(logged, t.completedMinutes)
        var byHour: [Int: Int] = [:]
        for e in mine { byHour[cal.component(.hour, from: e.start), default: 0] += e.minutes(now: now) }
        let outcome: TaskRecord.Outcome = t.isDone ? .done : (actual >= 5 ? .partly : .dropped)
        let lead = max(0, cal.dateComponents([.day], from: cal.startOfDay(for: t.createdAt), to: cal.startOfDay(for: t.due)).day ?? 0)
        return TaskRecord(id: t.id, title: t.title, kind: t.kind, category: t.category, subject: t.subject, topics: t.topics,
                          estimate: t.estimateMinutes, actual: actual, putOff: t.deferralCount, leadDays: lead, createdAt: t.createdAt,
                          due: t.due, closedAt: now, outcome: outcome, why: why,
                          hour: byHour.max { $0.value < $1.value }?.key)
    }

    public mutating func add(_ r: TaskRecord) {
        records.removeAll { $0.id == r.id }
        records.append(r)
        if records.count > Self.keep { records.removeFirst(records.count - Self.keep) }
    }

    /// Tasks past their due by a day that were never finished: they end as dropped (or partly), once.
    public mutating func expire(_ items: [WorkItem], entries: [Entry], now: Date, calendar cal: Calendar) -> [UUID] {
        var out: [UUID] = []
        for t in items where t.isOpen && t.parentId == nil && t.due < now.addingTimeInterval(-86400) && !records.contains(where: { $0.id == t.id }) {
            add(Self.record(t, cleared: false, entries: entries, now: now, calendar: cal))
            out.append(t.id)
        }
        return out
    }

    /// Records like this task: same category or a shared topic, a shared title word, or the same kind.
    public func similar(to t: WorkItem) -> [TaskRecord] {
        let words = Set(CategoryRules.key(t.title).split(separator: " ").map(String.init).filter { $0.count >= 4 })
        let topics = Set((t.topics + [t.subject].compactMap { $0 }).map { $0.lowercased() })
        return records.filter { r in
            guard r.id != t.id else { return false }
            let rw = Set(r.key.split(separator: " ").map(String.init))
            let sameWord = !words.isDisjoint(with: rw)
            let sameTopic = !topics.isEmpty && !topics.isDisjoint(with: Set((r.topics + [r.subject].compactMap { $0 }).map { $0.lowercased() }))
            let sameCat = t.category != nil && r.category == t.category && t.category != CategoryTree.studying
            return (r.kind == t.kind && (sameWord || sameTopic || t.kind != .other)) || sameWord || sameCat
        }.sorted { $0.closedAt < $1.closedAt }
    }

    public struct Rate: Hashable, Sendable {
        public var dropped: Int
        public var of: Int
        public var usualPutOff: Double
        /// The hour they usually got worked on, when it's late (21:00 or after).
        public var lateHour: Int?
        public var share: Double { of == 0 ? 0 : Double(dropped) / Double(of) }
    }

    public func rate(_ rs: [TaskRecord]) -> Rate {
        let recent = Array(rs.suffix(8))
        let dropped = recent.filter { $0.outcome != .done }.count
        let putOff = recent.isEmpty ? 0 : Double(recent.reduce(0) { $0 + $1.putOff }) / Double(recent.count)
        let hours = recent.compactMap(\.hour).sorted()
        let median = hours.isEmpty ? nil : hours[hours.count / 2]
        return Rate(dropped: dropped, of: recent.count, usualPutOff: putOff, lateHour: median.flatMap { $0 >= 21 ? $0 : nil })
    }

    /// A kind you usually drop (≥3 similar, ≥50% dropped): it gets attention in the plan (H3) and a warning (H2).
    public func atRisk(_ t: WorkItem) -> Bool {
        let r = rate(similar(to: t))
        return r.of >= 3 && r.share >= 0.5
    }

    /// "You've dropped 4 of the last 5 reading tasks; they're usually put off to after 9 pm."
    public func warning(for t: WorkItem) -> String? {
        let s = similar(to: t)
        let r = rate(s)
        guard r.of >= 3, r.share >= 0.5 else { return nil }
        let noun = t.kind == .other ? "tasks like this" : "\(t.kind.rawValue) tasks"
        var line = "You've dropped \(r.dropped) of the last \(r.of) \(noun)"
        if let h = r.lateHour { line += "; they're usually put off to after \(h % 12 == 0 ? 12 : h % 12) pm" }
        else if r.usualPutOff >= 2 { line += "; they usually get put off \(Int(r.usualPutOff.rounded())) times" }
        return line
    }

    /// H2: the facts for new tasks of a kind you usually drop, unless the reply already gives them (code writes the
    /// numbers; the model only says it). nil when there's nothing to add.
    public func note(for newItems: [WorkItem], reply: String) -> String? {
        let lines = newItems.compactMap { warning(for: $0) }.filter { w in
            let nums = w.split(whereSeparator: { !$0.isNumber }).map(String.init)
            return !nums.allSatisfy { reply.contains($0) }
        }
        return lines.isEmpty ? nil : lines.joined(separator: ". ") + "."
    }

    /// One line per kind and category with enough history, for the box's context (H2) and the insight pass (H6):
    /// "reading: dropped 4 of 5, put off 2× on average, worked on after 21:00".
    public func summary(limit: Int = 6) -> [String] {
        var out: [(Int, String)] = []
        for (kind, rs) in Dictionary(grouping: records, by: \.kind) where rs.count >= 3 {
            let r = rate(rs)
            var l = "\(kind.rawValue): dropped \(r.dropped) of \(r.of)"
            if r.usualPutOff >= 1 { l += ", put off \(String(format: "%.0f", r.usualPutOff))× on average" }
            if let h = r.lateHour { l += ", worked on after \(h):00" }
            out.append((r.dropped, l))
        }
        var byHour: [Int: (Int, Int)] = [:]
        for r in records { if let h = r.hour { byHour[h / 3 * 3, default: (0, 0)].1 += 1; if r.outcome != .done { byHour[h / 3 * 3]!.0 += 1 } } }
        for (h, v) in byHour.sorted(by: { $0.key < $1.key }) where v.1 >= 4 && Double(v.0) / Double(v.1) >= 0.5 {
            out.append((v.0, "started \(h):00–\(h + 3):00: dropped \(v.0) of \(v.1)"))
        }
        return out.sorted { $0.0 > $1.0 }.prefix(limit).map(\.1)
    }
}
