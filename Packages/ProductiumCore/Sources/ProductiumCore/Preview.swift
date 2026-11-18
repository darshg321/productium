import Foundation

// v1.1 A.4 / A.6: show the effect, not the edit. Every situation (and DayRule change) gets a receipt that compares
// the plan with and without it, day by day: "Tue: School 8:30–3:00 → 9:15–3:30 · up 7:20 → 8:05 · study 90 → 45 min".

public struct DayDiff: Hashable, Sendable {
    public var day: Date
    public var lines: [String]
}

public enum Preview {
    /// Plans both inputs with the same clock and compares the next `days` days.
    public static func diff(before: PlannerInput, after: PlannerInput, days: Int = 7) -> [DayDiff] {
        var b = before, a = after
        b.horizonDays = max(b.horizonDays, days + 1)
        a.horizonDays = max(a.horizonDays, days + 1)
        return diff(Planner.plan(b), Planner.plan(a), from: before.now, days: days, calendar: before.calendar)
    }

    /// The same, with one situation added.
    public static func diff(_ input: PlannerInput, adding s: Situation, days: Int = 7) -> [DayDiff] {
        var after = input
        after.situations.append(s)
        return diff(before: input, after: after, days: days)
    }

    public static func diff(_ before: Plan, _ after: Plan, from now: Date, days: Int, calendar cal: Calendar) -> [DayDiff] {
        let today = cal.startOfDay(for: now)
        return (0..<days).compactMap { i -> DayDiff? in
            guard let d = cal.date(byAdding: .day, value: i, to: today) else { return nil }
            let lines = compare(before, after, on: d, calendar: cal)
            return lines.isEmpty ? nil : DayDiff(day: d, lines: lines)
        }
    }

    static let fixedKinds: Set<BlockKind> = [.commitment, .event, .routine, .meal]

    static func compare(_ b: Plan, _ a: Plan, on d: Date, calendar cal: Calendar) -> [String] {
        func t(_ x: Date) -> String {
            let c = cal.dateComponents([.hour, .minute], from: x)
            let h = (c.hour ?? 0) % 12 == 0 ? 12 : (c.hour ?? 0) % 12
            return String(format: "%d:%02d", h, c.minute ?? 0)
        }
        func span(_ x: PlannedBlock) -> String { "\(t(x.start))–\(t(x.end))" }
        var out: [String] = []

        let wb = b.wakePlans.first { cal.isDate($0.day, inSameDayAs: d) }?.wake
        let wa = a.wakePlans.first { cal.isDate($0.day, inSameDayAs: d) }?.wake
        if let wb, let wa, wb != wa { out.append("up \(t(wb)) → \(t(wa))") }

        // Fixed time, matched by kind and title, in time order.
        let fb = b.blocks(on: d, calendar: cal).filter { fixedKinds.contains($0.kind) }
        let fa = a.blocks(on: d, calendar: cal).filter { fixedKinds.contains($0.kind) }
        let titles = (fb + fa).sorted { $0.start < $1.start }.reduce(into: [String]()) { acc, x in
            if !acc.contains(x.title) { acc.append(x.title) }
        }
        for title in titles {
            let xb = fb.filter { $0.title == title }.map(span), xa = fa.filter { $0.title == title }.map(span)
            guard xb != xa else { continue }
            switch (xb.isEmpty, xa.isEmpty) {
            case (true, false): out.append("+ \(title) \(xa.joined(separator: ", "))")
            case (false, true): out.append("no \(title)")
            default: out.append("\(title) \(xb.joined(separator: ", ")) → \(xa.joined(separator: ", "))")
            }
        }

        let sb = b.blocks(on: d, calendar: cal).filter(\.isStudy).reduce(0) { $0 + $1.minutes }
        let sa = a.blocks(on: d, calendar: cal).filter(\.isStudy).reduce(0) { $0 + $1.minutes }
        if sb != sa { out.append(sa == 0 ? "no study (was \(minutesLabel(sb)))" : "study \(minutesLabel(sb)) → \(minutesLabel(sa))") }

        let bb = b.blocks.first { $0.kind == .sleep && cal.isDate($0.start.addingTimeInterval(-6 * 3600), inSameDayAs: d) }?.start
        let ba = a.blocks.first { $0.kind == .sleep && cal.isDate($0.start.addingTimeInterval(-6 * 3600), inSameDayAs: d) }?.start
        if let bb, let ba, bb != ba { out.append("bed \(t(bb)) → \(t(ba))") }

        let mb = Set((b.mutes ?? []).filter { cal.isDate($0.day, inSameDayAs: d) }.map { $0.kind?.rawValue ?? "*" })
        let ma = Set((a.mutes ?? []).filter { cal.isDate($0.day, inSameDayAs: d) }.map { $0.kind?.rawValue ?? "*" })
        if ma.contains("*") && !mb.contains("*") { out.append("no reminders") }
        else { for k in ma.subtracting(mb).sorted() where k != "*" { out.append("no \(k) reminders") } }
        return out
    }

    /// "Tue 17 Nov: School 8:30–3:00 → 9:15–3:30 · study 1h 30m → 45m", one line per changed day.
    public static func receipt(_ diffs: [DayDiff], calendar cal: Calendar, limit: Int = 7) -> [String] {
        let f = DateFormatter.local("EEE d MMM", cal)
        let lines = diffs.prefix(limit).map { "\(f.string(from: $0.day)): " + $0.lines.joined(separator: " · ") }
        return diffs.count > limit ? lines + ["…and \(diffs.count - limit) more days"] : lines
    }
}

// MARK: - A.3: what a change may not break, and how it's applied

public enum SituationTier: String, Codable, Sendable {
    /// Ends within ~14 days (or has an end date that close): applied at once, with Undo.
    case short
    /// Open-ended but describes facts (a timetable, a rotation, a new commute): applied at once with a receipt.
    case facts
    /// Open-ended change to how the app behaves (capacity, free time, block length, reminders): only the insight
    /// pass makes these, quietly, within maximum steps.
    case behaviour
}

public struct SituationRefusal: Error, Hashable, Sendable {
    public var rule: String
    public var reason: String
}

public enum SituationRules {
    public static let shortDays = 14
    static let behaviourPaths: Set<String> = ["planner.capacity", "planner.freeTimeMultiplier", "planner.maxBlockMinutes"]
    /// Largest step from the usual value an open-ended behaviour override may take (the insight pass's limits).
    static let maxStep: [String: Double] = ["planner.capacity": 0.2, "planner.freeTimeMultiplier": 0.2, "planner.maxBlockMinutes": 10]

    /// The last day a situation can apply, if its scope or expiry bounds it.
    public static func lastDay(_ s: Situation, calendar cal: Calendar) -> Date? {
        func bound(_ r: DayRule) -> Date? {
            switch r {
            case .dates(_, let until): return until
            case .on(let ds): return ds.max()
            case .all(let rs): return rs.compactMap(bound).min()
            case .any(let rs): let b = rs.map(bound); return b.contains { $0 == nil } ? nil : b.compactMap { $0 }.max()
            default: return nil
            }
        }
        return [s.expires, bound(s.scope)].compactMap { $0 }.min()
    }

    public static func tier(_ s: Situation, now: Date, calendar cal: Calendar) -> SituationTier {
        if let last = lastDay(s, calendar: cal),
           (cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: last)).day ?? 0) <= shortDays {
            return .short
        }
        let behaviour = s.effects.contains { e in
            switch e {
            case .setInput(let p, _): return behaviourPaths.contains(p)
            case .mute: return true
            default: return false
            }
        }
        return behaviour ? .behaviour : .facts
    }

    /// Checks a situation before it's stored: the writer may make it, its inputs and items exist, and the plan
    /// it produces keeps every invariant. Returns the tier it's applied at, or why it's refused.
    public static func admit(_ s: Situation, into input: PlannerInput, writer: Writer, calendarEventIds: Set<String> = [],
                             days: Int = 14) -> Result<SituationTier, SituationRefusal> {
        let cal = input.calendar
        let tier = tier(s, now: input.now, calendar: cal)
        if tier == .behaviour && writer != .reflection {
            return .failure(SituationRefusal(rule: "behaviour",
                reason: "An open-ended change to how Productium plans only comes from your weeks (What Productium Thinks). For a few days, say until when."))
        }
        let items = Set(input.items.map(\.id)), acts = Set(input.commitments.map(\.id))
        for e in s.effects {
            switch e {
            case .setInput(let p, let v):
                guard let spec = SituationInputs.spec(p) else {
                    return .failure(SituationRefusal(rule: "input", reason: "There's no planner input called “\(p)”"))
                }
                guard spec.range.contains(v) else {
                    return .failure(SituationRefusal(rule: "range", reason: "\(p) must be between \(Knobs.format(spec.range.lowerBound)) and \(Knobs.format(spec.range.upperBound))"))
                }
                if tier == .behaviour, let step = maxStep[p], abs(v - usual(p, input)) > step + 1e-9 {
                    return .failure(SituationRefusal(rule: "step", reason: "\(p) can move at most \(Knobs.format(step)) at a time"))
                }
            case .hold(let i), .boost(let i):
                guard items.contains(i) else { return .failure(SituationRefusal(rule: "item", reason: "No such task")) }
            case let .place(i, st, en):
                guard items.contains(i) else { return .failure(SituationRefusal(rule: "item", reason: "No such task")) }
                guard en > st, en.minutesFromMidnight - st.minutesFromMidnight <= 240 else {
                    return .failure(SituationRefusal(rule: "time", reason: "A study block is between a few minutes and 4 hours, ending after it starts"))
                }
            case .replace(let c, let blocks):
                guard acts.contains(c) else { return .failure(SituationRefusal(rule: "activity", reason: "No such activity")) }
                guard !blocks.isEmpty, blocks.allSatisfy({ $0.end > $0.start }) else {
                    return .failure(SituationRefusal(rule: "activity", reason: "A timetable needs periods with a start before the end"))
                }
            case let .busy(st, en, _), let .free(st, en):
                guard en > st else { return .failure(SituationRefusal(rule: "time", reason: "\(st.label)–\(en.label) ends before it starts")) }
            case .mute, .note: break
            }
        }
        // Calendar events are read-only: a situation can't free up their time.
        let evaluator = DayRuleEvaluator(book: input.dayRules, calendar: cal)
        let start = cal.startOfDay(for: input.now)
        for i in 0..<days {
            guard let d = cal.date(byAdding: .day, value: i, to: start), s.isActive(on: d, calendar: cal),
                  evaluator.matches(s.scope, on: d) else { continue }
            for e in s.effects {
                guard case let .free(st, en) = e,
                      let a = cal.date(bySettingHour: st.hour, minute: st.minute, second: 0, of: d),
                      let b = cal.date(bySettingHour: en.hour, minute: en.minute, second: 0, of: d) else { continue }
                if let ev = input.events.first(where: { calendarEventIds.contains($0.id) && $0.start < b && a < $0.end }) {
                    return .failure(SituationRefusal(rule: "calendar", reason: "“\(ev.title)” is in your calendar; change it there"))
                }
            }
        }
        // The resolved plan keeps the sleep floor: a situation's busy time may not eat into a night below it.
        var after = input
        after.situations.append(s)
        after.horizonDays = max(input.horizonDays, days)
        let plan = Planner.plan(after)
        let floor = input.preferences.sleepFloorMinutes
        for sleep in plan.blocks where sleep.kind == .sleep {
            let taken = plan.blocks.filter { $0.sourceId == "situation:\(s.id)" && $0.start < sleep.end && sleep.start < $0.end }
                .reduce(0.0) { $0 + min($1.end, sleep.end).timeIntervalSince(max($1.start, sleep.start)) }
            let left = Int((sleep.end.timeIntervalSince(sleep.start) - taken) / 60)
            if taken > 0 && left < floor {
                return .failure(SituationRefusal(rule: "sleep",
                    reason: "That leaves \(minutesLabel(max(0, left))) of sleep, under your \(minutesLabel(floor)) floor"))
            }
        }
        return .success(tier)
    }

    static func usual(_ path: String, _ input: PlannerInput) -> Double {
        switch path {
        case "planner.maxBlockMinutes": return Double(input.policy.maxBlockMinutes)
        default: return 1
        }
    }
}
