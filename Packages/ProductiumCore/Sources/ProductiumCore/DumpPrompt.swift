import Foundation

extension Schemas {
    /// Flat on purpose: one action shape with optional fields is far fewer schema tokens than
    /// one schema per action type. Formats are explained once, in the prompt.
    public static let dump: JSONValue = {
        let bool: JSONValue = .object(["type": .string("boolean")])
        let part = obj(["title": str, "start": str, "end": str, "weekdays": arr(int), "color": str],
                       required: ["title", "start", "end"])
        let action = obj([
            "type": strEnum(DumpActionType.allCases.map(\.rawValue)),
            "id": str, "target": str, "title": str, "kind": str, "subject": str, "due": str,
            "estimateMinutes": int, "importance": int, "difficulty": int, "progressMinutes": int, "doneMinutes": int,
            "topics": arr(str), "notes": str, "parent": str, "color": str,
            "weekdays": arr(int), "start": str, "end": str, "bufferMinutes": int, "validFrom": str, "validUntil": str,
            "parts": arr(part), "date": str, "cancelled": bool, "wake": str,
            "activity": str, "category": str, "phase": strEnum(["start", "end"]),
            "at": str, "routine": str, "minutes": int, "enabled": bool,
            "mood": int, "energy": int, "note": str, "screenMinutes": int, "distractingMinutes": int,
            "apps": arr(obj(["name": str, "minutes": int, "distracting": bool], required: ["name", "minutes"])),
            "key": str, "value": str,
        ], required: ["type"])
        return obj(["actions": arr(action), "reply": str], required: ["actions", "reply"])
    }()
}

/// Everything the Inbox can see. The app fills it from its state; the context is rebuilt for
/// every message, so the model always works from what's really there now.
public struct DumpContextInput: Sendable {
    public var now: Date
    public var calendar: Calendar
    public var state: DumpState
    /// Imported from the iOS calendar: shown, but changed in Calendar, not here.
    public var calendarEvents: [FixedEvent]
    public var todaySegments: [Segment]
    public var plan: Plan
    public var warnings: [PlanWarning]

    public init(now: Date, calendar: Calendar, state: DumpState, calendarEvents: [FixedEvent] = [],
                todaySegments: [Segment] = [], plan: Plan = .empty, warnings: [PlanWarning] = []) {
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
        with screenshots. You see the app's whole state in the context and change it with actions; the app applies \
        them in order, then reruns its planner. Return actions, then a reply.

        How the app works:
        - Tasks (t…): homework, tests, projects with a due date and an estimate. Steps of a project have a parent.
        - Weekly activities (a…): school, classes, clubs, jobs; repeat on weekdays. School is just activities of \
        kind school: one "School" block, or one per period/class.
        - One-off events (e…): busy time on one date. Calendar events (cal) are read-only here.
        - Day changes (d…): one date differs from the usual week (no school, late start, sleep in).
        - The planner places study blocks, breaks, free time, dinner, wind-down and sleep itself, around the \
        fixed things. You can't place or move a study block directly: change the task (due, estimate), the \
        activities, a day change or a setting, and say so if they asked for a specific time.
        - Colours: every task, activity and event can have its own; categories have defaults (study blue, free \
        orange, sleep indigo, fixed time gray).

        Rules:
        - Name existing things by id from the context (id: "a1b2c3"). Never add something that is already there: \
        update it. Read the context before every change; your earlier messages may already have done it.
        - Splitting an activity (school into periods): split_activity with id and parts; never add periods \
        next to the original. Parts keep the original's days unless given weekdays; days no part covers keep the \
        original. To change a period later, update_activity its id. If the periods already exist, update them.
        - Several things at once: one action each, in order. Fix rather than duplicate. If unsure, do the likely \
        thing and say so.

        Formats: times 24h HH:mm, dates YYYY-MM-DD, date-times local YYYY-MM-DDTHH:mm. weekdays 1=Sun..7=Sat.
        Actions (id = the thing's id; target = its name only if it has no id):
        - add_task: title, kind (test|quiz|assignment|project|essay|application|reading|practice|chore|other), subject, \
        due (no time: tests 08:00, submissions 23:59), estimateMinutes (realistic), importance 1-5, difficulty 1-3, \
        topics, notes, color, parent (a task id, for a step). One per deadline on an assignment sheet.
        - update_task: id + any of title, kind, subject, due, estimateMinutes, importance, difficulty, \
        progressMinutes (adds), doneMinutes (sets), topics, notes, color. complete_task, reopen_task, delete_task: id.
        - add_activity: title, kind (school|extracurricular|job|family|other), weekdays, start, end, bufferMinutes \
        (travel before/after, default 10; 0 between periods), color, validFrom/validUntil (dates, for a term).
        - update_activity: id + any of those. delete_activity: id.
        - split_activity: id, parts [{title, start, end, weekdays?, color?}].
        - add_event: title, date, start, end, color. update_event, delete_event: id.
        - change_day: date; id of the activity (or target "school" for all of school); cancelled=true or new \
        start/end; or wake alone ("sleeping in till 10 sat"). With a day change's id: edits it. "Didn't go to \
        school" is change_day, not log. delete_day_change: id (or date + target).
        - log: something that happened: activity (short key: to_school, from_school, school, study, sleep, in_bed…), \
        phase start/end, at. "Woke at 9" = sleep end 09:00.
        - routine: routine id (get_ready|to_school|from_school), minutes, enabled.
        - mood: 1-5, energy 1-5, note in their words. Only if they say how they feel.
        - screen_time: per day shown: date, screenMinutes, distractingMinutes (social, video, games, feeds), apps. \
        Unreadable week view: one action for today with the daily average.
        - settings: key and value (text), one action per setting. Keys: \
        \(DumpSettings.keys.map { "\($0.0) (\($0.1))" }.joined(separator: ", ")).
        - set_color: color (\(Palette.names.joined(separator: "|")), #RRGGBB, or default) and either id \
        (task/activity/event) or category (\(Palette.categories.joined(separator: "|")), subject:<name>, \
        task:<kind>). Colour all of a subject with subject:<name>, so new tasks match.

        reply: 1-3 short plain sentences: what changed, or the answer to their question. Don't claim a change \
        you didn't make an action for.
        """
    }

    /// The app's state, compact: every reference the model needs to change things exactly.
    public static func dumpContext(_ c: DumpContextInput) -> String {
        let cal = c.calendar, now = c.now, s = c.state
        func fmt(_ f: String) -> DateFormatter {
            let d = DateFormatter(); d.calendar = cal; d.timeZone = cal.timeZone; d.locale = Locale(identifier: "en_US_POSIX")
            d.dateFormat = f
            return d
        }
        let df = fmt("EEE yyyy-MM-dd HH:mm"), hm = fmt("HH:mm"), day = fmt("EEE yyyy-MM-dd"), short = fmt("EEE MM-dd")
        let wd = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        func days(_ set: Set<Int>) -> String { set.sorted().map { wd[$0] }.joined(separator: "/") }
        func col(_ v: String?) -> String { v.map { " color \($0)" } ?? "" }
        let today = cal.startOfDay(for: now)
        var l = ["Now: \(df.string(from: now)) \(cal.timeZone.identifier)"]

        let p = s.prefs
        l.append("Settings: sleepNeedMinutes \(p.sleepNeedMinutes), schoolDayWake \(p.schoolDayWake.label), freeDayWake "
                 + "\(p.freeDayWake.label), autoWake \(p.autoWake), windDownMinutes \(p.windDownMinutes), dinner "
                 + "\(p.dinner?.label ?? "none") (\(p.dinnerMinutes)m), focusBlockMinutes \(p.focusBlockMinutes), breakMinutes "
                 + "\(p.breakMinutes), maxStudyMinutes school/free \(p.maxStudyMinutesSchoolDay)/\(p.maxStudyMinutesFreeDay), "
                 + "minFreeMinutes school/free \(p.minFreeMinutesSchoolDay)/\(p.minFreeMinutesFreeDay), allowSleepTradeoffs "
                 + "\(p.allowSleepTradeoffs), chronotype \(p.chronotype.rawValue), schoolDays \(days(p.schoolDays)), "
                 + "screenTimeGoalMinutes \(p.screenTimeGoalMinutes), nudgeLevel \(p.nudges.level.rawValue), alarms "
                 + "\(p.nudges.alarms), interests \(p.interests.isEmpty ? "none" : p.interests.joined(separator: ", "))")
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

        // Only what's happened so far today: that's what corrections refer to. (* = assumed, not observed.)
        let past = c.todaySegments.filter { $0.minutes >= 15 && $0.start <= now }
        if !past.isEmpty {
            l.append("Today so far: " + past.map { "\(hm.string(from: $0.start))-\(hm.string(from: $0.end)) \($0.label)\($0.inferred ? "*" : "")" }
                .joined(separator: ", "))
        }
        let marks = s.markers.filter { cal.isDate($0.at, inSameDayAs: now) }
        if !marks.isEmpty {
            l.append("Check-ins today: " + marks.map { "\(hm.string(from: $0.at)) \($0.activity) \($0.phase.rawValue)" }.joined(separator: ", "))
        }

        // The plan as the student sees it on the Schedule tab: today and tomorrow in full, then study only.
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
