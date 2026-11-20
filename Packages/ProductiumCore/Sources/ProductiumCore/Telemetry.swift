import Foundation

// v1.2 Part T: a development log kept on the phone and written into every backup, so a problem found while using
// the app can be traced from the export alone (what happened, in what order, what the code decided). Record anything
// that could ever be useful: the app isn't released, and the log only leaves the phone in a backup you make.
// Bounded only so the backup stays a reasonable size: the newest `maxEvents`, at most `maxAgeDays` old.
//
// Record at decisions and boundaries, not in loops: a box turn and its receipt, a replan and what it couldn't fit,
// every sensor / Health read (count, error), notifications scheduled and answered, alarms reconciled, intents run,
// background launches, and every time the AI said it couldn't do something (`gap`): that list is v1.3's backlog.

public struct TelemetryEvent: Codable, Hashable, Sendable {
    public enum Area: String, Codable, CaseIterable, Sendable {
        case box, gap, planner, log, sensor, health, notification, alarm, intent, lifecycle, ai, storage, error
    }
    public enum Level: String, Codable, Comparable, Sendable {
        case debug, info, warn, error
        var order: Int { [.debug: 0, .info: 1, .warn: 2, .error: 3][self]! }
        public static func < (a: Level, b: Level) -> Bool { a.order < b.order }
    }

    public var at: Date
    public var area: Area
    public var name: String
    public var level: Level
    /// Anything useful: ids, refs, counts, durations, errors, titles, messages, coordinates, small JSON.
    public var detail: [String: String]

    public init(at: Date, area: Area, name: String, level: Level = .info, detail: [String: String] = [:]) {
        self.at = at
        self.area = area
        self.name = name
        self.level = level
        self.detail = detail
    }
}

public struct Telemetry: Codable, Hashable, Sendable {
    public static let maxEvents = 20000
    public static let maxAgeDays = 60
    public static let maxValueLength = 4000

    public var events: [TelemetryEvent] = []
    public init() {}

    public mutating func record(_ area: TelemetryEvent.Area, _ name: String, level: TelemetryEvent.Level = .info,
                                at: Date = Date(), _ detail: [String: String] = [:]) {
        events.append(TelemetryEvent(at: at, area: area, name: name, level: level,
                                     detail: detail.mapValues { String($0.prefix(Self.maxValueLength)) }))
        if events.count > Self.maxEvents + 1000 { events.removeFirst(events.count - Self.maxEvents) }
    }

    public mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-Double(Self.maxAgeDays) * 86400)
        events.removeAll { $0.at < cutoff }
        if events.count > Self.maxEvents { events.removeFirst(events.count - Self.maxEvents) }
    }

    public func recent(_ area: TelemetryEvent.Area? = nil, atLeast level: TelemetryEvent.Level = .debug, limit: Int = 50) -> [TelemetryEvent] {
        Array(events.filter { (area == nil || $0.area == area) && $0.level >= level }.suffix(limit))
    }

    /// One box turn: what you said, what was asked for, what was applied, held and refused.
    public mutating func boxTurn(_ r: BoxReceipt, turnId: UUID, message: String, ops: [BoxOp], at: Date) {
        let opsJSON = (try? JSONEncoder().encode(ops)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        record(.box, "turn", level: r.problems.isEmpty ? .info : .warn, at: at, [
            "turn": turnId.uuidString,
            "message": message,
            "opsJSON": opsJSON,
            "ops": ops.map { "\($0.noun.rawValue).\($0.verb.rawValue)\($0.ref.map { " " + $0 } ?? "")" }.joined(separator: "; "),
            "lines": r.lines.joined(separator: " | "),
            "problems": r.problems.joined(separator: " | "),
            "held": r.held.map(\.why).joined(separator: " | "),
            "warnings": r.warnings.joined(separator: " | "),
        ].filter { !$0.value.isEmpty })
        for p in r.problems { record(.gap, "op_failed", level: .warn, at: at, ["turn": turnId.uuidString, "problem": p]) }
    }

    /// The AI said it couldn't do what was asked (the box's `gap` field), or an op it needed doesn't exist.
    public mutating func gap(_ what: String, said: String?, turnId: UUID?, at: Date) {
        record(.gap, "cant_do", level: .warn, at: at,
               ["what": what, "said": said ?? "", "turn": turnId?.uuidString ?? ""].filter { !$0.value.isEmpty })
    }
}

/// A snapshot written into the export next to the state: the numbers to look at first when something's off.
public enum Diagnostics {
    public static func snapshot(_ s: AppState, now: Date, calendar cal: Calendar) -> [String: String] {
        var d: [String: String] = [:]
        d["schema"] = "\(s.schema)"
        for src in EntrySource.allCases { d["entries.\(src.rawValue)"] = "\(s.entries.filter { $0.source == src }.count)" }
        d["entries.repeating"] = "\(s.entries.filter { $0.repeats != nil }.count)"
        d["running"] = TimeLog.running(s.entries).map { "\($0.title) since \(ISO8601DateFormatter().string(from: $0.start))" } ?? "none"
        d["rules"] = "\(s.rules.count)"
        d["tasks.open"] = "\(s.items.filter(\.isOpen).count)"
        d["categories"] = "\(s.categories.nodes.count)"
        for back in 0..<3 {
            guard let day = cal.date(byAdding: .day, value: -back, to: cal.startOfDay(for: now)) else { continue }
            let slices = TimeLog.past(s.entries, in: Days.dayInterval(day, cal), now: now, book: s.dayRules, calendar: cal)
            let untracked = slices.filter { $0.entry == nil }.reduce(0) { $0 + $1.minutes }
            let assumed = slices.filter(\.assumed).reduce(0) { $0 + $1.minutes }
            let total = slices.reduce(0) { $0 + $1.minutes }
            d["coverage.\(DayKeys.key(day, cal))"] = "tracked \(total - untracked - assumed) assumed \(assumed) untracked \(untracked) of \(total) min"
        }
        for area in TelemetryEvent.Area.allCases {
            let ev = s.telemetry.events.filter { $0.area == area }
            guard let last = ev.last else { continue }
            d["telemetry.\(area.rawValue)"] = "\(ev.count) events, last \(last.name) at \(ISO8601DateFormatter().string(from: last.at))"
        }
        if let e = s.telemetry.events.last(where: { $0.level == .error }) {
            d["lastError"] = "\(e.area.rawValue).\(e.name) \(e.detail.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))"
        }
        return d
    }
}
