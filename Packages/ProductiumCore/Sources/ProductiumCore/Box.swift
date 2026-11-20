import Foundation

// v1.2 O6: the box's request and answer. `BoxPrompt.system` (fixed, so the server's cache holds), `BoxContext.make`
// (the days themselves, with refs: what the model sees is what it can edit), `BoxSchema.result` (the forced tool's
// input) and `BoxResult.read` (lenient decoding: one bad op never loses the others). `BoxApplier` applies the ops.

public struct BoxResult: Hashable, Sendable {
    public var ops: [BoxOp]
    public var reply: String
    /// What the model couldn't do and why (Part T: goes to telemetry, v1.3's backlog).
    public var gap: String?
    public var facts: [AboutMeFact]
    public var queries: [TimeQuery]
    /// Ops that didn't decode, as text, for telemetry.
    public var unreadable: [String]

    public init(ops: [BoxOp], reply: String, gap: String? = nil, facts: [AboutMeFact] = [], queries: [TimeQuery] = [],
                unreadable: [String] = []) {
        self.ops = ops
        self.reply = reply
        self.gap = gap
        self.facts = facts
        self.queries = queries
        self.unreadable = unreadable
    }

    /// `timeZone` is the app's: dates inside day rules ("on": ["2026-11-20"]) are local days.
    public static func read(_ res: AIResponse, timeZone: TimeZone = .current) -> BoxResult? {
        for c in res.candidates { if let r = read(c, timeZone: timeZone) { return r } }
        let prose = res.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard res.candidates.isEmpty, prose.filter(\.isLetter).count >= 3, !prose.contains("{") else { return nil }
        return BoxResult(ops: [], reply: String(prose.prefix(600)))
    }

    public static func read(_ v: JSONValue, timeZone: TimeZone = .current) -> BoxResult? {
        guard case .object(let o) = v else { return nil }
        let dec = decoder(timeZone)
        func decode<T: Decodable>(_ t: T.Type, _ j: JSONValue) -> T? {
            (try? JSONEncoder().encode(j)).flatMap { try? dec.decode(T.self, from: $0) }
        }
        var ops: [BoxOp] = [], bad: [String] = []
        if case .array(let raw)? = o["ops"] {
            for item in raw {
                if let op = decode(BoxOp.self, normalise(item)) { ops.append(op) } else { bad.append(item.compactText) }
            }
        }
        var reply = ""
        if case .string(let r)? = o["reply"] { reply = r.trimmingCharacters(in: .whitespacesAndNewlines) }
        var gap: String?
        if case .string(let g)? = o["gap"], !g.trimmingCharacters(in: .whitespaces).isEmpty { gap = g }
        var facts: [AboutMeFact] = [], queries: [TimeQuery] = []
        if case .array(let fs)? = o["facts"] { facts = fs.compactMap { try? $0.decode(AboutMeFact.self) }.filter { !$0.text.isEmpty } }
        if case .array(let qs)? = o["queries"] { queries = qs.compactMap { decode(TimeQuery.self, $0) } }
        guard !reply.isEmpty || !ops.isEmpty || !queries.isEmpty else { return nil }
        return BoxResult(ops: ops, reply: reply, gap: gap, facts: facts, queries: queries, unreadable: bad)
    }

    /// Dates the model writes: "yyyy-MM-dd" (a local day), or a local / ISO date-time.
    public static func decoder(_ tz: TimeZone) -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            if let n = try? c.decode(Double.self) { return Date(timeIntervalSinceReferenceDate: n) }
            let s = try c.decode(String.self)
            if s.count == 10 {
                var cal = Calendar(identifier: .gregorian)
                cal.timeZone = tz
                if let day = DayKeys.date(s, cal) { return day }
            }
            if let date = AIMapper.parseDate(s, timeZone: tz) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unreadable date \(s)")
        }
        return d
    }

    /// Fields written beside `noun` / `verb` instead of under `fields` are moved under it; nulls are dropped.
    static func normalise(_ v: JSONValue) -> JSONValue {
        guard case .object(let raw) = v else { return v }
        var op: [String: JSONValue] = [:], fields: [String: JSONValue] = [:]
        for (k, val) in raw {
            if case .null = val { continue }
            switch k {
            case "fields": if case .object(let f) = val { for (fk, fv) in f { if case .null = fv { continue }; fields[fk] = fv } }
            case "noun", "verb", "ref": op[k] = val
            default: fields[k] = fields[k] ?? val
            }
        }
        op["fields"] = .object(fields)
        return .object(op)
    }
}

extension JSONValue {
    var compactText: String {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}

public enum BoxSchema {
    static let str = Schemas.str, int = Schemas.int
    static let bool: JSONValue = .object(["type": .string("boolean")])
    static let anyObject: JSONValue = .object(["type": .string("object")])
    static func arr(_ of: JSONValue) -> JSONValue { Schemas.arr(of) }
    /// Every property optional, nothing else allowed.
    static func open(_ props: [String: JSONValue]) -> JSONValue { Schemas.obj(props, required: []) }

    public static let fields: JSONValue = open([
        "title": str, "start": str, "end": str, "day": str, "category": str, "topics": arr(str), "note": str,
        "repeats": anyObject, "from": str, "until": str, "open": bool, "alert": str, "task": str,
        "due": str, "minutes": int, "kind": Schemas.strEnum(TaskKind.allCases.map(\.rawValue)), "difficulty": int,
        "importance": int, "maxMinutesPerDay": int, "firstStep": str, "notBefore": str,
        "text": str, "said": str, "limits": anyObject, "mood": int, "energy": int,
        "screen": open([
            "minutes": int, "period": str, "dateLabelShown": str, "date": str, "partial": bool, "pickups": int,
            "firstPickup": str, "notifications": int,
            "apps": arr(Schemas.obj(["name": str, "minutes": int, "category": str, "pickups": int, "notifications": int],
                                    required: ["name", "minutes"])),
        ]),
    ])

    public static let op: JSONValue = Schemas.obj([
        "noun": Schemas.strEnum(BoxOp.Noun.allCases.map(\.rawValue)),
        "verb": Schemas.strEnum(BoxOp.Verb.allCases.map(\.rawValue)),
        "ref": str,
        "fields": fields,
    ], required: ["noun", "verb"])

    public static let fact: JSONValue = Schemas.obj(["section": str, "text": str, "replaces": str], required: ["text"])

    public static let query: JSONValue = Schemas.obj([
        "id": str,
        "range": open(["last": str, "preset": str, "from": str, "to": str]),
        "filter": open(["categories": arr(str), "groups": arr(str), "topics": arr(str), "tasks": arr(str), "titles": arr(str),
                        "weekdays": arr(int), "hours": arr(int), "confirmedOnly": bool]),
        "groupBy": Schemas.strEnum(TimeQueryEngine.groupings.sorted()),
        "measure": Schemas.strEnum(TimeQueryEngine.measures.sorted()),
        "compare": Schemas.strEnum(["previous", "none"]),
        "chart": Schemas.strEnum(["ring", "bar", "stackedBar", "line", "heatmap", "number", "table"]),
    ], required: ["id", "range"])

    public static let result: JSONValue = Schemas.obj([
        "ops": arr(op), "reply": str, "gap": str, "queries": arr(query), "facts": arr(fact),
    ], required: ["ops", "reply"])
}

// MARK: - Context

public struct BoxContextInput: Sendable {
    public var now: Date
    public var calendar: Calendar
    public var state: BoxState
    /// The planner's future entries (`PlanEntries.from`), shown as planned.
    public var planned: [Entry]
    public var aboutMe: String
    public var settings: String

    public init(now: Date, calendar: Calendar, state: BoxState, planned: [Entry] = [], aboutMe: String = "", settings: String = "") {
        self.now = now
        self.calendar = calendar
        self.state = state
        self.planned = planned
        self.aboutMe = aboutMe
        self.settings = settings
    }
}

public enum BoxContext {
    /// Yesterday, today and the next 7 days.
    public static let daysBack = 1, daysAhead = 7

    public static func make(_ c: BoxContextInput) -> String {
        let cal = c.calendar, now = c.now, s = c.state
        func f(_ p: String) -> DateFormatter { DateFormatter.local(p, cal) }
        let hm = f("HH:mm"), dayF = f("EEE yyyy-MM-dd"), dt = f("EEE MM-dd HH:mm")
        func parity(_ d: Date) -> String { cal.component(.day, from: d) % 2 == 1 ? "odd date" : "even date" }
        func path(_ id: CategoryID) -> String { s.categories.pathText(id) }
        func task(_ id: UUID?) -> String { id.map { " task " + Ref.task($0) } ?? "" }
        var l: [String] = []
        l.append("Now: \(f("EEE yyyy-MM-dd HH:mm").string(from: now)) (\(cal.timeZone.identifier), \(parity(now)))")
        if !c.settings.isEmpty { l.append("Settings: \(c.settings)") }
        l.append("About the student: \(c.aboutMe.isEmpty ? "nothing yet" : c.aboutMe)")
        if let r = TimeLog.running(s.entries) {
            l.append("Running now: \(EntryRef.entry(r.id)) \"\(r.title)\" since \(hm.string(from: r.start)) · \(path(r.category))\(task(r.taskId))")
        } else {
            l.append("Running now: nothing")
        }

        let series = s.entries.filter { $0.repeats != nil }.sorted { ($0.start.timeOfDay, $0.title) < ($1.start.timeOfDay, $1.title) }
        if !series.isEmpty {
            l.append("Repeating (change the series by its ref; one day of it by ref@yyyy-MM-dd):")
            for e in series {
                let r = e.repeats!
                var line = "- \(EntryRef.entry(e.id)) \(hm.string(from: e.start))–\((e.end).map { hm.string(from: $0) } ?? "?") \"\(e.title)\" \(r.days.text(cal))"
                if let u = r.until { line += " until \(DayKeys.key(u, cal))" }
                line += " · \(path(e.category))\(e.open ? " [open time]" : "")\(task(e.taskId))\(alert(e.alert))"
                l.append(line)
            }
        }

        let today = cal.startOfDay(for: now)
        l.append("Days (past entries are assumed unless confirmed; planned = the planner's, moving one makes it yours):")
        for i in -daysBack...daysAhead {
            let day = cal.date(byAdding: .day, value: i, to: today)!
            let occ = Days.on(day, s.entries + c.planned, now: now, book: s.dayRules, calendar: cal, includeSkipped: true)
                .filter { cal.isDate($0.start, inSameDayAs: day) }
            let label = i == 0 ? " (today)" : i == 1 ? " (tomorrow)" : i == -1 ? " (yesterday)" : ""
            l.append("\(dayF.string(from: day)), \(parity(day))\(label):\(occ.isEmpty ? " nothing" : "")")
            for o in occ {
                var flags: [String] = []
                if o.mark == .skipped { flags.append("skipped") }
                if o.running { flags.append("running") }
                if o.source == .plan { flags.append("planned") }
                if o.source == .calendar { flags.append("calendar") }
                if o.source == .sensor { flags.append("sensor") }
                if o.entry.open { flags.append("open") }
                if o.end <= now && o.mark != .skipped && !o.running {
                    if o.isPlannedSession { flags.append("not started") }
                    else if o.assumed { flags.append("assumed") }
                    else if o.mark == .confirmed { flags.append("confirmed") }
                }
                let cat = o.entry.repeats == nil ? " · \(path(o.category))" : ""
                l.append("  \(o.ref) \(hm.string(from: o.start))–\(o.running ? "now" : hm.string(from: o.end)) \(o.title)\(cat)\(task(o.taskId))\(flags.isEmpty ? "" : " [" + flags.joined(separator: ", ") + "]")")
            }
        }

        let open = s.items.filter(\.isOpen).sorted { $0.due < $1.due }
        l.append("Open tasks:\(open.isEmpty ? " none" : "")")
        for t in open {
            var line = "- \(Ref.task(t.id)) \"\(t.title)\" due \(dt.string(from: t.due)) · \(minutesLabel(t.estimateMinutes))"
            if t.completedMinutes > 0 { line += " (\(minutesLabel(t.completedMinutes)) done)" }
            line += " · \(t.kind.rawValue), difficulty \(t.difficulty), importance \(t.importance)"
            if let m = t.maxMinutesPerDay { line += ", max \(minutesLabel(m))/day" }
            if let nb = t.notBefore { line += ", not before \(dt.string(from: nb))" }
            if let c = t.category { line += " · \(path(c))" }
            if let fs = t.firstStep { line += " · first step: \(fs)" }
            l.append(line)
        }
        let recent = s.items.filter { !$0.isOpen && ($0.doneAt ?? .distantPast) > now.addingTimeInterval(-3 * 86400) }
        if !recent.isEmpty {
            l.append("Recently closed: " + recent.map { "\(Ref.task($0.id)) \"\($0.title)\" \($0.state.rawValue)" }.joined(separator: "; "))
        }
        let rules = Rules.active(s.rules, at: now, calendar: cal)
        if !rules.isEmpty {
            l.append("Rules:")
            for r in rules {
                l.append("- \(r.ref) \(r.text)\(r.days.map { " (\($0.text(cal)))" } ?? "")\(r.until.map { " until \(DayKeys.key($0, cal))" } ?? "")")
            }
        }
        l.append("Categories (id name):")
        func walk(_ parent: CategoryID?, _ depth: Int) {
            for n in s.categories.children(parent).sorted(by: { $0.name < $1.name }) {
                l.append(String(repeating: "  ", count: depth) + "\(n.id) \(n.name)")
                walk(n.id, depth + 1)
            }
        }
        walk(nil, 0)
        return l.joined(separator: "\n")
    }

    static func alert(_ a: Alert?) -> String {
        guard let a else { return "" }
        return " [\(a.kind.rawValue)\(a.minutesBefore > 0 ? " \(a.minutesBefore)m before" : "")\(a.edge == .end ? " the end" : "")]"
    }
}

extension Date {
    fileprivate var timeOfDay: Double { timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 86400) }
}

// MARK: - Prompt

public enum BoxPrompt {
    /// Fixed text: the server's cache and session depend on it staying byte-identical.
    public static func system() -> String {
        """
        You are the assistant in Productium, an iPhone app where a high-school student tracks every minute of their \
        day and plans around deadlines. Warm, brief, concrete, never shaming. Sleep is never traded for test prep.

        You run the app's one text box. The student writes anything (messy, typos, screenshots). The context shows the \
        app as it is now: the days with every entry and its ref, open tasks, rules and categories. You change it with \
        ops, applied in order, and reply. Always call the tool.

        The app is time entries:
        - An entry is a stretch of time: past (it happened), running (one at a time), or future (planned). It can \
        repeat on any day rule. Refs: e1a2b3c is an entry or a whole series; e1a2b3c@2026-11-20 is one day of a series.
        - Past entries are assumed (classes, calendar events, things said ahead, planned routines) unless confirmed. \
        Planned study that wasn't started is "not started": it never counts as done.
        - Tasks (t…) have a due time and minutes; the planner spreads them before the due as planned entries, \
        respecting maxMinutesPerDay, notBefore, difficulty, and open time (spares, lunch: light work only).
        - Rules (u…) change how the planner fills days for a while (wake, windDownMinutes, capacityFactor, \
        maxBlockMinutes, noStudyAfter, mute / muteAll). Anything else is an entry, a task field, or a fact.
        - You can change anything, past included: the student may have forgotten to track or want to correct something. \
        The app asks the student before big removals or new alarms; just send the op.

        Ops: {noun, verb, ref?, fields}. Nouns entry, task, rule, setting, mood, screen_time. Verbs:
        - entry add: title, start, end (no end + start now or earlier = running), category, topics, note, repeats, \
        from, until, open, alert, task. entry change (ref, or ref@date for one day only): any of those. entry remove \
        (a series ref removes all of it; ref@date or a calendar event just that day). entry skip (ref or ref@date: \
        didn't / won't happen; or fields category + day to skip everything in it that day). entry confirm (ref@date: \
        yes, it happened). entry start (title, category) / entry stop (end?).
        - task add: title, due, minutes, kind, difficulty 1-3, importance 1-5, category, maxMinutesPerDay, notBefore, \
        firstStep, topics, note. task change (ref): any of those. task start (ref): start working on it now. task done / \
        task drop / task remove (ref).
        - rule add: text, said, from, until, repeats (which days), limits. rule change / remove (ref).
        - setting change: title = the setting (nudgeLevel, windDownMinutes, wakeAlarms, schoolDays…), text = value. \
        mood add: mood 1-5, energy, note. screen_time add: screen {minutes, apps, date…} read off a screenshot.
        Formats: start / end / due "HH:mm" with day "yyyy-MM-dd" (or "yyyy-MM-dd HH:mm", or "now"); dates \
        "yyyy-MM-dd". category: an id from the list, or a path "Work › Extracurricular › Volleyball" (missing levels \
        are created, at most 3 deep). repeats is a day rule: {"weekdays":[2,3,4,5,6]} (1=Sun..7=Sat), \
        {"dateParity":"odd"}, {"all":[rule, rule]}, {"any":[…]}, {"not":rule}, {"on":["2026-11-20"]}, \
        {"weekParity":{"anchor":"2026-11-16","odd":false}}, {"nthOf":{"sequence":"school","mod":2,"eq":0}}. \
        alert: "notify", "notify:10" (minutes before), "alarm:30", "alarm@end", "none".

        How to say things:
        - School happens on the school days in Settings: a timetable's day rule includes them ({"all": [{"weekdays": \
        …}, …]}), even when the student only describes the rotation.
        - A timetable is one repeating entry per period, category School › subject; keep the period number in the \
        title ("P2 Spare"), and mark spares and lunch open. Number periods in the order the student lists them, \
        counting spares and lunch, unless they number them differently. Different timetables on different days (odd / \
        even dates, A / B days) are separate series with different rules. When periods swap, each period keeps its own \
        length and the times shift (P1 8:26–9:38 and P2 9:38–10:58 swapped: P2 8:26–9:46, P1 9:46–10:58). A period keeps its number when it moves (on a swapped day the first \
        period is still "P2 Spare"), and "period 2" means P2 itself, wherever it falls that day. Every school minute \
        from the first bell to the last belongs to some period.
        - "X is due in class / at my data period": use the start of that day's occurrence from the context.
        - Pushing a task to another day: notBefore that day (it keeps its due date). If its due is before then, \
        change due instead. "Only N minutes a day" is maxMinutesPerDay on the one task; never split a task into copies.
        - Start / stop: "starting X" for an open task is task start; otherwise entry start. "done X" for a task is task \
        done (it also stops it). "finished just now", "that was actually 3:30": change the entry's end or start.
        - "Didn't do X" / "no X tomorrow": skip that entry (or that day of it). Changing one day of a series: change \
        ref@date. A calendar event is never edited in Calendar: skip it here, or change it (it becomes the student's own).
        - Logging the past: entry add with start and end, filed in the closest category. Use the context: "end of \
        school" is when today's last class ends; "my usual walk" is how long the last ones took.
        - What happens on the side (music, babysitting while doing homework) goes in note; one active entry at a time. \
        Scrolling is Unproductive › Scrolling whatever the app.
        - A standing preference ("spares are for easy work") becomes fields (open time, task difficulty), not a rule.

        queries (optional), when asked about their time: {id "q1", range {last "28d" | preset "this week" | from, to}, \
        filter {categories, groups, topics, tasks, titles, weekdays, hours, confirmedOnly}, groupBy, measure, compare \
        "previous", chart}. Never write numbers about their time yourself: write {q1.total}, {q1.avgPerDay}, \
        {q1.top}, {q1.rows}, {q1.days}, {q1.previous}, {q1.change} in the reply and the app fills them in. "Math \
        class" is the category School › Math; "math" overall is topics ["math"].
        facts (optional): what they said about themselves or their life, for About the student. section Stated.
        gap (optional): only if you couldn't do part of what they asked: what and why.
        reply: 1-3 short plain sentences: what changed (only what your ops did), or the answer, or one question if \
        the message could mean two different changes. If you guessed something (a time, a length), say so.
        """
    }
}

// MARK: - One turn

public enum BoxTurn {
    /// The request for one message, continuing the conversation (the server keeps the session and cache).
    public static func request(_ convo: Conversation, context: String, text: String, images: [AIImage] = [],
                               maxTokens: Int = 3000, model: String = AIModel.sonnet, effort: String? = nil) -> (AIRequest, JSONValue) {
        let content = ConversationPolicy.userContent(for: convo, text: text, images: images, fullContext: context)
        let req = convo.request(system: BoxPrompt.system(), tool: ConversationPolicy.tool(schema: BoxSchema.result),
                                userContent: content, maxTokens: maxTokens, model: model, effort: effort)
        return (req, content)
    }

    /// Records the turn so the next message starts with what was applied.
    public static func record(_ convo: inout Conversation, at: Date, text: String, content: JSONValue, response res: AIResponse,
                              result: BoxResult, receipt: BoxReceipt, context: String, turnId: UUID = UUID(), callId: UUID? = nil,
                              reply: String? = nil) {
        let changes = receipt.lines + receipt.held.map { "Waiting for the student's Approve: \($0.why)" }
        convo.add(ConversationTurn(id: turnId, at: at, text: text, userContent: content, assistantContent: res.rawContent,
                                   reply: reply ?? result.reply,
                                   applied: AppliedReport(changes: changes, problems: receipt.problems + receipt.warnings),
                                   callId: callId, tokens: res.tokens, context: context, queries: result.queries))
    }
}
