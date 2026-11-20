import Foundation

// v1.2 O6 / O8: the box's operations. A few nouns and verbs with refs, so Sonnet always knows how to say the
// everyday things, and open values (free titles, category paths, any DayRule, notes, rules) so it can say the odd
// ones. The AI may change anything, past included: you may not have tracked something, or want it corrected.
//
// There are no refusals for "risky" things. An op that would
//   - remove a whole repeating series,
//   - remove or overwrite an hour or more of time you logged yourself, or
//   - add a full-screen alarm (Part J)
// is held, and shown to you as one Approve / Decline. Everything applied has a receipt line and Undo.
// Calendar is never written: "change" on a calendar event = skip it there and make it your own entry.

public struct BoxFields: Codable, Hashable, Sendable {
    // Time
    public var title: String?
    /// ISO date-time, `yyyy-MM-dd HH:mm`, `HH:mm` (on `day`, else today), or `now`.
    public var start: String?
    public var end: String?
    /// `yyyy-MM-dd`: the day for `HH:mm` times and for `skip`.
    public var day: String?
    /// A category id ("work.studying") or a path ("Work › Extracurricular › Volleyball"); missing nodes are created.
    public var category: String?
    public var topics: [String]?
    public var note: String?
    public var repeats: DayRule?
    public var from: String?
    public var until: String?
    /// Open time (a spare, lunch): you're there, but light work can be planned in it.
    public var open: Bool?
    /// "notify", "notify:10", "alarm:30", "alarm@end", "none".
    public var alert: String?
    /// A task ref: this entry is time for that task.
    public var task: String?
    // Tasks
    public var due: String?
    public var minutes: Int?
    public var kind: String?
    public var difficulty: Int?
    public var importance: Int?
    public var maxMinutesPerDay: Int?
    public var firstStep: String?
    /// Not scheduled before this (`yyyy-MM-dd` or a time).
    public var notBefore: String?
    // Rules
    public var text: String?
    public var said: String?
    public var limits: PlannerLimits?
    // Side ops (`BoxSideOps`): mood 1-5 with energy, a Screen Time reading.
    public var mood: Int?
    public var energy: Int?
    public var screen: BoxScreen?

    public init(title: String? = nil, start: String? = nil, end: String? = nil, day: String? = nil, category: String? = nil,
                topics: [String]? = nil, note: String? = nil, repeats: DayRule? = nil, from: String? = nil,
                until: String? = nil, open: Bool? = nil, alert: String? = nil, task: String? = nil, due: String? = nil,
                minutes: Int? = nil, kind: String? = nil, difficulty: Int? = nil, importance: Int? = nil,
                maxMinutesPerDay: Int? = nil, firstStep: String? = nil, notBefore: String? = nil, text: String? = nil,
                said: String? = nil, limits: PlannerLimits? = nil, mood: Int? = nil, energy: Int? = nil, screen: BoxScreen? = nil) {
        self.mood = mood
        self.energy = energy
        self.screen = screen
        self.title = title
        self.start = start
        self.end = end
        self.day = day
        self.category = category
        self.topics = topics
        self.note = note
        self.repeats = repeats
        self.from = from
        self.until = until
        self.open = open
        self.alert = alert
        self.task = task
        self.due = due
        self.minutes = minutes
        self.kind = kind
        self.difficulty = difficulty
        self.importance = importance
        self.maxMinutesPerDay = maxMinutesPerDay
        self.firstStep = firstStep
        self.notBefore = notBefore
        self.text = text
        self.said = said
        self.limits = limits
    }
}

public struct BoxOp: Codable, Hashable, Sendable {
    public enum Noun: String, Codable, CaseIterable, Sendable { case entry, task, rule, setting, mood, screen_time, query }
    public enum Verb: String, Codable, CaseIterable, Sendable {
        case add, change, remove, start, stop, skip, confirm, done, drop
    }

    public var noun: Noun
    public var verb: Verb
    /// `e…`, `e…@yyyy-MM-dd`, `t…`, `u…`.
    public var ref: String?
    public var fields: BoxFields

    public init(_ noun: Noun, _ verb: Verb, ref: String? = nil, _ fields: BoxFields = BoxFields()) {
        self.noun = noun
        self.verb = verb
        self.ref = ref
        self.fields = fields
    }
}

/// An op waiting for your Approve / Decline, with why.
public struct HeldOp: Hashable, Sendable {
    public var op: BoxOp
    public var why: String
}

/// What the box's turn did, line by line, plus what Undo needs.
public struct BoxReceipt: Hashable, Sendable {
    public var lines: [String] = []
    public var warnings: [String] = []
    public var problems: [String] = []
    public var held: [HeldOp] = []
    /// Entries as they were before this turn (nil = didn't exist). Undo restores these.
    public var before: [UUID: Entry?] = [:]
    public var rulesBefore: [UUID: Rule?] = [:]
    public var tasksBefore: [UUID: WorkItem?] = [:]
    public var categoriesBefore: CategoryTree?
    public var dayRulesBefore: DayRuleBook?
    public init() {}
}

/// The parts of `AppState` the box works on.
public struct BoxState: Sendable {
    public var entries: [Entry]
    public var rules: [Rule]
    public var items: [WorkItem]
    public var categories: CategoryTree
    public var dayRules: DayRuleBook
    public var sleepFloorMinutes: Int

    public init(entries: [Entry] = [], rules: [Rule] = [], items: [WorkItem] = [], categories: CategoryTree = CategoryTree(),
                dayRules: DayRuleBook = DayRuleBook(), sleepFloorMinutes: Int = 420) {
        self.entries = entries
        self.rules = rules
        self.items = items
        self.categories = categories
        self.dayRules = dayRules
        self.sleepFloorMinutes = sleepFloorMinutes
    }
}

public enum BoxApplier {
    /// Removing or overwriting this much of your own logged time needs your Approve.
    public static let approvalMinutes = 60

    /// Applies ops in order. With `approved`, held ops are applied too (you tapped Approve).
    public static func apply(_ ops: [BoxOp], to s: inout BoxState, now: Date, calendar cal: Calendar,
                             approved: Bool = false) -> BoxReceipt {
        var ctx = Ctx(now: now, cal: cal)
        for op in ops {
            var trial = s
            var tctx = ctx
            tctx.apply(op, &trial)
            if !approved, let why = risk(before: s, after: trial, now: now) {
                ctx.r.held.append(HeldOp(op: op, why: why))
                continue
            }
            s = trial
            ctx = tctx
        }
        return ctx.r
    }

    /// Why a change needs your Approve, if it does.
    static func risk(before: BoxState, after: BoxState, now: Date) -> String? {
        let afterIds = Set(after.entries.map(\.id))
        if let gone = before.entries.first(where: { $0.repeats != nil && !afterIds.contains($0.id) }) {
            return "Removes “\(gone.title)” every time it repeats"
        }
        func ownPast(_ es: [Entry], only ids: Set<UUID>) -> Int {
            es.filter { $0.source == .you && $0.repeats == nil && ids.contains($0.id) && $0.marks.isEmpty }
                .reduce(0) { $0 + max(0, Int((min($1.end ?? now, now).timeIntervalSince($1.start)) / 60)) }
        }
        let existing = Set(before.entries.map(\.id))
        let lost = ownPast(before.entries, only: existing) - ownPast(after.entries, only: existing)
        if lost >= approvalMinutes { return "Removes or replaces \(minutesLabel(lost)) you logged" }
        let oldAlarms = Set(before.entries.filter { $0.alert?.kind == .alarm }.map(\.id))
        if let a = after.entries.first(where: { $0.alert?.kind == .alarm && !oldAlarms.contains($0.id) }) {
            return "Adds a full-screen alarm for “\(a.title)”"
        }
        return nil
    }

    /// Puts back everything a receipt changed.
    public static func undo(_ r: BoxReceipt, in s: inout BoxState) {
        for (id, old) in r.before {
            s.entries.removeAll { $0.id == id }
            if let old { s.entries.append(old) }
        }
        for (id, old) in r.rulesBefore {
            s.rules.removeAll { $0.id == id }
            if let old { s.rules.append(old) }
        }
        for (id, old) in r.tasksBefore {
            s.items.removeAll { $0.id == id }
            if let old { s.items.append(old) }
        }
        if let t = r.categoriesBefore { s.categories = t }
        if let b = r.dayRulesBefore { s.dayRules = b }
    }

    struct Ctx {
        let now: Date
        let cal: Calendar
        var r = BoxReceipt()

        // MARK: Snapshots

        mutating func snapAll(_ old: [Entry], _ new: [Entry]) {
            let oldById = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for e in new where oldById[e.id] != e && r.before[e.id] == nil { r.before[e.id] = .some(oldById[e.id]) }
            let newIds = Set(new.map(\.id))
            for e in old where !newIds.contains(e.id) && r.before[e.id] == nil { r.before[e.id] = .some(e) }
        }
        mutating func snapTask(_ id: UUID, _ s: BoxState) {
            if r.tasksBefore[id] == nil { r.tasksBefore[id] = .some(s.items.first { $0.id == id }) }
        }

        // MARK: Parsing

        func dayDate(_ f: BoxFields) -> Date { f.day.flatMap { DayKeys.date($0, cal) } ?? cal.startOfDay(for: now) }

        func time(_ v: String?, _ f: BoxFields) -> Date? {
            guard let v = v?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return nil }
            if v.lowercased() == "now" { return now }
            if !v.contains("-"), let t = ClockText.timeOfDay(v) {
                return cal.date(bySettingHour: t.hour, minute: t.minute, second: 0, of: dayDate(f))
            }
            if v.count == 10, let d = DayKeys.date(v, cal) { return d }
            return AIMapper.parseDate(v, timeZone: cal.timeZone)
        }

        func dayOnly(_ v: String?) -> Date? { v.flatMap { DayKeys.date(String($0.prefix(10)), cal) } }

        func alert(_ v: String?) -> Alert?? {
            guard let raw = v?.lowercased().trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
            if raw == "none" || raw == "off" { return .some(nil) }
            let edge: Alert.Edge = raw.contains("@end") ? .end : .start
            let base = raw.replacingOccurrences(of: "@end", with: "").replacingOccurrences(of: "@start", with: "")
            let parts = base.split(separator: ":")
            guard let k = parts.first.flatMap({ Alert.Kind(rawValue: String($0)) }) else { return nil }
            // An alarm only gets here through Approve (`risk` holds new ones), so it's approved.
            return .some(Alert(k, edge: edge, minutesBefore: parts.count > 1 ? Int(parts[1]) ?? 0 : 0, approved: k == .alarm))
        }

        func task(_ ref: String?, _ s: BoxState) -> Int? {
            guard let ref, let p = EntryRef.parse(ref), p.kind == .task else { return nil }
            let hits = s.items.indices.filter { EntryRef.matches(p, s.items[$0].id) }
            return hits.count == 1 ? hits[0] : nil
        }

        /// A category id, or a path created as needed (depth ≤3; the taxonomy pass tidies later).
        mutating func category(_ raw: String?, fallback: CategoryID, _ s: inout BoxState) -> CategoryID {
            guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return fallback }
            if s.categories.node(raw) != nil { return raw }
            let names = raw.components(separatedBy: CharacterSet(charactersIn: "›>/")).map {
                $0.trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }
            var parent: CategoryID?
            for n in names {
                if let hit = s.categories.find(n, under: parent) { parent = hit.id; continue }
                if r.categoriesBefore == nil { r.categoriesBefore = s.categories }
                guard let made = s.categories.add(n, under: parent) else { break }
                r.lines.append("New category \(s.categories.pathText(made.id))")
                parent = made.id
            }
            return parent ?? fallback
        }

        mutating func problem(_ p: String) { r.problems.append(p) }

        func span(_ e: Entry) -> String { TimeLog.span(e, cal) }

        // MARK: Dispatch

        mutating func apply(_ op: BoxOp, _ s: inout BoxState) {
            switch (op.noun, op.verb) {
            case (.entry, .add): addEntry(op.fields, &s)
            case (.entry, .change): changeEntry(op, &s)
            case (.entry, .remove): removeEntry(op, &s)
            case (.entry, .skip): skip(op, &s)
            case (.entry, .confirm): confirm(op, &s)
            case (.entry, .start), (.task, .start): start(op, &s)
            case (.entry, .stop), (.task, .stop): stop(op.fields, &s)
            case (.task, .add): addTask(op.fields, &s)
            case (.task, .change), (.task, .done), (.task, .drop): changeTask(op, &s)
            case (.task, .remove): removeTask(op, &s)
            case (.rule, .add): addRule(op.fields, &s)
            case (.rule, .change), (.rule, .remove): changeRule(op, &s)
            default: problem("\(op.noun.rawValue) \(op.verb.rawValue) isn't handled here")
            }
        }

        // MARK: Entries

        mutating func addEntry(_ f: BoxFields, _ s: inout BoxState) {
            guard let title = f.title?.trimmingCharacters(in: .whitespaces), !title.isEmpty,
                  let start = time(f.start, f) else { return problem("An entry needs a title and a start") }
            let end = time(f.end, f)
            if let end, end <= start { return problem("“\(title)” ends before it starts") }
            let ti = task(f.task, s)
            let fallback = ti.flatMap { s.items[$0].category } ?? CategoryTree.other
            let running = end == nil && f.repeats == nil && start <= now
            var e = Entry(title: String(title.prefix(120)), start: start,
                          end: running ? nil : (end ?? start.addingTimeInterval(1800)),
                          category: category(f.category, fallback: fallback, &s), topics: f.topics ?? [], note: f.note,
                          taskId: ti.map { s.items[$0].id }, open: f.open ?? false, source: .you, createdAt: now)
            if let rep = f.repeats { e.repeats = Repeat(rep, from: dayOnly(f.from), until: dayOnly(f.until)) }
            if case .some(let a) = alert(f.alert) { e.alert = a }
            let old = s.entries
            if running {
                r.lines += TimeLog.start(e, at: start, now: now, entries: &s.entries, calendar: cal).lines
            } else {
                let lr = TimeLog.insert(e, now: now, entries: &s.entries, calendar: cal)
                r.lines.append((start < now && e.repeats == nil ? "Logged " : "Added ") + "\(e.title) \(span(e))"
                               + (e.repeats.map { ", \($0.days.text(cal))" } ?? "") + " · \(s.categories.pathText(e.category))")
                r.lines += lr.lines
            }
            snapAll(old, s.entries)
            sleepCheck(e, s)
        }

        func find(_ ref: String?, _ s: BoxState) -> (Int, DayKey?)? {
            guard let ref, let hit = EntryRef.resolve(ref, in: s.entries) else { return nil }
            return (hit.index, hit.occurrence)
        }

        mutating func changeEntry(_ op: BoxOp, _ s: inout BoxState) {
            guard var (i, occ) = find(op.ref, s) else { return problem("Couldn't find entry \(op.ref ?? "?")") }
            var f = op.fields
            // A bare "09:53" in a change means that time on the entry's own day (or the occurrence's), not today.
            if f.day == nil { f.day = occ ?? DayKeys.key(s.entries[i].start, cal) }
            let old = s.entries
            // One occurrence of a series, or a calendar event: it becomes your own entry, the original is skipped.
            if s.entries[i].source == .calendar && occ == nil { occ = DayKeys.key(s.entries[i].start, cal) }
            if let key = occ {
                if s.entries[i].repeats != nil {
                    guard let one = Days.detach(&s.entries[i], occurrence: key, calendar: cal, now: now) else {
                        return problem("“\(s.entries[i].title)” doesn't happen on \(key)")
                    }
                    s.entries.append(one)
                } else if s.entries[i].source == .calendar {
                    var one = s.entries[i]
                    s.entries[i].marks[key] = .skipped
                    one.id = UUID()
                    one.source = .you
                    one.marks = [:]
                    s.entries.append(one)
                }
                i = s.entries.count - 1
            }
            var e = s.entries[i]
            if let t = f.title { e.title = String(t.prefix(120)) }
            if let st = time(f.start, f) {
                // Moving keeps the length unless an end is given.
                let len = (e.end ?? st).timeIntervalSince(e.start)
                e.start = st
                if e.end != nil { e.end = st.addingTimeInterval(len) }
            }
            if let en = time(f.end, f) { e.end = en }
            if let end = e.end, end <= e.start { s.entries = old; return problem("“\(e.title)” would end before it starts") }
            if f.category != nil { e.category = category(f.category, fallback: e.category, &s) }
            if let t = f.topics { e.topics = t }
            if let n = f.note { e.note = n }
            if let rep = f.repeats { e.repeats = Repeat(rep, from: dayOnly(f.from) ?? e.repeats?.from, until: dayOnly(f.until)) }
            else if let u = f.until, e.repeats != nil { e.repeats?.until = dayOnly(u) }
            if let o = f.open { e.open = o }
            if case .some(let a) = alert(f.alert) { e.alert = a }
            if f.task != nil { e.taskId = task(f.task, s).map { s.items[$0].id } }
            // Moving a planned block makes it yours: the planner works around it from now on.
            if e.source == .plan { e.source = .you; e.createdAt = now }
            s.entries[i] = e
            if e.source == .you && e.repeats == nil {
                s.entries.remove(at: i)
                r.lines += TimeLog.insert(e, now: now, entries: &s.entries, calendar: cal).lines
            }
            snapAll(old, s.entries)
            r.lines.append("Changed \(e.title)" + (occ.map { " on \($0)" } ?? "") + " to \(span(e))")
            sleepCheck(e, s)
        }

        mutating func removeEntry(_ op: BoxOp, _ s: inout BoxState) {
            guard let (i, occ) = find(op.ref, s) else { return problem("Couldn't find entry \(op.ref ?? "?")") }
            let e = s.entries[i]
            let old = s.entries
            if e.source == .calendar || (occ != nil && e.repeats != nil) {
                let key = occ ?? DayKeys.key(e.start, cal)
                s.entries[i].marks[key] = .skipped
                r.lines.append(e.source == .calendar ? "Hid \(e.title) on \(key) (it's still in Calendar)" : "Skipped \(e.title) on \(key)")
            } else {
                s.entries.remove(at: i)
                r.lines.append("Removed \(e.title)" + (e.repeats == nil ? " \(span(e))" : " (every time)"))
            }
            snapAll(old, s.entries)
        }

        /// `skip` by ref (one occurrence: it didn't / won't happen) or by category and day ("no school Friday").
        mutating func skip(_ op: BoxOp, _ s: inout BoxState) {
            let f = op.fields
            let old = s.entries
            if let ref = op.ref {
                guard let (i, occ) = find(ref, s) else { return problem("Couldn't find entry \(ref)") }
                let key = occ ?? Days.key(s.entries[i], on: dayDate(f), cal)
                s.entries[i].marks[key] = .skipped
                snapAll(old, s.entries)
                return r.lines.append("Skipped \(s.entries[i].title) on \(key)")
            }
            guard let raw = f.category, let cat = s.categories.node(raw)?.id ?? s.categories.find(raw)?.id else {
                return problem("Skip needs an entry, or a category and a day")
            }
            if r.dayRulesBefore == nil { r.dayRulesBefore = s.dayRules }
            let refs = Days.skip(category: cat, on: dayDate(f), entries: &s.entries, tree: s.categories,
                                 book: &s.dayRules, now: now, calendar: cal)
            snapAll(old, s.entries)
            let day = DayKeys.key(dayDate(f), cal)
            r.lines.append(refs.isEmpty ? "Nothing in \(s.categories.pathText(cat)) on \(day) to skip"
                                        : "\(s.categories.pathText(cat)) skipped on \(day) (\(refs.count))")
        }

        /// Yes to assumed time.
        mutating func confirm(_ op: BoxOp, _ s: inout BoxState) {
            guard let (i, occ) = find(op.ref, s) else { return problem("Couldn't find entry \(op.ref ?? "?")") }
            let old = s.entries
            let key = occ ?? DayKeys.key(s.entries[i].start, cal)
            s.entries[i].marks[key] = .confirmed
            snapAll(old, s.entries)
            r.lines.append("Confirmed \(s.entries[i].title) on \(key)")
        }

        mutating func start(_ op: BoxOp, _ s: inout BoxState) {
            var f = op.fields
            if op.noun == .task, f.task == nil { f.task = op.ref }
            let ti = task(f.task, s)
            if let t = f.task, ti == nil { return problem("Couldn't find task \(t)") }
            guard let title = f.title ?? ti.map({ s.items[$0].title }), !title.isEmpty else { return problem("Start what?") }
            let at = min(time(f.start, f) ?? now, now)
            let fallback = ti.flatMap { s.items[$0].category } ?? CategoryTree.other
            let e = Entry(title: title, start: at, end: nil, category: category(f.category, fallback: fallback, &s),
                          topics: f.topics ?? [], note: f.note, taskId: ti.map { s.items[$0].id }, source: .you, createdAt: now)
            let old = s.entries
            r.lines += TimeLog.start(e, at: at, now: now, entries: &s.entries, calendar: cal).lines
            snapAll(old, s.entries)
        }

        mutating func stop(_ f: BoxFields, _ s: inout BoxState) {
            guard TimeLog.running(s.entries) != nil else { return problem("Nothing is running") }
            let old = s.entries
            r.lines += TimeLog.stop(at: min(time(f.end, f) ?? now, now), entries: &s.entries, calendar: cal).lines
            snapAll(old, s.entries)
        }

        // MARK: Tasks

        mutating func addTask(_ f: BoxFields, _ s: inout BoxState) {
            guard let title = f.title?.trimmingCharacters(in: .whitespaces), !title.isEmpty,
                  let due = time(f.due, f) else { return problem("A task needs a title and a due time") }
            var item = WorkItem(title: String(title.prefix(120)), kind: f.kind.flatMap(TaskKind.init(rawValue:)) ?? .other,
                                due: due, estimateMinutes: f.minutes, importance: f.importance ?? 3,
                                difficulty: f.difficulty ?? 2, topics: f.topics ?? [], notes: f.note, source: .ai, createdAt: now)
            item.category = f.category.map { category($0, fallback: CategoryTree.studying, &s) }
            item.maxMinutesPerDay = f.maxMinutesPerDay
            item.firstStep = f.firstStep
            item.notBefore = time(f.notBefore, f)
            r.tasksBefore[item.id] = .some(nil)
            s.items.append(item)
            r.lines.append("Task: \(item.title), \(minutesLabel(item.estimateMinutes)), due \(DateFormatter.local("EEE d MMM H:mm", cal).string(from: due))")
        }

        mutating func changeTask(_ op: BoxOp, _ s: inout BoxState) {
            guard let i = task(op.ref, s) else { return problem("Couldn't find task \(op.ref ?? "?")") }
            snapTask(s.items[i].id, s)
            let f = op.fields
            switch op.verb {
            case .done:
                s.items[i].state = .done
                s.items[i].doneAt = now
                if TimeLog.running(s.entries)?.taskId == s.items[i].id { stop(BoxFields(), &s) }
                return r.lines.append("Done: \(s.items[i].title)")
            case .drop:
                s.items[i].state = .dropped
                s.items[i].doneAt = now
                return r.lines.append("Dropped: \(s.items[i].title)")
            default: break
            }
            var t = s.items[i]
            if let v = f.title { t.title = String(v.prefix(120)) }
            if let v = time(f.due, f) { t.due = v }
            if let v = f.minutes { t.estimateMinutes = max(5, v) }
            if let v = f.kind.flatMap(TaskKind.init(rawValue:)) { t.kind = v }
            if let v = f.difficulty { t.difficulty = max(1, min(3, v)) }
            if let v = f.importance { t.importance = max(1, min(5, v)) }
            if let v = f.maxMinutesPerDay { t.maxMinutesPerDay = v > 0 ? v : nil }
            if let v = f.firstStep { t.firstStep = v.isEmpty ? nil : v }
            if let v = f.notBefore { t.notBefore = v.isEmpty ? nil : time(v, f) }
            if let v = f.note { t.notes = v }
            if let v = f.topics { t.topics = v }
            if let c = f.category { t.category = category(c, fallback: CategoryTree.studying, &s) }
            s.items[i] = t
            r.lines.append("Changed task \(t.title)")
        }

        mutating func removeTask(_ op: BoxOp, _ s: inout BoxState) {
            guard let i = task(op.ref, s) else { return problem("Couldn't find task \(op.ref ?? "?")") }
            snapTask(s.items[i].id, s)
            r.lines.append("Deleted task \(s.items[i].title)")
            s.items.remove(at: i)
        }

        // MARK: Rules

        mutating func addRule(_ f: BoxFields, _ s: inout BoxState) {
            guard let text = f.text?.trimmingCharacters(in: .whitespaces), !text.isEmpty, let limits = f.limits,
                  !limits.isEmpty else { return problem("A rule needs text and what it changes in the planner") }
            let rule = Rule(text: text, said: f.said, from: dayOnly(f.from), until: dayOnly(f.until), days: f.repeats,
                            limits: limits.clamped, createdAt: now)
            r.rulesBefore[rule.id] = .some(nil)
            s.rules.append(rule)
            r.lines.append("Rule: \(text)" + (rule.until.map { " (until \(DayKeys.key($0, cal)))" } ?? ""))
        }

        mutating func changeRule(_ op: BoxOp, _ s: inout BoxState) {
            guard let raw = op.ref, let p = EntryRef.parse(raw), p.kind == .rule,
                  let i = s.rules.indices.first(where: { EntryRef.matches(p, s.rules[$0].id) }) else {
                return problem("Couldn't find rule \(op.ref ?? "?")")
            }
            if r.rulesBefore[s.rules[i].id] == nil { r.rulesBefore[s.rules[i].id] = .some(s.rules[i]) }
            if op.verb == .remove {
                r.lines.append("Removed rule: \(s.rules[i].text)")
                s.rules.remove(at: i)
                return
            }
            let f = op.fields
            if let t = f.text { s.rules[i].text = t }
            if let u = f.until { s.rules[i].until = dayOnly(u) }
            if let fr = f.from { s.rules[i].from = dayOnly(fr) }
            if let d = f.repeats { s.rules[i].days = d }
            if let l = f.limits { s.rules[i].limits = l.clamped }
            r.lines.append("Rule changed: \(s.rules[i].text)")
        }

        // MARK: Sleep floor (applied, with a warning)

        mutating func sleepCheck(_ e: Entry, _ s: BoxState) {
            guard s.categories.isUnder(e.category, CategoryTree.sleep), let end = e.end else { return }
            let m = Int(end.timeIntervalSince(e.start) / 60)
            if m < s.sleepFloorMinutes {
                r.warnings.append("That's \(minutesLabel(m)) of sleep, under your \(minutesLabel(s.sleepFloorMinutes)) floor")
            }
        }
    }
}
