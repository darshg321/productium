import Foundation

public struct MysteryGap: Codable, Hashable, Sendable {
    public var start: Date
    public var end: Date
    public var ongoing: Bool
    public var minutes: Int { Int(end.timeIntervalSince(start) / 60) }
    public init(start: Date, end: Date, ongoing: Bool) { self.start = start; self.end = end; self.ongoing = ongoing }
}

public struct AskedGap: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var start: Date
    public var end: Date
    public var askedAt: Date
    public var answer: String?
    public var activity: String?
    public init(id: UUID = UUID(), start: Date, end: Date, askedAt: Date, answer: String? = nil, activity: String? = nil) {
        self.id = id
        self.start = start
        self.end = end
        self.askedAt = askedAt
        self.answer = answer
        self.activity = activity
    }
}

public struct GapLog: Codable, Hashable, Sendable {
    public var asked: [AskedGap]
    public init(asked: [AskedGap] = []) { self.asked = asked }

    public func askedCount(on day: Date, calendar cal: Calendar) -> Int {
        asked.filter { cal.isDate($0.askedAt, inSameDayAs: day) }.count
    }

    public func covers(_ g: MysteryGap) -> Bool {
        asked.contains { a in
            let overlap = min(a.end, g.end).timeIntervalSince(max(a.start, g.start))
            return overlap > 0.5 * min(a.end.timeIntervalSince(a.start), g.end.timeIntervalSince(g.start))
                || (g.ongoing && a.start == g.start)
        }
    }
}

public struct GapInput: Sendable {
    public var now: Date
    public var day: DayInputs
    public var scrolling: [ScrollSession]
    public var phoneUse: [Date]
    public var plan: Plan
    public var focusing: Bool
    public var log: GapLog

    public init(now: Date, day: DayInputs, scrolling: [ScrollSession] = [], phoneUse: [Date] = [], plan: Plan = .empty,
                focusing: Bool = false, log: GapLog = GapLog()) {
        self.now = now
        self.day = day
        self.scrolling = scrolling
        self.phoneUse = phoneUse
        self.plan = plan
        self.focusing = focusing
        self.log = log
    }
}

public enum GapDetector {
    public static let minMinutes = 40
    public static let askAfterEnd: TimeInterval = 10 * 60
    public static let askOngoingAt: TimeInterval = 45 * 60
    public static let freshFor: TimeInterval = 2 * 3600
    public static let maxPerDay = 4

    public static func gaps(_ input: GapInput, calendar cal: Calendar) -> [MysteryGap] {
        let now = input.now
        let segs = TimelineBuilder.segments(input.day, calendar: cal, now: now)
        var open = segs.filter { $0.category == .free && $0.inferred && $0.label == "Free" }.map { ($0.start, $0.end) }
        var known = input.scrolling.map { ($0.openedAt, $0.endedAt ?? now) }
        known += input.plan.blocks.filter(\.isStudy).map { ($0.start, $0.end) }
        for (ks, ke) in known {
            open = open.flatMap { (s, e) -> [(Date, Date)] in
                guard ks < e, ke > s else { return [(s, e)] }
                return [(s, min(e, ks)), (max(s, ke), e)].filter { $0.1 > $0.0 }
            }
        }
        let moving = input.day.motion.filter { $0.isTravel }
        return open.compactMap { s, e in
            let g = MysteryGap(start: s, end: e, ongoing: e >= now.addingTimeInterval(-60))
            guard g.minutes >= minMinutes else { return nil }
            let awake = input.phoneUse.contains { $0 >= s.addingTimeInterval(-5 * 60) && $0 <= e.addingTimeInterval(5 * 60) }
                || moving.contains { $0.end > s && $0.start < e }
            return awake ? g : nil
        }
    }

    public static func due(_ input: GapInput, calendar cal: Calendar) -> MysteryGap? {
        let now = input.now
        guard allowed(at: now, input, calendar: cal) else { return nil }
        return gaps(input, calendar: cal).reversed().first { g in
            guard !input.log.covers(g), now.timeIntervalSince(g.start) <= freshFor else { return false }
            return g.ongoing ? now.timeIntervalSince(g.start) >= askOngoingAt : now >= g.end.addingTimeInterval(askAfterEnd)
        }
    }

    public static func nextAsk(_ input: GapInput, calendar cal: Calendar) -> (at: Date, gap: MysteryGap)? {
        let now = input.now
        let segs = TimelineBuilder.segments(input.day, calendar: cal, now: now)
        guard let last = segs.last, last.category == .free, last.inferred, last.label == "Free" else { return nil }
        var since = last.start
        for s in input.scrolling where (s.endedAt ?? now) > since && (s.endedAt ?? now) <= now { since = s.endedAt ?? now }
        let at = since.addingTimeInterval(askOngoingAt)
        guard at > now, at.timeIntervalSince(since) <= freshFor, cal.isDate(at, inSameDayAs: now) else { return nil }
        var later = input
        later.now = at
        guard allowed(at: at, later, calendar: cal) else { return nil }
        let g = MysteryGap(start: since, end: at, ongoing: true)
        return input.log.covers(g) ? nil : (at, g)
    }

    static func allowed(at t: Date, _ input: GapInput, calendar cal: Calendar) -> Bool {
        guard !input.focusing, input.log.askedCount(on: t, calendar: cal) < maxPerDay else { return false }
        let quiet = input.plan.blocks.contains { ($0.kind == .windDown || $0.kind == .sleep) && $0.start <= t && t < $0.end }
        return !quiet
    }

    public static func question(_ g: MysteryGap, calendar cal: Calendar) -> String {
        let f = DateFormatter.local("h:mm", cal)
        return g.ongoing ? "What have you been doing since \(f.string(from: g.start))?"
            : "What were you doing \(f.string(from: g.start))–\(f.string(from: g.end))?"
    }
}

public enum GapAnswer {
    static let vocabulary: [(words: [String], key: String, category: TimeCategory)] = [
        (["homework", "studying", "study", "essay", "assignment", "revising", "revision"], "study", .study),
        (["gym", "workout", "run", "running", "basketball", "soccer", "swim", "practice", "training"], "exercise", .activities),
        (["nap", "napping", "slept", "sleeping"], "nap", .sleep),
        (["dinner", "lunch", "eating", "snack", "breakfast", "cooking"], "meal", .routine),
        (["shower", "getting ready", "chores", "cleaning", "laundry"], "chores", .routine),
        (["bus", "driving", "walking home", "commute", "travel"], "travel", .commute),
        (["gaming", "games", "tv", "netflix", "youtube", "tiktok", "instagram", "scrolling", "phone"], "screen", .screen),
        (["friends", "hanging out", "family", "call", "facetime"], "social", .free),
        (["reading", "music", "guitar", "piano", "drawing", "art"], "hobby", .free),
    ]

    public static func markers(for text: String, gap: MysteryGap, commitments: [Commitment], known: [AskedGap],
                               calendar cal: Calendar) -> [TimelineEvent]? {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "’", with: "'")
        guard !t.isEmpty else { return nil }
        func pair(_ key: String, _ c: TimeCategory) -> [TimelineEvent] {
            [TimelineEvent(at: gap.start, phrase: text, activity: key, category: c, phase: .start, source: .notification),
             TimelineEvent(at: gap.end, phrase: text, activity: key, category: c, phase: .end, source: .notification)]
        }
        if let c = commitments.first(where: { t.contains(MarkerParser.normalise($0.title)) }) {
            return pair(MarkerParser.normalise(c.title), TimeCategory.from(c.kind))
        }
        let words = t.split(whereSeparator: { !$0.isLetter && $0 != "'" }).count
        guard words <= 4 else { return nil }
        if let v = vocabulary.first(where: { $0.words.contains { t.contains($0) } }) { return pair(v.key, v.category) }
        if let prev = known.first(where: { $0.answer?.lowercased() == t }), let key = prev.activity {
            return pair(key, .free)
        }
        return nil
    }

    public static func boxText(_ text: String, gap: MysteryGap, calendar cal: Calendar) -> String {
        let f = DateFormatter.local("yyyy-MM-dd'T'HH:mm", cal)
        return "From \(f.string(from: gap.start)) to \(f.string(from: gap.end)) I was: \(text)"
    }

    public static func repeated(_ asked: [AskedGap], calendar cal: Calendar) -> [(activity: String, weekday: Int, hour: Int, count: Int)] {
        var groups: [String: (String, Int, Int, Int)] = [:]
        for a in asked {
            guard let act = a.activity else { continue }
            let wd = cal.component(.weekday, from: a.start), h = cal.component(.hour, from: a.start)
            let k = "\(act)|\(wd)|\(h)"
            groups[k] = (act, wd, h, (groups[k]?.3 ?? 0) + 1)
        }
        return groups.values.filter { $0.3 >= 3 }.map { (activity: $0.0, weekday: $0.1, hour: $0.2, count: $0.3) }
            .sorted { $0.count > $1.count }
    }
}
