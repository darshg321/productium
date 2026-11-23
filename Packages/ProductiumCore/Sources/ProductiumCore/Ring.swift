import Foundation

// v1.2 Part G: the ring (Home: today; Review: day / week / month), the forecast you can beat, Up Next's one line,
// and mood by time of day. All computed from the log (`TimeLog.past`), so every screen agrees.

public struct RingSlice: Hashable, Identifiable, Sendable {
    /// A category id, a group's raw value, or `untracked`.
    public var id: String
    public var name: String
    public var group: CategoryGroup?
    public var minutes: Int
    /// The hatched part: forecast (or planned) minutes still to come in the range.
    public var forecast: Int
    /// The same range one period earlier (Review's "▲ 1h 20 vs last week").
    public var previous: Int?
    public var symbol: String
    public var colour: String

    public var delta: Int? { previous.map { minutes - $0 } }
}

public struct RingModel: Hashable, Sendable {
    public var range: DateInterval
    /// Inner ring: groups (and Untracked).
    public var groups: [RingSlice]
    /// Outer ring: the level-2 categories (School › Math, Work › Studying, a root without children).
    public var categories: [RingSlice]
    /// Actual minutes per leaf, for drilling down.
    public var leaves: [CategoryID: Int]
    public var actualMinutes: Int
    public var forecastMinutes: Int
    public var untrackedMinutes: Int
    public var trackingGaps: Int

    /// Awake minutes so far that are accounted for (the ring's centre).
    public var trackedMinutes: Int { actualMinutes - untrackedMinutes }

    static func level2(_ id: CategoryID, _ tree: CategoryTree) -> CategoryID {
        if id == CategoryTree.untracked { return id }
        let p = tree.path(id)
        return p.count >= 2 ? p[1].id : (p.first?.id ?? id)
    }

    /// `forecast`: minutes per level-2 category for the part of the range after `now` (nil: what's planned).
    public static func make(entries: [Entry], tree: CategoryTree, range: DateInterval, now: Date, forecast: [CategoryID: Int]? = nil,
                            previous: DateInterval? = nil, book: DayRuleBook = DayRuleBook(), calendar cal: Calendar) -> RingModel {
        let past = TimeLog.past(entries, in: range, now: now, book: book, calendar: cal)
        var leaves = TimeLog.totals(past)
        var cats: [CategoryID: Int] = [:]
        for (c, m) in leaves { cats[level2(c, tree), default: 0] += m }
        var ahead: [CategoryID: Int] = forecast ?? [:]
        if forecast == nil, range.end > now {
            // The rest of the range as planned (everything ahead, resolved by rank; free time isn't planned).
            let rest = DateInterval(start: max(now, range.start), end: range.end)
            let occ = Days.expand(entries, in: rest, now: now, book: book, calendar: cal).filter { !$0.running }
            for s in TimeLog.resolve(occ, in: rest) where s.entry != nil { ahead[level2(s.category, tree), default: 0] += s.minutes }
        }
        var prev: [CategoryID: Int] = [:]
        if let p = previous {
            for (c, m) in TimeLog.totals(TimeLog.past(entries, in: p, now: now, book: book, calendar: cal)) { prev[level2(c, tree), default: 0] += m }
        }
        func slice(_ id: CategoryID) -> RingSlice {
            let n = tree.node(id)
            return RingSlice(id: id, name: id == CategoryTree.untracked ? "Untracked" : (n?.name ?? id), group: tree.group(id),
                             minutes: cats[id] ?? 0, forecast: ahead[id] ?? 0, previous: previous == nil ? nil : (prev[id] ?? 0),
                             symbol: id == CategoryTree.untracked ? "questionmark" : (n?.symbol ?? "circle"),
                             colour: id == CategoryTree.untracked ? "gray" : (n?.colour ?? "gray"))
        }
        let ids = Set(cats.keys).union(ahead.keys).union(prev.keys)
        let catSlices = ids.map(slice).filter { $0.minutes > 0 || $0.forecast > 0 || ($0.previous ?? 0) > 0 }
            .sorted { ($0.group.map(order) ?? 9, -($0.minutes + $0.forecast)) < ($1.group.map(order) ?? 9, -($1.minutes + $1.forecast)) }
        var groups: [RingSlice] = []
        for g in CategoryGroup.allCases {
            let mine = catSlices.filter { $0.group == g && $0.id != CategoryTree.untracked }
            guard !mine.isEmpty else { continue }
            groups.append(RingSlice(id: g.rawValue, name: g.title, group: g, minutes: mine.reduce(0) { $0 + $1.minutes },
                                    forecast: mine.reduce(0) { $0 + $1.forecast },
                                    previous: previous == nil ? nil : mine.reduce(0) { $0 + ($1.previous ?? 0) },
                                    symbol: g.symbol, colour: g.colour))
        }
        if let u = catSlices.first(where: { $0.id == CategoryTree.untracked }) { groups.append(u) }
        leaves[CategoryTree.untracked] = nil
        let untracked = cats[CategoryTree.untracked] ?? 0
        return RingModel(range: range, groups: groups, categories: catSlices, leaves: leaves,
                         actualMinutes: past.reduce(0) { $0 + $1.minutes }, forecastMinutes: ahead.values.reduce(0, +),
                         untrackedMinutes: untracked, trackingGaps: Goals.gaps(past).count)
    }

    static func order(_ g: CategoryGroup) -> Int { CategoryGroup.allCases.firstIndex(of: g) ?? 9 }

}

extension CategoryGroup {
    public var title: String {
        switch self {
        case .productive: return "Productive"
        case .essential: return "Essentials"
        case .rest: return "Free Time"
        case .unproductive: return "Unproductive"
        }
    }
    public var symbol: String {
        switch self {
        case .productive: return "pencil.line"
        case .essential: return "checklist"
        case .rest: return "sun.max"
        case .unproductive: return "hourglass"
        }
    }
    public var colour: String {
        switch self {
        case .productive: return "blue"
        case .essential: return "green"
        case .rest: return "yellow"
        case .unproductive: return "pink"
        }
    }
}

// MARK: - G1a: the forecast you can beat

public struct DayForecast: Hashable, Sendable {
    /// Minutes still to come today per level-2 category (the hatched ring).
    public var rest: [CategoryID: Int]
    /// The whole day expected: actual so far + `rest`.
    public var expected: [CategoryID: Int]
    /// Your usual similar day (median per category).
    public var usual: [CategoryID: Int]
    public var similarDays: Int
    public var label: String

    public static let minDays = 3

    /// Similar days: the last 4 of the same weekday and the last 7 of the same kind (school / free). The median of what
    /// they did from this time of day on is the rest of today, with today's fixed time (school, calendar, the planned
    /// Sleep) taken as planned. Fewer than 3 similar days: nil (the ring shows the plan alone).
    public static func make(entries: [Entry], tree: CategoryTree, now: Date, isSchoolDay: (Date) -> Bool,
                            book: DayRuleBook = DayRuleBook(), calendar cal: Calendar) -> DayForecast? {
        let today = cal.startOfDay(for: now)
        let school = isSchoolDay(today)
        let weekday = cal.component(.weekday, from: today)
        var similar: [Date] = []
        for k in 1...28 {
            guard let d = cal.date(byAdding: .day, value: -k, to: today) else { continue }
            if cal.component(.weekday, from: d) == weekday && similar.filter({ cal.component(.weekday, from: $0) == weekday }).count < 4 {
                similar.append(d)
            }
        }
        for k in 1...7 {
            guard let d = cal.date(byAdding: .day, value: -k, to: today), isSchoolDay(d) == school, !similar.contains(d) else { continue }
            similar.append(d)
        }
        // Only days that were actually tracked (some told, sensor or health time).
        similar = similar.filter { d in
            entries.contains { $0.repeats == nil && $0.source != .plan && $0.source != .calendar && cal.isDate($0.start, inSameDayAs: d) }
        }
        guard similar.count >= minDays else { return nil }
        let secondsIn = now.timeIntervalSince(today)
        func byL2(_ slices: [LogSlice]) -> [CategoryID: Int] {
            var o: [CategoryID: Int] = [:]
            for s in slices { o[RingModel.level2(s.category, tree), default: 0] += s.minutes }
            return o
        }
        var restSamples: [[CategoryID: Int]] = [], fullSamples: [[CategoryID: Int]] = []
        for d in similar {
            let day = Days.dayInterval(d, cal)
            let cut = d.addingTimeInterval(min(secondsIn, day.duration))
            let after = DateInterval(start: cut, end: day.end)
            fullSamples.append(byL2(TimeLog.past(entries, in: day, now: day.end, book: book, calendar: cal)))
            restSamples.append(byL2(TimeLog.past(entries, in: after, now: day.end, book: book, calendar: cal)))
        }
        func median(_ xs: [[CategoryID: Int]]) -> [CategoryID: Int] {
            let keys = Set(xs.flatMap(\.keys))
            var o: [CategoryID: Int] = [:]
            for k in keys {
                let v = xs.map { $0[k] ?? 0 }.sorted()
                let m = v[v.count / 2]
                if m > 0 { o[k] = m }
            }
            return o
        }
        let restMedian = median(restSamples)
        // Today's fixed time ahead, exactly as planned.
        let todayEnd = Days.dayInterval(now, cal).end
        let ahead = DateInterval(start: now, end: todayEnd)
        let fixedOcc = Days.expand(entries, in: ahead, now: now, book: book, calendar: cal)
            .filter { !$0.running && !$0.isPlannedSession && ($0.source == .calendar || ($0.source == .you && $0.entry.repeats != nil)
                || ($0.source == .plan && tree.isUnder($0.category, CategoryTree.sleep))) }
        var fixed: [CategoryID: Int] = [:]
        for s in TimeLog.resolve(fixedOcc, in: ahead) where s.entry != nil { fixed[RingModel.level2(s.category, tree), default: 0] += s.minutes }
        let fixedTotal = fixed.values.reduce(0, +)
        let left = max(0, Int(ahead.duration / 60) - fixedTotal)
        // The rest follows the usual similar day (median per category, as it was), with today's fixed time instead of
        // the usual one; only if that's more than the time left is the usual part scaled down. What's left is Untracked.
        let flexible = restMedian.filter { fixed[$0.key] == nil && $0.key != CategoryTree.untracked }
        let flexTotal = flexible.values.reduce(0, +)
        let scale = flexTotal > left ? Double(left) / Double(flexTotal) : 1
        var rest = fixed
        for (k, v) in flexible { rest[k, default: 0] += Int((Double(v) * scale).rounded(.down)) }
        let used = rest.values.reduce(0, +)
        if used < Int(ahead.duration / 60) { rest[CategoryTree.untracked, default: 0] += Int(ahead.duration / 60) - used }
        let soFar = byL2(TimeLog.past(entries, in: DateInterval(start: today, end: now), now: now, book: book, calendar: cal))
        var expected = soFar
        for (k, v) in rest { expected[k, default: 0] += v }
        let name = DateFormatter.local("EEEE", cal).string(from: today)
        return DayForecast(rest: rest, expected: expected, usual: median(fullSamples), similarDays: similar.count,
                           label: "Usual \(name)")
    }
}

/// G1a: how today compares with your usual day, in one line, naming only the two biggest differences that matter.
public struct ForecastVerdict: Hashable, Sendable {
    public enum Kind: String, Sendable { case beat, onTrack, behind }
    public struct Difference: Hashable, Sendable {
        public var category: CategoryID
        public var name: String
        public var minutes: Int
        public var better: Bool
    }
    public var kind: Kind
    public var differences: [Difference]
    public var line: String

    public static func make(_ f: DayForecast, actualSoFar: [CategoryID: Int], tree: CategoryTree, goals: [Goal], now: Date,
                            calendar cal: Calendar) -> ForecastVerdict {
        var diffs: [Difference] = []
        for k in Set(f.expected.keys).union(f.usual.keys) {
            guard let dir = Goals.direction(k, tree: tree, goals: goals) else { continue }
            let d = (f.expected[k] ?? 0) - (f.usual[k] ?? 0)
            guard abs(d) >= 10 else { continue }
            let name = k == CategoryTree.untracked ? "Untracked" : (tree.node(k)?.name ?? k)
            diffs.append(Difference(category: k, name: name, minutes: d, better: dir == .atLeast ? d > 0 : d < 0))
        }
        diffs.sort { abs($0.minutes) > abs($1.minutes) }
        // Less Untracked is good, but it never makes up for more scrolling: it only speaks when nothing else differs.
        let real = diffs.filter { $0.category != CategoryTree.untracked }
        let top = Array((real.isEmpty ? diffs : real).prefix(2))
        func signed(_ m: Int) -> String { (m >= 0 ? "+" : "−") + minutesLabel(abs(m)) }
        let named = top.map { "\($0.name) \(signed($0.minutes))" }.joined(separator: ", ")
        guard let first = top.first else {
            return ForecastVerdict(kind: .onTrack, differences: [], line: "On track for your \(f.label.lowercased())")
        }
        if top.allSatisfy(\.better) {
            return ForecastVerdict(kind: .beat, differences: top, line: "On track to beat your usual: " + named)
        }
        guard !first.better else {
            return ForecastVerdict(kind: .onTrack, differences: top, line: "Close to your usual: " + named)
        }
        // Behind: the one that's worse, where you are now and the time left. No red, no shame line.
        let usual = f.usual[first.category] ?? 0
        let soFar = actualSoFar[first.category] ?? 0
        let hoursLeft = max(0, Int(Days.dayInterval(now, cal).end.timeIntervalSince(now) / 3600))
        return ForecastVerdict(kind: .behind, differences: top,
                               line: "\(f.label): \(minutesLabel(usual)) \(first.name.lowercased()). You're at \(minutesLabel(soFar)) with \(hoursLeft) hours left.")
    }
}

// MARK: - G4: Up Next's one line

public enum UpNext {
    /// "Do these and you'll hit Studying 2h and still have 1h 40 free before bed at 22:30." Or, when the plan can't
    /// fit it all: "Not enough time for all of this: Gatsby moves to tomorrow." Or "Nothing left today."
    public static func summary(plan: Plan, items: [WorkItem], entries: [Entry], goals: [Goal], tree: CategoryTree, now: Date,
                               book: DayRuleBook = DayRuleBook(), calendar cal: Calendar) -> String {
        let todayEnd = Days.dayInterval(now, cal).end
        let left = plan.blocks.filter { $0.isStudy && $0.end > now && $0.start < todayEnd }
        let bed = plan.blocks.first { $0.kind == .sleep && $0.start > now && $0.start < todayEnd.addingTimeInterval(4 * 3600) }?.start
        let hm = DateFormatter.local("H:mm", cal)
        let short = plan.shortfalls.compactMap { id, _ in items.first { $0.id == id && $0.isOpen } }
            .filter { $0.due < todayEnd.addingTimeInterval(86400) }
        if let s = short.first {
            return "Not enough time for all of this: \(s.title) won't fit before it's due. Ask the box to move something."
        }
        let movedTomorrow = plan.warnings.first { $0.message.lowercased().contains("tomorrow") }
        if left.isEmpty {
            if let w = movedTomorrow { return w.message }
            return bed.map { "Nothing left today. Free until bed at \(hm.string(from: $0))." } ?? "Nothing left today."
        }
        var parts: [String] = []
        let leftMinutes = left.reduce(0) { $0 + Int($1.end.timeIntervalSince(max($1.start, now)) / 60) }
        if let g = goals.first(where: { if case .category = $0.measure { return $0.active && $0.direction == .atLeast && $0.period == .day }; return false }) {
            let p = Goals.progress(g, entries: entries, tree: tree, items: items, now: now, book: book, calendar: cal)
            let reach = p.value + leftMinutes
            parts.append(reach >= g.target ? "you'll hit \(g.title) \(minutesLabel(g.target))" : "you'll get \(g.title) to \(minutesLabel(reach)) of \(minutesLabel(g.target))")
        } else {
            parts.append("that's \(minutesLabel(leftMinutes)) of work")
        }
        if let bed {
            // Free = until bed, minus what's planned or fixed in between (wind-down included).
            let rest = DateInterval(start: now, end: bed)
            let busy = plan.blocks.filter { $0.end > now && $0.start < bed && $0.kind != .free && $0.kind != .gap && $0.kind != .breakTime }
                .reduce(0) { $0 + Int(min($1.end, bed).timeIntervalSince(max($1.start, now)) / 60) }
            let fixed = Days.expand(entries.filter { $0.source != .plan }, in: rest, now: now, book: book, calendar: cal)
                .filter { $0.busy && !$0.running }.reduce(0) { $0 + Int(min($1.end, bed).timeIntervalSince(max($1.start, now)) / 60) }
            let free = max(0, Int(rest.duration / 60) - busy - fixed)
            parts.append("still have \(minutesLabel(free)) free before bed at \(hm.string(from: bed))")
        }
        return "Do these and " + parts.joined(separator: " and ") + "."
    }
}

// MARK: - G6: mood by time of day

public struct MoodMap: Hashable, Sendable {
    /// Average mood per weekday (1 = Sun) and hour.
    public var cells: [Int: [Int: Double]]
    public var counts: [Int: [Int: Int]]
    /// "Lowest around 4–6 pm on school days", when it's clear (≥8 moods, a 0.7 point dip, ≥3 in the dip).
    public var noticed: String?

    public static func make(_ moods: [MoodEntry], since: Date, isSchoolDay: (Date) -> Bool, calendar cal: Calendar) -> MoodMap {
        let ms = moods.filter { $0.at >= since }
        var sums: [Int: [Int: Double]] = [:], counts: [Int: [Int: Int]] = [:]
        for m in ms {
            let wd = cal.component(.weekday, from: m.at), h = cal.component(.hour, from: m.at)
            sums[wd, default: [:]][h, default: 0] += Double(m.mood)
            counts[wd, default: [:]][h, default: 0] += 1
        }
        var cells: [Int: [Int: Double]] = [:]
        for (wd, hs) in sums { for (h, s) in hs { cells[wd, default: [:]][h] = s / Double(counts[wd]![h]!) } }
        var noticed: String?
        let school = ms.filter { isSchoolDay(cal.startOfDay(for: $0.at)) }
        if school.count >= 8 {
            let avg = school.reduce(0.0) { $0 + Double($1.mood) } / Double(school.count)
            // Two-hour windows; the lowest one, if it's clearly lower.
            var best: (Int, Double, Int)?
            for start in stride(from: 6, through: 22, by: 2) {
                let inW = school.filter { (start..<start + 2).contains(cal.component(.hour, from: $0.at)) }
                guard inW.count >= 3 else { continue }
                let a = inW.reduce(0.0) { $0 + Double($1.mood) } / Double(inW.count)
                if best == nil || a < best!.1 { best = (start, a, inW.count) }
            }
            if let b = best, avg - b.1 >= 0.7 {
                func h12(_ h: Int) -> String { "\(h % 12 == 0 ? 12 : h % 12)" }
                let mer = b.0 + 2 <= 12 ? "am" : "pm"
                noticed = "Lowest around \(h12(b.0))–\(h12(b.0 + 2)) \(mer) on school days"
            }
        }
        return MoodMap(cells: cells, counts: counts, noticed: noticed)
    }
}
