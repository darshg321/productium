import Foundation

// v1.2 Part P: patterns, without being asked. Code finds candidates in the last four weeks of the log, each with its
// evidence and counts; the insight pass only picks up to two and words them (never trust model numbers).

public struct Pattern: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case followThrough, after, weekday, earlyStart }
    public var id: String
    public var kind: Kind
    /// A plain sentence written by code (the model may reword it, never change its numbers).
    public var text: String
    public var evidence: [String]
    /// How strong it is (minutes or share difference × how many days), for ordering.
    public var strength: Double
}

public enum PatternFinder {
    public static func find(entries: [Entry], tree: CategoryTree, now: Date, book: DayRuleBook = DayRuleBook(),
                            calendar cal: Calendar, days: Int = 28) -> [Pattern] {
        let today = cal.startOfDay(for: now)
        let dayList = (1...days).compactMap { cal.date(byAdding: .day, value: -$0, to: today) }.reversed()
        var slicesByDay: [Date: [LogSlice]] = [:]
        for d in dayList { slicesByDay[d] = TimeLog.past(entries, in: Days.dayInterval(d, cal), now: now, book: book, calendar: cal) }
        var out: [Pattern] = []
        out += followThrough(entries: entries, now: now, from: dayList.first ?? today, calendar: cal)
        out += after(slicesByDay, tree: tree, calendar: cal)
        out += weekdays(slicesByDay, tree: tree, calendar: cal)
        out += earlyStart(slicesByDay, tree: tree, calendar: cal)
        return out.sorted { $0.strength > $1.strength }
    }

    static func h12(_ h: Int) -> String { "\(h % 12 == 0 ? 12 : h % 12) \(h < 12 ? "am" : "pm")" }

    /// "Your planned 9 pm study happens 1 in 5 times; 4 pm happens 4 in 5."
    static func followThrough(entries: [Entry], now: Date, from: Date, calendar cal: Calendar) -> [Pattern] {
        let planned = entries.filter { $0.source == .plan && $0.taskId != nil && $0.start >= from && ($0.end ?? $0.start) <= now }
        let worked = entries.filter { $0.taskId != nil && $0.source != .plan && $0.repeats == nil }
        var byHour: [Int: (Int, Int)] = [:]
        for p in planned {
            let did = worked.contains { $0.taskId == p.taskId && cal.isDate($0.start, inSameDayAs: p.start) }
            let h = cal.component(.hour, from: p.start) / 2 * 2
            byHour[h, default: (0, 0)].1 += 1
            if did { byHour[h]!.0 += 1 }
        }
        let rated = byHour.filter { $0.value.1 >= 4 }
        guard let low = rated.min(by: { Double($0.value.0) / Double($0.value.1) < Double($1.value.0) / Double($1.value.1) }),
              let high = rated.max(by: { Double($0.value.0) / Double($0.value.1) < Double($1.value.0) / Double($1.value.1) }),
              low.key != high.key else { return [] }
        let lr = Double(low.value.0) / Double(low.value.1), hr = Double(high.value.0) / Double(high.value.1)
        guard hr - lr >= 0.4 else { return [] }
        return [Pattern(id: "follow|\(low.key)|\(high.key)", kind: .followThrough,
                        text: "Your planned \(h12(low.key)) study happens \(low.value.0) in \(low.value.1) times; \(h12(high.key)) happens \(high.value.0) in \(high.value.1)",
                        evidence: ["\(h12(low.key)): \(low.value.0) of \(low.value.1) done", "\(h12(high.key)): \(high.value.0) of \(high.value.1) done"],
                        strength: (hr - lr) * Double(low.value.1 + high.value.1))]
    }

    /// "You lose about 40 minutes after practice on Tuesdays (scrolling, 4 of the last 4)."
    static func after(_ byDay: [Date: [LogSlice]], tree: CategoryTree, calendar cal: Calendar) -> [Pattern] {
        var occurrences: [String: [(Date, Int)]] = [:]
        var names: [String: String] = [:]
        for (d, slices) in byDay {
            for (i, s) in slices.enumerated() {
                guard let e = s.entry, !tree.isUnder(e.category, CategoryTree.unproductive), !tree.isUnder(e.category, CategoryTree.sleep),
                      s.minutes >= 30 else { continue }
                let key = RingModel.level2(e.category, tree) + "|\(cal.component(.weekday, from: d))"
                names[key] = tree.node(RingModel.level2(e.category, tree))?.name ?? e.title
                let windowEnd = s.end.addingTimeInterval(60 * 60)
                let scrolled = slices[(i + 1)...].filter { $0.start < windowEnd && ($0.entry.map { tree.isUnder($0.category, CategoryTree.scrolling) } ?? false) }
                    .reduce(0) { $0 + Int(min($1.end, windowEnd).timeIntervalSince($1.start) / 60) }
                occurrences[key, default: []].append((d, scrolled))
            }
        }
        var out: [Pattern] = []
        for (key, occ) in occurrences {
            let last = occ.sorted { $0.0 < $1.0 }.suffix(4)
            guard last.count >= 3 else { continue }
            let hits = last.filter { $0.1 >= 20 }
            guard hits.count >= 3 else { continue }
            let avg = hits.reduce(0) { $0 + $1.1 } / hits.count
            let wd = Int(key.split(separator: "|").last!)!
            let day = DateFormatter.local("EEEE", cal).standaloneWeekdaySymbols[wd - 1]
            out.append(Pattern(id: "after|\(key)", kind: .after,
                               text: "You lose about \(minutesLabel(avg)) after \(names[key]!.lowercased()) on \(day)s (scrolling, \(hits.count) of the last \(last.count))",
                               evidence: hits.map { "\(DateFormatter.local("MMM d", cal).string(from: $0.0)): \($0.1)m" }, strength: Double(avg * hits.count)))
        }
        return out
    }

    /// "Thursdays have 1h 10m less study than your other days."
    static func weekdays(_ byDay: [Date: [LogSlice]], tree: CategoryTree, calendar cal: Calendar) -> [Pattern] {
        var study: [Int: [Int]] = [:]
        for (d, s) in byDay {
            let m = s.filter { $0.entry.map { tree.isUnder($0.category, CategoryTree.studying) } ?? false }.reduce(0) { $0 + $1.minutes }
            study[cal.component(.weekday, from: d), default: []].append(m)
        }
        let all = study.values.flatMap { $0 }
        guard all.count >= 14 else { return [] }
        var out: [Pattern] = []
        for (wd, xs) in study where xs.count >= 3 {
            let others = study.filter { $0.key != wd }.values.flatMap { $0 }
            guard !others.isEmpty else { continue }
            let a = xs.reduce(0, +) / xs.count, b = others.reduce(0, +) / others.count
            guard abs(a - b) >= 45 else { continue }
            let day = DateFormatter.local("EEEE", cal).standaloneWeekdaySymbols[wd - 1]
            out.append(Pattern(id: "weekday|\(wd)", kind: .weekday,
                               text: "\(day)s have \(minutesLabel(abs(a - b))) \(a > b ? "more" : "less") study than your other days",
                               evidence: ["\(day): \(minutesLabel(a)) on average over \(xs.count)", "other days: \(minutesLabel(b))"],
                               strength: Double(abs(a - b)) * Double(xs.count) / 2))
        }
        return out
    }

    /// "Days you start before 10 have 1h 20 more study."
    static func earlyStart(_ byDay: [Date: [LogSlice]], tree: CategoryTree, calendar cal: Calendar) -> [Pattern] {
        var early: [Int] = [], late: [Int] = []
        for (_, s) in byDay {
            let study = s.filter { $0.entry.map { tree.isUnder($0.category, CategoryTree.studying) } ?? false }
            guard let first = study.first else { continue }
            let m = study.reduce(0) { $0 + $1.minutes }
            if cal.component(.hour, from: first.start) < 10 { early.append(m) } else { late.append(m) }
        }
        guard early.count >= 3, late.count >= 3 else { return [] }
        let a = early.reduce(0, +) / early.count, b = late.reduce(0, +) / late.count
        guard a - b >= 30 else { return [] }
        return [Pattern(id: "early|10", kind: .earlyStart, text: "Days you start before 10 have \(minutesLabel(a - b)) more study",
                        evidence: ["\(early.count) days starting before 10: \(minutesLabel(a))", "\(late.count) later starts: \(minutesLabel(b))"],
                        strength: Double(a - b) * Double(min(early.count, late.count)))]
    }
}
