import Foundation

// MARK: - Brain dump: one box for everything
//
// The student types (or pastes a screenshot of) anything: new deadlines, what they did,
// what changed, how they feel, a question. Haiku returns a list of actions plus a reply.
// `DumpApplier` turns them into state changes on the device, deterministically and
// testably, and reports what it changed so the UI can show it with an Undo.

public struct DumpApp: Codable, Hashable, Sendable {
    public var name: String
    public var minutes: Int
    public var distracting: Bool?
}

/// One flat action record. Only the fields relevant to `type` are set.
public struct DumpAction: Codable, Hashable, Sendable {
    public var type: String
    public var target: String?
    public var title: String?
    public var kind: String?
    public var subject: String?
    public var due: String?
    public var estimateMinutes: Int?
    public var importance: Int?
    public var difficulty: Int?
    public var progressMinutes: Int?
    public var topics: [String]?
    public var weekdays: [Int]?
    public var start: String?
    public var end: String?
    public var date: String?
    public var cancelled: Bool?
    public var wake: String?
    public var activity: String?
    public var category: String?
    public var phase: String?
    public var at: String?
    public var routine: String?
    public var minutes: Int?
    public var mood: Int?
    public var energy: Int?
    public var note: String?
    public var screenMinutes: Int?
    public var distractingMinutes: Int?
    public var apps: [DumpApp]?
    public var sleepNeedMinutes: Int?
    public var freeDayWake: String?
    public var maxStudyMinutesSchoolDay: Int?
    public var minFreeMinutesSchoolDay: Int?
    public var interests: [String]?

    public init(type: String) { self.type = type }
}

public struct DumpResult: Codable, Hashable, Sendable {
    public var actions: [DumpAction]
    public var reply: String
    public init(actions: [DumpAction], reply: String) { self.actions = actions; self.reply = reply }
}

public enum DumpActionType: String, CaseIterable, Sendable {
    case addTask = "add_task", updateTask = "update_task", completeTask = "complete_task", deleteTask = "delete_task"
    case addActivity = "add_activity", updateActivity = "update_activity", deleteActivity = "delete_activity"
    case addEvent = "add_event", changeDay = "change_day", log, routine, mood
    case screenTime = "screen_time", settings
}

extension Schemas {
    public static let dump: JSONValue = {
        let hhmm: JSONValue = .object(["type": .string("string"), "description": .string("24h HH:mm")])
        let action = obj([
            "type": strEnum(DumpActionType.allCases.map(\.rawValue)),
            "target": .object(["type": .string("string"), "description": .string("name of the existing task/activity this changes")]),
            "title": str, "kind": str, "subject": str,
            "due": .object(["type": .string("string"), "description": .string("local ISO date-time")]),
            "estimateMinutes": int, "importance": int, "difficulty": int, "progressMinutes": int, "topics": arr(str),
            "weekdays": arr(int), "start": hhmm, "end": hhmm,
            "date": .object(["type": .string("string"), "description": .string("YYYY-MM-DD")]),
            "cancelled": .object(["type": .string("boolean")]), "wake": hhmm,
            "activity": str, "category": strEnum(TimeCategory.allCases.map(\.rawValue)),
            "phase": strEnum(["start", "end"]),
            "at": .object(["type": .string("string"), "description": .string("local ISO date-time it happened")]),
            "routine": strEnum(["get_ready", "to_school", "from_school"]), "minutes": int,
            "mood": int, "energy": int, "note": str,
            "screenMinutes": int, "distractingMinutes": int,
            "apps": arr(obj(["name": str, "minutes": int, "distracting": .object(["type": .string("boolean")])], required: ["name", "minutes"])),
            "sleepNeedMinutes": int, "freeDayWake": hhmm, "maxStudyMinutesSchoolDay": int, "minFreeMinutesSchoolDay": int,
            "interests": arr(str),
        ], required: ["type"])
        return obj(["actions": arr(action), "reply": str], required: ["actions", "reply"])
    }()
}

extension Prompts {
    public static func dump() -> String {
        persona + """

        You are the brain behind a planner's single input box. The student dumps anything, messy and \
        abbreviated, sometimes with screenshots. Turn it into actions, then reply.

        Actions (use as many as needed, none if it's only a question):
        - add_task: new assignment/test/quiz/project/essay/application/reading/chore. due = local ISO date-time. \
          If no time: tests/quizzes 08:00, submissions 23:59. Estimate realistic minutes for a high schooler. \
          importance 1-5 (finals, applications = 5), difficulty 1-3, topics if they say what's on it. \
          Screenshots of assignment sheets or syllabi → one add_task per deadline.
        - update_task / complete_task / delete_task: target = the existing task's name. update can change due, \
          estimateMinutes, title, importance, or add progressMinutes ("did 30 min of the essay").
        - add_activity / update_activity / delete_activity: recurring weekly things (weekdays 1=Sun..7=Sat, start/end HH:mm). \
          target = existing activity for update/delete. kind: school|extracurricular|job|family|other.
        - add_event: one-off busy time (title, date, start, end).
        - change_day: a one-day change. target = activity name, or "school" for all of school. date = YYYY-MM-DD. \
          cancelled=true for "didn't go"/"no practice", or new start/end. wake = that day's wake-up time \
          ("sleeping in till 10 sat" → change_day date + wake 10:00, no target).
        - log: something that happened, with at = when (default now). phase start/end. activity short lowercase key; \
          use to_school/from_school/school/study/sleep for those. "woke up at 9" → activity sleep, phase end, at 09:00. \
          "got out of bed 9:40" → activity in_bed, phase end, at 09:40 (plus a start at wake time if known). \
          A correction to the assumed day ("didn't go to school today") is change_day, not log.
        - routine: the usual duration of get_ready / to_school / from_school ("walk to school takes 25 min").
        - mood: 1-5 (+ energy 1-5) only when they express how they feel. Keep their words in note.
        - screen_time: from a Screen Time screenshot or a stated number. One action per day shown: date, screenMinutes \
          (total), distractingMinutes (social, video, games, browsing feeds), apps with minutes + distracting flag. \
          A week view: one action per visible day if the bars are readable, otherwise a single action dated today \
          with the daily average.
        - settings: sleepNeedMinutes, freeDayWake, maxStudyMinutesSchoolDay, minFreeMinutesSchoolDay, interests. \
          Never set sleep below 450 minutes.

        Use the context to resolve "today", "tmrw", "fri", names, and what the app assumed. Prefer correcting \
        existing things over creating duplicates. If unsure what they meant, do the most likely thing and say so.
        reply: one or two short sentences confirming what changed in plain words (no lists), or answering their \
        question using the context. If they ask whether to stay up studying for a test, sleep wins.
        """
    }

    /// Everything the model needs to resolve references and corrections.
    public static func dumpContext(now: Date, calendar cal: Calendar, items: [WorkItem], commitments: [Commitment],
                                   exceptions: [DayException], routines: [Routine], todaySegments: [Segment],
                                   todayMarkers: [TimelineEvent], plan: Plan) -> String {
        let df = DateFormatter(); df.calendar = cal; df.timeZone = cal.timeZone; df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "EEEE yyyy-MM-dd HH:mm"
        let hm = DateFormatter(); hm.calendar = cal; hm.timeZone = cal.timeZone; hm.dateFormat = "HH:mm"
        let day = DateFormatter(); day.calendar = cal; day.timeZone = cal.timeZone; day.dateFormat = "EEE yyyy-MM-dd"
        let wd = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        var l = ["Now: \(df.string(from: now)) (\(cal.timeZone.identifier))"]
        l.append("Weekly schedule:")
        for c in commitments {
            l.append("- \(c.title) [\(c.kind.rawValue)] \(c.weekdays.sorted().map { wd[$0] }.joined(separator: "/")) \(c.start.label)-\(c.end.label)")
        }
        let upcoming = exceptions.filter { $0.day >= cal.startOfDay(for: now) }
        if !upcoming.isEmpty {
            l.append("One-day changes already set:")
            for e in upcoming {
                let what = e.commitmentId.flatMap { id in commitments.first { $0.id == id }?.title } ?? e.kind?.rawValue ?? "day"
                l.append("- \(day.string(from: e.day)) \(what): " + (e.cancelled ? "cancelled" : [e.start.map { "starts \($0.label)" }, e.end.map { "ends \($0.label)" }, e.wake.map { "wake \($0.label)" }].compactMap { $0 }.joined(separator: ", ")))
            }
        }
        l.append("Usual durations: " + routines.map { "\($0.name) \($0.minutes) min" }.joined(separator: ", "))
        l.append("Today so far as the app understands it:")
        for s in todaySegments where s.minutes >= 10 {
            l.append("- \(hm.string(from: s.start))-\(hm.string(from: s.end)) \(s.label)\(s.inferred ? " (assumed)" : "")")
        }
        if !todayMarkers.isEmpty {
            l.append("Check-ins today: " + todayMarkers.map { "\(hm.string(from: $0.at)) \($0.activity) \($0.phase.rawValue)" }.joined(separator: ", "))
        }
        if let w = plan.wakePlans.first(where: { $0.wake > now }) {
            l.append("Next planned wake-up: \(day.string(from: w.wake)) \(hm.string(from: w.wake))")
        }
        let open = items.filter { !$0.isDone && $0.parentId == nil }.sorted { $0.due < $1.due }.prefix(30)
        l.append("Open tasks:")
        for i in open {
            l.append("- \(i.title) [\(i.kind.rawValue)] due \(df.string(from: i.due)), \(i.completedMinutes)/\(i.estimateMinutes) min")
        }
        return l.joined(separator: "\n")
    }
}

/// The slice of app state the brain dump may change.
public struct DumpState: Sendable {
    public var items: [WorkItem]
    public var commitments: [Commitment]
    public var exceptions: [DayException]
    public var oneOffs: [FixedEvent]
    public var markers: [TimelineEvent]
    public var routines: [Routine]
    public var moods: [MoodEntry]
    public var screen: [ScreenDay]
    public var prefs: Preferences

    public init(items: [WorkItem], commitments: [Commitment], exceptions: [DayException], oneOffs: [FixedEvent],
                markers: [TimelineEvent], routines: [Routine], moods: [MoodEntry], screen: [ScreenDay], prefs: Preferences) {
        self.items = items
        self.commitments = commitments
        self.exceptions = exceptions
        self.oneOffs = oneOffs
        self.markers = markers
        self.routines = routines
        self.moods = moods
        self.screen = screen
        self.prefs = prefs
    }
}

public enum DumpApplier {
    /// Applies every action it can. Returns human-readable lines of what changed.
    @discardableResult
    public static func apply(_ r: DumpResult, to s: inout DumpState, now: Date, calendar cal: Calendar) -> [String] {
        var log: [String] = []
        let tz = cal.timeZone
        func tod(_ v: String?) -> TimeOfDay? {
            guard let v else { return nil }
            let p = v.split(separator: ":").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard let h = p.first, (0...23).contains(h) else { return nil }
            return TimeOfDay(h, p.count > 1 ? p[1] : 0)
        }
        func day(_ v: String?) -> Date {
            guard let v, let d = AIMapper.parseDate(v, timeZone: tz) else { return cal.startOfDay(for: now) }
            return cal.startOfDay(for: d)
        }
        func when(_ v: String?) -> Date {
            guard let v, let d = AIMapper.parseDate(v, timeZone: tz) else { return now }
            // A bare date parses to 23:59, and a moment in the future isn't a log. Keep it sane.
            return min(d, now)
        }
        func taskIndex(_ t: String?) -> Int? {
            match(t, s.items.indices.filter { !s.items[$0].isDone || s.items[$0].doneAt.map { now.timeIntervalSince($0) < 86400 } == true }
                .map { ($0, s.items[$0].title) })
        }
        func activityIndex(_ t: String?) -> Int? { match(t, s.commitments.indices.map { ($0, s.commitments[$0].title) }) }

        for a in r.actions {
            guard let type = DumpActionType(rawValue: a.type) else { continue }
            switch type {
            case .addTask:
                let p = ParsedItem(title: a.title ?? a.target ?? "", kind: a.kind ?? "other", subject: a.subject, due: a.due ?? "",
                                   estimateMinutes: a.estimateMinutes, importance: a.importance, difficulty: a.difficulty, topics: a.topics)
                guard let item = AIMapper.item(p, timeZone: tz) else { continue }
                if let i = s.items.firstIndex(where: { !$0.isDone && $0.title.lowercased() == item.title.lowercased() }) {
                    s.items[i].due = item.due
                    log.append("Updated \(item.title)")
                } else {
                    s.items.append(item)
                    log.append("Added \(item.title)")
                }
            case .updateTask:
                guard let i = taskIndex(a.target ?? a.title) else { continue }
                if let t = a.title, a.target != nil { s.items[i].title = t }
                if let d = a.due.flatMap({ AIMapper.parseDate($0, timeZone: tz) }) { s.items[i].due = d }
                if let m = a.estimateMinutes { s.items[i].estimateMinutes = max(5, m) }
                if let m = a.importance { s.items[i].importance = max(1, min(5, m)) }
                if let m = a.difficulty { s.items[i].difficulty = max(1, min(3, m)) }
                if let m = a.progressMinutes { s.items[i].completedMinutes += max(0, m) }
                if let t = a.topics { s.items[i].topics = t }
                log.append("Changed \(s.items[i].title)")
            case .completeTask:
                guard let i = taskIndex(a.target ?? a.title) else { continue }
                s.items[i].isDone = true
                s.items[i].doneAt = now
                log.append("Done: \(s.items[i].title)")
            case .deleteTask:
                guard let i = taskIndex(a.target ?? a.title) else { continue }
                let id = s.items[i].id
                log.append("Removed \(s.items[i].title)")
                s.items.removeAll { $0.id == id || $0.parentId == id }
            case .addActivity:
                guard let c = AIMapper.commitment(ParsedCommitment(title: a.title ?? "", kind: a.kind ?? "extracurricular",
                                                                   weekdays: a.weekdays ?? [], start: a.start ?? "", end: a.end ?? "")) else { continue }
                s.commitments.append(c)
                log.append("Added \(c.title) to your week")
            case .updateActivity:
                guard let i = activityIndex(a.target ?? a.title) else { continue }
                if let w = a.weekdays, !w.isEmpty { s.commitments[i].weekdays = Set(w.filter { (1...7).contains($0) }) }
                if let t = tod(a.start) { s.commitments[i].start = t }
                if let t = tod(a.end) { s.commitments[i].end = t }
                if let t = a.title, a.target != nil { s.commitments[i].title = t }
                log.append("Changed \(s.commitments[i].title)")
            case .deleteActivity:
                guard let i = activityIndex(a.target ?? a.title) else { continue }
                log.append("Removed \(s.commitments[i].title)")
                let id = s.commitments[i].id
                s.commitments.remove(at: i)
                s.exceptions.removeAll { $0.commitmentId == id }
            case .addEvent:
                let d = day(a.date)
                guard let st = tod(a.start), let en = tod(a.end),
                      let sd = cal.date(bySettingHour: st.hour, minute: st.minute, second: 0, of: d),
                      let ed = cal.date(bySettingHour: en.hour, minute: en.minute, second: 0, of: d), ed > sd else { continue }
                s.oneOffs.append(FixedEvent(id: UUID().uuidString, title: a.title ?? "Busy", start: sd, end: ed))
                log.append("Added \(a.title ?? "event")")
            case .changeDay:
                let d = day(a.date)
                var ex = DayException(day: d, cancelled: a.cancelled ?? false, start: tod(a.start), end: tod(a.end),
                                      wake: tod(a.wake), note: a.note)
                if let t = a.target?.lowercased(), !t.isEmpty {
                    if let k = CommitmentKind(rawValue: t) {
                        ex.kind = k
                    } else if let i = activityIndex(t) {
                        ex.commitmentId = s.commitments[i].id
                    } else if t.contains("school") {
                        ex.kind = .school
                    } else { continue }
                } else if ex.wake == nil { continue }
                // Replace an earlier change for the same thing on the same day.
                s.exceptions.removeAll { cal.isDate($0.day, inSameDayAs: d) && $0.commitmentId == ex.commitmentId
                    && $0.kind == ex.kind && ($0.wake != nil) == (ex.wake != nil) }
                s.exceptions.append(ex)
                log.append(ex.cancelled ? "No \(a.target ?? "plans") on that day" : "Changed that day")
            case .log:
                guard let act = a.activity?.lowercased(), !act.isEmpty else { continue }
                let phase = MarkerPhase(rawValue: a.phase ?? "end") ?? .end
                s.markers.append(TimelineEvent(at: when(a.at), phrase: a.note ?? act, activity: act,
                                               category: TimeCategory(rawValue: a.category ?? "") ?? .free, phase: phase, source: .voice))
                log.append("Logged \(act.replacingOccurrences(of: "_", with: " "))")
            case .routine:
                guard let id = a.routine, let m = a.minutes, let i = s.routines.firstIndex(where: { $0.id == id }), m > 0, m < 240 else { continue }
                // Stated durations replace learned samples: the student knows best.
                s.routines[i].samples = Array(repeating: m, count: 3)
                log.append("\(s.routines[i].name) is \(m) min")
            case .mood:
                guard let m = a.mood else { continue }
                s.moods.append(MoodEntry(at: now, mood: m, energy: a.energy, note: a.note))
            case .screenTime:
                let d = day(a.date)
                let apps = (a.apps ?? []).map { AppUsage(name: $0.name, minutes: max(0, $0.minutes), distracting: $0.distracting ?? false) }
                let distracting = a.distractingMinutes ?? apps.filter(\.distracting).reduce(0) { $0 + $1.minutes }
                let entry = ScreenDay(day: d, distractingMinutes: max(0, distracting), totalMinutes: a.screenMinutes,
                                      apps: apps.isEmpty ? nil : apps, source: "screenshot")
                s.screen.removeAll { cal.isDate($0.day, inSameDayAs: d) }
                s.screen.append(entry)
                s.screen.sort { $0.day < $1.day }
                log.append("Screen time saved")
            case .settings:
                if let v = a.sleepNeedMinutes { s.prefs.sleepNeedMinutes = max(450, min(600, v)) }
                if let v = tod(a.freeDayWake) { s.prefs.freeDayWake = v }
                if let v = a.maxStudyMinutesSchoolDay { s.prefs.maxStudyMinutesSchoolDay = max(30, min(360, v)) }
                if let v = a.minFreeMinutesSchoolDay { s.prefs.minFreeMinutesSchoolDay = max(30, min(300, v)) }
                if let v = a.interests { s.prefs.interests = v }
                log.append("Settings updated")
            }
        }
        return log
    }

    /// Best fuzzy match of a spoken name against existing names (exact > contains > shared words).
    static func match(_ target: String?, _ candidates: [(Int, String)]) -> Int? {
        guard let target, !target.isEmpty else { return nil }
        func norm(_ s: String) -> String {
            s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
        }
        let t = norm(target)
        let tw = Set(t.split(separator: " "))
        var best: (Int, Double)?
        for (i, name) in candidates {
            let n = norm(name)
            var score = 0.0
            if n == t { score = 3 }
            else if n.contains(t) || t.contains(n) { score = 2 }
            else {
                let nw = Set(n.split(separator: " "))
                let j = Double(tw.intersection(nw).count) / Double(max(1, tw.union(nw).count))
                if j >= 0.34 { score = 1 + j }
            }
            if score > 0, score > (best?.1 ?? 0) { best = (i, score) }
        }
        return best?.0
    }
}
