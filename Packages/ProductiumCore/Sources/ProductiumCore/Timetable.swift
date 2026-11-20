import Foundation

/// The timetable as Entries (v1.2 step 6): one repeating entry per class period under School › <class> (source `you`,
/// topic = class; spares and lunch are `open`), and one repeating entry per other commitment. Onboarding and Settings
/// write these; the planner, the timeline and the box all read them. `Commitment` survives only as the shape Settings
/// edits and the older readers (marker parsing, place offers) still take, until they move to entries.
public enum Timetable {
    static let openWords = ["spare", "lunch", "free period", "study hall", "break", "recess"]

    /// "P2 Math" / "2: Math" / "Math" → "Math".
    public static func className(_ title: String) -> String {
        let t = title.trimmingCharacters(in: .whitespaces)
        if let r = t.range(of: #"^[Pp]?\d+\s*[:.\-–]?\s*"#, options: .regularExpression), r.upperBound < t.endIndex {
            return String(t[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        return t
    }

    static func isOpen(_ title: String) -> Bool {
        let t = title.lowercased()
        return openWords.contains { t.contains($0) }
    }

    static func rule(_ weekdays: Set<Int>, _ when: DayRule?) -> DayRule {
        let days: DayRule = .weekdays(weekdays.isEmpty ? Set(1...7) : weekdays)
        guard let when else { return days }
        return .all([days, when])
    }

    static func category(_ kind: CommitmentKind, title: String, tree: inout CategoryTree) -> (CategoryID, [String]) {
        switch kind {
        case .school:
            let cls = className(title)
            let id = tree.add(cls, under: CategoryTree.school)?.id ?? CategoryTree.school
            return (id, [cls.lowercased()])
        case .extracurricular:
            return (tree.add(title, under: CategoryTree.extracurricular)?.id ?? CategoryTree.extracurricular, [])
        case .job: return (CategoryTree.work, [])
        case .family, .other: return (CategoryTree.other, [])
        }
    }

    /// The entries for one commitment: one per period when it has periods, else one. A single entry keeps the
    /// commitment's id, so editing it again replaces it.
    public static func entries(for c: Commitment, tree: inout CategoryTree, anchor: Date, calendar cal: Calendar) -> [Entry] {
        let day = cal.startOfDay(for: c.validFrom.map { max($0, anchor) } ?? anchor)
        func at(_ t: TimeOfDay) -> Date { cal.date(bySettingHour: t.hour, minute: t.minute, second: 0, of: day) ?? day }
        func make(id: UUID, title: String, s: TimeOfDay, e: TimeOfDay, weekdays: Set<Int>, when: DayRule?) -> Entry? {
            guard at(e) > at(s) else { return nil }
            let (cat, topics) = category(c.kind, title: title, tree: &tree)
            return Entry(id: id, title: title, start: at(s), end: at(e), category: cat, filedByYou: true, topics: topics,
                         repeats: Repeat(rule(weekdays, when), from: c.validFrom, until: c.validUntil),
                         open: isOpen(title), source: .you, createdAt: anchor)
        }
        guard let periods = c.periods, !periods.isEmpty else {
            return make(id: c.id, title: c.title, s: c.start, e: c.end, weekdays: c.weekdays, when: c.when).map { [$0] } ?? []
        }
        return periods.enumerated().compactMap { i, p in
            let both: DayRule? = [c.when, p.when].compactMap { $0 }.reduce(nil as DayRule?) { acc, r in acc.map { .all([$0, r]) } ?? r }
            return make(id: Planner.stableUUID("period|\(c.id)|\(i)"), title: p.title, s: p.start, e: p.end,
                        weekdays: p.weekdays.isEmpty ? c.weekdays : p.weekdays, when: both)
        }
    }

    /// Replaces what a commitment wrote before (same ids) with its current entries.
    public static func write(_ c: Commitment, into entries: inout [Entry], tree: inout CategoryTree, anchor: Date,
                             calendar cal: Calendar) {
        let new = Self.entries(for: c, tree: &tree, anchor: anchor, calendar: cal)
        let ids = Set(new.map(\.id)).union([c.id])
        // Marks (a cancelled day, a confirmed class) belong to the series: keep them when it's edited.
        let marks = Dictionary(entries.filter { ids.contains($0.id) }.map { ($0.id, $0.marks) }, uniquingKeysWith: { a, _ in a })
        entries.removeAll { ids.contains($0.id) }
        entries += new.map { var e = $0; e.marks = marks[e.id] ?? [:]; return e }
    }

    // MARK: Back to the editor's shape

    /// The weekdays and any extra condition in a repeat rule.
    static func split(_ r: DayRule) -> (Set<Int>, DayRule?) {
        switch r {
        case .weekdays(let w): return (w, nil)
        case .all(let rs):
            if let i = rs.firstIndex(where: { if case .weekdays = $0 { return true }; return false }), case .weekdays(let w) = rs[i] {
                var rest = rs; rest.remove(at: i)
                return (w, rest.isEmpty ? nil : rest.count == 1 ? rest[0] : .all(rest))
            }
            return (Set(1...7), r)
        default: return (Set(1...7), r)
        }
    }

    public static func kind(of category: CategoryID, tree: CategoryTree) -> CommitmentKind {
        if tree.isUnder(category, CategoryTree.school) { return .school }
        if tree.isUnder(category, CategoryTree.extracurricular) { return .extracurricular }
        if tree.isUnder(category, CategoryTree.work) { return .job }
        return .other
    }

    /// Your repeating entries as commitments, one per entry (a period is one row). For Settings, and for the older
    /// readers that still take `Commitment`.
    public static func commitments(from entries: [Entry], tree: CategoryTree, calendar cal: Calendar) -> [Commitment] {
        entries.filter { $0.source == .you && $0.repeats != nil && $0.end != nil && $0.category != CategoryTree.sleep }
            .compactMap { e in
                guard let rep = e.repeats, let end = e.end else { return nil }
                let (days, when) = split(rep.days)
                func tod(_ d: Date) -> TimeOfDay { TimeOfDay(cal.component(.hour, from: d), cal.component(.minute, from: d)) }
                return Commitment(id: e.id, title: e.title, kind: kind(of: e.category, tree: tree), weekdays: days,
                                  start: tod(e.start), end: tod(end), bufferMinutes: 0,
                                  validFrom: rep.from, validUntil: rep.until, when: when)
            }
            .sorted { ($0.start, $0.title) < ($1.start, $1.title) }
    }
}
