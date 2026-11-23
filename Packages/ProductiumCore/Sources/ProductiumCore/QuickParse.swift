import Foundation

// v1.2 O7: the everyday lane on the phone, no network. Start, stop / done, "X from A to B", mood, "school as usual".
// Certain or pass: anything with a second clause, a future word, an ambiguous task or a time it can't place goes to
// Sonnet instead. It answers with ordinary `BoxOp`s, so the receipt, Undo and telemetry are the box's own.

public struct QuickParsed: Hashable, Sendable {
    public enum Kind: String, Sendable { case start, stop, taskDone, log, mood, confirm }
    public var kind: Kind
    public var ops: [BoxOp]
    public init(kind: Kind, ops: [BoxOp]) { self.kind = kind; self.ops = ops }
}

public struct QuickContext: Sendable {
    public var now: Date
    public var calendar: Calendar
    public var entries: [Entry]
    public var items: [WorkItem]
    public var tree: CategoryTree
    public var rules: CategoryRules
    public var scrollingApps: [String: Bool]
    public var book: DayRuleBook
    /// The activity grid's live tiles: "I'm showering" starts the Shower tile.
    public var tiles: [QuickStart]

    public init(now: Date, calendar: Calendar, entries: [Entry], items: [WorkItem], tree: CategoryTree = CategoryTree(),
                rules: CategoryRules = CategoryRules(), scrollingApps: [String: Bool] = [:], book: DayRuleBook = DayRuleBook(),
                tiles: [QuickStart] = []) {
        self.now = now
        self.calendar = calendar
        self.entries = entries
        self.items = items
        self.tree = tree
        self.rules = rules
        self.scrollingApps = scrollingApps
        self.book = book
        self.tiles = tiles
    }
}

public enum QuickParse {
    public static func parse(_ raw: String, _ c: QuickContext) -> QuickParsed? {
        let t = normalise(raw)
        guard !t.isEmpty, t.count <= 80, !t.contains("?"), !t.contains("\n") else { return nil }
        let parsers: [(String, QuickContext) -> QuickParsed?] = [
            { t, _ in mood(t) }, confirm, woke, stop, since, start, doing, log, tileOnly,
        ]
        for parse in parsers { if let r = parse(t, c) { return r } }
        return nil
    }

    // MARK: Text

    static func normalise(_ raw: String) -> String {
        var t = raw.lowercased().replacingOccurrences(of: "’", with: "'")
        t = t.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!")))
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        for p in ["ok so ", "okay so ", "ok ", "okay ", "so ", "alright ", "just "] where t.hasPrefix(p) { t = String(t.dropFirst(p.count)) }
        return t
    }

    static func match(_ s: String, _ pattern: String) -> [String?]? {
        guard let re = try? NSRegularExpression(pattern: "^" + pattern + "$"),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: s).map { String(s[$0]) } }
    }

    /// Words that make a message more than one plain action: a plan, two things, a condition.
    static let notCertain: Set<String> = [
        "tomorrow", "tonight", "later", "next", "every", "each", "until", "till", "and", "then", "but", "if", "when",
        "before", "after", "due", "remind", "should", "need", "needs", "want", "wanna", "gonna", "will", "plan",
        "schedule", "move", "cancel", "skip", "didn't", "didnt", "not", "no", "don't", "dont", "can't", "cant", "maybe",
        "yesterday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "week", "today", "on",
        "by", "for", "with", "about", "again", "also", "instead", "actually", "wrong", "change", "minutes", "min", "hours",
        "is", "are", "was", "were", "be", "timetable", "always", "usually", "around", "thing", "stuff", "it", "kinda",
        "since", "from", "ago", "till", "til",
    ]

    /// A title that ends in a time word ("Productium development since"): never made into a start button.
    public static func endsInTimeWord(_ title: String) -> Bool {
        guard let last = title.lowercased().split(separator: " ").last else { return false }
        return ["since", "from", "ago", "at", "until", "till", "now"].contains(String(last)) || last.contains(":")
    }

    /// A short plain name: 1–4 words, letters (and a digit in a name like "p2"), nothing that makes it a plan.
    static func plainTitle(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        var words = s.split(separator: " ").map(String.init)
        if let f = words.first, ["my", "the", "a", "some", "doing", "on", "at"].contains(f), words.count > 1 { words.removeFirst() }
        guard (1...4).contains(words.count), words.allSatisfy({ w in
            !notCertain.contains(w) && w.allSatisfy { $0.isLetter || $0 == "'" || $0 == "-" || $0 == "&" || $0.isNumber }
                && w.contains(where: \.isLetter)
        }) else { return nil }
        let joined = words.joined(separator: " ")
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }

    static let agoPattern = #"(?: (?:like )?(\d{1,3}|a|an|half an) ?(min|mins|minute|minutes|m|hour|hours|hr|hrs|h) ago| just now| now)?"#

    static func ago(_ n: String?, _ unit: String?, now: Date) -> Date? {
        guard let unit else { return nil }
        let count: Double
        switch n {
        case "a", "an": count = 1
        case "half an": count = 0.5
        default: guard let v = n.flatMap(Double.init) else { return nil }; count = v
        }
        let minutes = unit.hasPrefix("h") ? count * 60 : count
        guard minutes <= 6 * 60 else { return nil }
        return now.addingTimeInterval(-minutes * 60)
    }

    public static func stamp(_ d: Date, _ cal: Calendar) -> String { DateFormatter.local("yyyy-MM-dd HH:mm", cal).string(from: d) }

    // MARK: Tasks

    /// The one open task this names, if exactly one does.
    public static func task(named title: String, _ c: QuickContext) -> WorkItem? {
        let k = CategoryRules.key(title)
        let open = c.items.filter { $0.isOpen && $0.parentId == nil || ($0.isOpen && $0.parentId != nil) }
        let exact = open.filter { CategoryRules.key($0.title) == k }
        if exact.count == 1 { return exact[0] }
        let padded = { (s: String) in " \(CategoryRules.key(s)) " }
        let partial = open.filter { padded($0.title).contains(" \(k) ") }
        return partial.count == 1 && k.count >= 4 ? partial[0] : nil
    }

    static func tasksNamed(_ title: String, _ c: QuickContext) -> Int {
        let k = CategoryRules.key(title)
        return c.items.filter { $0.isOpen && " \(CategoryRules.key($0.title)) ".contains(" \(k) ") }.count
    }

    // MARK: Start

    static func start(_ t: String, _ c: QuickContext) -> QuickParsed? {
        guard let m = match(t, #"(?:i'?m |i am |now )?(?:starting|start|started|beginning|begin|began|doing|working on)(?: on)? (.+?)"# + agoPattern)
        else { return nil }
        guard let title = plainTitle(m[1]) else { return nil }
        if title.lowercased() == "it" || title.lowercased() == "now" { return nil }
        return started(title, at: ago(m[2], m[3], now: c.now), c)
    }

    static func started(_ title: String, at: Date?, _ c: QuickContext, tile: QuickStart? = nil) -> QuickParsed? {
        var f = BoxFields()
        if let at { f.start = stamp(at, c.calendar) }
        if let task = task(named: title, c) {
            return QuickParsed(kind: .start, ops: [BoxOp(.task, .start, ref: Ref.task(task.id), f)])
        }
        // Two tasks share the word ("reading"): which one is a question for Sonnet.
        guard tasksNamed(title, c) == 0 else { return nil }
        f.title = title
        let cat = tile?.category ?? c.rules.category(for: title, tree: c.tree, scrollingApps: c.scrollingApps)
        f.category = cat
        let topics = CategoryRules.topics(for: title, category: cat, tree: c.tree)
        if !topics.isEmpty { f.topics = topics }
        return QuickParsed(kind: .start, ops: [BoxOp(.entry, .start, f)])
    }

    // MARK: v1.5 B3: backfill ("X since 11:15", "X since 10 mins ago", "X 5 minutes ago")

    static let lead = #"(?:i'?ve been |i have been |have been |been |i'?m |i am |i was |was |i )?(?:starting |started |start |doing |working on |on )?"#
    static let agoOnly = #"(?:like )?(\d{1,3}|a|an|half an) ?(min|mins|minute|minutes|m|hour|hours|hr|hrs|h) ago"#

    static func since(_ t: String, _ c: QuickContext) -> QuickParsed? {
        var title: String?, at: Date?
        if let m = match(t, lead + #"(.+?),? (?:since|from|starting at|started at|beginning at) (?:like |about |around )?"# + time) {
            title = m[1]; at = clock(m[2], c)
        } else if let m = match(t, lead + #"(.+?),? (?:since |from |starting |started )?"# + agoOnly) {
            title = m[1]; at = ago(m[2], m[3], now: c.now)
        } else { return nil }
        guard let at, let name = plainTitle(title), !["it", "now"].contains(name.lowercased()) else { return nil }
        return started(tile(for: name.lowercased(), c.tiles)?.title ?? name, at: at, c, tile: tile(for: name.lowercased(), c.tiles))
    }

    /// One clock time, placed at its latest reading in the last 8 hours ("since 11:15" at 11:30 is 11:15 today).
    static func clock(_ s: String?, _ c: QuickContext) -> Date? {
        guard var v = s?.replacingOccurrences(of: ".", with: "") else { return nil }
        if v == "noon" { v = "12pm" }
        if v == "midnight" { v = "12am" }
        var mer: String?
        if v.hasSuffix("am") || v.hasSuffix("pm") { mer = String(v.suffix(2)); v = String(v.dropLast(2)).trimmingCharacters(in: .whitespaces) }
        let p = v.split(separator: ":").compactMap { Int($0) }
        guard let h = p.first, (0...23).contains(h) else { return nil }
        let m = p.count > 1 ? p[1] : 0
        guard (0...59).contains(m) else { return nil }
        var hours: [Int]
        if h > 12 || h == 0 { hours = [h] } else if mer == "am" { hours = [h == 12 ? 0 : h] } else if mer == "pm" { hours = [h == 12 ? 12 : h + 12] }
        else { hours = [h, h == 12 ? 0 : h + 12] }
        let today = c.calendar.startOfDay(for: c.now)
        let days = [today, c.calendar.date(byAdding: .day, value: -1, to: today)!]
        let candidates = days.flatMap { d in hours.compactMap { c.calendar.date(bySettingHour: $0, minute: m, second: 0, of: d) } }
            .filter { $0 <= c.now.addingTimeInterval(120) && c.now.timeIntervalSince($0) <= 8 * 3600 }
        return candidates.max().map { min($0, c.now) }
    }

    /// "at 7:30", "10 min ago", or nothing (now).
    static let whenPattern = #"(?: (?:at |around |like )?"# + time + #"| "# + agoOnly + #")?"#

    static func when(_ m: [String?], from i: Int, _ c: QuickContext) -> Date? {
        if let a = m[i] { return clock(a, c) }
        if m[i + 1] != nil { return ago(m[i + 1], m[i + 2], now: c.now) }
        return c.now
    }

    // MARK: v1.5 B3: "woke up", "out of bed"

    static func woke(_ t: String, _ c: QuickContext) -> QuickParsed? {
        if let m = match(t, #"(?:i )?(?:just )?(?:woke up|woken up|woke|awake|i'?m up|i'?m awake)"# + whenPattern) {
            guard let at = when(m, from: 1, c) else { return nil }
            // The night that covers it (or ends nearest it): it ends then, and you said so.
            let range = DateInterval(start: at.addingTimeInterval(-20 * 3600), end: max(at, c.now).addingTimeInterval(4 * 3600))
            let nights = Days.expand(c.entries, in: range, now: c.now, book: c.book, calendar: c.calendar)
                .filter { c.tree.isUnder($0.category, CategoryTree.sleep) || $0.category == CategoryTree.sleep }
                .filter { $0.start < at && $0.end > at.addingTimeInterval(-3 * 3600) && $0.end < at.addingTimeInterval(5 * 3600) }
            guard let night = nights.max(by: { ($0.rank, $0.start) < ($1.rank, $1.start) }) else { return nil }
            var f = BoxFields()
            f.end = stamp(at, c.calendar)
            f.start = stamp(night.start, c.calendar)
            return QuickParsed(kind: .log, ops: [BoxOp(.entry, .change, ref: night.ref, f)] + confirmSensor(night))
        }
        if let m = match(t, #"(?:i )?(?:just )?(?:out of bed|got out of bed|got up|getting up|i'?m out of bed)"# + whenPattern) {
            guard let at = when(m, from: 1, c) else { return nil }
            let ready = c.tiles.first { $0.category == CategoryTree.gettingReady }
            var f = BoxFields(title: ready?.title ?? "Getting ready", category: ready?.category ?? CategoryTree.gettingReady)
            if at < c.now.addingTimeInterval(-60) { f.start = stamp(at, c.calendar) }
            return QuickParsed(kind: .start, ops: [BoxOp(.entry, .start, f)])
        }
        return nil
    }

    // MARK: v1.5 B3: a tile's name alone ("shower") starts it now

    static func tileOnly(_ t: String, _ c: QuickContext) -> QuickParsed? {
        guard t.split(separator: " ").count <= 3, plainTitle(t) != nil,
              let tile = c.tiles.first(where: { $0.keys.contains(CategoryRules.key(t)) }) else { return nil }
        return started(tile.title, at: nil, c, tile: tile)
    }

    /// "done getting ready" with nothing running: today's assumed occurrence of it ends now (or then), and you said so.
    static func doneOccurrence(_ title: String, at: Date?, _ c: QuickContext) -> QuickParsed? {
        let end = at ?? c.now
        let phrase = title.lowercased()
        let keys = Set([CategoryRules.key(title), stemmed(phrase)])
        let tileCat = tile(for: phrase, c.tiles)?.category
        let today = DateInterval(start: c.calendar.startOfDay(for: c.now), end: c.now)
        let hits = Days.expand(c.entries, in: today, now: c.now, book: c.book, calendar: c.calendar)
            .filter { $0.assumed && $0.start < end && $0.taskId == nil }
            .filter { keys.contains(CategoryRules.key($0.title)) || (tileCat != nil && $0.category == tileCat) }
        guard let d = hits.max(by: { $0.start < $1.start }) else { return nil }
        var f = BoxFields()
        f.start = stamp(d.start, c.calendar)
        f.end = stamp(end, c.calendar)
        return QuickParsed(kind: .log, ops: [BoxOp(.entry, .change, ref: d.ref, f)] + confirmSensor(d))
    }

    /// A sensor's guess you corrected is yours to keep (plan entries and series become your own entries by the change).
    static func confirmSensor(_ d: DayEntry) -> [BoxOp] {
        d.source == .sensor && d.entry.repeats == nil ? [BoxOp(.entry, .confirm, ref: d.ref)] : []
    }

    /// "getting ready" → "get ready", "showering" → "shower".
    static func stemmed(_ phrase: String) -> String {
        let p = CategoryRules.key(phrase)
        guard let first = p.split(separator: " ").first.map(String.init), first.hasSuffix("ing"), first.count >= 5 else { return p }
        var stem = String(first.dropLast(3))
        if stem.count >= 3, let l = stem.last, stem.dropLast().last == l, !"aeiouls".contains(l) { stem = String(stem.dropLast()) }
        return ([stem] + p.split(separator: " ").dropFirst().map(String.init)).joined(separator: " ")
    }

    // MARK: "I'm showering (now)"

    /// -ing words that say how you are, not what you're doing.
    static let notActivities: Set<String> = ["going", "feeling", "thinking", "wondering", "planning", "trying", "being", "hoping",
                                             "looking", "wanting", "needing", "kidding", "assuming", "guessing", "dying", "bring",
                                             "nothing", "something", "everything", "anything", "morning", "evening", "boring",
                                             "starting", "doing", "working", "beginning", "stopping", "finishing", "ending"]

    static func doing(_ t: String, _ c: QuickContext) -> QuickParsed? {
        let words = #"([a-z]+ing)((?: [a-z0-9'&-]+){0,3}?)"#
        let m = match(t, #"(?:i'?m|i am)(?: currently| just| now)? "# + words + #"(?: now| rn| right now)?"#)
            ?? match(t, words + #" (?:now|rn|right now)"#)
        guard let m, let verb = m[1], !notActivities.contains(verb), verb.count >= 5 else { return nil }
        let phrase = verb + (m[2] ?? "")
        if let tile = tile(for: phrase, c.tiles) { return started(tile.title, at: nil, c, tile: tile) }
        guard let title = plainTitle(phrase) else { return nil }
        return started(title, at: nil, c)
    }

    /// The tile "showering" means: the same words, or the -ing word's stem ("napping" → Nap, "exercising" → Exercise).
    static func tile(for phrase: String, _ tiles: [QuickStart]) -> QuickStart? {
        let p = CategoryRules.key(phrase)
        guard let first = p.split(separator: " ").first.map(String.init) else { return nil }
        var stem = String(first.dropLast(3))
        if stem.count >= 3, let l = stem.last, stem.dropLast().last == l, !"aeiouls".contains(l) { stem = String(stem.dropLast()) }
        let rest = p.split(separator: " ").dropFirst().joined(separator: " ")
        let stemmed = ([stem] + (rest.isEmpty ? [] : [rest])).joined(separator: " ")
        return tiles.first { $0.keys.contains(p) || $0.keys.contains(stemmed) }
            ?? (rest.isEmpty && stem.count >= 3 ? tiles.first { t in t.keys.contains { $0 == stem + "e" || $0 == stem + "s" } } : nil)
    }

    // MARK: Stop / done

    static func stop(_ t: String, _ c: QuickContext) -> QuickParsed? {
        guard let m = match(t, #"(?:i'?m |i am |all )?(?:done|stop|stopped|stopping|finished|finish|end|ended|over|that's it|thats it|done for now)(?: with)?(?: (?:the |my )?(.+?))??"# + agoPattern)
        else { return nil }
        let at = ago(m[2], m[3], now: c.now)
        var f = BoxFields()
        if let at { f.end = stamp(at, c.calendar) }
        let running = TimeLog.running(c.entries)
        guard let rawTitle = m[1] else {
            guard running != nil else { return nil }
            return QuickParsed(kind: .stop, ops: [BoxOp(.entry, .stop, f)])
        }
        if ["it", "now", "for", "for now", "for the day", "for today", "that", "this"].contains(rawTitle) {
            guard running != nil else { return nil }
            return QuickParsed(kind: .stop, ops: [BoxOp(.entry, .stop, f)])
        }
        guard let title = plainTitle(rawTitle) else { return nil }
        let k = CategoryRules.key(title)
        // "done reading" while Reading runs: the task is done (that also stops it). A plain entry just stops.
        if let r = running, " \(CategoryRules.key(r.title)) ".contains(" \(k) ") {
            if let tid = r.taskId, at == nil, c.items.contains(where: { $0.id == tid && $0.isOpen }) {
                return QuickParsed(kind: .taskDone, ops: [BoxOp(.task, .done, ref: Ref.task(tid))])
            }
            return QuickParsed(kind: .stop, ops: [BoxOp(.entry, .stop, f)])
        }
        if tasksNamed(title, c) == 0, let d = doneOccurrence(title, at: at, c) { return d }
        guard at == nil, let task = task(named: title, c) else { return nil }
        return QuickParsed(kind: .taskDone, ops: [BoxOp(.task, .done, ref: Ref.task(task.id))])
    }

    // MARK: Log "X from A to B"

    static let time = #"(\d{1,2}(?::\d{2})?(?: ?[ap]\.?m\.?)?|noon|midnight)"#
    static let dash = #" ?(?:to|till|til|until|-|–) ?(?:like )?"#

    static func log(_ t: String, _ c: QuickContext) -> QuickParsed? {
        let lead = #"(?:i was |was |i did |did |i had |had |i went |went )?(?:at |on |doing |to )?"#
        var title: String?, a: String?, b: String?
        if let m = match(t, lead + #"(.+?),? (?:from )?(?:like )?"# + time + dash + time) {
            (title, a, b) = (m[1], m[2], m[3])
        } else if let m = match(t, #"(?:from )?"# + time + dash + time + #",? "# + lead + #"(.+?)"#) {
            (title, a, b) = (m[3], m[1], m[2])
        } else { return nil }
        guard let name = plainTitle(title), let (start, end) = resolve(a, b, c) else { return nil }
        if let task = task(named: name, c) {
            return QuickParsed(kind: .log, ops: [BoxOp(.entry, .add, BoxFields(title: task.title, start: stamp(start, c.calendar),
                                                                                end: stamp(end, c.calendar), task: Ref.task(task.id)))])
        }
        guard tasksNamed(name, c) == 0 else { return nil }
        let cat = c.rules.category(for: name, tree: c.tree, scrollingApps: c.scrollingApps)
        let topics = CategoryRules.topics(for: name, category: cat, tree: c.tree)
        return QuickParsed(kind: .log, ops: [BoxOp(.entry, .add, BoxFields(title: name, start: stamp(start, c.calendar),
                                                                            end: stamp(end, c.calendar), category: cat,
                                                                            topics: topics.isEmpty ? nil : topics))])
    }

    /// Clock words to a past stretch today. Without am / pm, the latest reading that has already ended wins;
    /// if it can't be placed in the past today, it's not certain.
    static func resolve(_ a: String?, _ b: String?, _ c: QuickContext) -> (Date, Date)? {
        func parts(_ s: String?) -> (h: Int, m: Int, mer: String?)? {
            guard var s = s?.replacingOccurrences(of: ".", with: "") else { return nil }
            if s == "noon" { return (12, 0, "pm") }
            if s == "midnight" { return (0, 0, "am") }
            var mer: String?
            if s.hasSuffix("am") || s.hasSuffix("pm") { mer = String(s.suffix(2)); s = String(s.dropLast(2)).trimmingCharacters(in: .whitespaces) }
            let p = s.split(separator: ":").compactMap { Int($0) }
            guard let h = p.first, (0...23).contains(h) else { return nil }
            let m = p.count > 1 ? p[1] : 0
            guard (0...59).contains(m) else { return nil }
            return (h, m, mer)
        }
        guard let x = parts(a), let y = parts(b) else { return nil }
        func hours(_ p: (h: Int, m: Int, mer: String?), other: String?) -> [Int] {
            let mer = p.mer ?? other
            if p.h > 12 || p.h == 0 { return [p.h] }
            switch mer {
            case "am": return [p.h == 12 ? 0 : p.h]
            case "pm": return [p.h == 12 ? 12 : p.h + 12]
            default: return [p.h, p.h == 12 ? 12 : p.h + 12]
            }
        }
        let day = c.calendar.startOfDay(for: c.now)
        func at(_ h: Int, _ m: Int) -> Date { c.calendar.date(bySettingHour: h, minute: m, second: 0, of: day)! }
        var best: (Date, Date)?
        for hs in hours(x, other: y.mer) {
            for he in hours(y, other: nil) {
                let s = at(hs, x.m), e = at(he, y.m)
                guard e > s, e.timeIntervalSince(s) <= 8 * 3600, e <= c.now.addingTimeInterval(5 * 60) else { continue }
                if best == nil || e > best!.1 { best = (s, min(e, c.now)) }
            }
        }
        return best
    }

    // MARK: Mood

    static let emoji: [Character: Int] = ["😀": 5, "😁": 5, "😄": 5, "😊": 5, "🙂": 4, "😌": 4, "😐": 3, "😶": 3, "😕": 2,
                                           "🙁": 2, "😔": 2, "😩": 1, "😞": 1, "😢": 1, "😭": 1]

    static func mood(_ t: String) -> QuickParsed? {
        if t.count == 1, let ch = t.first, let m = emoji[ch] {
            return QuickParsed(kind: .mood, ops: [BoxOp(.mood, .add, BoxFields(mood: m))])
        }
        guard let m = match(t, #"(?:mood|feeling|feel|i feel|i'm feeling|im feeling)(?: is| like| a)?:? ?(\d)(?: ?/ ?5| out of 5)?"#),
              let n = m[1].flatMap(Int.init), (1...5).contains(n) else { return nil }
        return QuickParsed(kind: .mood, ops: [BoxOp(.mood, .add, BoxFields(mood: n))])
    }

    // MARK: Confirm

    static func confirm(_ t: String, _ c: QuickContext) -> QuickParsed? {
        guard match(t, #"(?:school|classes|class)(?: was| went)? (?:as usual|as normal|normal|like usual|like normal|fine|the usual)"#) != nil
        else { return nil }
        let day = Days.dayInterval(c.now, c.calendar)
        let past = DateInterval(start: day.start, end: max(day.start, c.now))
        let refs = Days.expand(c.entries, in: past, now: c.now, book: c.book, calendar: c.calendar)
            .filter { $0.assumed && c.tree.isUnder($0.category, CategoryTree.school) }
            .map(\.ref)
        guard !refs.isEmpty else { return nil }
        return QuickParsed(kind: .confirm, ops: refs.map { BoxOp(.entry, .confirm, ref: $0) })
    }
}
