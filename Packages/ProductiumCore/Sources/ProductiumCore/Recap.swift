import Foundation

/// v1.3 Review: how much of a day already has something in it (classes, events, planned work, routines), between
/// waking and bedtime. Tomorrow's number says whether the plan has caught up with what's coming.
public struct PlannedShare: Hashable, Sendable {
    public var plannedMinutes: Int
    public var awakeMinutes: Int

    public var fraction: Double { awakeMinutes == 0 ? 0 : min(1, Double(plannedMinutes) / Double(awakeMinutes)) }
    public var percent: Int { Int((fraction * 100).rounded()) }

    /// Awake = from the end of the night's Sleep to the start of the next one (else the whole day).
    public static func make(_ day: Date, entries: [Entry], tree: CategoryTree, now: Date, book: DayRuleBook = DayRuleBook(),
                            calendar cal: Calendar) -> PlannedShare {
        let range = Days.dayInterval(day, cal)
        let noon = range.start.addingTimeInterval(12 * 3600)
        let occ = Days.expand(entries, in: range, now: now, book: book, calendar: cal)
        let sleep = occ.filter { tree.isUnder($0.category, CategoryTree.sleep) && $0.minutes >= 120 }
        let wake = max(range.start, sleep.filter { $0.end <= noon || $0.start < range.start.addingTimeInterval(6 * 3600) }.map(\.end).max() ?? range.start)
        let bed = min(range.end, sleep.filter { $0.start > noon }.map(\.start).min() ?? range.end)
        guard bed > wake else { return PlannedShare(plannedMinutes: 0, awakeMinutes: 0) }
        let spans = occ.filter { !tree.isUnder($0.category, CategoryTree.sleep) }
            .map { (max($0.start, wake), min($0.end, bed)) }.filter { $0.1 > $0.0 }.sorted { $0.0 < $1.0 }
        var covered: TimeInterval = 0
        var cursor = wake
        for (s, e) in spans where e > cursor {
            covered += e.timeIntervalSince(max(s, cursor))
            cursor = e
        }
        return PlannedShare(plannedMinutes: Int(covered / 60), awakeMinutes: Int(bed.timeIntervalSince(wake) / 60))
    }
}

/// v1.3 Review → Your Week: the recap you can open any time (Spotify Wrapped style). Everything is counted from the
/// log; nothing the model says is a number here.
public struct WeekRecap: Hashable, Sendable {
    public struct Slice: Hashable, Sendable {
        public var id: CategoryID
        public var name: String
        public var minutes: Int
    }

    public var start: Date
    public var end: Date
    public var trackedMinutes: Int
    public var workMinutes: Int
    public var usualWorkMinutes: Int?
    public var scrollingMinutes: Int
    public var usualScrollingMinutes: Int?
    public var deadlinesMet: Int
    public var deadlinesDue: Int
    public var bestDay: Date?
    public var bestScore: Int?
    public var averageScore: Int
    /// The level-2 categories with the most time (Sleep and Untracked left out), most first.
    public var top: [Slice]
    public var sleepPerNight: Int?
    public var topApp: Slice?
    public var mood: Double?

    /// `scores` are the week's days in order; `before` the 4 weeks before it (any number of days, averaged to a week).
    public static func make(days: [Date], scores: [DayScore], before: [DayScore], entries: [Entry], tree: CategoryTree,
                            moods: [MoodEntry], now: Date, book: DayRuleBook = DayRuleBook(), calendar cal: Calendar) -> WeekRecap? {
        guard let first = days.first, let last = days.last, days.count == scores.count else { return nil }
        let range = DateInterval(start: cal.startOfDay(for: first), end: Days.dayInterval(last, cal).end)
        let slices = TimeLog.past(entries, in: range, now: now, book: book, calendar: cal)
        var byCat: [CategoryID: Int] = [:]
        var apps: [String: Int] = [:]
        var sleep = 0
        for s in slices {
            guard let e = s.entry else { continue }
            if tree.isUnder(s.category, CategoryTree.sleep) { sleep += s.minutes; continue }
            byCat[RingModel.level2(s.category, tree), default: 0] += s.minutes
            if tree.isUnder(s.category, CategoryTree.scrolling) && e.source == .sensor { apps[e.title, default: 0] += s.minutes }
        }
        let top = byCat.filter { $0.value >= 15 && $0.key != CategoryTree.transition }
            .map { Slice(id: $0.key, name: tree.node($0.key)?.name ?? $0.key, minutes: $0.value) }
            .sorted { ($0.minutes, $1.name) > ($1.minutes, $0.name) }
        let best = zip(days, scores).max { ($0.1.score, $1.0) < ($1.1.score, $0.0) }
        let weeks = Double(max(1, before.count)) / 7
        let tracked = scores.reduce(0) { $0 + $1.wakingMinutes - $1.untrackedMinutes }
        let mine = moods.filter { range.contains($0.at) }
        let nights = days.filter { $0 <= now }.count
        return WeekRecap(start: range.start, end: range.end, trackedMinutes: tracked,
                         workMinutes: scores.reduce(0) { $0 + $1.workMinutes },
                         usualWorkMinutes: before.isEmpty ? nil : Int(Double(before.reduce(0) { $0 + $1.workMinutes }) / weeks),
                         scrollingMinutes: scores.reduce(0) { $0 + $1.scrollingMinutes },
                         usualScrollingMinutes: before.isEmpty ? nil : Int(Double(before.reduce(0) { $0 + $1.scrollingMinutes }) / weeks),
                         deadlinesMet: scores.reduce(0) { $0 + $1.deadlinesMet }, deadlinesDue: scores.reduce(0) { $0 + $1.deadlinesDue },
                         bestDay: best.map { $0.0 }, bestScore: best.map { $0.1.score },
                         averageScore: scores.isEmpty ? 0 : scores.reduce(0) { $0 + $1.score } / scores.count,
                         top: Array(top.prefix(5)), sleepPerNight: sleep > 0 && nights > 0 ? sleep / nights : nil,
                         topApp: apps.max { ($0.value, $1.key) < ($1.value, $0.key) }.map { Slice(id: CategoryTree.scrolling, name: $0.key, minutes: $0.value) },
                         mood: mine.isEmpty ? nil : Double(mine.reduce(0) { $0 + $1.mood }) / Double(mine.count))
    }
}

/// Vision gives text boxes, not lines: an app's name and its time sit side by side, and sorting by height alone puts
/// them in either order. Boxes whose middles are within half a line of each other are one row, read left to right.
public enum OCRLines {
    public struct Box: Hashable, Sendable {
        public var text: String
        /// Normalised, origin bottom-left (Vision's).
        public var x: Double, y: Double, height: Double
        public init(text: String, x: Double, y: Double, height: Double) {
            self.text = text
            self.x = x
            self.y = y
            self.height = height
        }
        var mid: Double { y + height / 2 }
    }

    public static func join(_ boxes: [Box]) -> String {
        var rows: [[Box]] = []
        for b in boxes.sorted(by: { $0.mid > $1.mid }) {
            if let last = rows.last?.last, abs(last.mid - b.mid) < max(last.height, b.height) * 0.5 {
                rows[rows.count - 1].append(b)
            } else {
                rows.append([b])
            }
        }
        return rows.map { $0.sorted { $0.x < $1.x }.map(\.text).joined(separator: " ") }.joined(separator: "\n")
    }
}
