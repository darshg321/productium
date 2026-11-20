import Foundation

public enum TimeCategory: String, Codable, CaseIterable, Sendable {
    case sleep, school, activities, study, commute, routine, screen, free

    public var label: String {
        switch self {
        case .sleep: return "Sleep"
        case .school: return "School"
        case .activities: return "Activities"
        case .study: return "Study"
        case .commute: return "Travel"
        case .routine: return "Routine"
        case .screen: return "Scrolling"
        case .free: return "Free"
        }
    }

    public static func from(_ kind: CommitmentKind) -> TimeCategory {
        switch kind {
        case .school: return .school
        case .extracurricular, .job: return .activities
        case .family, .other: return .free
        }
    }
}

public enum MarkerPhase: String, Codable, Sendable { case start, end, point }
public enum MarkerSource: String, Codable, Sendable { case manual, voice, geofence, notification, health, inferred }

public struct CheckIn: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var at: Date
    public var phrase: String
    public var activity: String
    public var category: TimeCategory
    public var phase: MarkerPhase
    public var source: MarkerSource

    public init(id: UUID = UUID(), at: Date, phrase: String, activity: String, category: TimeCategory,
                phase: MarkerPhase, source: MarkerSource = .manual) {
        self.id = id
        self.at = at
        self.phrase = phrase
        self.activity = activity
        self.category = category
        self.phase = phase
        self.source = source
    }
}

public enum MarkerParser {
    public static func parse(_ raw: String, at: Date, commitments: [Commitment], calendar cal: Calendar,
                             source: MarkerSource = .manual) -> [CheckIn] {
        let text = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "’", with: "'")
        guard !text.isEmpty else { return [] }
        let morning = cal.component(.hour, from: at) < 12
        func ev(_ activity: String, _ cat: TimeCategory, _ phase: MarkerPhase) -> CheckIn {
            CheckIn(at: at, phrase: raw, activity: activity, category: cat, phase: phase, source: source)
        }
        func has(_ any: [String]) -> Bool { any.contains { text.contains($0) } }

        if has(["woke up", "just woke", "awake now", "i'm up", "im up"]) { return [ev("wake", .sleep, .end)] }
        if has(["going to bed", "going to sleep", "goodnight", "good night", "in bed"]) { return [ev("sleep", .sleep, .start)] }
        if has(["left home", "leaving home", "leaving the house", "left the house", "heading out", "out the door"]) {
            return [ev(morning ? "to_school" : "out", .commute, .start)]
        }
        if has(["at school", "got to school", "arrived at school", "arrived school", "reached school", "in school"]) {
            return [ev("to_school", .commute, .end), ev("school", .school, .start)]
        }
        if has(["left school", "leaving school", "school's out", "schools out", "school out", "done with school", "school done", "finished school"]) {
            return [ev("school", .school, .end), ev("from_school", .commute, .start)]
        }
        let words = Set(text.split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init))
        if has(["got home", "back home", "at home", "home now", "i'm home", "im home", "arrived home"]) || (words.contains("home") && words.count <= 2) {
            return [ev(morning ? "out" : "from_school", .commute, .end)]
        }

        let endVerbs = ["finished ", "done with ", "ended ", "end of ", "ending ", "just finished ", "out of "]
        let startVerbs = ["starting ", "started ", "start ", "beginning ", "begin ", "at ", "going to ", "heading to "]
        var phase: MarkerPhase = .point
        var subject = text
        for v in endVerbs where text.hasPrefix(v) { phase = .end; subject = String(text.dropFirst(v.count)); break }
        if phase == .point {
            for v in startVerbs where text.hasPrefix(v) { phase = .start; subject = String(text.dropFirst(v.count)); break }
        }
        if phase == .point {
            for suffix in [" done", " finished", " over"] where text.hasSuffix(suffix) {
                phase = .end; subject = String(text.dropLast(suffix.count))
            }
        }
        subject = subject.replacingOccurrences(of: " class", with: "")
            .replacingOccurrences(of: " practice", with: "")
            .replacingOccurrences(of: "the ", with: "")
            .replacingOccurrences(of: "my ", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard phase != .point, !subject.isEmpty else { return [] }

        let studyWords = ["homework", "studying", "study", "essay", "revision", "revising", "reading", "assignment", "application"]
        if let c = commitments.first(where: { normalise($0.title).contains(subject) || subject.contains(normalise($0.title)) }) {
            return [ev(normalise(c.title), TimeCategory.from(c.kind), phase)]
        }
        if studyWords.contains(where: { subject.contains($0) }) { return [ev("study", .study, phase)] }
        let hour = cal.component(.hour, from: at)
        let schoolish = ["math", "english", "history", "science", "bio", "chem", "physics", "french", "spanish", "art", "gym", "pe", "lunch", "period"]
        if schoolish.contains(where: { subject.contains($0) }) && (7...16).contains(hour) {
            return [ev(subject, .school, phase)]
        }
        return [ev(subject, .free, phase)]
    }

    public static func normalise(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: " class", with: "").replacingOccurrences(of: " practice", with: "")
            .trimmingCharacters(in: .whitespaces)
    }
}

public enum MarkerCategory {
    static let studyWords = ["study", "homework", "revis", "essay", "assignment", "application", "draft", "reading"]

    /// The category a marker belongs in, decided from its name; the model's own value is only the last resort.
    public static func infer(activity: String, commitments: [Commitment], model: TimeCategory? = nil) -> TimeCategory {
        let key = activity.lowercased().replacingOccurrences(of: " ", with: "_")
        switch key {
        case "to_school", "from_school", "travel", "commute": return .commute
        case "get_ready": return .routine
        default: break
        }
        if SleepEstimator.normalised(activity: activity, phase: .start) != nil
            || SleepEstimator.normalised(activity: activity, phase: .end) != nil { return .sleep }
        let norm = MarkerParser.normalise(activity.replacingOccurrences(of: "_", with: " "))
        if let c = commitments.first(where: { MarkerParser.normalise($0.title) == norm }) { return TimeCategory.from(c.kind) }
        if studyWords.contains(where: { norm.contains($0) }) { return .study }
        return model ?? .free
    }
}

public enum RoutineLearner {
    public static func learn(day events: [CheckIn], healthWake: Date?, routines: [Routine]) -> [Routine] {
        var out = routines
        let sorted = events.sorted { $0.at < $1.at }
        func observe(_ id: String, from a: Date?, to b: CheckIn?) {
            guard let a, let b, b.at > a, let idx = out.firstIndex(where: { $0.id == id }),
                  !out[idx].learnedFrom.contains(b.id) else { return }
            if out[idx].observe(Int((b.at.timeIntervalSince(a) / 60).rounded())) { out[idx].learnedFrom.insert(b.id) }
        }
        func first(_ activity: String, _ phase: MarkerPhase, after: Date? = nil) -> CheckIn? {
            sorted.first { $0.activity == activity && $0.phase == phase && (after == nil || $0.at > after!) }
        }
        let leftHome = first("to_school", .start)
        observe("to_school", from: leftHome?.at, to: first("to_school", .end, after: leftHome?.at))
        let leftSchool = first("from_school", .start)
        observe("from_school", from: leftSchool?.at, to: first("from_school", .end, after: leftSchool?.at))
        let wake = first("wake", .end)?.at ?? first("sleep", .end)?.at ?? healthWake
        if let wake, let leftHome, leftHome.at.timeIntervalSince(wake) < 3 * 3600 {
            observe("get_ready", from: wake, to: leftHome)
        }
        return out
    }

    public static func observedDuration(of activity: String, in events: [CheckIn]) -> Int? {
        let s = events.sorted { $0.at < $1.at }
        guard let a = s.first(where: { $0.activity == activity && $0.phase == .start }),
              let b = s.first(where: { $0.activity == activity && $0.phase == .end && $0.at > a.at }) else { return nil }
        return Int(b.at.timeIntervalSince(a.at) / 60)
    }
}

public struct Segment: Codable, Hashable, Sendable {
    public var start: Date
    public var end: Date
    public var category: TimeCategory
    public var label: String
    public var inferred: Bool
    public var minutes: Int { Int(end.timeIntervalSince(start) / 60) }
}

public struct DayInputs: Sendable {
    public var day: Date
    /// Your timetable and everything else timed (v1.2): the days' fixed time comes from here.
    public var entries: [Entry]
    public var categories: CategoryTree
    public var routines: [Routine]
    public var itemsById: [UUID: WorkItem]
    public var health: HealthDay?
    public var nextHealth: HealthDay?
    public var screen: ScreenDay?
    public var prefs: Preferences
    public var motion: [MotionSpan]
    public var scrollSessions: [ScrollSession]
    public var scrollingApps: [String: Bool]
    public var progress: [ProgressEntry]
    public var dayRules: DayRuleBook

    public init(day: Date, entries: [Entry] = [], categories: CategoryTree = CategoryTree(),
                routines: [Routine], itemsById: [UUID: WorkItem] = [:],
                health: HealthDay?, nextHealth: HealthDay? = nil, screen: ScreenDay?, prefs: Preferences,
                motion: [MotionSpan] = [], scrollSessions: [ScrollSession] = [],
                scrollingApps: [String: Bool] = [:], progress: [ProgressEntry] = [],
                dayRules: DayRuleBook = DayRuleBook()) {
        self.dayRules = dayRules
        self.progress = progress
        self.scrollSessions = scrollSessions
        self.scrollingApps = scrollingApps
        self.motion = motion
        self.day = day
        self.entries = entries
        self.categories = categories
        self.routines = routines
        self.itemsById = itemsById
        self.health = health
        self.nextHealth = nextHealth
        self.screen = screen
        self.prefs = prefs
    }
}

public enum TimelineBuilder {
    public static func segments(_ d: DayInputs, calendar cal: Calendar, now: Date? = nil) -> [Segment] {
        let dayStart = cal.startOfDay(for: d.day)
        guard let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        let total = Int(dayEnd.timeIntervalSince(dayStart) / 60)
        var cat = [TimeCategory?](repeating: nil, count: total)
        var label = [String](repeating: "", count: total)
        var inferred = [Bool](repeating: true, count: total)
        func idx(_ t: Date) -> Int { max(0, min(total, Int(t.timeIntervalSince(dayStart) / 60))) }
        func paint(_ a: Date, _ b: Date, _ c: TimeCategory, _ l: String, observed: Bool) {
            let i = idx(a), j = idx(b)
            guard j > i else { return }
            for m in i..<j { cat[m] = c; label[m] = l; inferred[m] = !observed }
        }
        func at(_ t: TimeOfDay) -> Date { cal.date(bySettingHour: t.hour, minute: t.minute, second: 0, of: dayStart) ?? dayStart }

        struct Fixed { var title: String; var start: Date; var end: Date; var kind: CommitmentKind; var category: TimeCategory; var assumed: Bool }
        let occ: [Fixed] = Days.on(dayStart, d.entries.filter { $0.source != .plan }, now: now ?? dayEnd, book: d.dayRules, calendar: cal)
            .filter { cal.isDate($0.start, inSameDayAs: dayStart) && $0.taskId == nil && !$0.running }
            .map { Fixed(title: $0.title, start: $0.start, end: $0.end, kind: Timetable.kind(of: $0.category, tree: d.categories),
                         category: d.categories.legacy($0.category), assumed: $0.assumed) }
            .sorted { $0.start < $1.start }
        // What the log says happened (resolved by rank, up to now); planned and assumed time shows ahead of that.
        let nowOrEnd = min(now ?? dayEnd, dayEnd)
        let slices = TimeLog.past(d.entries, in: DateInterval(start: dayStart, end: dayEnd), now: nowOrEnd, book: d.dayRules, calendar: cal)
        for o in occ where o.end > nowOrEnd { paint(max(o.start, nowOrEnd), o.end, o.category, o.title, observed: false) }
        for sl in slices { if let e = sl.entry, e.assumed { paint(sl.start, sl.end, d.categories.legacy(e.category), e.title, observed: false) } }
        let checkedIn = Set(slices.compactMap(\.entry).flatMap { $0.entry.topics })
        for r in d.routines where r.enabled && !checkedIn.contains(r.id) {
            let anchored = occ.filter { r.anchorKind == nil || $0.kind == r.anchorKind }
            switch r.anchor {
            case .beforeFirstCommitment:
                if let f = anchored.first {
                    paint(f.start.addingTimeInterval(-Double(r.minutes) * 60), f.start, r.category, r.name, observed: false)
                }
            case .afterLastCommitment:
                if let l = anchored.max(by: { $0.end < $1.end }) {
                    paint(l.end, l.end.addingTimeInterval(Double(r.minutes) * 60), r.category, r.name, observed: false)
                }
            case .afterWake:
                if let w = d.health?.wake, cal.isDate(w, inSameDayAs: dayStart) {
                    paint(w, w.addingTimeInterval(Double(r.minutes) * 60), r.category, r.name, observed: false)
                }
            }
        }

        for m in d.motion where m.end > dayStart && m.start < dayEnd {
            guard let (c, l) = MotionTimeline.segment(m) else { continue }
            paint(max(m.start, dayStart), min(m.end, dayEnd), c, l, observed: false)
        }

        if let h = d.health, let wake = h.wake {
            let bed = h.bedtime ?? wake.addingTimeInterval(-Double(h.sleepMinutes ?? d.prefs.sleepNeedMinutes) * 60)
            paint(max(bed, dayStart), wake, .sleep, "Sleep", observed: h.sleepSource != .motion && h.sleepSource != .plan)
        } else {
            let fromEntries = occ.map { FixedEvent(id: "entry", title: $0.title, start: $0.start, end: $0.end, kind: $0.kind) }
            let w = WakePlanner.plan(for: dayStart, events: fromEntries, routines: d.routines,
                                     prefs: d.prefs, calendar: cal,
                                     isSchoolDay: Days.isSchoolDay(dayStart, entries: d.entries, tree: d.categories, prefs: d.prefs,
                                                                   book: d.dayRules, calendar: cal)).wake
            paint(dayStart, w, .sleep, "Sleep", observed: false)
        }
        if let next = d.nextHealth, let bed = next.bedtime, cal.isDate(bed, inSameDayAs: dayStart) {
            paint(bed, dayEnd, .sleep, "Sleep", observed: true)
        }

        // Timed scrolling is exact where nothing else is known; school and sleep keep their time.
        for sess in d.scrollSessions where sess.app.isEmpty == false && cal.isDate(sess.openedAt, inSameDayAs: dayStart) {
            guard ScrollingApps.isScrolling(sess.app, d.scrollingApps) else { continue }
            let end = sess.endedAt ?? min(now ?? dayEnd, sess.openedAt.addingTimeInterval(Double(ScrollLog.estimateCap) * 60))
            let i = idx(sess.openedAt), j = idx(end)
            guard j > i else { continue }
            for m in i..<j where cat[m] == nil || cat[m] == .routine || cat[m] == .commute {
                cat[m] = .screen; label[m] = sess.app; inferred[m] = sess.isEstimated || sess.isOpen
            }
        }

        // Screenshot minutes have no timestamps. Whatever the timed sessions don't cover is placed in free time
        // (evening first, then the afternoon) and marked inferred, so Your Week shows it. Real study or check-ins
        // painted after this still win. (v1.1 C9)
        if let scr = d.screen?.distractingMinutes, scr > 0 {
            var need = scr - cat.reduce(0) { $0 + ($1 == .screen ? 1 : 0) }
            let upto = now.map { cal.isDate($0, inSameDayAs: dayStart) ? idx($0) : total } ?? total
            let evening = 19 * 60, afternoon = 15 * 60
            let order = Array(evening..<min(total, 23 * 60)) + Array((afternoon..<evening).reversed())
            for m in order where need > 0 && m < upto && cat[m] == nil {
                cat[m] = .screen; label[m] = "Scrolling"; inferred[m] = true
                need -= 1
            }
        }

        // Tracked time wins over everything else painted: it's what you said happened.
        for sl in slices { if let e = sl.entry, !e.assumed { paint(sl.start, sl.end, d.categories.legacy(e.category), e.title, observed: true) } }

        let limit = now.map { cal.isDate($0, inSameDayAs: dayStart) ? idx($0) : total } ?? total

        var out: [Segment] = []
        var m = 0
        while m < limit {
            let c = cat[m] ?? .free
            let l = cat[m] == nil ? "Free" : label[m]
            let inf = cat[m] == nil ? true : inferred[m]
            var n = m + 1
            while n < limit && (cat[n] ?? .free) == c && (cat[n] == nil ? "Free" : label[n]) == l
                    && (cat[n] == nil ? true : inferred[n]) == inf { n += 1 }
            out.append(Segment(start: dayStart.addingTimeInterval(Double(m) * 60),
                               end: dayStart.addingTimeInterval(Double(n) * 60), category: c, label: l, inferred: inf))
            m = n
        }
        return out
    }

    static func display(_ activity: String) -> String {
        switch activity {
        case "to_school": return "To school"
        case "from_school": return "Home from school"
        case "school": return "School"
        case "study": return "Study"
        case "sleep", "wake": return "Sleep"
        case "out": return "Out"
        default: return activity.prefix(1).uppercased() + activity.dropFirst()
        }
    }

    public static func totals(_ segments: [Segment], screen: ScreenDay?) -> [TimeCategory: Int] {
        var t: [TimeCategory: Int] = [:]
        for s in segments { t[s.category, default: 0] += s.minutes }
        // Timed sessions are already in the strip; screenshot minutes beyond them have no timestamps,
        // so they're carved out of free time as an estimate.
        if let scr = screen?.distractingMinutes, scr > 0 {
            let extra = max(0, scr - (t[.screen] ?? 0))
            let carved = min(extra, t[.free] ?? 0)
            t[.free, default: 0] -= carved
            t[.screen, default: 0] += extra
        }
        return t
    }
}

public enum CheckInSuggester {
    public static func suggestion(now: Date, todaysEvents: [CheckIn], commitments: [Commitment],
                                  routines: [Routine], calendar cal: Calendar) -> String? {
        let weekday = cal.component(.weekday, from: now)
        let school = commitments.filter { $0.weekdays.contains(weekday) && $0.kind == .school }
        func at(_ t: TimeOfDay) -> Date { cal.date(bySettingHour: t.hour, minute: t.minute, second: 0, of: now) ?? now }
        let logged = Set(todaysEvents.map { "\($0.activity)|\($0.phase.rawValue)" })
        guard let first = school.min(by: { $0.start < $1.start }), let last = school.max(by: { $0.end < $1.end }) else { return nil }
        let toSchool = routines.first { $0.id == "to_school" }?.minutes ?? 20
        let start = at(first.start), end = at(last.end)
        let leave = start.addingTimeInterval(-Double(toSchool + 15) * 60)
        let needsCommute = (routines.first { $0.id == "to_school" }?.samples.count ?? 0) < 5
        let needsHome = (routines.first { $0.id == "from_school" }?.samples.count ?? 0) < 5
        if needsCommute, now >= leave.addingTimeInterval(-20 * 60), now < start, !logged.contains("to_school|start") { return "Left home" }
        if needsCommute, logged.contains("to_school|start"), !logged.contains("to_school|end"), now < start.addingTimeInterval(3600) { return "At school" }
        if needsHome, now >= end, now < end.addingTimeInterval(2 * 3600), !logged.contains("from_school|start") { return "Left school" }
        if needsHome, logged.contains("from_school|start"), !logged.contains("from_school|end") { return "Home" }
        return nil
    }
}

extension TimeCategory: CodingKeyRepresentable {}
