import Foundation

// v1.2 Part B: the time log. Every minute of the past is an entry or Untracked.
//
// - Your one-off entries are kept non-overlapping when they're written: the newer one wins, and the receipt says
//   what was cut. (One thing is active at a time; what runs on the side, like music, is a note.)
// - Everything else (series, calendar, health, sensors, planned routines) is stored as it came and settled when
//   the log is read (`resolve`), by `DayEntry.rank`. So rebuilding sensor entries never has to undo a cut.
// - `TimeLog.past` is the one function every screen, total, goal and query uses for "what happened".

public struct LogReceipt: Hashable, Sendable {
    public var lines: [String] = []
    /// Ids of entries added, changed, or removed (for Undo through `ChangeLog`).
    public var added: [UUID] = []
    public var changed: [UUID] = []
    public var removed: [Entry] = []
    public init() {}

    public mutating func merge(_ o: LogReceipt) {
        lines += o.lines
        added += o.added
        changed += o.changed
        removed += o.removed
    }
}

/// A piece of the resolved log: one entry wins it, or nothing explains it (`entry == nil`, Untracked).
public struct LogSlice: Hashable, Sendable {
    public var start: Date
    public var end: Date
    public var entry: DayEntry?
    public var category: CategoryID { entry?.category ?? CategoryTree.untracked }
    public var assumed: Bool { entry?.assumed ?? false }
    public var minutes: Int { Int((end.timeIntervalSince(start) / 60).rounded()) }
}

public enum TimeLog {
    /// v1.6 E4: fixed time (a class from the timetable, a calendar event) counts as happened without asking.
    public static func isFixed(_ d: DayEntry, tree: CategoryTree) -> Bool {
        d.source == .calendar || (d.entry.repeats != nil && tree.isUnder(d.category, CategoryTree.school))
    }

    public static func running(_ entries: [Entry]) -> Entry? {
        entries.filter(\.isRunning).max { $0.start < $1.start }
    }

    /// Starts a live entry at `at` (backdated if in the past), closing the running one there. Whatever else of
    /// yours was under way from `at` until now ends at `at`; plans of yours further ahead are left alone.
    @discardableResult
    public static func start(_ new: Entry, at: Date, now: Date? = nil, entries: inout [Entry], calendar cal: Calendar) -> LogReceipt {
        var e = new
        e.start = at
        e.end = nil
        e.repeats = nil
        var r = stop(at: at, entries: &entries, calendar: cal)
        r.merge(insert(e, now: max(at, now ?? at), entries: &entries, calendar: cal))
        r.lines.append("Started \(e.title) at \(clock(at, cal))")
        return r
    }

    /// Stopped this soon after starting, it was a mis-tap: the entry goes instead of leaving a 0-minute stretch.
    public static let mistapSeconds: TimeInterval = 60

    /// Ends the running entry at `at`. One that would end before it began, or under a minute after, is removed.
    @discardableResult
    public static func stop(at: Date, entries: inout [Entry], calendar cal: Calendar) -> LogReceipt {
        var r = LogReceipt()
        for i in entries.indices.reversed() where entries[i].isRunning {
            if at <= entries[i].start {
                r.removed.append(entries[i])
                r.lines.append("Removed \(entries[i].title) (it hadn't started yet)")
                entries.remove(at: i)
            } else if at.timeIntervalSince(entries[i].start) < mistapSeconds && entries[i].createdAt > at.addingTimeInterval(-mistapSeconds) {
                r.removed.append(entries[i])
                r.lines.append("Cancelled \(entries[i].title)")
                entries.remove(at: i)
            } else {
                entries[i].end = at
                r.changed.append(entries[i].id)
                r.lines.append("Stopped \(entries[i].title) at \(clock(at, cal)) (\(minutesLabel(entries[i].minutes())))")
            }
        }
        return r
    }

    /// Adds an entry. One of yours trims the one-offs of yours it overlaps (newer wins); others are stored as
    /// they are. A running entry covers `start…now`: what overlaps that ends at its start, and nothing later is cut.
    @discardableResult
    public static func insert(_ new: Entry, now: Date? = nil, entries: inout [Entry], calendar cal: Calendar) -> LogReceipt {
        var r = LogReceipt()
        if new.source == .you && new.repeats == nil {
            let ns = new.start, ne = new.end ?? max(now ?? ns, ns.addingTimeInterval(1))
            var out: [Entry] = []
            for x in entries {
                guard x.source == .you, x.repeats == nil, x.id != new.id else { out.append(x); continue }
                let xs = x.start, xe = x.end ?? .distantFuture
                guard xs < ne && ns < xe else { out.append(x); continue }
                var parts: [Entry] = []
                if xs < ns { var a = x; a.end = ns; parts.append(a) }
                if xe > ne && new.end != nil { var b = x; b.start = ne; if !parts.isEmpty { b.id = UUID() }; parts.append(b) }
                // v1.6 A7: a sliver under a minute isn't kept.
                parts.removeAll { ($0.end ?? .distantFuture).timeIntervalSince($0.start) < 60 }
                if !parts.isEmpty && !parts.contains(where: { $0.id == x.id }) { parts[0].id = x.id }
                if parts.isEmpty {
                    r.removed.append(x)
                    r.lines.append("Replaced \(x.title) \(span(x, cal))")
                } else {
                    r.changed.append(x.id)
                    r.added += parts.dropFirst().map(\.id)
                    r.lines.append("Trimmed \(x.title) to " + parts.map { span($0, cal) }.joined(separator: " and "))
                }
                out += parts
            }
            entries = out
        }
        entries.append(new)
        r.added.append(new.id)
        return r
    }

    /// Splits a one-off entry in two at `at`. Returns the id of the second part.
    @discardableResult
    public static func split(_ id: UUID, at: Date, entries: inout [Entry]) -> UUID? {
        guard let i = entries.firstIndex(where: { $0.id == id }), entries[i].repeats == nil,
              entries[i].start < at, (entries[i].end ?? .distantFuture) > at else { return nil }
        var b = entries[i]
        b.id = UUID()
        b.start = at
        entries[i].end = at
        entries.append(b)
        return b.id
    }

    /// The log as non-overlapping slices over `range`, highest rank winning each minute (B.0), newer winning ties.
    /// Time nothing covers is an Untracked slice. Pass the occurrences you want counted (e.g. only up to now, or
    /// without `plan` entries).
    public static func resolve(_ occurrences: [DayEntry], in range: DateInterval) -> [LogSlice] {
        let items = occurrences.filter { $0.end > $0.start && $0.start < range.end && $0.end > range.start }
        var cuts = Set([range.start, range.end])
        for o in items {
            cuts.insert(max(range.start, o.start))
            cuts.insert(min(range.end, o.end))
        }
        let points = cuts.sorted()
        var out: [LogSlice] = []
        for (a, b) in zip(points, points.dropFirst()) where b > a {
            let winner = items.filter { $0.start <= a && $0.end >= b }.max(by: beats)
            if let last = out.last, last.end == a, last.entry?.id == winner?.id {
                out[out.count - 1].end = b
            } else {
                out.append(LogSlice(start: a, end: b, entry: winner))
            }
        }
        return out
    }

    /// What happened over `range` (clipped to `now`): every entry except planned task sessions (they only count
    /// once you start them, say you did them, or confirm them), resolved by rank, with Untracked gaps.
    public static func past(_ entries: [Entry], in range: DateInterval, now: Date, book: DayRuleBook = DayRuleBook(),
                            calendar cal: Calendar) -> [LogSlice] {
        let end = min(range.end, now)
        guard end > range.start else { return [] }
        let r = DateInterval(start: range.start, end: end)
        let occ = Days.expand(entries, in: r, now: now, book: book, calendar: cal)
            .filter { !$0.isPlannedSession }
        return transitions(resolve(occ, in: r))
    }

    /// A gap this long or shorter between two things is moving from one to the next, not Untracked (the goal is no
    /// untracked stretch over 15 minutes).
    public static let transitionMinutes = TrackPrompts.goalMinutes

    /// Untracked slices of at most `transitionMinutes` with something on both sides become Transition (already confirmed:
    /// there's nothing to ask about).
    static func transitions(_ slices: [LogSlice]) -> [LogSlice] {
        var out = slices
        for i in out.indices.dropFirst().dropLast() where out[i].entry == nil && out[i - 1].entry != nil && out[i + 1].entry != nil
            && out[i].end.timeIntervalSince(out[i].start) <= Double(transitionMinutes) * 60 {
            let e = Entry(id: Entry.sensorId("transition|\(Int(out[i].start.timeIntervalSince1970))"), title: "Transition",
                          start: out[i].start, end: out[i].end, category: CategoryTree.transition, source: .sensor,
                          createdAt: out[i].start)
            out[i].entry = DayEntry(entry: e, occurrence: nil, start: e.start, end: out[i].end, running: false, mark: .confirmed)
        }
        return out
    }

    /// Untracked stretches at least `minutes` long (the 30-minute goal, the "what are you up to?" prompts).
    public static func untracked(_ slices: [LogSlice], atLeast minutes: Int) -> [LogSlice] {
        slices.filter { $0.entry == nil && $0.minutes >= minutes }
    }

    /// Assumed time to confirm with a quick yes / no (or in the end-of-day review).
    public static func assumed(_ slices: [LogSlice]) -> [DayEntry] {
        var seen = Set<String>()
        return slices.compactMap(\.entry).filter { $0.assumed && seen.insert($0.id).inserted }
    }

    /// `a < b` in priority: rank, then newer, then the later start, then id (so the result is deterministic).
    static func beats(_ a: DayEntry, _ b: DayEntry) -> Bool {
        if a.rank != b.rank { return a.rank < b.rank }
        if a.entry.createdAt != b.entry.createdAt { return a.entry.createdAt < b.entry.createdAt }
        if a.start != b.start { return a.start < b.start }
        return a.id < b.id
    }

    /// v1.6 D2: unfocused work counts half in the Work ring and the score; Tracked time stays as it was.
    public static func focusWeight(_ focus: Int?) -> Double { focus == 1 ? 0.5 : 1 }

    /// v1.5: the last stretch of work you finished (≥10 min, in the last 3 hours) that has no focus rating yet.
    /// v1.6 D3: only time that happened: not skipped, not a session placed ahead that nobody tracked.
    public static func unratedWork(_ entries: [Entry], tree: CategoryTree, now: Date) -> Entry? {
        entries.filter { e in
            guard e.source == .you, e.repeats == nil, e.focus == nil, let end = e.end, end <= now, end > now.addingTimeInterval(-3 * 3600),
                  end.timeIntervalSince(e.start) >= 600, !e.marks.values.contains(.skipped), !Sessions.isUnworkedPlan(e) else { return false }
            return e.taskId != nil || tree.isUnder(e.category, CategoryTree.work)
        }.max { ($0.end ?? $0.start) < ($1.end ?? $1.start) }
    }

    /// Minutes of rated work per focus level (v1.6: 1 unfocused, 2 focused) in `range`.
    public static func focusMinutes(_ entries: [Entry], in range: DateInterval) -> [Int: Int] {
        entries.reduce(into: [:]) { out, e in
            guard let f = e.focus, (1...2).contains(f), let end = e.end, end > range.start, e.start < range.end else { return }
            out[f, default: 0] += Int(min(end, range.end).timeIntervalSince(max(e.start, range.start)) / 60)
        }
    }

    /// Rated work in `range` as (focused, total) minutes, overall and by part of day.
    public struct FocusStats: Sendable {
        public var focused = 0, total = 0
        public var parts: [(name: String, focused: Int, total: Int)] = []
        public var share: Double { total == 0 ? 0 : Double(focused) / Double(total) }

        /// The part of day with the highest share, when at least two parts have an hour of ratings.
        public var best: String? {
            let enough = parts.filter { $0.total >= 60 }
            guard enough.count >= 2 else { return nil }
            return enough.max { Double($0.focused) / Double($0.total) < Double($1.focused) / Double($1.total) }?.name
        }

        /// For the insight pass: "Focus ratings (14 days): 5h rated, 70% focused; morning 80% of 2h, …".
        public func line(days: Int) -> String? {
            guard total > 0 else { return nil }
            let p = parts.filter { $0.total > 0 }.map { "\($0.name) \(Int((Double($0.focused) / Double($0.total) * 100).rounded()))% of \(minutesLabel($0.total))" }
            return "Focus ratings (\(days) days): \(minutesLabel(total)) rated, \(Int((share * 100).rounded()))% focused"
                + (p.isEmpty ? "" : "; " + p.joined(separator: ", "))
        }
    }

    public static func focusStats(_ entries: [Entry], in range: DateInterval, calendar cal: Calendar) -> FocusStats {
        let names = ["morning", "afternoon", "evening"]
        var f = [0, 0, 0], t = [0, 0, 0]
        for e in entries {
            guard let r = e.focus, (1...2).contains(r), let end = e.end, end > range.start, e.start < range.end else { continue }
            let start = max(e.start, range.start)
            let m = Int(min(end, range.end).timeIntervalSince(start) / 60)
            let h = cal.component(.hour, from: start)
            let i = h < 12 ? 0 : h < 17 ? 1 : 2
            t[i] += m
            if r >= 2 { f[i] += m }
        }
        return FocusStats(focused: f.reduce(0, +), total: t.reduce(0, +), parts: (0..<3).map { (names[$0], f[$0], t[$0]) })
    }

    /// Minutes per category in the resolved slices (Untracked included).
    public static func totals(_ slices: [LogSlice]) -> [CategoryID: Int] {
        slices.reduce(into: [:]) { $0[$1.category, default: 0] += $1.minutes }
    }

    static func clock(_ d: Date, _ cal: Calendar) -> String { DateFormatter.local("H:mm", cal).string(from: d) }
    static func span(_ e: Entry, _ cal: Calendar) -> String {
        "\(clock(e.start, cal))–" + (e.end.map { clock($0, cal) } ?? "now")
    }
}
