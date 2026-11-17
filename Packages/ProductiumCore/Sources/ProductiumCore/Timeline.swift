import Foundation

// MARK: - Categories of time

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

// MARK: - Check-in markers ("left home", "at school", "finished math")

public enum MarkerPhase: String, Codable, Sendable { case start, end, point }
public enum MarkerSource: String, Codable, Sendable { case manual, voice, geofence, notification, health, inferred }

public struct TimelineEvent: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var at: Date
    public var phrase: String
    /// Normalised activity key (e.g. "to_school", "school", "math", "soccer").
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

/// Turns tiny free-text check-ins into timeline markers, on the device and
/// instantly. Anything it doesn't recognise goes to Claude, then comes back as
/// the same `TimelineEvent`.
public enum MarkerParser {
    public static func parse(_ raw: String, at: Date, commitments: [Commitment], calendar cal: Calendar,
                             source: MarkerSource = .manual) -> [TimelineEvent] {
        let text = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "’", with: "'")
        guard !text.isEmpty else { return [] }
        let morning = cal.component(.hour, from: at) < 12
        func ev(_ activity: String, _ cat: TimeCategory, _ phase: MarkerPhase) -> TimelineEvent {
            TimelineEvent(at: at, phrase: raw, activity: activity, category: cat, phase: phase, source: source)
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
        // A class name we don't know as a commitment, said during school hours: school.
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

// MARK: - Learning from markers

public enum RoutineLearner {
    /// Looks at one day's markers and teaches the routines how long they take.
    /// Returns the routines with new samples added.
    public static func learn(day events: [TimelineEvent], healthWake: Date?, routines: [Routine]) -> [Routine] {
        var out = routines
        let sorted = events.sorted { $0.at < $1.at }
        func observe(_ id: String, from a: Date?, to b: TimelineEvent?) {
            guard let a, let b, b.at > a, let idx = out.firstIndex(where: { $0.id == id }),
                  !out[idx].learnedFrom.contains(b.id) else { return }
            if out[idx].observe(Int((b.at.timeIntervalSince(a) / 60).rounded())) { out[idx].learnedFrom.insert(b.id) }
        }
        func first(_ activity: String, _ phase: MarkerPhase, after: Date? = nil) -> TimelineEvent? {
            sorted.first { $0.activity == activity && $0.phase == phase && (after == nil || $0.at > after!) }
        }
        // The earliest start, whatever its source, pairs with the first end after it.
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

    /// How long a named commitment really runs (e.g. practice that always goes 20 min over).
    public static func observedDuration(of activity: String, in events: [TimelineEvent]) -> Int? {
        let s = events.sorted { $0.at < $1.at }
        guard let a = s.first(where: { $0.activity == activity && $0.phase == .start }),
              let b = s.first(where: { $0.activity == activity && $0.phase == .end && $0.at > a.at }) else { return nil }
        return Int(b.at.timeIntervalSince(a.at) / 60)
    }
}

// MARK: - A day reconstructed: where the time actually went

public struct Segment: Codable, Hashable, Sendable {
    public var start: Date
    public var end: Date
    public var category: TimeCategory
    public var label: String
    /// True when filled in from routines/schedule rather than observed.
    public var inferred: Bool
    public var minutes: Int { Int(end.timeIntervalSince(start) / 60) }
}

public struct DayInputs: Sendable {
    public var day: Date
    public var events: [TimelineEvent]
    public var commitments: [Commitment]
    public var fixedEvents: [FixedEvent]
    public var routines: [Routine]
    public var outcomes: [BlockOutcome]
    public var itemsById: [UUID: WorkItem]
    public var health: HealthDay?
    public var nextHealth: HealthDay?
    public var screen: ScreenDay?
    public var prefs: Preferences
    public var exceptions: [DayException]
    /// Motion spans (Core Motion): evidence between routine assumptions and check-ins.
    public var motion: [MotionSpan]

    public init(day: Date, events: [TimelineEvent], commitments: [Commitment], fixedEvents: [FixedEvent] = [],
                routines: [Routine], outcomes: [BlockOutcome], itemsById: [UUID: WorkItem] = [:],
                health: HealthDay?, nextHealth: HealthDay? = nil, screen: ScreenDay?, prefs: Preferences,
                exceptions: [DayException] = [], motion: [MotionSpan] = []) {
        self.motion = motion
        self.exceptions = exceptions
        self.day = day
        self.events = events
        self.commitments = commitments
        self.fixedEvents = fixedEvents
        self.routines = routines
        self.outcomes = outcomes
        self.itemsById = itemsById
        self.health = health
        self.nextHealth = nextHealth
        self.screen = screen
        self.prefs = prefs
    }
}

public enum TimelineBuilder {
    /// Paints a 1440-minute day in priority layers: schedule and routines (inferred) <
    /// sleep < logged study < explicit check-ins. Untouched awake minutes are free time.
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

        // Layer 1: schedule + routines (assumed to have happened).
        let occ = Commitment.occurrences(d.commitments, on: dayStart, exceptions: d.exceptions, calendar: cal)
        let todays = occ.map(\.commitment)
        for o in occ { paint(o.start, o.end, TimeCategory.from(o.commitment.kind), o.commitment.title, observed: false) }
        for e in d.fixedEvents where cal.isDate(e.start, inSameDayAs: dayStart) {
            paint(e.start, e.end, TimeCategory.from(e.kind), e.title, observed: false)
        }
        // A routine that was checked in today is painted from the check-ins, not assumed as well.
        let checkedIn = Set(d.events.filter { cal.isDate($0.at, inSameDayAs: dayStart) }.map(\.activity))
        for r in d.routines where r.enabled && !checkedIn.contains(r.id) {
            let anchored = occ.filter { r.anchorKind == nil || $0.commitment.kind == r.anchorKind }
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

        // Layer 1b: motion. Better than an assumed routine, not as good as a check-in.
        for m in d.motion where m.end > dayStart && m.start < dayEnd {
            guard let (c, l) = MotionTimeline.segment(m) else { continue }
            paint(max(m.start, dayStart), min(m.end, dayEnd), c, l, observed: false)
        }

        // Layer 2: sleep (HealthKit, or the planned sleep window).
        if let h = d.health, let wake = h.wake {
            let bed = h.bedtime ?? wake.addingTimeInterval(-Double(h.sleepMinutes ?? d.prefs.sleepNeedMinutes) * 60)
            paint(max(bed, dayStart), wake, .sleep, "Sleep", observed: h.sleepSource != .motion && h.sleepSource != .plan)
        } else {
            // No Health data: assume the planned wake-up, which already knows about
            // exceptions (no school today means a free-day wake).
            let w = WakePlanner.plan(for: dayStart, commitments: d.commitments, events: d.fixedEvents, routines: d.routines,
                                     prefs: d.prefs, calendar: cal, exceptions: d.exceptions).wake
            paint(dayStart, w, .sleep, "Sleep", observed: false)
        }
        if let next = d.nextHealth, let bed = next.bedtime, cal.isDate(bed, inSameDayAs: dayStart) {
            // The night that starts this evening (its bedtime is today).
            paint(bed, dayEnd, .sleep, "Sleep", observed: true)
        }

        // Layer 3: study the student actually did (block outcomes).
        for o in d.outcomes where o.status != .skipped && cal.isDate(o.plannedStart, inSameDayAs: dayStart) {
            let title = o.itemId.flatMap { d.itemsById[$0]?.title } ?? "Study"
            paint(o.plannedStart, o.plannedStart.addingTimeInterval(Double(o.actualMinutes) * 60), .study, title, observed: true)
        }

        // Layer 4: explicit markers, the ground truth. Pair start → end per activity.
        let evs = d.events.filter { cal.isDate($0.at, inSameDayAs: dayStart) }.sorted { $0.at < $1.at }
        var open: [String: TimelineEvent] = [:]
        for e in evs {
            switch e.phase {
            case .start:
                open[e.activity] = e
            case .end:
                if let s = open.removeValue(forKey: e.activity) {
                    paint(s.at, e.at, e.category, display(e.activity), observed: true)
                } else if e.activity == "wake" || e.activity == "sleep" {
                    paint(dayStart, e.at, .sleep, "Sleep", observed: true)
                } else if let scheduled = todays.first(where: { MarkerParser.normalise($0.title) == e.activity }) {
                    paint(at(scheduled.start), e.at, e.category, scheduled.title, observed: true)
                } else if let r = d.routines.first(where: { $0.id == e.activity }) {
                    paint(e.at.addingTimeInterval(-Double(r.minutes) * 60), e.at, e.category, r.name, observed: true)
                }
            case .point:
                break
            }
        }
        // Still-open activities run until the scheduled end, `now`, or 2 h max.
        for (_, s) in open {
            var end = s.at.addingTimeInterval(2 * 3600)
            if let scheduled = todays.first(where: { MarkerParser.normalise($0.title) == s.activity }) { end = at(scheduled.end) }
            if let r = d.routines.first(where: { $0.id == s.activity }) { end = s.at.addingTimeInterval(Double(r.minutes) * 60) }
            if s.activity == "sleep" { end = dayEnd }
            if let now, now < end { end = now }
            paint(s.at, end, s.category, display(s.activity), observed: true)
        }

        // Future minutes on today aren't "free time" yet.
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

    /// Minutes per category for one day. Screen time (from Screen Time thresholds)
    /// isn't time-stamped, so it's carved out of free time.
    public static func totals(_ segments: [Segment], screen: ScreenDay?) -> [TimeCategory: Int] {
        var t: [TimeCategory: Int] = [:]
        for s in segments { t[s.category, default: 0] += s.minutes }
        if let scr = screen?.distractingMinutes, scr > 0 {
            let carved = min(scr, t[.free] ?? 0)
            t[.free, default: 0] -= carved
            t[.screen, default: 0] += scr
        }
        return t
    }
}

// MARK: - What to suggest checking in next (one tap)

public enum CheckInSuggester {
    /// The one marker most likely to be useful right now, or nil. The app shows it
    /// as a single chip, so the student taps instead of types.
    public static func suggestion(now: Date, todaysEvents: [TimelineEvent], commitments: [Commitment],
                                  routines: [Routine], calendar cal: Calendar) -> String? {
        let weekday = cal.component(.weekday, from: now)
        let school = commitments.filter { $0.weekdays.contains(weekday) && $0.kind == .school }
        func at(_ t: TimeOfDay) -> Date { cal.date(bySettingHour: t.hour, minute: t.minute, second: 0, of: now) ?? now }
        let logged = Set(todaysEvents.map { "\($0.activity)|\($0.phase.rawValue)" })
        guard let first = school.min(by: { $0.start < $1.start }), let last = school.max(by: { $0.end < $1.end }) else { return nil }
        let toSchool = routines.first { $0.id == "to_school" }?.minutes ?? 20
        let start = at(first.start), end = at(last.end)
        let leave = start.addingTimeInterval(-Double(toSchool + 15) * 60)
        // Learning phase: ask until each routine has a few samples, then stop asking.
        let needsCommute = (routines.first { $0.id == "to_school" }?.samples.count ?? 0) < 5
        let needsHome = (routines.first { $0.id == "from_school" }?.samples.count ?? 0) < 5
        if needsCommute, now >= leave.addingTimeInterval(-20 * 60), now < start, !logged.contains("to_school|start") { return "Left home" }
        if needsCommute, logged.contains("to_school|start"), !logged.contains("to_school|end"), now < start.addingTimeInterval(3600) { return "At school" }
        if needsHome, now >= end, now < end.addingTimeInterval(2 * 3600), !logged.contains("from_school|start") { return "Left school" }
        if needsHome, logged.contains("from_school|start"), !logged.contains("from_school|end") { return "Home" }
        return nil
    }
}

// Encode `[TimeCategory: Int]` as a JSON object, not a flat array.
extension TimeCategory: CodingKeyRepresentable {}
