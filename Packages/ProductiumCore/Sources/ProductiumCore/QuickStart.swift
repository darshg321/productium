import Foundation

// v1.2 D2: start buttons. The first time you start something by text that isn't a task, it gets a button. Buttons are
// ranked by how likely they are now (hour, weekday, place, what you just finished) from the log itself; one unused for
// 21 days drops to More; one a task or a planned habit covers today is hidden (the task row's Start is the way in).
// D7: something done on most days at a similar time becomes a habit the planner gives a slot.

public struct QuickStart: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var category: CategoryID
    public var topics: [String]
    public var createdAt: Date
    /// You removed it (long press → Remove). It isn't made again from the same title.
    public var removed: Bool

    public init(id: UUID = UUID(), title: String, category: CategoryID, topics: [String] = [], createdAt: Date, removed: Bool = false) {
        self.id = id
        self.title = title
        self.category = category
        self.topics = topics
        self.createdAt = createdAt
        self.removed = removed
    }

    public var key: String { CategoryRules.key(title) }
}

public struct QuickStarts: Codable, Hashable, Sendable {
    public var buttons: [QuickStart] = []
    public init() {}

    public static let unusedDays = 21
    public static let rowSize = 5

    /// Something was started (by text, a notification, Siri). Tasks don't get buttons: their row has Start.
    @discardableResult
    public mutating func noteStart(_ e: Entry, at: Date) -> QuickStart? {
        guard e.taskId == nil, e.source == .you else { return nil }
        let k = CategoryRules.key(e.title)
        guard !k.isEmpty else { return nil }
        if let i = buttons.firstIndex(where: { $0.key == k }) {
            if buttons[i].removed { return nil }
            buttons[i].category = e.category
            if !e.topics.isEmpty { buttons[i].topics = e.topics }
            return buttons[i]
        }
        let b = QuickStart(title: e.title, category: e.category, topics: e.topics, createdAt: at)
        buttons.append(b)
        return b
    }

    public mutating func remove(_ id: UUID) {
        if let i = buttons.firstIndex(where: { $0.id == id }) { buttons[i].removed = true }
    }

    public mutating func rename(_ id: UUID, to title: String) {
        let t = title.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty, let i = buttons.firstIndex(where: { $0.id == id }) { buttons[i].title = t }
    }

    public mutating func recategorise(_ id: UUID, to category: CategoryID) {
        if let i = buttons.firstIndex(where: { $0.id == id }) { buttons[i].category = category }
    }

    public struct Ranked: Hashable, Sendable {
        public var row: [QuickStart]
        public var more: [QuickStart]
    }

    /// Ranked for `now`: the top `rowSize` likely ones, the rest in More. Scored from the log over the last 28 days.
    public func ranked(entries: [Entry], now: Date, place: UUID? = nil, covered: Set<String> = [], book: DayRuleBook = DayRuleBook(),
                       calendar cal: Calendar) -> Ranked {
        let live = buttons.filter { !$0.removed && !covered.contains($0.key) }
        guard !live.isEmpty else { return Ranked(row: [], more: []) }
        let from = cal.date(byAdding: .day, value: -28, to: cal.startOfDay(for: now)) ?? now
        let past = entries.filter { $0.repeats == nil && $0.source != .plan && $0.start >= from && $0.start < now }
        let byKey = Dictionary(grouping: past, by: { CategoryRules.key($0.title) })
        let hourNow = Double(cal.component(.hour, from: now)) + Double(cal.component(.minute, from: now)) / 60
        let weekday = cal.component(.weekday, from: now)
        let weekend = weekday == 1 || weekday == 7
        // What was just finished (in the last 30 minutes), and what usually follows it.
        let justDone = past.filter { ($0.end ?? now) <= now && ($0.end ?? now) > now.addingTimeInterval(-30 * 60) }
            .max { ($0.end ?? now) < ($1.end ?? now) }
        var follows: [String: Int] = [:]
        if let j = justDone {
            let jk = CategoryRules.key(j.title)
            let sorted = past.sorted { $0.start < $1.start }
            for (a, b) in zip(sorted, sorted.dropFirst()) where CategoryRules.key(a.title) == jk
                && b.start.timeIntervalSince(a.end ?? a.start) < 45 * 60 {
                follows[CategoryRules.key(b.title), default: 0] += 1
            }
        }
        func score(_ b: QuickStart) -> Double {
            var s = 0.0
            for e in byKey[b.key] ?? [] {
                let h = Double(cal.component(.hour, from: e.start)) + Double(cal.component(.minute, from: e.start)) / 60
                var d = abs(h - hourNow)
                d = min(d, 24 - d)
                var w = exp(-(d * d) / (2 * 1.5 * 1.5))
                let wd = cal.component(.weekday, from: e.start)
                if wd == weekday { w *= 1.5 } else if (wd == 1 || wd == 7) == weekend { w *= 1.2 }
                if let p = place, e.placeId == p { w *= 2 }
                let age = now.timeIntervalSince(e.start) / 86400
                w *= max(0.3, 1 - age / 40)
                s += w
            }
            s += Double(follows[b.key] ?? 0) * 0.8
            // A brand-new button gets a little room so it can be found.
            if now.timeIntervalSince(b.createdAt) < 2 * 86400 { s += 0.3 }
            return s
        }
        let lastUse = Dictionary(byKey.map { ($0.key, $0.value.map(\.start).max() ?? .distantPast) }, uniquingKeysWith: max)
        let stale = { (b: QuickStart) in
            let last = max(lastUse[b.key] ?? .distantPast, b.createdAt)
            return now.timeIntervalSince(last) > Double(Self.unusedDays) * 86400
        }
        let scored = live.map { ($0, score($0)) }.sorted { ($0.1, $1.0.title) > ($1.1, $0.0.title) }
        let row = scored.filter { !stale($0.0) }.prefix(Self.rowSize).map(\.0)
        let rowIds = Set(row.map(\.id))
        let more = scored.map(\.0).filter { !rowIds.contains($0.id) }.sorted { $0.title < $1.title }
        return Ranked(row: Array(row), more: more)
    }

    /// Title keys a task or a planned habit covers today: their buttons hide (the task row's Start is the way in).
    public static func covered(today day: Date, items: [WorkItem], planned: [Entry], calendar cal: Calendar) -> Set<String> {
        var out = Set<String>()
        for e in planned where cal.isDate(e.start, inSameDayAs: day) {
            if let t = e.taskId, let item = items.first(where: { $0.id == t }), item.isOpen { out.insert(CategoryRules.key(item.title)) }
            if e.taskId == nil, e.source == .plan, e.note == Habits.note { out.insert(CategoryRules.key(e.title)) }
        }
        for t in items where t.isOpen && cal.isDate(t.due, inSameDayAs: day) { out.insert(CategoryRules.key(t.title)) }
        return out
    }
}

/// D7: something you do on most days at a similar time. The planner gives it a slot, so it doesn't collide with study.
public struct Habit: Codable, Hashable, Sendable {
    public var title: String
    public var category: CategoryID
    /// The usual start (median), and the usual length.
    public var start: TimeOfDay
    public var minutes: Int
    public var days: Int

    public var key: String { CategoryRules.key(title) }
}

public enum Habits {
    /// Plan entries a habit made carry this note, so the button they cover can hide.
    public static let note = "Your usual time"
    static let window = 7, needed = 4, spread = 45

    /// Activities on ≥4 of the last 7 days, starting within ±45 minutes of their median. Timetable, calendar, sleep,
    /// school and tasks aren't habits (they're already planned); neither is anything you made a series for.
    public static func detect(_ entries: [Entry], tree: CategoryTree, now: Date, calendar cal: Calendar) -> [Habit] {
        let today = cal.startOfDay(for: now)
        guard let from = cal.date(byAdding: .day, value: -window, to: today) else { return [] }
        let own = entries.filter { $0.repeats != nil && $0.source == .you }.map { CategoryRules.key($0.title) }
        let past = entries.filter {
            $0.repeats == nil && ($0.source == .you || $0.source == .sensor) && $0.taskId == nil && $0.start >= from && $0.start < today
                && $0.end != nil && !tree.isUnder($0.category, CategoryTree.sleep) && !tree.isUnder($0.category, CategoryTree.school)
                && !tree.isUnder($0.category, CategoryTree.unproductive)
        }
        var out: [Habit] = []
        for (k, es) in Dictionary(grouping: past, by: { CategoryRules.key($0.title) }) where !own.contains(k) {
            // One per day: the first of the day.
            let firsts = Dictionary(grouping: es, by: { cal.startOfDay(for: $0.start) }).compactMap { $0.value.min { $0.start < $1.start } }
            guard firsts.count >= needed else { continue }
            let mins = firsts.map { cal.component(.hour, from: $0.start) * 60 + cal.component(.minute, from: $0.start) }.sorted()
            let median = mins[mins.count / 2]
            let near = firsts.filter { e in
                let m = cal.component(.hour, from: e.start) * 60 + cal.component(.minute, from: e.start)
                return abs(m - median) <= spread
            }
            guard near.count >= needed else { continue }
            let lengths = near.map { $0.minutes() }.sorted()
            let latest = near.max { $0.start < $1.start }!
            out.append(Habit(title: latest.title, category: latest.category, start: TimeOfDay(minutes: median),
                             minutes: max(5, lengths[lengths.count / 2]), days: near.count))
        }
        return out.sorted { $0.start < $1.start }
    }
}
