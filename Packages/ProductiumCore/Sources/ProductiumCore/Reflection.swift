import Foundation

public struct Deferral: Hashable, Sendable {
    public var itemId: UUID
    public var title: String
    public var count: Int
    public var lastAt: Date?
    public var reasons: [String]
}

public enum ReflectionTrigger: String, Codable, Sendable { case deferrals, lowFollowThrough, weekly, asked }

public enum Reflection {
    public static func deferrals(items: [WorkItem], outcomes: [BlockOutcome], missedBlocks: [PlannedBlock] = [],
                                 extra: [UUID: Int] = [:], since: Date) -> [Deferral] {
        items.filter { !$0.isDone }.compactMap { item in
            let skipped = outcomes.filter { $0.itemId == item.id && $0.plannedStart >= since && ($0.status == .skipped || $0.actualMinutes == 0) }
            let missed = missedBlocks.filter { $0.itemId == item.id && $0.start >= since }
            let n = skipped.count + missed.count + (extra[item.id] ?? 0)
            guard n > 0 else { return nil }
            let last = (skipped.map(\.plannedStart) + missed.map(\.start)).max()
            return Deferral(itemId: item.id, title: item.title, count: n, lastAt: last, reasons: [])
        }.sorted { $0.count > $1.count }
    }

    public static func trigger(now: Date, lastRun: Date?, deferrals: [Deferral], days: [DayRecord], weeklyDue: Bool,
                               asked: Bool, paused: Bool, budgetAllows: Bool, calendar cal: Calendar) -> ReflectionTrigger? {
        guard budgetAllows, !paused else { return nil }
        if let l = lastRun, cal.isDate(l, inSameDayAs: now) { return nil }
        if asked { return .asked }
        if deferrals.contains(where: { $0.count >= 3 }) { return .deferrals }
        let last3 = days.sorted { $0.day < $1.day }.suffix(3)
        if last3.count == 3, last3.allSatisfy({ $0.planned > 0 && Double($0.done) < 0.5 * Double($0.planned) }) { return .lowFollowThrough }
        if weeklyDue { return .weekly }
        return nil
    }

    public static func system() -> String {
        Prompts.persona + """

        You are Productium's weekly reflection. You see what the student told the app about themselves, what the \
        app believes, what they put off, and planned vs done for two weeks. Suggest at most 3 small, specific \
        changes to how the app behaves, grounded in that evidence. The student approves each one; nothing \
        happens otherwise, and suggestions they rejected before are listed: don't repeat them.

        What you can suggest (proposals):
        - knob: change how the planner or nudges behave. knob one of the listed behaviour knobs, value the new \
        number. Changes are small: the app limits each step.
        - starter_step: for a task they keep putting off, a 5-20 minute concrete first step ("open the doc and \
        fix one paragraph"): task (id), title, minutes, due (local date-time, soon).
        - intention: an if-then reminder: trigger time (weekdays 1=Sun..7=Sat, time HH:mm) or arrive_home; text \
        ("When you get home Tuesday, open the Waterloo doc"); task (id) if it's about one.
        - belief_group: a pattern worth tracking ("After-school slump 3-4 pm"): group_id, group_title, and at \
        least 3 pieces of evidence. At most one.
        Each with reason (one sentence, the evidence) and evidence (short lines).
        about_me: up to 3 lines for the student's about-me file: section Inferred ("text — evidence: …, \
        confidence: low|med|high, since YYYY-MM-DD") or Patterns ("puts off university essays: deferred 3× this week").
        note: two sentences for the card, warm and specific ("You've put off the Waterloo revision 3 times. Make \
        it a 15-minute first step right after school?").
        Never touch sleep need, the sleep floor, sleep trade-offs, or anything the student wrote (titles, due dates). \
        If nothing is worth changing, return no proposals and say so in the note.
        """
    }

    public static let schema: JSONValue = {
        let s = Schemas.str, i = Schemas.int, n: JSONValue = .object(["type": .string("number")])
        let proposal = Schemas.obj([
            "type": Schemas.strEnum(["knob", "starter_step", "intention", "belief_group"]),
            "knob": s, "value": n, "task": s, "title": s, "minutes": i, "due": s,
            "trigger": Schemas.strEnum(["time", "arrive_home"]), "weekdays": Schemas.arr(i), "time": s, "text": s,
            "group_id": s, "group_title": s, "reason": s, "evidence": Schemas.arr(s),
        ], required: ["type", "reason"])
        return Schemas.obj(["note": s, "proposals": Schemas.arr(proposal),
                            "about_me": Schemas.arr(Schemas.obj(["section": s, "text": s], required: ["section", "text"]))],
                           required: ["note", "proposals"])
    }()

    public struct Output: Codable, Hashable, Sendable {
        public struct Proposal: Codable, Hashable, Sendable {
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
            public var reason: String
            public var evidence: [String]?
        }
        public struct Line: Codable, Hashable, Sendable { public var section: String; public var text: String }
        public var note: String
        public var proposals: [Proposal]
        public var about_me: [Line]?
    }

    public static func request(now: Date, aboutMe: AboutMe, beliefs: Beliefs, routines: [Routine], deferrals: [Deferral],
                               days: [DayRecord], policy: BehaviourPolicy, feedback: [String], conversations: [String],
                               items: [WorkItem], trigger: ReflectionTrigger, question: String?, calendar cal: Calendar) -> String {
        let df = DateFormatter(); df.calendar = cal; df.timeZone = cal.timeZone; df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "EEE yyyy-MM-dd HH:mm"
        let short = DateFormatter(); short.calendar = cal; short.timeZone = cal.timeZone; short.locale = df.locale
        short.dateFormat = "EEE MM-dd"
        var l = ["Now: \(df.string(from: now)). Why now: \(trigger.rawValue)" + (question.map { ". They asked: \($0)" } ?? "")]
        l.append(aboutMe.promptText)
        l.append(beliefs.summary(routines: routines))
        l.append("Put off: " + (deferrals.isEmpty ? "nothing" : deferrals.prefix(8).map { d in
            "\(Ref.task(d.itemId)) \"\(d.title)\" \(d.count)×" + (d.lastAt.map { " (last \(short.string(from: $0)))" } ?? "")
        }.joined(separator: "; ")))
        let open = items.filter { !$0.isDone && $0.parentId == nil }.sorted { $0.due < $1.due }.prefix(10)
        l.append("Open tasks: " + open.map { "\(Ref.task($0.id)) \"\($0.title)\" due \(short.string(from: $0.due)) \($0.completedMinutes)/\($0.estimateMinutes)m" }
            .joined(separator: "; "))
        l.append("Last 14 days planned/done (min): " + days.sorted { $0.day < $1.day }.suffix(14)
            .map { "\(short.string(from: $0.day)) \($0.planned)/\($0.done)" }.joined(separator: ", "))
        let knobs = Registry.knobs.filter { $0.tier == .behaviour }.map { k in
            "\(k.key) \(Knobs.value(k.key, in: policy).map(Knobs.format) ?? "?") (\(k.format), \(k.note))"
        }
        l.append("Behaviour knobs now: " + knobs.joined(separator: "; "))
        if !policy.intentions.isEmpty { l.append("Reminders already: " + policy.intentions.map(\.text).joined(separator: "; ")) }
        if !feedback.isEmpty { l.append("Turned down before (don't repeat): " + feedback.joined(separator: " | ")) }
        if !conversations.isEmpty { l.append("Recent conversations: " + conversations.suffix(6).joined(separator: " | ")) }
        return l.joined(separator: "\n")
    }

    public static func drafts(_ o: Output, runId: UUID, items: [WorkItem], now: Date, model: String,
                              calendar cal: Calendar) -> [BehaviourProposal] {
        func make(_ c: ProposalChange, _ reason: String, _ ev: [String]) -> BehaviourProposal {
            BehaviourProposal(runId: runId, change: c, from: "", to: "", reason: reason, evidence: ev, model: model, at: now)
        }
        func task(_ ref: String?) -> WorkItem? { ref.flatMap { r in items.first { Ref.matches(r, prefix: "t", full: $0.id.uuidString) } } }
        var out: [BehaviourProposal] = []
        for p in o.proposals {
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
                                                          time: DumpApplier.timeOfDay(p.time), text: text, itemId: task(p.task)?.id)),
                                p.reason, ev))
            case "beliefgroup":
                guard let id = p.group_id ?? p.group_title, let title = p.group_title ?? p.group_id else { continue }
                let slug = id.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "_" }
                out.append(make(.beliefGroup(BeliefGroup(id: slug, title: title), evidence: ev), p.reason, ev))
            default: continue
            }
        }
        for line in o.about_me ?? [] {
            guard let s = AboutMeSection(loose: line.section) else { continue }
            out.append(make(.aboutMe(section: s, text: line.text), "From this week's reflection", []))
        }
        return out
    }
}
