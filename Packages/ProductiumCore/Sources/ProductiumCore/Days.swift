import Foundation

// v1.2 O2: turns stored Entries into the occurrences on a range of days. The one view of time that the planner, the
// day screens, the ring, alarms, nudges and the box context all read. What the box sees here is exactly what it can
// edit, by the same ref.

public enum Days {
    /// Every occurrence overlapping `range`, sorted by start. Running entries end at `now`.
    /// Skipped occurrences are left out unless `includeSkipped` (the entry sheet and receipts show them).
    public static func expand(_ entries: [Entry], in range: DateInterval, now: Date, book: DayRuleBook = DayRuleBook(),
                              calendar cal: Calendar, includeSkipped: Bool = false,
                              evaluator: DayRuleEvaluator? = nil) -> [DayEntry] {
        let ev = evaluator ?? DayRuleEvaluator(book: book, calendar: cal)
        var out: [DayEntry] = []
        for e in entries {
            if let r = e.repeats {
                out += occurrences(of: e, r, in: range, ev: ev, includeSkipped: includeSkipped)
            } else {
                let mark = e.marks[DayKeys.key(e.start, cal)]
                if mark == .skipped && !includeSkipped { continue }
                let d = DayEntry(entry: e, occurrence: nil, start: e.start, end: max(e.start, e.end ?? now),
                                 running: e.end == nil, mark: mark)
                if overlaps(d, range) { out.append(d) }
            }
        }
        return superseding(out).sorted { ($0.start, $0.end, $0.id) < ($1.start, $1.end, $1.id) }
    }

    /// How far apart a tracked trip or routine and the planned one can start and still be the same thing.
    public static let supersedeMinutes = 45

    /// v1.5: a planned trip or routine you tracked yourself is gone from the log, not left to delete: the planned
    /// "Walk home" 15:00–15:20 and the Walking you tracked 15:36–16:17 are one walk. Same category (any Travel counts
    /// as the same), overlapping or starting within `supersedeMinutes`.
    static func superseding(_ occ: [DayEntry]) -> [DayEntry] {
        let told = occ.filter { $0.source == .you && !$0.assumed && ($0.running || $0.end.timeIntervalSince($0.start) >= 180) }
        guard !told.isEmpty else { return occ }
        func root(_ c: CategoryID) -> Substring { c.split(separator: ".").first ?? Substring(c) }
        func same(_ a: CategoryID, _ b: CategoryID) -> Bool {
            a == b || (root(a) == root(CategoryTree.travel) && root(b) == root(CategoryTree.travel))
        }
        return occ.filter { a in
            guard a.assumed, a.source == .plan || (a.source == .you && a.entry.repeats != nil),
                  a.taskId == nil, ["travel", "essentials"].contains(root(a.category)),
                  a.category != CategoryTree.transition else { return true }
            let near = Double(supersedeMinutes) * 60
            return !told.contains { t in
                t.entry.id != a.entry.id && same(t.category, a.category)
                    && ((t.start < a.end && t.end > a.start) || abs(t.start.timeIntervalSince(a.start)) <= near)
            }
        }
    }

    /// The occurrences overlapping one calendar day.
    public static func on(_ day: Date, _ entries: [Entry], now: Date, book: DayRuleBook = DayRuleBook(),
                          calendar cal: Calendar, includeSkipped: Bool = false, evaluator: DayRuleEvaluator? = nil) -> [DayEntry] {
        expand(entries, in: dayInterval(day, cal), now: now, book: book, calendar: cal, includeSkipped: includeSkipped,
               evaluator: evaluator)
    }

    public static func dayInterval(_ day: Date, _ cal: Calendar) -> DateInterval {
        let s = cal.startOfDay(for: day)
        return DateInterval(start: s, end: cal.date(byAdding: .day, value: 1, to: s) ?? s.addingTimeInterval(86400))
    }

    static func overlaps(_ d: DayEntry, _ r: DateInterval) -> Bool {
        if d.end <= d.start { return d.start >= r.start && d.start < r.end }
        return d.start < r.end && d.end > r.start
    }

    static func occurrences(of e: Entry, _ r: Repeat, in range: DateInterval, ev: DayRuleEvaluator,
                            includeSkipped: Bool) -> [DayEntry] {
        let cal = ev.calendar
        let first = cal.startOfDay(for: r.from ?? e.start)
        // An overnight occurrence (Sleep 22:30–7:00) that began the day before still overlaps the range.
        var day = max(first, cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: range.start))!)
        var to = cal.startOfDay(for: range.end)
        if let until = r.until { to = min(to, cal.startOfDay(for: until)) }
        let sh = cal.component(.hour, from: e.start), sm = cal.component(.minute, from: e.start)
        let length = max(0, Int(((e.end ?? e.start).timeIntervalSince(e.start) / 60).rounded()))
        var out: [DayEntry] = []
        var steps = 0
        while day <= to && steps < 800 {
            defer { day = cal.date(byAdding: .day, value: 1, to: day)!; steps += 1 }
            guard ev.matches(r.days, on: day) else { continue }
            let key = DayKeys.key(day, cal)
            let mark = e.marks[key]
            if mark == .skipped && !includeSkipped { continue }
            guard let s = cal.date(bySettingHour: sh, minute: sm, second: 0, of: day) else { continue }
            // Wall-clock end, so Sleep 22:30–7:00 still ends at 7:00 across a DST change.
            let endMinutes = sh * 60 + sm + length
            let endDay = cal.date(byAdding: .day, value: endMinutes / 1440, to: day)!
            let tod = TimeOfDay(minutes: endMinutes)
            let end = cal.date(bySettingHour: tod.hour, minute: tod.minute, second: 0, of: endDay) ?? s
            let d = DayEntry(entry: e, occurrence: key, start: s, end: max(s, end), running: false, mark: mark)
            if overlaps(d, range) { out.append(d) }
        }
        return out
    }

    // MARK: - Editing one occurrence

    /// The key an occurrence of this entry on `day` is marked under (one-offs: their start day).
    public static func key(_ e: Entry, on day: Date, _ cal: Calendar) -> DayKey {
        DayKeys.key(e.repeats == nil ? e.start : day, cal)
    }

    /// Changing one occurrence of a series (moved, retimed, renamed, a different alert): the series is skipped that
    /// day and the occurrence becomes its own one-off entry, which is then edited like any other.
    public static func detach(_ series: inout Entry, occurrence key: DayKey, calendar cal: Calendar,
                              now: Date) -> Entry? {
        guard series.repeats != nil, let day = DayKeys.date(key, cal),
              let occ = on(day, [series], now: now, calendar: cal).first(where: { $0.occurrence == key }) else { return nil }
        series.marks[key] = .skipped
        var one = series
        one.id = UUID()
        one.repeats = nil
        one.marks = [:]
        one.start = occ.start
        one.end = occ.end
        one.source = series.source == .calendar ? .you : series.source
        one.createdAt = series.createdAt
        return one
    }

    /// Skips everything on `day` filed under `category` ("No school Friday" = skip Friday's School entries).
    /// Plan entries are just replanned, so they're left alone. Skipping all of School labels the day `no-school`,
    /// so A/B rotations counted over school days shift by themselves. Returns the refs skipped.
    @discardableResult
    public static func skip(category: CategoryID, on day: Date, entries: inout [Entry], tree: CategoryTree,
                            book: inout DayRuleBook, now: Date, calendar cal: Calendar) -> [String] {
        let todays = on(day, entries, now: now, book: book, calendar: cal)
            .filter { tree.isUnder($0.category, category) && $0.source != .plan && cal.isDate($0.start, inSameDayAs: day) }
        var refs: [String] = []
        for d in todays {
            guard let i = entries.firstIndex(where: { $0.id == d.entry.id }) else { continue }
            entries[i].marks[d.occurrence ?? DayKeys.key(entries[i].start, cal)] = .skipped
            refs.append(d.ref)
        }
        if tree.isUnder(CategoryTree.school, category) { book.label(noSchoolLabel, [day], calendar: cal) }
        return refs
    }

    public static let noSchoolLabel = "no-school"

    /// Yes to every assumed occurrence overlapping `range` (one swipe across the morning: "school as usual").
    /// Returns the refs confirmed.
    @discardableResult
    public static func confirm(in range: DateInterval, entries: inout [Entry], now: Date, book: DayRuleBook = DayRuleBook(),
                               calendar cal: Calendar) -> [String] {
        let clipped = DateInterval(start: range.start, end: max(range.start, min(range.end, now)))
        var refs: [String] = []
        for d in expand(entries, in: clipped, now: now, book: book, calendar: cal) where d.assumed {
            guard let i = entries.firstIndex(where: { $0.id == d.entry.id }) else { continue }
            entries[i].marks[d.occurrence ?? DayKeys.key(entries[i].start, cal)] = .confirmed
            refs.append(d.ref)
        }
        return refs
    }

    // MARK: - School days

    /// A school day: some School entry happens that day; with no timetable yet, the weekdays in Settings.
    public static func isSchoolDay(_ day: Date, entries: [Entry], tree: CategoryTree, prefs: Preferences,
                                   book: DayRuleBook = DayRuleBook(), calendar cal: Calendar) -> Bool {
        guard hasTimetable(entries, tree: tree) else { return prefs.schoolDays.contains(cal.component(.weekday, from: day)) }
        let ds = on(day, entries.filter { $0.source != .plan }, now: day, book: book, calendar: cal)
        return ds.contains { tree.isUnder($0.category, CategoryTree.school) && cal.isDate($0.start, inSameDayAs: day) }
    }

    /// Whether the timetable lives in Entries (any repeating entry under School).
    public static func hasTimetable(_ entries: [Entry], tree: CategoryTree) -> Bool {
        entries.contains { $0.repeats != nil && tree.isUnder($0.category, CategoryTree.school) }
    }
}
