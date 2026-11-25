import Foundation

// v1.2 Part 0: one type for everything that happens at a time. Classes, events, calendar events, task sessions,
// sleep, meals, the plan's blocks and the time log are all `Entry`s. Past = it happened (or is assumed to have),
// `end == nil` = running now, future = it will. A repeating entry is one stored value; `Days.expand` turns it into
// occurrences.
//
// Kept deliberately small so the model can say anything with it:
// - A series can only be *marked* per day (skipped, or confirmed). Anything else about one day (moved, retimed,
//   renamed) is just its own one-off entry, plus a skip on the series. One way to edit time, not two.
// - Whether the planner works around an entry follows from what it is: every non-plan entry is busy, unless it's
//   `open` (a spare period, lunch: you're there, but light work can go in it).
// - Overlaps are settled by how specific and how direct the source is (`DayEntry.rank`), not by flags.
//
// Rule for later work: no new timed type. A new need is a field here, a `Rule`, or a setting.

/// Opaque, stable id of a node in the `CategoryTree` ("school.math"). Never changes when a node is renamed or moved.
public typealias CategoryID = String

/// `yyyy-MM-dd` in the app's calendar. Keys an occurrence by the day it falls on (a series' normal day).
public typealias DayKey = String

public enum DayKeys {
    public static func key(_ d: Date, _ cal: Calendar) -> DayKey { AlarmPlanner.dayKey(d, cal) }

    public static func date(_ k: DayKey, _ cal: Calendar) -> Date? {
        let p = k.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return cal.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }
}

/// Where an entry came from.
public enum EntrySource: String, Codable, CaseIterable, Sendable {
    /// You: the box, a start button, a notification answer, a Shortcut, onboarding (the timetable).
    case you
    /// Imported from Calendar. Calendar itself is never written; changing one here = skip it + your own entry.
    case calendar
    /// Measured by Health (sleep, workouts).
    case health
    /// Inferred from location, motion, Screen Time and other signals (Part N).
    case sensor
    /// Made by the planner. Future plan entries are regenerated on every replan; past ones stay as history.
    case plan
}

/// What you said about one occurrence.
public enum Mark: String, Codable, Sendable {
    /// Didn't happen / not happening ("no school Friday", "didn't play Valorant", a hidden calendar event).
    case skipped
    /// You said yes to assumed time (the quick yes / no, or the end-of-day review).
    case confirmed
}

/// A notification or alarm tied to an entry's start or end. The wake alarm is an alarm at the end of Sleep.
public struct Alert: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case notify, alarm }
    public enum Edge: String, Codable, Sendable { case start, end }
    public var kind: Kind
    public var edge: Edge
    public var minutesBefore: Int
    /// Full-screen alarms only ring once you've allowed them (Part J). Notifications don't need it.
    public var approved: Bool

    public init(_ kind: Kind, edge: Edge = .start, minutesBefore: Int = 0, approved: Bool = false) {
        self.kind = kind
        self.edge = edge
        self.minutesBefore = max(0, minutesBefore)
        self.approved = approved
    }

    public static func notify(before m: Int = 0) -> Alert { Alert(.notify, minutesBefore: m) }
    public static let wake = Alert(.alarm, edge: .end, approved: true)
}

/// When a repeating entry recurs. The entry's own `start` / `end` give the time of day and the first day.
public struct Repeat: Codable, Hashable, Sendable {
    /// Which days (weekdays, odd / even dates, A/B rotations, labels, every other week …).
    public var days: DayRule
    /// First and last day, inclusive. `from` nil = the entry's start day.
    public var from: Date?
    public var until: Date?

    public init(_ days: DayRule, from: Date? = nil, until: Date? = nil) {
        self.days = days
        self.from = from
        self.until = until
    }

    public static func weekly(_ weekdays: Set<Int>, from: Date? = nil, until: Date? = nil) -> Repeat {
        Repeat(.weekdays(weekdays), from: from, until: until)
    }
}

public struct Entry: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var start: Date
    /// nil = running now. At most one entry runs (`TimeLog`).
    public var end: Date?
    public var category: CategoryID
    /// You filed it yourself (or corrected it): the AI and the taxonomy pass never re-file it.
    public var filedByYou: Bool
    public var topics: [String]
    public var placeId: UUID?
    /// Anything else worth keeping: what you were doing on the side ("music"), where exactly, why.
    public var note: String?
    /// Time for a task (a study session, a chore). Starting a task = starting an entry with its id.
    public var taskId: UUID?
    public var repeats: Repeat?
    /// Per-occurrence marks, keyed by the occurrence's day. One-offs use their start day.
    public var marks: [DayKey: Mark]
    /// You're there but it isn't busy (a spare period, lunch): the planner may put light work in it.
    public var open: Bool
    public var alert: Alert?
    public var source: EntrySource
    public var createdAt: Date
    /// How focused you were in this stretch of work (1 unfocused, 2 focused, 0 skipped), asked after it.
    public var focus: Int?

    public init(id: UUID = UUID(), title: String, start: Date, end: Date?, category: CategoryID,
                filedByYou: Bool = false, topics: [String] = [], placeId: UUID? = nil, note: String? = nil,
                taskId: UUID? = nil, repeats: Repeat? = nil, marks: [DayKey: Mark] = [:], open: Bool = false,
                alert: Alert? = nil, source: EntrySource, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.category = category
        self.filedByYou = filedByYou
        self.topics = topics
        self.placeId = placeId
        self.note = note
        self.taskId = taskId
        self.repeats = repeats
        self.marks = marks
        self.open = open
        self.alert = alert
        self.source = source
        self.createdAt = createdAt
    }

    public var isRunning: Bool { end == nil && repeats == nil }

    /// Length of one occurrence (a running entry: up to `now`).
    public func minutes(now: Date = Date()) -> Int {
        Int(((end ?? max(now, start)).timeIntervalSince(start) / 60).rounded())
    }

    /// Calendar events get ids derived from their EventKit id, so a re-import keeps marks and refs stable.
    public static func calendarId(_ eventKitId: String) -> UUID { Planner.stableUUID("calendar|\(eventKitId)") }

    /// Sensor entries get ids derived from the signal that made them, so rebuilding them is idempotent.
    public static func sensorId(_ signalKey: String) -> UUID { Planner.stableUUID("sensor|\(signalKey)") }
}

/// One occurrence, as every screen, the planner, the ring and the box see it.
public struct DayEntry: Hashable, Identifiable, Sendable {
    public var entry: Entry
    /// The occurrence's day for repeating entries (`e…@2026-11-20`), nil for one-offs.
    public var occurrence: DayKey?
    public var start: Date
    /// A running entry ends at `now` here; `running` says so.
    public var end: Date
    public var running: Bool
    public var mark: Mark?

    /// Stable across replans and launches: the entry id, plus `@day` for an occurrence of a repeating entry.
    public var id: String { occurrence.map { "\(entry.id.uuidString)@\($0)" } ?? entry.id.uuidString }
    public var ref: String { EntryRef.entry(entry.id, occurrence: occurrence) }
    public var title: String { entry.title }
    public var category: CategoryID { entry.category }
    public var source: EntrySource { entry.source }
    public var taskId: UUID? { entry.taskId }
    public var alert: Alert? { entry.alert }
    public var minutes: Int { Int((end.timeIntervalSince(start) / 60).rounded()) }

    /// Busy for the planner: everything you, Calendar or Health put there, unless it's open time.
    public var busy: Bool { source != .plan && source != .sensor && !entry.open }

    /// Not verified: scheduled ahead (a class, a calendar event, something you said you'd do), inferred by a
    /// sensor, or a planned routine (sleep, dinner). It counts as what happened unless you say no. Planned task
    /// sessions are never assumed: they need tracked time, or they're missed (`Accountability`).
    public var assumed: Bool {
        if mark == .confirmed || running || isPlannedSession { return false }
        switch source {
        case .health: return false
        case .sensor, .calendar: return true
        case .plan: return taskId == nil
        // Said before it began ("Valorant at 9:30 tonight") = a plan of yours; said live or afterwards = what happened.
        case .you: return entry.repeats != nil || entry.createdAt < start.addingTimeInterval(-60)
        }
    }

    /// Time set aside for a task ahead of time, by the planner or by you ("do reading at 4"). It's a plan, not a
    /// record: it only becomes tracked time if you start it (or say you did it).
    public var isPlannedSession: Bool {
        guard taskId != nil, mark != .confirmed, !running else { return false }
        return source == .plan || (source == .you && entry.createdAt < start.addingTimeInterval(-60))
    }

    /// Who wins when two cover the same minute (B.0). What you said about that specific time beats anything
    /// measured, which beats anything scheduled, which beats a sensor's guess, which beats a planned routine.
    public var rank: Int {
        switch source {
        case .you: return assumed ? 3 : 5
        case .health: return 4
        case .calendar: return 3
        case .sensor: return 2
        case .plan: return 1
        }
    }
}

/// Refs the box uses (Part 0.2): `e…` entry (series), `e…@yyyy-MM-dd` one occurrence, `t…` task, `u…` rule.
/// Short refs are the first 6 hex digits of the id.
public enum EntryRef {
    public static func entry(_ id: UUID, occurrence: DayKey? = nil) -> String {
        "e" + Ref.short(id.uuidString) + (occurrence.map { "@\($0)" } ?? "")
    }
    public static func task(_ id: UUID) -> String { Ref.task(id) }
    public static func rule(_ id: UUID) -> String { "u" + Ref.short(id.uuidString) }

    public enum Kind: Hashable, Sendable { case entry, task, rule }

    public struct Parsed: Hashable, Sendable {
        public var kind: Kind
        /// Hex prefix (or the whole UUID string) to match against ids.
        public var id: String
        public var occurrence: DayKey?
    }

    public static func parse(_ raw: String) -> Parsed? {
        let r = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard let p = r.first else { return nil }
        let kind: Kind
        switch p {
        case "e": kind = .entry
        case "t": kind = .task
        case "u": kind = .rule
        default: return nil
        }
        let parts = r.dropFirst().split(separator: "@", maxSplits: 1).map(String.init)
        guard let id = parts.first, !id.isEmpty else { return nil }
        let occ = parts.count > 1 ? parts[1] : nil
        if let occ, occ.split(separator: "-").count != 3 { return nil }
        if kind != .entry && occ != nil { return nil }
        return Parsed(kind: kind, id: id, occurrence: occ)
    }

    /// Whether a parsed ref names this id (full UUID, the 6-digit short ref, or an unambiguous ≥4-digit prefix).
    public static func matches(_ p: Parsed, _ id: UUID) -> Bool {
        if p.id == id.uuidString.lowercased() { return true }
        let mine = Ref.short(id.uuidString)
        return p.id.count >= 4 && p.id.allSatisfy(\.isHexDigit) && mine.hasPrefix(p.id)
    }

    /// The one entry a ref names, or nil if none or more than one match.
    public static func resolve(_ raw: String, in entries: [Entry]) -> (index: Int, occurrence: DayKey?)? {
        guard let p = parse(raw), p.kind == .entry else { return nil }
        let hits = entries.indices.filter { matches(p, entries[$0].id) }
        guard hits.count == 1 else { return nil }
        return (hits[0], p.occurrence)
    }
}

// MARK: - Tasks

public enum TaskState: String, Codable, Sendable { case open, done, dropped }

// `WorkItem` is v1.2's Task (named so it doesn't clash with Swift's `Task`): something with a deadline and an
// amount of time it needs. The planner spreads that time before the deadline as `plan` entries with its id; time
// spent on it is any entry with its `taskId`, whenever you did it.
extension WorkItem {
    /// Open: the planner schedules it. Done and dropped tasks are both out of the plan; only `done` counts as done.
    public var isOpen: Bool { state == .open }
    /// Light enough for open time (a spare, lunch): easy, or short.
    public var isLight: Bool { difficulty <= 1 || estimateMinutes - completedMinutes <= 20 }
}

// MARK: - Plan output as Entries

public enum PlanEntries {
    /// The plan's future blocks as `plan` Entries (O3). Blocks that came from an Entry are left out (they already
    /// are one), and so are free / gap / break windows: free time is the absence of an entry.
    public static func from(_ plan: Plan, items: [WorkItem], now: Date, calendar cal: Calendar = .current) -> [Entry] {
        let byId = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // The wake alarm on a school morning says when to leave (it's the planned Sleep's end).
        let leave = Dictionary(plan.wakePlans.compactMap { w in w.leaveBy.map { (w.wake, $0) } }, uniquingKeysWith: { a, _ in a })
        return plan.blocks.compactMap { b -> Entry? in
            guard b.end > now, !(b.sourceId?.hasPrefix("entry:") ?? false) else { return nil }
            let category: CategoryID
            switch b.kind {
            case .work, .review: category = b.itemId.flatMap { byId[$0]?.category } ?? CategoryTree.studying
            case .sleep: category = CategoryTree.sleep
            case .windDown: category = CategoryTree.windDown
            case .meal: category = CategoryTree.meals
            case .routine:
                if let s = b.sourceId, s.hasPrefix("habit:") { category = String(s.dropFirst(6)) }
                else { category = b.sourceId?.hasSuffix("school") == true ? CategoryTree.travel : CategoryTree.gettingReady }
            case .commitment, .event: category = CategoryTree.other
            case .free, .gap, .breakTime: return nil
            }
            var note = b.hint
            if b.kind == .sleep, let l = leave[b.end] { note = "Leave by \(NudgePlanner.clock(l, cal))" }
            return Entry(id: b.id, title: b.title, start: b.start, end: b.end, category: category, note: note,
                         taskId: b.itemId, alert: b.kind == .sleep ? .wake : nil, source: .plan, createdAt: plan.generatedAt)
        }
    }

    /// After a replan: future plan entries are replaced. v1.6 A1: a past or running session nobody worked on is
    /// dropped when the new plan moved it (its task is planned again, or the session is gone from the plan), so a move
    /// leaves no copy behind. One whose task isn't planned again stays, as planned but not done.
    public static func replace(in entries: inout [Entry], with new: [Entry], now: Date) {
        let newIds = Set(new.map(\.id))
        let replanned = Set(new.filter { $0.start >= now }.compactMap(\.taskId))
        let snapshot = entries
        entries.removeAll { e in
            guard e.source == .plan else { return false }
            if e.start >= now { return true }
            guard let task = e.taskId, !newIds.contains(e.id), !Sessions.isWorked(e, entries: snapshot, now: now) else { return false }
            return (e.end ?? now) > now || replanned.contains(task)
        }
        let keep = Set(entries.map(\.id))
        entries += new.filter { $0.start >= now && !keep.contains($0.id) }
    }
}

// MARK: - Alerts (O4)

/// Alarms and notifications wanted by Entries' `alert`s. `AlarmPlanner.desired` adds the alarms to its wanted list,
/// so the device reconciler is unchanged. Alarms ring only when approved (Part J) and alarms are allowed at all.
public enum EntryAlerts {
    public struct Fire: Hashable, Sendable {
        /// Stable: the occurrence id and edge, so a replan that doesn't move it doesn't touch the device.
        public var key: String
        public var at: Date
        public var title: String
        public var kind: Alert.Kind
        public var approved: Bool
        public var ref: String
    }

    public static func due(_ occurrences: [DayEntry], now: Date) -> [Fire] {
        occurrences.compactMap { o -> Fire? in
            guard let a = o.alert, !o.running, o.mark != .skipped else { return nil }
            let edge = a.edge == .start ? o.start : o.end
            let at = edge.addingTimeInterval(-Double(a.minutesBefore) * 60)
            guard at > now else { return nil }
            let title: String
            switch (a.edge, a.minutesBefore) {
            case (.end, _) where o.category == CategoryTree.sleep:
                title = o.entry.note.flatMap { $0.hasPrefix("Leave by") ? $0 : nil } ?? "Good morning"
            case (.start, 0): title = o.title
            case (.start, let m): title = "\(o.title) in \(minutesLabel(m))"
            case (.end, 0): title = "\(o.title) ends now"
            case (.end, let m): title = "\(o.title) ends in \(minutesLabel(m))"
            }
            return Fire(key: "entry.\(o.id).\(a.edge.rawValue)", at: at, title: title, kind: a.kind,
                        approved: a.approved, ref: o.ref)
        }.sorted { ($0.at, $0.key) < ($1.at, $1.key) }
    }

    public static func alarms(_ occurrences: [DayEntry], now: Date, allowed: Bool) -> [PlannedAlarm] {
        guard allowed else { return [] }
        return due(occurrences, now: now).filter { $0.kind == .alarm && $0.approved }
            .map { PlannedAlarm(key: $0.key, kind: .entry, at: $0.at, title: $0.title) }
    }
}
