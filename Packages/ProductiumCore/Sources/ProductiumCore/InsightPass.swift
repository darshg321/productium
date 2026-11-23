import Foundation

public struct Deferral: Hashable, Sendable {
    public var itemId: UUID
    public var title: String
    public var count: Int
    public var lastAt: Date?
    public var reasons: [String]
}

public enum InsightTrigger: String, Codable, Sendable { case deferrals, lowFollowThrough, weekly, asked }

public struct InsightInput {
    public var now: Date
    public var calendar: Calendar
    public var trigger: InsightTrigger
    public var question: String?
    public var aboutMe: AboutMe
    public var beliefs: Beliefs
    public var routines: [Routine]
    public var deferrals: [Deferral]
    public var days: [DayRecord]
    public var summary: PeriodSummary?
    public var policy: BehaviourPolicy
    public var feedback: [String]
    public var changes: String?
    public var conversations: [String]
    public var items: [WorkItem]
    public var plan: Plan
    public var moods: [MoodEntry]
    public var taper: ScreenTaper
    public var learned: LearnedModel
    public var dayRules: DayRuleBook
    /// `MetricsExport.summary` (G6).
    public var metrics: String?
    /// v1.2 P1: candidate patterns from the log, with their evidence (the pass picks ≤2 and words them).
    public var patterns: [Pattern] = []
    /// v1.2 H6: how tasks of each kind and hour ended (`TaskHistory.summary`).
    public var trackRecord: [String] = []
    /// v1.2 I5: goals with this week's progress, first in the note. `aiGoals` may be moved ±10%.
    public var goals: [String] = []
    public var aiGoals: [Goal] = []
    /// v1.2 N3: what the student answered when plan and reality disagreed ("No school today" Tue).
    public var answers: [String] = []
    /// v1.3 A4: the activity grid and what's typed with no tile (`GridTidy.summary`).
    public var grid: [String] = []
    /// v1.5: how focused rated work was (`TimeLog.FocusStats.line`).
    public var focus: String?

    public init(now: Date, calendar: Calendar, trigger: InsightTrigger, question: String? = nil, aboutMe: AboutMe = .empty,
                beliefs: Beliefs = Beliefs(), routines: [Routine] = Routine.defaults, deferrals: [Deferral] = [], days: [DayRecord] = [],
                summary: PeriodSummary? = nil, policy: BehaviourPolicy = BehaviourPolicy(), feedback: [String] = [],
                changes: String? = nil, conversations: [String] = [], items: [WorkItem] = [], plan: Plan = .empty,
                moods: [MoodEntry] = [], taper: ScreenTaper = ScreenTaper(), learned: LearnedModel = LearnedModel(),
                dayRules: DayRuleBook = DayRuleBook(), metrics: String? = nil) {
        self.metrics = metrics
        self.dayRules = dayRules
        self.now = now
        self.calendar = calendar
        self.trigger = trigger
        self.question = question
        self.aboutMe = aboutMe
        self.beliefs = beliefs
        self.routines = routines
        self.deferrals = deferrals
        self.days = days
        self.summary = summary
        self.policy = policy
        self.feedback = feedback
        self.changes = changes
        self.conversations = conversations
        self.items = items
        self.plan = plan
        self.moods = moods
        self.taper = taper
        self.learned = learned
    }
}

/// v1.1 D.2: one Sonnet call that writes the Weekly Note (the only visible output) and quietly applies small
/// changes to how Productium behaves (`ChangeLog.apply`). Replaces the approval-gated Opus reflection and the
/// separate weekly review.
public enum InsightPass {
    public static func deferrals(items: [WorkItem], since: Date) -> [Deferral] {
        items.filter { $0.isOpen }.compactMap { item in
            let log = item.deferrals.filter { $0.at >= since }
            guard !log.isEmpty else { return nil }
            return Deferral(itemId: item.id, title: item.title, count: log.count, lastAt: log.map(\.at).max(),
                            reasons: Array(log.compactMap(\.reason).suffix(3)))
        }.sorted { $0.count > $1.count }
    }

    /// Runs with the weekly note, or at most once a day when something needs a look (a task put off 3+ times,
    /// under half the plan done 3 days running), or when the student asks.
    public static func trigger(now: Date, lastRun: Date?, deferrals: [Deferral], days: [DayRecord], weeklyDue: Bool,
                               asked: Bool, budgetAllows: Bool, calendar cal: Calendar) -> InsightTrigger? {
        guard budgetAllows else { return nil }
        if asked { return .asked }
        if weeklyDue { return .weekly }
        if let l = lastRun, cal.isDate(l, inSameDayAs: now) { return nil }
        if deferrals.contains(where: { $0.count >= 3 }) { return .deferrals }
        let last3 = days.sorted { $0.day < $1.day }.suffix(3)
        if last3.count == 3, last3.allSatisfy({ $0.planned > 0 && Double($0.done) < 0.5 * Double($0.planned) }) { return .lowFollowThrough }
        return nil
    }

    public static func system() -> String {
        (Prompts.persona + """

        You read the student's week and do two things.

        1. The Weekly Note they see: headline (under 10 words), wins (1-2 short sentences, specific), suggestions         (at most 2 small tweaks backed by research: sleep regularity, spacing, self-testing, shorter blocks, phone         out of the room). Kind about misses. If they asked a question, answer it in the suggestions. "Focus ratings" \
        are their own sense of how focused work was: weigh minutes by it, and the part of day they focus best is \
        evidence for when to plan hard work.

        2. changes: up to 3 small changes to how the app behaves, applied at once without asking. Only make one         when the data shows a clear pattern; none is a fine answer. Never mention them in the note.
        - knob: one of the listed behaviour knobs, value = the new number (the app limits each step).
        - starter_step: for a task put off often, a 5-20 min concrete first step: task (id), title, minutes, due.
        - intention: an if-then reminder: trigger time (weekdays 1=Sun..7=Sat, time HH:mm) or arrive_home; text;         task (id) if it's about one.
        - belief_group: a pattern worth tracking: group_id, group_title, 3+ evidence lines. At most one.
        - alarm: only proposed, the student taps Allow first: alarm_kind clock (time HH:mm, scope days, label) or \
        before_due (task, minutes before). For example an alarm 5 minutes before the time they keep missing. At most one.
        \(DayRuleText.grammar)
        Each has reason (one sentence of evidence) and evidence (short lines). Don't redo anything under "Undone         before".
        Goals come first in the note: which closed, which moved, one suggestion. goal_changes: you may move a goal marked \
        [ai] by at most 10% (goal id, target minutes); never one of theirs.
        patterns: from "Patterns found", pick at most 2 that matter and word each in one plain sentence (keep its numbers \
        exactly). Shown in Review; none is fine.
        grid: keep the activity grid tidy (up to 5, applied at once): add a tile for something typed often with no tile \
        (title, category id, SF Symbol), merge a duplicate (from, into), rename a vague one (from, to), hide one unused \
        30+ days. Never touch tiles marked (theirs). None is fine.
        about_me: up to 3 lines, section Inferred ("text — evidence: …, confidence: low|med|high, since YYYY-MM-DD")         or Patterns ("puts off university essays: deferred 3× this week").
        """).replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression)
    }

    public static let schema: JSONValue = {
        let s = Schemas.str, i = Schemas.int, n: JSONValue = .object(["type": .string("number")])
        let change = Schemas.obj([
            "type": Schemas.strEnum(["knob", "starter_step", "intention", "belief_group", "alarm"]),
            "alarm_kind": s, "alarm_target": s, "label": s,
            "said": s, "scope": s, "effects": Schemas.arr(s), "expires": s,
            "knob": s, "value": n, "task": s, "title": s, "minutes": i, "due": s,
            "trigger": Schemas.strEnum(["time", "arrive_home"]), "weekdays": Schemas.arr(i), "time": s, "text": s,
            "group_id": s, "group_title": s, "reason": s, "evidence": Schemas.arr(s),
        ], required: ["type", "reason"])
        return Schemas.obj(["headline": s, "wins": Schemas.arr(s), "suggestions": Schemas.arr(s),
                            "changes": Schemas.arr(change),
                            "patterns": Schemas.arr(Schemas.obj(["id": s, "text": s], required: ["id", "text"])),
                            "goal_changes": Schemas.arr(Schemas.obj(["goal": s, "target": i], required: ["goal", "target"])),
                            "grid": Schemas.arr(Schemas.obj(["action": Schemas.strEnum(["add", "merge", "rename", "hide"]), "title": s,
                                                             "to": s, "category": s, "symbol": s, "reason": s],
                                                            required: ["action", "title", "reason"])),
                            "about_me": Schemas.arr(Schemas.obj(["section": s, "text": s], required: ["section", "text"]))],
                           required: ["headline", "wins", "suggestions", "changes"])
    }()

    public struct Output: Codable, Hashable, Sendable {
        public struct Change: Codable, Hashable, Sendable {
            public var type: String
            public var knob: String?
            public var value: Double?
            public var task: String?
            public var title: String?
            public var minutes: Int?
            public var due: String?
            public var trigger: String?
            public var weekdays: [Int]?
            public var time: String?
            public var text: String?
            public var group_id: String?
            public var group_title: String?
            public var alarm_kind: String?
            public var alarm_target: String?
            public var label: String?
            public var said: String?
            public var scope: String?
            public var effects: [String]?
            public var expires: String?
            public var reason: String
            public var evidence: [String]?
        }
        public struct Line: Codable, Hashable, Sendable { public var section: String; public var text: String }
        public struct PatternLine: Codable, Hashable, Sendable { public var id: String; public var text: String }
        public struct GoalChange: Codable, Hashable, Sendable { public var goal: String; public var target: Int }
        public struct GridLine: Codable, Hashable, Sendable {
            public var action: String
            public var title: String
            public var to: String?
            public var category: String?
            public var symbol: String?
            public var reason: String
        }
        public var headline: String
        public var wins: [String]
        public var suggestions: [String]
        public var changes: [Change]
        public var about_me: [Line]?
        public var patterns: [PatternLine]?
        public var goal_changes: [GoalChange]?
        public var grid: [GridLine]?

        public var review: WeeklyReview { WeeklyReview(headline: headline, wins: wins, suggestions: Array(suggestions.prefix(2))) }
    }

    public static func request(_ x: InsightInput) -> String {
        let cal = x.calendar
        let df = DateFormatter.local("EEE yyyy-MM-dd HH:mm", cal), short = DateFormatter.local("EEE MM-dd", cal)
        var l = [Prompts.context(now: x.now, items: x.items, plan: x.plan, summary: x.summary, moods: x.moods, taper: x.taper,
                                 learned: x.learned, calendar: cal, aboutMe: x.aboutMe,
                                 beliefs: x.beliefs.summary(routines: x.routines), changes: x.changes)]
        l.append("Why now: \(x.trigger.rawValue)" + (x.question.map { ". They asked: \($0)" } ?? "") + " (\(df.string(from: x.now)))")
        l.append("Put off: " + (x.deferrals.isEmpty ? "nothing" : x.deferrals.prefix(8).map { d in
            "\(Ref.task(d.itemId)) \"\(d.title)\" \(d.count)×" + (d.lastAt.map { " (last \(short.string(from: $0)))" } ?? "")
                + (d.reasons.isEmpty ? "" : ": " + d.reasons.joined(separator: "; "))
        }.joined(separator: "; ")))
        let open = x.items.filter { $0.isOpen && $0.parentId == nil }.sorted { $0.due < $1.due }.prefix(10)
        if !open.isEmpty {
            l.append("Task ids: " + open.map { "\(Ref.task($0.id)) \"\($0.title)\"" }.joined(separator: "; "))
        }
        let days = x.days.sorted { $0.day < $1.day }.suffix(14)
        if !days.isEmpty {
            l.append("Last 14 days planned/done (min): " + days.map { "\(short.string(from: $0.day)) \($0.planned)/\($0.done)" }
                .joined(separator: ", "))
        }
        let knobs = Registry.knobs.filter { $0.tier == .behaviour && !$0.reflectionForbidden }.map { k in
            "\(k.key) \(Knobs.value(k.key, in: x.policy).map(Knobs.format) ?? "?") (\(k.format), \(k.note))"
        }
        l.append("Behaviour knobs now: " + knobs.joined(separator: "; "))
        if !x.goals.isEmpty { l.append("Goals this week: " + x.goals.joined(separator: "; ")) }
        if !x.aiGoals.isEmpty { l.append("Goals you set [ai]: " + x.aiGoals.map { "\($0.ref) \($0.title) \(minutesLabel($0.target))/\($0.period.rawValue)" }.joined(separator: "; ")) }
        if let m = x.metrics { l.append(m) }
        if !x.trackRecord.isEmpty { l.append("How tasks ended (track record): " + x.trackRecord.joined(separator: "; ")) }
        l += x.grid
        if let f = x.focus { l.append(f) }
        if !x.answers.isEmpty { l.append("When plan and reality disagreed, they said: " + x.answers.joined(separator: "; ")) }
        if !x.patterns.isEmpty {
            l.append("Patterns found (id: text · evidence):")
            for p in x.patterns.prefix(6) { l.append("- \(p.id): \(p.text) · " + p.evidence.prefix(4).joined(separator: ", ")) }
        }
        if !x.dayRules.sequences.isEmpty { l.append("Day sequences: " + x.dayRules.sequences.map(\.name).joined(separator: ", ")) }
        if !x.policy.intentions.isEmpty { l.append("Reminders already: " + x.policy.intentions.map(\.text).joined(separator: "; ")) }
        if !x.feedback.isEmpty { l.append("Undone before (don't redo): " + x.feedback.joined(separator: " | ")) }
        if !x.conversations.isEmpty { l.append("Recent conversations: " + x.conversations.suffix(6).joined(separator: " | ")) }
        return l.joined(separator: "\n")
    }

    /// P2: the patterns it chose (only ids it was given; the text is the model's wording of code's numbers).
    public static func patterns(_ o: Output, candidates: [Pattern]) -> [Pattern] {
        var seen = Set<String>()
        return Array((o.patterns ?? []).compactMap { line -> Pattern? in
            guard seen.insert(line.id).inserted, var p = candidates.first(where: { $0.id == line.id }) else { return nil }
            // Numbers in the wording must be the code's: any number not in the candidate's text keeps the code's text.
            let nums = { (s: String) in Set(s.split(whereSeparator: { !$0.isNumber }).map(String.init)) }
            if nums(line.text).isSubset(of: nums(p.text + " " + p.evidence.joined(separator: " "))) { p.text = line.text }
            return p
        }.prefix(2))
    }

    /// I2: moves only goals the AI suggested, by at most 10% (`Goals.nudge`). Returns the lines for the Changes list.
    public static func goalChanges(_ o: Output, goals: inout [Goal]) -> [String] {
        var out: [String] = []
        for c in o.goal_changes ?? [] {
            guard let i = goals.firstIndex(where: { Ref.matches(c.goal, prefix: "g", full: $0.id.uuidString) }) else { continue }
            let old = goals[i].target
            if Goals.nudge(&goals[i], to: c.target) { out.append("\(goals[i].title) goal: \(minutesLabel(old)) → \(minutesLabel(goals[i].target))") }
        }
        return out
    }

    /// J4: the insight pass can't add alarms; an `alarm` change becomes one Approve / Decline row in the Weekly Note.
    public static func proposals(_ o: Output, items: [WorkItem], now: Date, calendar cal: Calendar) -> [Approval] {
        func task(_ ref: String?) -> WorkItem? { ref.flatMap { r in items.first { Ref.matches(r, prefix: "t", full: $0.id.uuidString) } } }
        let hm = DateFormatter.local("yyyy-MM-dd HH:mm", cal)
        var out: [Approval] = []
        for p in o.changes where p.type.lowercased().filter(\.isLetter) == "alarm" {
            let kind = (p.alarm_kind ?? "clock").lowercased().filter(\.isLetter)
            var f = BoxFields(category: CategoryTree.other, alert: "alarm")
            if kind == "beforedue", let t = task(p.task), t.isOpen {
                let at = t.due.addingTimeInterval(-Double(max(0, p.minutes ?? 30)) * 60)
                guard at > now else { continue }
                f.title = p.label?.isEmpty == false ? p.label : "\(t.title) is due soon"
                f.start = hm.string(from: at)
                f.end = f.start
            } else if let tod = ClockText.timeOfDay(p.time) {
                var day = cal.startOfDay(for: now)
                if let t = cal.date(bySettingHour: tod.hour, minute: tod.minute, second: 0, of: day), t <= now {
                    day = cal.date(byAdding: .day, value: 1, to: day)!
                }
                f.title = p.label?.isEmpty == false ? p.label : "Alarm"
                f.start = "\(DayKeys.key(day, cal)) \(tod.label.count == 4 ? "0" + tod.label : tod.label)"
                f.end = f.start
                f.repeats = DayRuleText.rule(p.scope, tz: cal.timeZone, items: items)
            } else { continue }
            out.append(Approval(ops: [BoxOp(.entry, .add, f)], why: p.reason, source: .insight, at: now))
            break
        }
        return out
    }

    public static func drafts(_ o: Output, runId: UUID, items: [WorkItem], now: Date, model: String,
                              calendar cal: Calendar) -> [LoggedChange] {
        func make(_ c: InsightChange, _ reason: String, _ ev: [String]) -> LoggedChange {
            LoggedChange(runId: runId, change: c, reason: reason, evidence: ev, model: model, at: now)
        }
        func task(_ ref: String?) -> WorkItem? { ref.flatMap { r in items.first { Ref.matches(r, prefix: "t", full: $0.id.uuidString) } } }
        var out: [LoggedChange] = []
        for p in o.changes {
            let ev = p.evidence ?? []
            switch p.type.lowercased().filter(\.isLetter) {
            case "knob":
                guard let k = p.knob, let v = p.value else { continue }
                out.append(make(.knob(key: k, to: v), p.reason, ev))
            case "starterstep":
                guard let t = task(p.task), let title = p.title else { continue }
                let due = p.due.flatMap { AIMapper.parseDate($0, timeZone: cal.timeZone) } ?? now.addingTimeInterval(2 * 86400)
                out.append(make(.starterStep(parent: t.id, title: title, minutes: p.minutes ?? 15, due: due), p.reason, ev))
            case "intention":
                guard let text = p.text else { continue }
                let home = p.trigger?.lowercased().contains("home") ?? false
                out.append(make(.intention(IntentionNudge(trigger: home ? .arriveHome : .time, weekdays: p.weekdays ?? [],
                                                          time: ClockText.timeOfDay(p.time), text: text, itemId: task(p.task)?.id)),
                                p.reason, ev))
            case "alarm": continue
            case "beliefgroup":
                guard let id = p.group_id ?? p.group_title, let title = p.group_title ?? p.group_id else { continue }
                let slug = id.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "_" }
                out.append(make(.beliefGroup(BeliefGroup(id: slug, title: title), evidence: ev), p.reason, ev))
            default: continue
            }
        }
        for g in o.grid ?? [] {
            let change: GridChange
            switch g.action.lowercased() {
            case "add": change = .add(title: g.title, category: g.category ?? CategoryTree.other, symbol: g.symbol)
            case "merge": guard let to = g.to else { continue }; change = .merge(from: g.title, into: to)
            case "rename": guard let to = g.to else { continue }; change = .rename(from: g.title, to: to)
            case "hide": change = .hide(title: g.title)
            default: continue
            }
            out.append(make(.grid(change), g.reason, []))
        }
        for line in o.about_me ?? [] {
            guard let s = AboutMeSection(loose: line.section) else { continue }
            out.append(make(.aboutMe(section: s, text: line.text), "Noticed this week", []))
        }
        return out
    }
}
