import Foundation

// v1.2 D4: "What are you up to?", timed by the tracking goal (no untracked waking stretch over 30 minutes). The first
// prompt comes at 25 minutes untracked, so there's time to answer before the goal is missed, then every 30 while
// nothing starts. Never in sleep, wind-down, a planned study block or school; after 2 ignored in a row, not again that
// day (the stretch still counts against the goal). Time already past gets one question in the past tense.
// A7: the morning "Slept about …?" when nothing measured the night.
// D6: the running entry's passive notification (the Live Activity's fallback).

/// What was asked and answered (for the back-off), kept a few days.
public struct PromptLog: Codable, Hashable, Sendable {
    public struct Asked: Codable, Hashable, Sendable {
        public var at: Date
        public var stretchStart: Date
        public var past: Bool
        public init(at: Date, stretchStart: Date, past: Bool) { self.at = at; self.stretchStart = stretchStart; self.past = past }
    }
    public var asked: [Asked] = []
    /// Scheduled but not yet delivered: they become `asked` once their time passes (`roll`).
    public var scheduled: [Asked] = []
    /// Answers and starts (any tracking at all resets the back-off).
    public var answered: [Date] = []
    /// Mornings the sleep question was answered (or measured), so it isn't asked twice.
    @SortedSet public var sleepAnswered: Set<String> = []
    public init() {}

    /// Prompts whose time has passed were delivered: they count as asked (for the back-off and "asked once").
    public mutating func roll(now: Date) {
        asked += scheduled.filter { $0.at <= now }
        scheduled.removeAll { $0.at <= now }
    }

    public mutating func prune(now: Date) {
        asked.removeAll { now.timeIntervalSince($0.at) > 3 * 86400 }
        answered.removeAll { now.timeIntervalSince($0) > 3 * 86400 }
        if sleepAnswered.count > 14 { sleepAnswered = Set(sleepAnswered.sorted().suffix(14)) }
    }

    /// Prompts delivered today since the last answer.
    public func ignoredInARow(now: Date, calendar cal: Calendar) -> Int {
        let lastAnswer = answered.filter { $0 <= now }.max() ?? .distantPast
        return asked.filter { $0.at <= now && $0.at > lastAnswer && cal.isDate($0.at, inSameDayAs: now) && !$0.past }.count
    }
}

public struct TrackPromptInput: Sendable {
    public var now: Date
    public var calendar: Calendar
    public var entries: [Entry]
    public var plan: Plan
    public var book: DayRuleBook
    public var log: PromptLog
    /// The three likeliest start buttons (their titles become the notification's actions).
    public var buttons: [String]

    public init(now: Date, calendar: Calendar, entries: [Entry], plan: Plan, book: DayRuleBook = DayRuleBook(), log: PromptLog = PromptLog(),
                buttons: [String] = []) {
        self.now = now
        self.calendar = calendar
        self.entries = entries
        self.plan = plan
        self.book = book
        self.log = log
        self.buttons = buttons
    }
}

public enum TrackPrompts {
    public static let goalMinutes = 30
    public static let firstAfter = 25
    public static let every = 30
    public static let maxIgnored = 2

    /// A moment nothing should ask: asleep, winding down, a planned study block (its own nudges cover it), before wake.
    static func quiet(_ t: Date, _ x: TrackPromptInput) -> Bool {
        if let b = x.plan.blocks.first(where: { $0.start <= t && t < $0.end }) {
            switch b.kind {
            case .sleep, .windDown, .work, .review: return true
            default: break
            }
        }
        let cal = x.calendar
        if let w = x.plan.wakePlans.first(where: { cal.isDate($0.wake, inSameDayAs: t) }), t < w.wake { return true }
        let h = cal.component(.hour, from: t)
        return h < 6 || h >= 23
    }

    /// Covered from `t` on by something that isn't a guess the prompt should fill: a running entry, your entries,
    /// the timetable, calendar, sensors, planned routines, and planned task sessions (their nudges cover them).
    static func coveredUntil(_ t: Date, _ x: TrackPromptInput) -> Date? {
        if TimeLog.running(x.entries) != nil { return .distantFuture }
        let horizon = DateInterval(start: t, duration: 18 * 3600)
        let occ = Days.expand(x.entries, in: horizon, now: x.now, book: x.book, calendar: x.calendar).filter { !$0.running }
        var until = t
        var moved = true
        while moved {
            moved = false
            for o in occ where o.start <= until.addingTimeInterval(60) && o.end > until {
                until = o.end
                moved = true
            }
        }
        return until > t ? until : nil
    }

    public static func plan(_ x: TrackPromptInput) -> [PlannedNudge] {
        let cal = x.calendar, now = x.now
        var out: [PlannedNudge] = []
        let hm = DateFormatter.local("H:mm", cal)
        let actions = Array(x.buttons.prefix(3))
        let today = Days.dayInterval(now, cal)
        let slices = TimeLog.past(x.entries, in: DateInterval(start: today.start, end: now), now: now, book: x.book, calendar: cal)

        // Past tense: closed untracked stretches today, ≥30 min, after wake, not asked yet. One question at a time.
        let wake = x.plan.wakePlans.first { cal.isDate($0.wake, inSameDayAs: now) }?.wake ?? today.start.addingTimeInterval(7 * 3600)
        let open = slices.last.map { $0.entry == nil && $0.end >= now.addingTimeInterval(-60) } ?? false
        let closed = TimeLog.untracked(open ? Array(slices.dropLast()) : slices, atLeast: goalMinutes)
            .filter { $0.start >= wake.addingTimeInterval(-60) && !quiet($0.start.addingTimeInterval(60), x) }
        if let gap = closed.last(where: { g in !x.log.asked.contains { $0.past && abs($0.stretchStart.timeIntervalSince(g.start)) < 60 } }),
           !quiet(now, x) {
            out.append(PlannedNudge(id: "track.past", kind: .untracked, at: now.addingTimeInterval(60),
                                    title: "Nothing logged \(hm.string(from: gap.start))–\(hm.string(from: gap.end))",
                                    body: "What was it? Tap one, or press and hold to type it.", actions: actions,
                                    window: DateInterval(start: gap.start, end: gap.end)))
        }

        // Live: from when tracking stops (now, or when what covers now ends), at 25 minutes, then every 30.
        guard x.log.ignoredInARow(now: now, calendar: cal) < maxIgnored else { return out }
        var start: Date
        if open, let last = slices.last {
            start = max(last.start, wake)
        } else if let until = coveredUntil(now, x), until != .distantFuture {
            start = until
        } else if coveredUntil(now, x) == .distantFuture {
            return out
        } else {
            start = now
        }
        start = max(start, wake)
        let already = x.log.ignoredInARow(now: now, calendar: cal)
        var t = start.addingTimeInterval(Double(firstAfter) * 60)
        // Slots that passed while the app wasn't running weren't asked; the next one is.
        while t <= now.addingTimeInterval(30) { t = t.addingTimeInterval(Double(every) * 60) }
        var n = 0
        while n < maxIgnored - already && t < max(start, now).addingTimeInterval(6 * 3600) {
            if t > now.addingTimeInterval(30), !quiet(t, x), cal.isDate(t, inSameDayAs: now) || t < today.end.addingTimeInterval(3600) {
                // Something planned or assumed between `start` and `t` would cover it: stop there.
                if let c = coveredUntil(start.addingTimeInterval(60), x), c < .distantFuture, c > start.addingTimeInterval(120) { break }
                out.append(PlannedNudge(id: "track.live.\(n)", kind: .untracked, at: t, title: "What are you up to?",
                                        body: "Nothing's been tracked since \(hm.string(from: start)). Tap one, or press and hold to type it.",
                                        actions: actions, window: DateInterval(start: start, end: t)))
                n += 1
            } else if quiet(t, x) {
                break
            }
            t = t.addingTimeInterval(Double(every) * 60)
        }
        return out
    }

    // MARK: A7

    /// At 10:00, when nothing measured last night (no Health night, nothing you said): "Slept about 11:20–7:05?"
    public static func sleepQuestion(entries: [Entry], now: Date, log: PromptLog, calendar cal: Calendar) -> PlannedNudge? {
        let day = cal.startOfDay(for: now)
        let key = DayKeys.key(day, cal)
        guard !log.sleepAnswered.contains(key), let ten = cal.date(bySettingHour: 10, minute: 0, second: 0, of: day), now < ten else { return nil }
        let night = DateInterval(start: day.addingTimeInterval(-6 * 3600), end: day.addingTimeInterval(13 * 3600))
        let occ = Days.expand(entries, in: night, now: now, calendar: cal).filter { $0.category == CategoryTree.sleep || $0.title == "Sleep" }
        if occ.contains(where: { $0.source == .health || ($0.source == .you && !$0.assumed) || $0.mark == .confirmed }) { return nil }
        guard let guess = occ.filter({ $0.source == .sensor }).max(by: { $0.minutes < $1.minutes })
            ?? occ.filter({ $0.source == .plan }).max(by: { $0.minutes < $1.minutes }) else { return nil }
        let hm = DateFormatter.local("H:mm", cal)
        return PlannedNudge(id: "track.sleep", kind: .sleepConfirm, at: ten,
                            title: "Slept about \(hm.string(from: guess.start))–\(hm.string(from: guess.end))?",
                            body: "Yes logs it. Change, or press and hold to type the right times.",
                            window: DateInterval(start: guess.start, end: guess.end))
    }

    // MARK: D6

    /// The running entry's notification, replaced every 10 minutes for two hours (passive, no sound).
    public static func running(_ e: Entry?, tree: CategoryTree, goalLine: String?, now: Date) -> [PlannedNudge] {
        guard let e, e.isRunning else { return [] }
        let path = tree.pathText(e.category)
        return (0...12).map { k in
            let at = now.addingTimeInterval(Double(k) * 600)
            let mins = max(0, Int(at.timeIntervalSince(e.start) / 60))
            var body = "\(minutesLabel(mins)) · \(path)"
            if let g = goalLine { body += " · \(g)" }
            return PlannedNudge(id: "running.\(k)", kind: .running, at: at, title: e.title, body: body)
        }
    }
}
