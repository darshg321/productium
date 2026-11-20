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

    /// Ends the running entry at `at`. One that would end before it began is removed.
    @discardableResult
    public static func stop(at: Date, entries: inout [Entry], calendar cal: Calendar) -> LogReceipt {
        var r = LogReceipt()
        for i in entries.indices.reversed() where entries[i].isRunning {
            if at <= entries[i].start {
                r.removed.append(entries[i])
                r.lines.append("Removed \(entries[i].title) (it hadn't started yet)")
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
        return resolve(occ, in: r)
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

    /// Minutes per category in the resolved slices (Untracked included).
    public static func totals(_ slices: [LogSlice]) -> [CategoryID: Int] {
        slices.reduce(into: [:]) { $0[$1.category, default: 0] += $1.minutes }
    }

    static func clock(_ d: Date, _ cal: Calendar) -> String { DateFormatter.local("H:mm", cal).string(from: d) }
    static func span(_ e: Entry, _ cal: Calendar) -> String {
        "\(clock(e.start, cal))–" + (e.end.map { clock($0, cal) } ?? "now")
    }
}
