import Foundation

// v1.2 D2 / v1.3 A: the activity grid. A seed set of templates ships with the app (onboarding unticks the ones that
// don't apply); starting something new by text adds a tile; the AI keeps the grid tidy (A4). Tiles are ranked by how
// likely they are now (time of day on this kind of day, place, what just ended; recency-weighted) from the log; one
// used once but not for 21 days drops to More; one a task or a planned habit covers today is hidden.
// D7: something done on most days at a similar time becomes a habit the planner gives a slot.

public enum QuickStartOrigin: String, Codable, Sendable {
    case template, you, ai
}

public struct QuickStart: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var category: CategoryID
    public var topics: [String]
    public var createdAt: Date
    /// Hidden (long press → Hide, unticked in onboarding, or the AI's tidy-up). It isn't made again from the same title.
    public var removed: Bool
    public var origin: QuickStartOrigin
    public var symbol: String?
    /// A pinned tile keeps its slot in the grid (0-based).
    public var pin: Int?
    /// You renamed or recategorised it: the AI leaves it alone.
    public var edited: Bool
    /// Other titles that start it (kept when the AI merges "Lunch" into "Eating").
    public var aliases: [String]

    public init(id: UUID = UUID(), title: String, category: CategoryID, topics: [String] = [], createdAt: Date, removed: Bool = false,
                origin: QuickStartOrigin = .you, symbol: String? = nil, pin: Int? = nil, edited: Bool = false, aliases: [String] = []) {
        self.id = id
        self.title = title
        self.category = category
        self.topics = topics
        self.createdAt = createdAt
        self.removed = removed
        self.origin = origin
        self.symbol = symbol
        self.pin = pin
        self.edited = edited
        self.aliases = aliases
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? def }
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        category = v(.category, CategoryTree.other)
        topics = v(.topics, [])
        createdAt = v(.createdAt, Date(timeIntervalSince1970: 0))
        removed = v(.removed, false)
        origin = v(.origin, .you)
        symbol = v(.symbol, nil)
        pin = v(.pin, nil)
        edited = v(.edited, false)
        aliases = v(.aliases, [])
    }

    enum CodingKeys: String, CodingKey { case id, title, category, topics, createdAt, removed, origin, symbol, pin, edited, aliases }

    public var key: String { CategoryRules.key(title) }
    /// Every title key that counts as this tile.
    public var keys: Set<String> { Set([key] + aliases.map(CategoryRules.key)) }
    public var isPinned: Bool { pin != nil }
}

/// A1: the tiles a fresh install starts with, in their tie-break order.
public struct QuickStartTemplate: Hashable, Sendable {
    public var title: String
    public var category: CategoryID
    public var symbol: String
    public var topics: [String]

    public init(_ title: String, _ category: CategoryID, _ symbol: String, topics: [String] = []) {
        self.title = title
        self.category = category
        self.symbol = symbol
        self.topics = topics
    }

    public static let all: [QuickStartTemplate] = [
        .init("Eating", CategoryTree.meals, "fork.knife", topics: ["Breakfast", "Lunch", "Dinner", "Snack"]),
        .init("Walking", CategoryTree.travel, "figure.walk"),
        .init("Commute", CategoryTree.travel, "bus", topics: ["To school", "Home"]),
        .init("Getting ready", CategoryTree.gettingReady, "tshirt"),
        .init("Shower", "essentials.shower", "shower"),
        .init("Homework", CategoryTree.studying, "pencil.line"),
        .init("Studying", CategoryTree.studying, "book"),
        .init("Reading", CategoryTree.studying, "book.closed"),
        .init("Class", CategoryTree.school, "building.2"),
        .init("Practice", CategoryTree.extracurricular, "music.note", topics: ["Instrument", "Sport"]),
        .init("Exercise", CategoryTree.extracurricular, "figure.run"),
        .init("Chores", CategoryTree.essentials, "house"),
        .init("Errands", CategoryTree.essentials, "bag"),
        .init("Hanging out", CategoryTree.free, "person.2"),
        .init("Gaming", CategoryTree.free, "gamecontroller"),
        .init("Social media", CategoryTree.scrolling, "iphone"),
        .init("Video / TV", CategoryTree.unproductive, "play.rectangle"),
        .init("Phone call", CategoryTree.free, "phone"),
        .init("Nap", CategoryTree.sleep, "bed.double"),
        .init("Wind down", CategoryTree.windDown, "moon.haze"),
    ]

    static let order: [String: Int] = Dictionary(all.enumerated().map { (CategoryRules.key($1.title), $0) }, uniquingKeysWith: min)
}

public struct QuickStarts: Codable, Hashable, Sendable {
    public var buttons: [QuickStart] = []
    public init() {}

    public static let unusedDays = 21
    /// A2: tiles visible on Home before "More".
    public static let gridSize = 12
    /// Live Activity buttons and gap answers.
    public static let topSize = 3
    public static let halfLifeDays = 21.0

    public var live: [QuickStart] { buttons.filter { !$0.removed } }

    /// The tile a title starts: a live one by name, then one it was merged into, then a hidden one.
    public func button(for title: String) -> QuickStart? { index(for: title).map { buttons[$0] } }

    func index(for title: String) -> Int? {
        let k = CategoryRules.key(title)
        return buttons.firstIndex { !$0.removed && $0.key == k } ?? buttons.firstIndex { !$0.removed && $0.keys.contains(k) }
            ?? buttons.firstIndex { $0.key == k }
    }

    /// A1: adds the templates that aren't there yet (by title), hidden ones staying hidden.
    public mutating func seedTemplates(at: Date, skip: Set<String> = []) {
        for t in QuickStartTemplate.all where button(for: t.title) == nil {
            buttons.append(QuickStart(title: t.title, category: t.category, topics: t.topics, createdAt: at,
                                      removed: skip.contains(CategoryRules.key(t.title)), origin: .template, symbol: t.symbol))
        }
    }

    /// Something was started (by text, a notification, Siri). Tasks don't get buttons: their row has Start.
    @discardableResult
    public mutating func noteStart(_ e: Entry, at: Date) -> QuickStart? {
        guard e.taskId == nil, e.source == .you, !QuickParse.endsInTimeWord(e.title) else { return nil }
        let k = CategoryRules.key(e.title)
        guard !k.isEmpty else { return nil }
        if let i = index(for: e.title) {
            if buttons[i].removed { return nil }
            if buttons[i].key == k, !buttons[i].edited {
                buttons[i].category = e.category
                if !e.topics.isEmpty { buttons[i].topics = e.topics }
            }
            return buttons[i]
        }
        let b = QuickStart(title: e.title, category: e.category, topics: e.topics, createdAt: at)
        buttons.append(b)
        return b
    }

    /// v1.5: buttons 1.4 made from a misread title ("Productium development since") are hidden.
    @discardableResult
    public mutating func hideTimeWordButtons() -> Int {
        var n = 0
        for i in buttons.indices where buttons[i].origin == .you && !buttons[i].removed && !buttons[i].edited
            && QuickParse.endsInTimeWord(buttons[i].title) {
            buttons[i].removed = true
            buttons[i].pin = nil
            n += 1
        }
        return n
    }

    public mutating func remove(_ id: UUID) {
        if let i = buttons.firstIndex(where: { $0.id == id }) { buttons[i].removed = true; buttons[i].pin = nil }
    }

    public mutating func unhide(_ id: UUID) {
        if let i = buttons.firstIndex(where: { $0.id == id }) { buttons[i].removed = false }
    }

    public mutating func rename(_ id: UUID, to title: String) {
        let t = title.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty, let i = buttons.firstIndex(where: { $0.id == id }), buttons[i].title != t {
            buttons[i].title = t
            buttons[i].edited = true
        }
    }

    public mutating func recategorise(_ id: UUID, to category: CategoryID) {
        if let i = buttons.firstIndex(where: { $0.id == id }), buttons[i].category != category {
            buttons[i].category = category
            buttons[i].edited = true
        }
    }

    /// Pins a tile to `slot` (nil unpins). Another tile pinned there moves to the next free slot.
    public mutating func pin(_ id: UUID, at slot: Int?) {
        guard let i = buttons.firstIndex(where: { $0.id == id }) else { return }
        buttons[i].pin = nil
        guard var s = slot else { return }
        let taken = Set(buttons.compactMap(\.pin))
        while taken.contains(s) { s += 1 }
        buttons[i].pin = s
        buttons[i].edited = true
    }

    public struct Ranked: Hashable, Sendable {
        public var row: [QuickStart]
        public var more: [QuickStart]
        public var top: [QuickStart] { Array(row.filter { !$0.isPinned }.prefix(QuickStarts.topSize)) }
    }

    /// When each tile was last started (over the entries given).
    public func lastUse(_ entries: [Entry]) -> [UUID: Date] {
        var byKey: [String: Date] = [:]
        for e in entries where e.repeats == nil && e.source != .plan {
            let k = CategoryRules.key(e.title)
            byKey[k] = max(byKey[k] ?? .distantPast, e.start)
        }
        var out: [UUID: Date] = [:]
        for b in buttons { if let d = b.keys.compactMap({ byKey[$0] }).max() { out[b.id] = d } }
        return out
    }

    /// A3: ranked for `now`: `size` tiles (pinned ones in their slots), the rest in More. Each past start counts by how close
    /// its time of day is (σ 45 min), whether it was on the same kind of day (school / free, labels) and weekday, here,
    /// and right after what just ended, halving every 3 weeks. Ties fall back to the template order.
    public func ranked(entries: [Entry], now: Date, place: UUID? = nil, covered: Set<String> = [], book: DayRuleBook = DayRuleBook(),
                       schoolDays: Set<Int> = [2, 3, 4, 5, 6], size: Int = QuickStarts.gridSize, calendar cal: Calendar) -> Ranked {
        let live = buttons.filter { !$0.removed && $0.keys.isDisjoint(with: covered) }
        guard !live.isEmpty else { return Ranked(row: [], more: []) }
        let from = cal.date(byAdding: .day, value: -84, to: cal.startOfDay(for: now)) ?? now
        let past = entries.filter { $0.repeats == nil && $0.source != .plan && $0.start >= from && $0.start < now }
        let byKey = Dictionary(grouping: past, by: { CategoryRules.key($0.title) })
        let hourNow = Double(cal.component(.hour, from: now)) + Double(cal.component(.minute, from: now)) / 60
        let weekday = cal.component(.weekday, from: now)
        var kinds: [String: String] = [:]
        func kind(_ d: Date) -> String {
            let k = DayKeys.key(d, cal)
            if let s = kinds[k] { return s }
            let labels = book.labels.filter { $0.value.contains(k) }.map(\.key).sorted()
            let school = schoolDays.contains(cal.component(.weekday, from: d)) && !labels.contains("no-school")
            let s = ([school ? "school" : "free"] + labels.filter { $0 != "no-school" }).joined(separator: "+")
            kinds[k] = s
            return s
        }
        let kindNow = kind(now)
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
            for e in b.keys.flatMap({ byKey[$0] ?? [] }) {
                let h = Double(cal.component(.hour, from: e.start)) + Double(cal.component(.minute, from: e.start)) / 60
                var d = abs(h - hourNow)
                d = min(d, 24 - d)
                var w = exp(-(d * d) / (2 * 0.75 * 0.75))
                if kind(e.start) != kindNow { w *= 0.25 }
                if cal.component(.weekday, from: e.start) == weekday { w *= 1.2 }
                if let p = place, e.placeId == p { w *= 2 }
                w *= pow(0.5, now.timeIntervalSince(e.start) / 86400 / Self.halfLifeDays)
                s += w
            }
            s += Double(b.keys.reduce(0) { $0 + (follows[$1] ?? 0) }) * 0.8
            // A brand-new tile of your own gets a little room so it can be found.
            if b.origin != .template, now.timeIntervalSince(b.createdAt) < 2 * 86400 { s += 0.3 }
            return s
        }
        let lastUse = lastUse(past)
        let stale = { (b: QuickStart) in
            guard b.origin != .template || lastUse[b.id] != nil else { return false }
            let last = max(lastUse[b.id] ?? .distantPast, b.createdAt)
            return now.timeIntervalSince(last) > Double(Self.unusedDays) * 86400
        }
        let order = { (b: QuickStart) in QuickStartTemplate.order[b.key] ?? Int.max }
        let scored = live.map { ($0, score($0)) }.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            if order($0.0) != order($1.0) { return order($0.0) < order($1.0) }
            return $0.0.title < $1.0.title
        }
        var slots = [QuickStart?](repeating: nil, count: size)
        for b in live where b.isPinned { if let p = b.pin, p < size, slots[p] == nil { slots[p] = b } }
        var used = Set(slots.compactMap { $0?.id })
        var queue = scored.filter { !stale($0.0) && !used.contains($0.0.id) }.map(\.0)[...]
        for i in slots.indices where slots[i] == nil {
            guard let b = queue.popFirst() else { break }
            slots[i] = b
            used.insert(b.id)
        }
        let row = slots.compactMap { $0 }
        let more = scored.map(\.0).filter { !used.contains($0.id) }.sorted { $0.title < $1.title }
        return Ranked(row: row, more: more)
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
