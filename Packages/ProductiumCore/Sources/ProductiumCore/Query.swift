import Foundation

// v1.2 Part F: "how much math in the last 28 days?" The model writes a `TimeQuery`; this engine runs it on the
// phone over `TimeLog.past`, so every number comes from code. The model's reply uses placeholders ({q1.total},
// {q1.avgPerDay}, {q1.top}, {q1.previous}, {q1.change}, {q1.rows}) that `QueryText.fill` replaces, so the answer
// still arrives in one call.
//
// Kept loose on purpose: ranges and filters accept the shapes a model naturally writes ("28d", "this week",
// category paths or ids, task refs or titles), and anything it can't resolve is reported as a problem, never as an
// empty chart.

public struct TimeQuery: Codable, Hashable, Sendable {
    public struct Range: Codable, Hashable, Sendable {
        /// "28d", "4w", "3m" (months), "1y".
        public var last: String?
        /// "today", "yesterday", "this week", "last week", "this month", "last month", "this year".
        public var preset: String?
        /// `yyyy-MM-dd`, inclusive.
        public var from: String?
        public var to: String?
        public init(last: String? = nil, preset: String? = nil, from: String? = nil, to: String? = nil) {
            self.last = last
            self.preset = preset
            self.from = from
            self.to = to
        }
    }

    public struct Filter: Codable, Hashable, Sendable {
        /// Ids or paths ("School › Math"); each includes its subtree. "untracked" selects Untracked time.
        public var categories: [String]?
        /// Groups: productive, essential, rest, unproductive.
        public var groups: [String]?
        public var topics: [String]?
        /// Task refs (t…) or titles.
        public var tasks: [String]?
        /// Case-insensitive substrings of the entry title.
        public var titles: [String]?
        /// 1 = Sunday … 7 = Saturday.
        public var weekdays: [Int]?
        /// 0–23: only time inside these hours.
        public var hours: [Int]?
        /// Only confirmed / tracked time (leave assumed time out).
        public var confirmedOnly: Bool?
        public init(categories: [String]? = nil, groups: [String]? = nil, topics: [String]? = nil, tasks: [String]? = nil,
                    titles: [String]? = nil, weekdays: [Int]? = nil, hours: [Int]? = nil, confirmedOnly: Bool? = nil) {
            self.categories = categories
            self.groups = groups
            self.topics = topics
            self.tasks = tasks
            self.titles = titles
            self.weekdays = weekdays
            self.hours = hours
            self.confirmedOnly = confirmedOnly
        }
    }

    public var id: String
    public var range: Range
    public var filter: Filter?
    /// none, day, week, weekday, hour, category (top level), category2, category3, group, topic, task, title.
    public var groupBy: String?
    /// minutes, share, count, avgPerDay, firstStart, lastEnd.
    public var measure: String?
    /// "previous": the same length of time just before.
    public var compare: String?
    /// ring, bar, stackedBar, line, heatmap, number, table.
    public var chart: String?

    public init(id: String, range: Range, filter: Filter? = nil, groupBy: String? = nil, measure: String? = nil,
                compare: String? = nil, chart: String? = nil) {
        self.id = id
        self.range = range
        self.filter = filter
        self.groupBy = groupBy
        self.measure = measure
        self.compare = compare
        self.chart = chart
    }
}

/// A chart pinned to Review (F3): the query is stored and re-run against the log every time it's shown.
public struct PinnedChart: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var query: TimeQuery
    public var pinnedAt: Date
    public init(id: UUID = UUID(), title: String, query: TimeQuery, pinnedAt: Date) {
        self.id = id; self.title = title; self.query = query; self.pinnedAt = pinnedAt
    }
}

public struct QueryResult: Hashable, Sendable {
    public struct Row: Hashable, Sendable {
        public var key: String
        public var label: String
        public var value: Double
        public var previous: Double?
    }
    public struct Coverage: Hashable, Sendable {
        public var days: Int
        /// Days with any time matching the filter.
        public var daysWithData: Int
        /// Of the matching minutes, how many were assumed (timetable, calendar, planned routines, sensors).
        public var assumedMinutes: Int
        /// Untracked minutes in the whole range (so a thin answer says why).
        public var untrackedMinutes: Int
    }

    public var id: String
    public var range: DateInterval
    public var measure: String
    public var chart: String
    public var rows: [Row]
    /// Minutes for time measures, a count for `count`, minutes after midnight for first / last.
    public var total: Double
    public var previousTotal: Double?
    public var coverage: Coverage
    public var problems: [String]
}

public enum TimeQueryEngine {
    public static let groupings: Set<String> = ["none", "day", "week", "weekday", "hour", "category", "category2", "category3",
                                                "group", "topic", "task", "title"]
    public static let measures: Set<String> = ["minutes", "share", "count", "avgPerDay", "firstStart", "lastEnd"]

    public static func run(_ q: TimeQuery, entries: [Entry], items: [WorkItem] = [], tree: CategoryTree, now: Date,
                           book: DayRuleBook = DayRuleBook(), calendar cal: Calendar) -> QueryResult {
        var problems: [String] = []
        let range = interval(q.range, now: now, cal: cal, problems: &problems)
        let measure = measures.contains(q.measure ?? "") ? q.measure! : "minutes"
        if let m = q.measure, !measures.contains(m) { problems.append("Unknown measure “\(m)”, used minutes") }
        let group = groupings.contains(q.groupBy ?? "") ? q.groupBy! : "none"
        if let g = q.groupBy, !groupings.contains(g) { problems.append("Unknown grouping “\(g)”, used none") }
        let f = resolve(q.filter, items: items, tree: tree, problems: &problems)

        func compute(_ r: DateInterval) -> (rows: [String: (label: String, value: Double)], total: Double, cov: QueryResult.Coverage) {
            let slices = TimeLog.past(entries, in: r, now: now, book: book, calendar: cal)
            let untracked = slices.filter { $0.entry == nil }.reduce(0) { $0 + $1.minutes }
            let pieces = split(slices, byHour: group == "hour" || f.hours != nil, cal: cal).filter { matches($0, f, tree: tree, cal: cal) }
            let days = max(1, cal.dateComponents([.day], from: cal.startOfDay(for: r.start), to: cal.startOfDay(for: r.end.addingTimeInterval(-1))).day! + 1)
            var minutes: [String: Double] = [:], labels: [String: String] = [:], ids: [String: Set<String>] = [:]
            var firsts: [String: [String: Int]] = [:], lasts: [String: [String: Int]] = [:]
            for p in pieces {
                let (k, label) = key(p, group, tree: tree, items: items, cal: cal)
                minutes[k, default: 0] += p.seconds / 60
                labels[k] = label
                ids[k, default: []].insert(p.slice.entry?.id ?? "untracked@\(p.start.timeIntervalSince1970)")
                let day = DayKeys.key(p.start, cal)
                let startM = cal.component(.hour, from: p.start) * 60 + cal.component(.minute, from: p.start)
                let endM = startM + Int(p.seconds / 60)
                firsts[k, default: [:]][day] = min(firsts[k]?[day] ?? .max, startM)
                lasts[k, default: [:]][day] = max(lasts[k]?[day] ?? .min, endM)
            }
            let all = minutes.values.reduce(0, +)
            var rows: [String: (String, Double)] = [:]
            for k in minutes.keys {
                let v: Double
                switch measure {
                case "share": v = all > 0 ? minutes[k]! / all : 0
                case "count": v = Double(ids[k]?.count ?? 0)
                case "avgPerDay": v = minutes[k]! / Double(days)
                case "firstStart": v = avg(firsts[k]!.values)
                case "lastEnd": v = avg(lasts[k]!.values)
                default: v = minutes[k]!
                }
                rows[k] = (labels[k] ?? k, v)
            }
            let total: Double
            switch measure {
            case "share": total = 1
            case "count": total = Double(ids.values.reduce(into: Set<String>()) { $0.formUnion($1) }.count)
            case "avgPerDay": total = all / Double(days)
            case "firstStart": total = avg(firsts.values.flatMap { $0.values })
            case "lastEnd": total = avg(lasts.values.flatMap { $0.values })
            default: total = all
            }
            let withData = Set(pieces.map { DayKeys.key($0.start, cal) }).count
            let assumed = pieces.filter { $0.slice.assumed }.reduce(0.0) { $0 + $1.seconds / 60 }
            return (rows, total, QueryResult.Coverage(days: days, daysWithData: withData, assumedMinutes: Int(assumed.rounded()),
                                                      untrackedMinutes: untracked))
        }

        let cur = compute(range)
        var prev: (rows: [String: (label: String, value: Double)], total: Double, cov: QueryResult.Coverage)?
        if q.compare == "previous" {
            let len = range.duration
            prev = compute(DateInterval(start: range.start.addingTimeInterval(-len), end: range.start))
        }
        var rows = cur.rows.map { QueryResult.Row(key: $0.key, label: $0.value.label, value: $0.value.value, previous: prev?.rows[$0.key]?.value ?? (prev == nil ? nil : 0)) }
        if group == "day" || group == "week" || group == "hour" || group == "weekday" {
            rows.sort { $0.key < $1.key }
        } else {
            rows.sort { ($0.value, $1.label) > ($1.value, $0.label) }
        }
        if q.filter?.topics?.isEmpty == false && cur.total == 0 && measure != "share" {
            problems.append("No time with topic \(q.filter!.topics!.joined(separator: ", ")) in that range")
        }
        return QueryResult(id: q.id, range: range, measure: measure, chart: q.chart ?? (group == "none" ? "number" : "bar"),
                           rows: rows, total: cur.total, previousTotal: prev?.total, coverage: cur.cov, problems: problems)
    }

    static func avg<S: Sequence>(_ xs: S) -> Double where S.Element == Int {
        let a = Array(xs)
        return a.isEmpty ? 0 : Double(a.reduce(0, +)) / Double(a.count)
    }

    // MARK: Range

    static func interval(_ r: TimeQuery.Range, now: Date, cal: Calendar, problems: inout [String]) -> DateInterval {
        let today = cal.startOfDay(for: now)
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today)!
        if let from = r.from.flatMap({ DayKeys.date(String($0.prefix(10)), cal) }) {
            let to = r.to.flatMap { DayKeys.date(String($0.prefix(10)), cal) }.flatMap { cal.date(byAdding: .day, value: 1, to: $0) } ?? tomorrow
            if to > from { return DateInterval(start: from, end: to) }
            problems.append("The range ends before it starts")
        }
        if let p = r.preset?.lowercased().trimmingCharacters(in: .whitespaces) {
            func span(_ c: Calendar.Component, back: Int) -> DateInterval? {
                guard let cur = cal.dateInterval(of: c, for: now),
                      let s = cal.date(byAdding: c, value: -back, to: cur.start) else { return nil }
                return back == 0 ? cur : DateInterval(start: s, end: cur.start)
            }
            switch p {
            case "today": return DateInterval(start: today, end: tomorrow)
            case "yesterday": return DateInterval(start: cal.date(byAdding: .day, value: -1, to: today)!, end: today)
            case "this week": if let i = span(.weekOfYear, back: 0) { return i }
            case "last week": if let i = span(.weekOfYear, back: 1) { return i }
            case "this month": if let i = span(.month, back: 0) { return i }
            case "last month": if let i = span(.month, back: 1) { return i }
            case "this year": if let i = span(.year, back: 0) { return i }
            default: problems.append("Unknown range “\(p)”, used the last 7 days")
            }
        }
        let raw = (r.last ?? "7d").lowercased().filter { !$0.isWhitespace }
        let n = Int(raw.filter(\.isNumber)) ?? 7
        let unit = raw.filter(\.isLetter)
        let days: Int
        switch unit {
        case "w", "wk", "week", "weeks": days = n * 7
        case "m", "mo", "month", "months": days = n * 30
        case "y", "year", "years": days = n * 365
        default: days = n
        }
        return DateInterval(start: cal.date(byAdding: .day, value: -(max(1, days) - 1), to: today)!, end: tomorrow)
    }

    // MARK: Filter

    struct Resolved {
        var categories: [CategoryID]?
        var untracked = false
        var groups: Set<CategoryGroup>?
        var topics: Set<String>?
        var tasks: Set<UUID>?
        var titles: [String]?
        var weekdays: Set<Int>?
        var hours: Set<Int>?
        var confirmedOnly = false
    }

    static func resolve(_ f: TimeQuery.Filter?, items: [WorkItem], tree: CategoryTree, problems: inout [String]) -> Resolved {
        var r = Resolved()
        guard let f else { return r }
        if let cs = f.categories, !cs.isEmpty {
            var ids: [CategoryID] = []
            for raw in cs {
                if raw.lowercased() == CategoryTree.untracked { r.untracked = true; continue }
                if let id = categoryId(raw, tree) { ids.append(id) } else { problems.append("No category “\(raw)”") }
            }
            r.categories = ids
        }
        if let gs = f.groups, !gs.isEmpty {
            r.groups = Set(gs.compactMap { CategoryGroup(rawValue: $0.lowercased()) })
            for g in gs where CategoryGroup(rawValue: g.lowercased()) == nil { problems.append("No group “\(g)”") }
        }
        if let ts = f.topics, !ts.isEmpty { r.topics = Set(ts.map { $0.lowercased() }) }
        if let ts = f.tasks, !ts.isEmpty {
            var ids = Set<UUID>()
            for raw in ts {
                if let p = EntryRef.parse(raw), p.kind == .task, let t = items.first(where: { EntryRef.matches(p, $0.id) }) { ids.insert(t.id) }
                else if let t = items.first(where: { $0.title.lowercased().contains(raw.lowercased()) }) { ids.insert(t.id) }
                else { problems.append("No task “\(raw)”") }
            }
            r.tasks = ids
        }
        if let ts = f.titles, !ts.isEmpty { r.titles = ts.map { $0.lowercased() } }
        if let w = f.weekdays, !w.isEmpty { r.weekdays = Set(w) }
        if let h = f.hours, !h.isEmpty { r.hours = Set(h) }
        r.confirmedOnly = f.confirmedOnly ?? false
        return r
    }

    /// An id, a name anywhere in the tree, or a path "School › Math" / "school/math".
    public static func categoryId(_ raw: String, _ tree: CategoryTree) -> CategoryID? {
        if tree.node(raw) != nil { return raw }
        let names = raw.components(separatedBy: CharacterSet(charactersIn: "›>/")).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var parent: CategoryID?
        for (i, n) in names.enumerated() {
            guard let hit = tree.find(n, under: parent) ?? (i == 0 ? tree.find(n) : nil) else { return nil }
            parent = hit.id
        }
        return parent
    }

    struct Piece {
        var slice: LogSlice
        var start: Date
        var seconds: Double
    }

    /// Slices cut at midnight (and at each hour when hours matter), so day / hour groups are exact.
    static func split(_ slices: [LogSlice], byHour: Bool, cal: Calendar) -> [Piece] {
        var out: [Piece] = []
        for s in slices {
            var t = s.start
            while t < s.end {
                let next = byHour ? cal.dateInterval(of: .hour, for: t)!.end : cal.dateInterval(of: .day, for: t)!.end
                let e = min(next, s.end)
                out.append(Piece(slice: s, start: t, seconds: e.timeIntervalSince(t)))
                t = e
            }
        }
        return out
    }

    static func matches(_ p: Piece, _ f: Resolved, tree: CategoryTree, cal: Calendar) -> Bool {
        if let w = f.weekdays, !w.contains(cal.component(.weekday, from: p.start)) { return false }
        if let h = f.hours, !h.contains(cal.component(.hour, from: p.start)) { return false }
        // Untracked time only when asked for by name ("untracked" in categories).
        guard let e = p.slice.entry else { return f.untracked }
        if f.confirmedOnly && e.assumed { return false }
        if let cs = f.categories, !(cs.contains { tree.isUnder(e.category, $0) }) { return false }
        if let gs = f.groups, !(tree.group(e.category).map(gs.contains) ?? false) { return false }
        if let ts = f.topics {
            let mine = Set(e.entry.topics.map { $0.lowercased() })
            let words = e.title.lowercased()
            if mine.isDisjoint(with: ts) && !ts.contains(where: { words.contains($0) }) { return false }
        }
        if let ts = f.tasks, !(e.taskId.map(ts.contains) ?? false) { return false }
        if let ts = f.titles, !ts.contains(where: { e.title.lowercased().contains($0) }) { return false }
        return true
    }

    static func key(_ p: Piece, _ group: String, tree: CategoryTree, items: [WorkItem], cal: Calendar) -> (String, String) {
        let e = p.slice.entry
        let cat = e?.category ?? CategoryTree.untracked
        func level(_ n: Int) -> (String, String) {
            let path = tree.path(cat)
            guard !path.isEmpty else { return (cat, tree.pathText(cat)) }
            let node = path[min(n, path.count) - 1]
            return (node.id, tree.pathText(node.id))
        }
        switch group {
        case "day": return (DayKeys.key(p.start, cal), DateFormatter.local("EEE d MMM", cal).string(from: p.start))
        case "week":
            let w = cal.dateInterval(of: .weekOfYear, for: p.start)!.start
            return (DayKeys.key(w, cal), "Week of " + DateFormatter.local("d MMM", cal).string(from: w))
        case "weekday":
            let d = cal.component(.weekday, from: p.start)
            return (String(d), cal.shortWeekdaySymbols[d - 1])
        case "hour":
            let h = cal.component(.hour, from: p.start)
            return (String(format: "%02d", h), String(format: "%d:00", h))
        case "category": return level(1)
        case "category2": return level(2)
        case "category3": return level(3)
        case "group": let g = tree.group(cat)?.rawValue ?? "untracked"; return (g, g.capitalized)
        case "topic": let t = e?.entry.topics.first ?? "(no topic)"; return (t, t)
        case "task":
            guard let id = e?.taskId else { return ("none", "Not a task") }
            return (id.uuidString, items.first { $0.id == id }?.title ?? "Task")
        case "title": let t = e?.title ?? "Untracked"; return (t.lowercased(), t)
        default: return ("all", "All")
        }
    }
}

/// Fills `{q1.total}` style placeholders in the model's reply with the engine's numbers.
public enum QueryText {
    public static func value(_ v: Double, measure: String) -> String {
        switch measure {
        case "share": return "\(Int((v * 100).rounded()))%"
        case "count": return "\(Int(v.rounded()))"
        case "firstStart", "lastEnd": return TimeOfDay(minutes: Int(v.rounded())).label
        default: return minutesLabel(Int(v.rounded()))
        }
    }

    public static func fill(_ reply: String, _ results: [QueryResult]) -> String {
        var out = reply
        for r in results {
            let top = r.rows.first.map { "\($0.label) (\(value($0.value, measure: r.measure)))" } ?? "nothing"
            var map: [String: String] = [
                "total": value(r.total, measure: r.measure),
                "avgPerDay": minutesLabel(Int((r.total / Double(max(1, r.coverage.days))).rounded())),
                "top": top,
                "rows": r.rows.prefix(5).map { "\($0.label) \(value($0.value, measure: r.measure))" }.joined(separator: ", "),
                "days": "\(r.coverage.daysWithData) of \(r.coverage.days) days",
            ]
            if let p = r.previousTotal {
                map["previous"] = value(p, measure: r.measure)
                let d = r.total - p
                map["change"] = (d >= 0 ? "+" : "−") + value(abs(d), measure: r.measure)
            }
            for (k, v) in map { out = out.replacingOccurrences(of: "{\(r.id).\(k)}", with: v) }
        }
        return out
    }
}
