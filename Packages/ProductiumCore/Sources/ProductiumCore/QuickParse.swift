import Foundation

// v1.2 O7: the everyday lane on the phone, no network. Start, stop / done, "X from A to B", mood, "school as usual".
// Certain or pass: anything with a second clause, a future word, an ambiguous task or a time it can't place goes to
// Sonnet instead. It answers with ordinary `BoxOp`s, so the receipt, Undo and telemetry are the box's own.

public struct QuickParsed: Hashable, Sendable {
    public enum Kind: String, Sendable { case start, stop, taskDone, log, mood, confirm }
    public var kind: Kind
    public var ops: [BoxOp]
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

    public init(now: Date, calendar: Calendar, entries: [Entry], items: [WorkItem], tree: CategoryTree = CategoryTree(),
                rules: CategoryRules = CategoryRules(), scrollingApps: [String: Bool] = [:], book: DayRuleBook = DayRuleBook()) {
        self.now = now
        self.calendar = calendar
        self.entries = entries
        self.items = items
        self.tree = tree
        self.rules = rules
        self.scrollingApps = scrollingApps
        self.book = book
    }
}

public enum QuickParse {
    public static func parse(_ raw: String, _ c: QuickContext) -> QuickParsed? {
        let t = normalise(raw)
        guard !t.isEmpty, t.count <= 80, !t.contains("?"), !t.contains("\n") else { return nil }
        return mood(t) ?? confirm(t, c) ?? stop(t, c) ?? start(t, c) ?? log(t, c)
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
    ]

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
        let at = ago(m[2], m[3], now: c.now)
        var f = BoxFields()
        if let at { f.start = stamp(at, c.calendar) }
        if let task = task(named: title, c) {
            return QuickParsed(kind: .start, ops: [BoxOp(.task, .start, ref: Ref.task(task.id), f)])
        }
        // Two tasks share the word ("reading"): which one is a question for Sonnet.
        guard tasksNamed(title, c) == 0 else { return nil }
        f.title = title
        let cat = c.rules.category(for: title, tree: c.tree, scrollingApps: c.scrollingApps)
        f.category = cat
        let topics = CategoryRules.topics(for: title, category: cat, tree: c.tree)
        if !topics.isEmpty { f.topics = topics }
        return QuickParsed(kind: .start, ops: [BoxOp(.entry, .start, f)])
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
