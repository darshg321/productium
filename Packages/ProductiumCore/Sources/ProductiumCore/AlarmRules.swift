import Foundation

// v1.1: alarms the student (through the box) or the insight pass can add, move, switch off or tie to a task, on top
// of the ones Productium works out itself. A rule is either a new alarm (a clock time, a time before a task is due,
// a time before a task's study blocks) or an adjustment to the generated ones (shift every bedtime alarm 15 minutes
// earlier on Fridays, no leave-by alarm on Wednesdays). All of them go through `AlarmPlanner.desired`, so the device
// reconciler cancels what a rule removed and adds what a rule created, with no extra scheduling code.

public struct AlarmRule: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        /// Rings at `time` on the days `when` matches (no rule: the next time that clock time comes).
        case clock
        /// `minutes` before the task `itemId` is due. Gone when the task is done or deleted.
        case beforeDue
        /// `minutes` before each planned study block (of `itemId`, or of any task).
        case beforeBlocks
        /// Moves the generated alarms of `target` by `minutes` (negative: earlier) on the days `when` matches.
        case shift
        /// Removes the generated alarms of `target` on the days `when` matches.
        case suppress
    }

    public var id: UUID
    public var label: String
    public var kind: Kind
    public var time: TimeOfDay?
    public var itemId: UUID?
    public var minutes: Int
    public var target: PlannedAlarm.Kind?
    public var when: DayRule?
    public var enabled: Bool
    public var expires: Date?
    public var source: Writer
    public var createdAt: Date

    public init(id: UUID = UUID(), label: String = "", kind: Kind, time: TimeOfDay? = nil, itemId: UUID? = nil, minutes: Int = 0,
                target: PlannedAlarm.Kind? = nil, when: DayRule? = nil, enabled: Bool = true, expires: Date? = nil,
                source: Writer = .box, createdAt: Date = Date()) {
        self.id = id
        self.label = label
        self.kind = kind
        self.time = time
        self.itemId = itemId
        self.minutes = minutes
        self.target = target
        self.when = when
        self.enabled = enabled
        self.expires = expires
        self.source = source
        self.createdAt = createdAt
    }

    /// Short words for receipts, the context and the Changes log.
    public func summary(items: [WorkItem] = [], calendar cal: Calendar) -> String {
        let task = itemId.flatMap { id in items.first { $0.id == id }?.title }
        let days = when.map { " (\($0.text(cal)))" } ?? ""
        switch kind {
        case .clock: return "\(label.isEmpty ? "Alarm" : label) at \(time?.label ?? "?")\(days)"
        case .beforeDue: return "\(label.isEmpty ? "Alarm" : label): \(minutes == 0 ? "when" : "\(minutesLabel(minutes)) before") \(task ?? "a task") is due"
        case .beforeBlocks: return "\(label.isEmpty ? "Alarm" : label): \(minutesLabel(minutes)) before \(task.map { "\($0) blocks" } ?? "each study block")\(days)"
        case .shift: return "\(target?.rawValue ?? "?") alarms \(abs(minutes)) min \(minutes < 0 ? "earlier" : "later")\(days)"
        case .suppress: return "No \(target?.rawValue ?? "?") alarms\(days)"
        }
    }

    public func isLive(now: Date, calendar cal: Calendar) -> Bool {
        guard enabled else { return false }
        if let e = expires, cal.startOfDay(for: now) > cal.startOfDay(for: e) { return false }
        return true
    }
}

public enum AlarmRules {
    /// At most this many alarms come from rules at once (the device holds a limited number of alarms).
    public static let maxRuleAlarms = 12
    public static let horizonDays = 14

    /// Adjusts the generated alarms, then adds the rules' own. Pure; the reconciler does the rest.
    public static func apply(_ base: [PlannedAlarm], rules: [AlarmRule], items: [WorkItem], plan: Plan, dayRules: DayRuleBook,
                             now: Date, calendar cal: Calendar, startedBlock: UUID? = nil, label: (Date) -> String) -> [PlannedAlarm] {
        let live = rules.filter { $0.isLive(now: now, calendar: cal) }.sorted { $0.createdAt < $1.createdAt }
        guard !live.isEmpty else { return base }
        let eval = DayRuleEvaluator(book: dayRules, calendar: cal)
        func matches(_ r: AlarmRule, _ d: Date) -> Bool { r.when.map { eval.matches($0, on: d) } ?? true }

        var out = base
        for r in live where r.kind == .shift || r.kind == .suppress {
            guard let t = r.target else { continue }
            if r.kind == .suppress {
                out.removeAll { $0.kind == t && matches(r, cal.startOfDay(for: $0.at)) }
            } else {
                out = out.map { a in
                    guard a.kind == t, matches(r, cal.startOfDay(for: a.at)) else { return a }
                    var a = a
                    a.at = a.at.addingTimeInterval(Double(r.minutes) * 60)
                    return a
                }
            }
        }

        var extra: [PlannedAlarm] = []
        let end = now.addingTimeInterval(Double(horizonDays) * 86400)
        let open = Dictionary(items.filter { $0.isOpen }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for r in live {
            let name = r.label
            switch r.kind {
            case .clock:
                guard let t = r.time else { continue }
                func at(_ day: Date) -> Date? { cal.date(bySettingHour: t.hour, minute: t.minute, second: 0, of: day) }
                let today = cal.startOfDay(for: now)
                if r.when == nil {
                    if let a = [0, 1].compactMap({ d in cal.date(byAdding: .day, value: d, to: today).flatMap(at) }).first(where: { $0 > now }) {
                        extra.append(PlannedAlarm(key: "rule.\(r.id.uuidString).\(AlarmPlanner.dayKey(a, cal))", kind: .missedStart, at: a,
                                                  title: name.isEmpty ? "Alarm" : name))
                    }
                } else {
                    for d in 0..<horizonDays {
                        guard let day = cal.date(byAdding: .day, value: d, to: today), matches(r, day), let a = at(day), a > now else { continue }
                        if let e = r.expires, cal.startOfDay(for: a) > cal.startOfDay(for: e) { continue }
                        extra.append(PlannedAlarm(key: "rule.\(r.id.uuidString).\(AlarmPlanner.dayKey(a, cal))", kind: .missedStart, at: a,
                                                  title: name.isEmpty ? "Alarm" : name))
                    }
                }
            case .beforeDue:
                guard let id = r.itemId, let item = open[id] else { continue }
                let a = item.due.addingTimeInterval(-Double(r.minutes) * 60)
                guard a > now, a < end.addingTimeInterval(30 * 86400) else { continue }
                extra.append(PlannedAlarm(key: "rule.\(r.id.uuidString).due", kind: .missedStart, at: a,
                                          title: name.isEmpty ? "\(item.title) is due\(r.minutes > 0 ? " in \(minutesLabel(r.minutes))" : "")" : name))
            case .beforeBlocks:
                for b in plan.blocks where b.isStudy && b.start > now && b.start < end && b.id != startedBlock {
                    if let id = r.itemId, b.itemId != id { continue }
                    if let id = r.itemId, open[id] == nil { continue }
                    guard matches(r, cal.startOfDay(for: b.start)) else { continue }
                    let a = b.start.addingTimeInterval(-Double(r.minutes) * 60)
                    guard a > now else { continue }
                    extra.append(PlannedAlarm(key: "rule.\(r.id.uuidString).\(b.id)", kind: .missedStart, at: a,
                                              title: name.isEmpty ? "\(b.title) at \(label(b.start))" : name, blockId: b.id))
                }
            case .shift, .suppress: break
            }
        }
        extra = Array(extra.sorted { $0.at < $1.at }.prefix(maxRuleAlarms))
        let taken = Set(extra.map { AlarmPlanner.minute($0.at) })
        // A generated alarm at the very minute of a rule's own is noise.
        out.removeAll { $0.kind != .wake && taken.contains(AlarmPlanner.minute($0.at)) }
        return out + extra
    }
}
