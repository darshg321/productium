import Foundation

extension Schemas {
    public static let dumpOp: JSONValue = obj([
        "op": strEnum(DumpOpKind.allCases.map(\.rawValue)),
        "entity": strEnum(Registry.entities.map(\.name)),
        "id": str,
        "fields": .object(["type": .string("object")]),
        "knob": str,
        "value": str,
    ], required: ["op"])

    public static let dumpFact: JSONValue = obj(["section": str, "text": str, "replaces": str], required: ["text"])

    public static let dumpEvidence: JSONValue = obj([
        "what": str, "start": str, "end": str, "minutes": int, "task": str,
        "kind": strEnum(["travel", "study", "activity", "sleep", "other"]), "estimated": .object(["type": .string("boolean")]),
    ], required: ["what"])

    public static let dump: JSONValue = obj(["ops": arr(dumpOp), "reply": str, "facts": arr(dumpFact), "evidence": arr(dumpEvidence)],
                                            required: ["ops", "reply"])
}

public struct DumpContextInput: Sendable {
    public var now: Date
    public var calendar: Calendar
    public var state: DumpState
    public var calendarEvents: [FixedEvent]
    public var todaySegments: [Segment]
    public var plan: Plan
    public var warnings: [PlanWarning]
    public var aboutMe: AboutMe

    public init(now: Date, calendar: Calendar, state: DumpState, calendarEvents: [FixedEvent] = [],
                todaySegments: [Segment] = [], plan: Plan = .empty, warnings: [PlanWarning] = [], aboutMe: AboutMe = .empty) {
        self.aboutMe = aboutMe
        self.now = now
        self.calendar = calendar
        self.state = state
        self.calendarEvents = calendarEvents
        self.todaySegments = todaySegments
        self.plan = plan
        self.warnings = warnings
    }
}

extension Prompts {
    public static func dump() -> String {
        persona + """

        You run the single input box of Productium, an iPhone planner. The student writes anything, messy, maybe \
        with screenshots. You see the app's whole state in the context and change it with operations; the app applies \
        them in order, then reruns its planner. Return operations, then a reply.

        How the app works:
        - Tasks (t…): homework, tests, projects with a due date and an estimate. Steps of a project have a parent.
        - Weekly activities (a…): school, classes, clubs, jobs; repeat on weekdays. School is just activities of \
        kind school: one "School" block whose periods (the timetable) are its periods field.
        - One-off events (e…): busy time on one date. Calendar events (cal) are read-only here.
        - Day changes (d…): one date differs from the usual week (no school, late start, sleep in).
        - The planner places study blocks, breaks, free time, dinner, wind-down and sleep itself, around the \
        fixed things. You can't place or move a study block directly: change the task (due, estimate), the \
        activities, a day change or a knob, and say so if they asked for a specific time.
        - Colours: every task, activity and event can have its own; categories have defaults (study blue, free \
        orange, sleep indigo, fixed time gray).

        Rules:
        - Name existing things by id from the context (id: "a1b2c3"). Never add something that is already there: \
        upsert it by id. Read the context before every change; your earlier messages may already have done it.
        - A school timetable (P1 Math, P2 English…) goes in the School activity's periods field, never as one-off \
        events. If periods already exist, upsert the activity by id with the full corrected list. Use the split \
        macro only to turn one activity into genuinely separate activities.
        - "About the student" is what they've told the app before. When you need to know something about \
        them, look there first; ask only if it isn't there.
        - Several things at once: one operation each, in order. Fix rather than duplicate. If unsure, do the \
        likely thing and say so.
        - Values the app learns (routines, beliefs, sleep need, wake times) change only when the student \
        states them. How the planner behaves isn't yours to change: say what you'd suggest instead.

        Formats: times 24h HH:mm, dates YYYY-MM-DD, date-times local YYYY-MM-DDTHH:mm. weekdays 1=Sun..7=Sat.
        Operations (ops), applied in order: upsert (entity, id?, fields), delete (entity, id), set (knob, value), \
        split (entity activity, id, fields.parts).
        \(Registry.promptText())

        facts (optional): lines for "About the student", only what they literally said about themselves, their \
        plans or their situation ("Applying to Waterloo, McMaster, UofT and Queen's", "CS club is Thursdays at \
        lunch"). section Stated. replaces: the old line's text when a fact changed. Not for one-off events.
        evidence (optional): what they did, with times, so the app learns from it: what, start/end (local \
        date-times), or minutes; kind travel|study|activity|sleep|other; task (id) for work on a task. "Left at \
        8:02, got to school 8:16" is one travel item 08:02-08:16. "Worked about 200 min on the drafts" is study, \
        minutes 200, task id. Work with no time ("wrote two drafts"): minutes your best estimate, estimated true. \
        If you set a task's doneMinutes for the same work, don't add study evidence for it too. Evidence replaces \
        markers for things they report afterwards; use a marker for "leaving now".

        reply: 1-3 short plain sentences: what changed, or the answer to their question. Don't claim a change \
        you didn't make an operation for. Each later message starts with what the app applied for your last \
        answer, then what changed in the context since.
        """
    }

    public static func dumpContext(_ c: DumpContextInput) -> String {
        let cal = c.calendar, now = c.now, s = c.state
        func fmt(_ f: String) -> DateFormatter { DateFormatter.local(f, cal) }
        let df = fmt("EEE yyyy-MM-dd HH:mm"), hm = fmt("HH:mm"), day = fmt("EEE yyyy-MM-dd"), short = fmt("EEE MM-dd")
        let wd = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        func days(_ set: Set<Int>) -> String { set.sorted().map { wd[$0] }.joined(separator: "/") }
        func col(_ v: String?) -> String { v.map { " color \($0)" } ?? "" }
        let today = cal.startOfDay(for: now)
        var l = ["Now: \(df.string(from: now)) \(cal.timeZone.identifier)"]
        l += c.aboutMe.promptText.split(separator: "\n").map(String.init)

        let p = s.prefs
        l.append("Settings: sleepNeedMinutes \(p.sleepNeedMinutes), schoolDayWake \(p.schoolDayWake.label), freeDayWake "
                 + "\(p.freeDayWake.label), autoWake \(p.autoWake), windDownMinutes \(p.windDownMinutes), allowSleepTradeoffs "
                 + "\(p.allowSleepTradeoffs), schoolDays \(days(p.schoolDays)), nudgeLevel \(p.nudges.level.rawValue), alarms "
                 + "\(p.nudges.alarms), interests \(p.interests.isEmpty ? "none" : p.interests.joined(separator: ", "))")
        l.append("Beliefs (set by knob when they state one): " + s.beliefs.items.map { "\($0.id) \($0.display) \($0.confidence.title.lowercased())" }
            .joined(separator: ", "))
        if !p.colors.isEmpty {
            l.append("Colours set: " + p.colors.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        }

        if s.commitments.isEmpty {
            l.append("Weekly activities: none")
        } else {
            l.append("Weekly activities:")
            let sorted = s.commitments.sorted { ($0.kind.rawValue, $0.start, $0.title) < ($1.kind.rawValue, $1.start, $1.title) }
            for a in sorted {
                var line = "- id \(Ref.activity(a.id)) \"\(a.title)\" [\(a.kind.rawValue)] \(days(a.weekdays)) \(a.start.label)-\(a.end.label)"
                if a.bufferMinutes != 10 { line += " buffer \(a.bufferMinutes)m" }
                if let ps = a.periods, !ps.isEmpty {
                    line += " periods: " + ps.map { "\($0.title) \($0.start.label)-\($0.end.label)" + ($0.weekdays.isEmpty ? "" : " \(days($0.weekdays))") }.joined(separator: ", ")
                }
                if let f = a.validFrom { line += " from \(day.string(from: f))" }
                if let u = a.validUntil { line += " until \(day.string(from: u))" }
                l.append(line + col(a.color))
            }
        }

        let upcomingDays = s.exceptions.filter { $0.day >= today }.sorted { $0.day < $1.day }
        if !upcomingDays.isEmpty {
            l.append("Day changes:")
            for e in upcomingDays {
                let what = e.commitmentId.flatMap { id in s.commitments.first { $0.id == id }.map { "\"\($0.title)\" (\(Ref.activity($0.id)))" } }
                    ?? e.kind.map { "all \($0.rawValue)" } ?? "the day"
                let how = e.cancelled ? "cancelled" : [e.start.map { "starts \($0.label)" }, e.end.map { "ends \($0.label)" },
                                                     e.wake.map { "wake \($0.label)" }].compactMap { $0 }.joined(separator: ", ")
                l.append("- id \(Ref.dayChange(e.id)) \(day.string(from: e.day)) \(what) \(how)\(e.note.map { " (\($0))" } ?? "")")
            }
        }

        let events = s.oneOffs.filter { $0.end > now }.sorted { $0.start < $1.start }.prefix(20)
        if !events.isEmpty {
            l.append("One-off events:")
            for e in events {
                l.append("- id \(Ref.event(e.id)) \"\(e.title)\" \(df.string(from: e.start))-\(hm.string(from: e.end))\(col(e.color))")
            }
        }
        let horizon = now.addingTimeInterval(4 * 86400)
        let cals = c.calendarEvents.filter { $0.end > now && $0.start < horizon }.sorted { $0.start < $1.start }.prefix(15)
        if !cals.isEmpty {
            l.append("Calendar (read-only): " + cals.map { "\($0.title) \(short.string(from: $0.start)) \(hm.string(from: $0.start))-\(hm.string(from: $0.end))" }
                .joined(separator: "; "))
        }

        l.append("Routines: " + s.routines.map { "\($0.id) \($0.minutes)m\($0.enabled ? "" : " (off)")" }.joined(separator: ", "))

        let open = s.items.filter { !$0.isDone }.sorted { $0.due < $1.due }
        let tops = open.filter { $0.parentId == nil }.prefix(40)
        if tops.isEmpty {
            l.append("Open tasks: none")
        } else {
            l.append("Open tasks:")
            for t in tops {
                var line = "- id \(Ref.task(t.id)) \"\(t.title)\" [\(t.kind.rawValue)]"
                if let sub = t.subject { line += " \(sub)" }
                line += " due \(df.string(from: t.due)) \(t.completedMinutes)/\(t.estimateMinutes)m imp \(t.importance) diff \(t.difficulty)"
                if !t.topics.isEmpty { line += " topics: \(t.topics.prefix(5).joined(separator: ", "))" }
                if let n = t.notes, !n.isEmpty { line += " notes: \(n.prefix(80))" }
                if let sh = c.plan.shortfalls[t.id], sh > 0 { line += " NOT ENOUGH TIME (\(sh)m short)" }
                l.append(line + col(t.color))
                for st in open.filter({ $0.parentId == t.id }) {
                    l.append("  - step id \(Ref.task(st.id)) \"\(st.title)\" due \(short.string(from: st.due)) \(st.completedMinutes)/\(st.estimateMinutes)m\(col(st.color))")
                }
            }
        }
        let recentDone = s.items.filter { $0.isDone && ($0.doneAt.map { now.timeIntervalSince($0) < 3 * 86400 } ?? false) }.prefix(10)
        if !recentDone.isEmpty {
            l.append("Recently done: " + recentDone.map { "\(Ref.task($0.id)) \"\($0.title)\"" }.joined(separator: "; "))
        }

        let past = c.todaySegments.filter { $0.minutes >= 15 && $0.start <= now }
        if !past.isEmpty {
            l.append("Today so far: " + past.map { "\(hm.string(from: $0.start))-\(hm.string(from: $0.end)) \($0.label)\($0.inferred ? "*" : "")" }
                .joined(separator: ", "))
        }
        let marks = s.markers.filter { cal.isDate($0.at, inSameDayAs: now) }
        if !marks.isEmpty {
            l.append("Check-ins today: " + marks.map { "\(hm.string(from: $0.at)) \($0.activity) \($0.phase.rawValue)" }.joined(separator: ", "))
        }

        func label(_ b: PlannedBlock) -> String {
            let k: String
            switch b.kind {
            case .work: k = "study"
            case .review: k = "review"
            case .breakTime: k = "break"
            case .commitment: k = b.sourceId.flatMap(UUID.init(uuidString:)).map { Ref.activity($0) } ?? "activity"
            case .event: k = "event"
            default: k = b.kind.rawValue
            }
            return "\(hm.string(from: b.start))-\(hm.string(from: b.end)) \(b.title) (\(k))"
        }
        for i in 0..<7 {
            guard let d = cal.date(byAdding: .day, value: i, to: today) else { continue }
            let blocks = c.plan.blocks(on: d, calendar: cal).filter { $0.kind != .sleep && $0.end > now }
            let shown = i < 2 ? blocks.filter { $0.kind != .breakTime } : blocks.filter(\.isStudy)
            let wake = c.plan.wakePlans.first { cal.isDate($0.day, inSameDayAs: d) }
            let bed = c.plan.blocks.first { $0.kind == .sleep && cal.isDate($0.start, inSameDayAs: d) }
            guard !shown.isEmpty || wake != nil else { continue }
            var line = "Plan \(i == 0 ? "today" : i == 1 ? "tomorrow" : short.string(from: d)):"
            if let w = wake, w.wake > now { line += " wake \(hm.string(from: w.wake))" + (w.leaveBy.map { ", leave \(hm.string(from: $0))" } ?? "") + ";" }
            line += " " + (shown.isEmpty ? "no study" : shown.map(label).joined(separator: ", "))
            if let b = bed { line += "; bed \(hm.string(from: b.start))" }
            l.append(line)
        }
        if !c.warnings.isEmpty {
            l.append("Warnings: " + c.warnings.prefix(5).map(\.message).joined(separator: " | "))
        }
        return l.joined(separator: "\n")
    }
}
