import Foundation

// MARK: - Brain dump: one box for everything
//
// The student types (or pastes a screenshot of) anything: new deadlines, what they did,
// what changed, how they feel, a question. Claude returns a list of actions plus a reply.
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

    /// Lenient: a reply with no actions, or actions with no reply, still counts. One malformed
    /// action is dropped rather than losing the whole message.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reply = (try? c.decodeIfPresent(String.self, forKey: .reply)) ?? ""
        let raw = (try? c.decodeIfPresent([JSONValue].self, forKey: .actions)) ?? []
        actions = raw.compactMap { try? $0.decode(DumpAction.self) }
        guard !reply.isEmpty || !raw.isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "no actions and no reply"))
        }
    }
}

extension DumpResult {
    /// Reads the Inbox answer out of a reply, whatever shape it came back in: the schema's
    /// `{actions, reply}`, a list of actions, one action on its own, the reply under another name,
    /// or plain prose (shown as the reply, changing nothing). Nil only when there's nothing to
    /// show and nothing to do.
    public static func read(_ res: AIResponse) -> DumpResult? {
        for c in res.candidates {
            let fitted = StructuredRepair.coerce(normalise(c), to: Schemas.dump)
            if var r = try? fitted.decode(DumpResult.self) {
                r.reply = r.reply.trimmingCharacters(in: .whitespacesAndNewlines)
                return r
            }
        }
        // No JSON at all, just sentences: the model answered in words. That's a reply.
        let prose = res.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard res.candidates.isEmpty, prose.filter(\.isLetter).count >= 3, !prose.contains("{"), !prose.contains("```"),
              !["null", "none", "undefined"].contains(prose.lowercased()) else { return nil }
        return DumpResult(actions: [], reply: String(prose.prefix(600)))
    }

    static func normalise(_ v: JSONValue) -> JSONValue {
        guard case .object(var o) = v else { return v }
        let plain = Dictionary(o.keys.map { (StructuredRepair.plain($0), $0) }, uniquingKeysWith: { a, _ in a })
        func value(_ names: [String]) -> JSONValue? { names.lazy.compactMap { plain[$0].flatMap { o[$0] } }.first }
        if plain["reply"] == nil,
           let r = value(["message", "response", "answer", "text", "summary", "content", "output"]), case .string = r {
            o["reply"] = r
        }
        if plain["actions"] == nil {
            if let a = value(["action", "changes", "items", "tasks"]) {
                o["actions"] = a
            } else if case .string(let t)? = value(["type"]), DumpActionType(loose: t) != nil {
                // One action on its own, with the reply (if any) beside its fields.
                var action = o
                action["reply"] = nil
                o = ["actions": .array([.object(action)]), "reply": o["reply"] ?? .string("")]
            }
        }
        return .object(o)
    }
}

public enum DumpActionType: String, CaseIterable, Sendable {
    case addTask = "add_task", updateTask = "update_task", completeTask = "complete_task", deleteTask = "delete_task"
    case addActivity = "add_activity", updateActivity = "update_activity", deleteActivity = "delete_activity"
    case addEvent = "add_event", changeDay = "change_day", log, routine, mood
    case screenTime = "screen_time", settings

    /// The schema's names, plus the near misses a model can produce: "addTask", "create_task",
    /// "mark_done", "remove_activity", "screentime", "preferences".
    public init?(loose raw: String) {
        if let exact = DumpActionType(rawValue: raw) { self = exact; return }
        let words = raw.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1_$2", options: .regularExpression).lowercased()
            .split(whereSeparator: { !$0.isLetter }).map(String.init)
        let joined = words.joined(separator: "_")
        if let exact = DumpActionType(rawValue: joined) { self = exact; return }
        func has(_ options: String...) -> Bool { words.contains { options.contains($0) } }
        let activity = has("activity", "activities", "commitment", "class", "club", "practice")
        if has("screen", "screentime") { self = .screenTime }
        else if has("setting", "settings", "preference", "preferences", "prefs") { self = .settings }
        else if has("mood", "feeling", "energy") { self = .mood }
        else if has("routine") { self = .routine }
        else if has("day", "exception") { self = .changeDay }
        else if has("event", "appointment") { self = .addEvent }
        else if has("log", "checkin", "marker", "happened") { self = .log }
        else if has("complete", "completed", "done", "finish", "finished") { self = .completeTask }
        else if has("delete", "remove", "cancel", "drop") { self = activity ? .deleteActivity : .deleteTask }
        else if has("update", "change", "edit", "move", "reschedule", "modify") { self = activity ? .updateActivity : .updateTask }
        else if has("add", "create", "new") { self = activity ? .addActivity : .addTask }
        else { return nil }
    }
}

extension Schemas {
    /// Flat on purpose: one action shape with optional fields is far fewer schema tokens than
    /// one schema per action type. Formats are explained once, in the prompt.
    public static let dump: JSONValue = {
        let bool: JSONValue = .object(["type": .string("boolean")])
        let action = obj([
            "type": strEnum(DumpActionType.allCases.map(\.rawValue)),
            "target": str, "title": str, "kind": str, "subject": str, "due": str,
            "estimateMinutes": int, "importance": int, "difficulty": int, "progressMinutes": int, "topics": arr(str),
            "weekdays": arr(int), "start": str, "end": str, "date": str, "cancelled": bool, "wake": str,
            "activity": str, "category": strEnum(TimeCategory.allCases.map(\.rawValue)), "phase": strEnum(["start", "end"]),
            "at": str, "routine": strEnum(["get_ready", "to_school", "from_school"]), "minutes": int,
            "mood": int, "energy": int, "note": str, "screenMinutes": int, "distractingMinutes": int,
            "apps": arr(obj(["name": str, "minutes": int, "distracting": bool], required: ["name", "minutes"])),
            "sleepNeedMinutes": int, "freeDayWake": str, "maxStudyMinutesSchoolDay": int, "minFreeMinutesSchoolDay": int,
            "interests": arr(str),
        ], required: ["type"])
        return obj(["actions": arr(action), "reply": str], required: ["actions", "reply"])
    }()
}

extension Prompts {
    public static func dump() -> String {
        persona + """

        You run a planner's single input box. The student writes anything, messy, maybe with screenshots. \
        Return actions, then a reply. Times are 24h HH:mm, dates YYYY-MM-DD, date-times local ISO. \
        weekdays 1=Sun..7=Sat. target = name of the existing task/activity being changed.
        - add_task: title, kind (test|quiz|assignment|project|essay|application|reading|practice|chore|other), subject, due \
        (no time given: tests 08:00, submissions 23:59), estimateMinutes (realistic), importance 1-5, difficulty 1-3, \
        topics. One per deadline on an assignment sheet.
        - update_task (due, estimateMinutes, title, importance, progressMinutes), complete_task, delete_task: target.
        - add_activity/update_activity/delete_activity: weekly; title, kind (school|extracurricular|job|family|other), \
        weekdays, start, end.
        - add_event: one-off busy time: title, date, start, end.
        - change_day: one day differs. date; target (activity, or "school"); cancelled=true or new start/end; or \
        wake alone for "sleeping in till 10 sat". "Didn't go to school" is change_day, not log.
        - log: something that happened: activity (short key: to_school, from_school, school, study, sleep, in_bed…), \
        phase start/end, at. "Woke at 9" = sleep end 09:00.
        - routine: usual minutes for get_ready/to_school/from_school.
        - mood: 1-5, energy 1-5, note in their words. Only if they say how they feel.
        - screen_time: per day shown: date, screenMinutes, distractingMinutes (social, video, games, feeds), apps. \
        Unreadable week view: one action for today with the daily average.
        - settings: sleepNeedMinutes (min 450), freeDayWake, maxStudyMinutesSchoolDay, minFreeMinutesSchoolDay, interests.
        Use the context for dates and names. Fix existing things rather than duplicate. If unsure, do the likely thing \
        and say so. reply: 1-2 short plain sentences saying what changed, or answering their question.
        """
    }

    /// Everything the model needs to resolve references and corrections, as compactly as possible.
    public static func dumpContext(now: Date, calendar cal: Calendar, items: [WorkItem], commitments: [Commitment],
                                   exceptions: [DayException], routines: [Routine], todaySegments: [Segment],
                                   todayMarkers: [TimelineEvent], plan: Plan) -> String {
        func fmt(_ f: String) -> DateFormatter {
            let d = DateFormatter(); d.calendar = cal; d.timeZone = cal.timeZone; d.locale = Locale(identifier: "en_US_POSIX")
            d.dateFormat = f
            return d
        }
        let df = fmt("EEE yyyy-MM-dd HH:mm"), hm = fmt("HH:mm"), day = fmt("EEE MM-dd")
        let wd = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        var l = ["Now: \(df.string(from: now)) \(cal.timeZone.identifier)"]
        if !commitments.isEmpty {
            l.append("Weekly: " + commitments.map {
                "\($0.title) [\($0.kind.rawValue)] \($0.weekdays.sorted().map { wd[$0] }.joined(separator: "/")) \($0.start.label)-\($0.end.label)"
            }.joined(separator: "; "))
        }
        let upcoming = exceptions.filter { $0.day >= cal.startOfDay(for: now) }
        if !upcoming.isEmpty {
            l.append("Day changes: " + upcoming.map { e in
                let what = e.commitmentId.flatMap { id in commitments.first { $0.id == id }?.title } ?? e.kind?.rawValue ?? "day"
                let how = e.cancelled ? "cancelled" : [e.start.map { "starts \($0.label)" }, e.end.map { "ends \($0.label)" },
                                                     e.wake.map { "wake \($0.label)" }].compactMap { $0 }.joined(separator: ", ")
                return "\(day.string(from: e.day)) \(what) \(how)"
            }.joined(separator: "; "))
        }
        l.append("Usual: " + routines.filter(\.enabled).map { "\($0.id) \($0.minutes)m" }.joined(separator: ", "))
        // Only what's happened so far today: that's what corrections refer to. (* = assumed, not observed.)
        let past = todaySegments.filter { $0.minutes >= 15 && $0.start <= now }
        if !past.isEmpty {
            l.append("Today so far: " + past.map { "\(hm.string(from: $0.start))-\(hm.string(from: $0.end)) \($0.label)\($0.inferred ? "*" : "")" }
                .joined(separator: ", "))
        }
        if !todayMarkers.isEmpty {
            l.append("Check-ins: " + todayMarkers.map { "\(hm.string(from: $0.at)) \($0.activity) \($0.phase.rawValue)" }.joined(separator: ", "))
        }
        if let w = plan.wakePlans.first(where: { $0.wake > now }) {
            l.append("Next wake: \(day.string(from: w.wake)) \(hm.string(from: w.wake))")
        }
        let open = items.filter { !$0.isDone && $0.parentId == nil }.sorted { $0.due < $1.due }.prefix(20)
        l.append("Open tasks: " + (open.isEmpty ? "none" : open.map {
            "\($0.title) [\($0.kind.rawValue)] due \(df.string(from: $0.due)) \($0.completedMinutes)/\($0.estimateMinutes)m"
        }.joined(separator: "; ")))
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
            guard let type = DumpActionType(loose: a.type) else { continue }
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
