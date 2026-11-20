import Foundation

/// Every alarm Productium wants on the device, and how to get the device there from whatever is on it now.
///
/// Why this exists (v1.1 C.1): alarms used to be rescheduled from two fire-and-forget tasks per replan that each
/// read "the ids I saved last time", cancelled those and saved new ones. Two replans close together, or the app
/// being suspended between scheduling and saving, left alarms that nothing tracked any more: they rang at old
/// times. Turning Wake-Up Alarms off never cancelled the wake alarms at all. Now there is one wanted list, and it
/// is compared with what the device actually has.
public enum AlarmPlanner {
    /// The next wake alarms kept on the device. Three covers a weekend without the app being opened.
    public static let wakeCount = 3

    /// `yyyy-MM-dd` in the app's calendar: keys name the day an alarm belongs to, not when it was planned.
    public static func dayKey(_ d: Date, _ cal: Calendar) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public static func wakeTitle(_ w: WakePlan, timeLabel: (Date) -> String) -> String {
        w.leaveBy.map { "Leave by \(timeLabel($0))" } ?? "Good morning"
    }

    /// The whole wanted list: wake alarms (Wake-Up Alarms) plus bedtime / leave / missed-start
    /// (Alarms for the Important Ones). Either toggle off means none of its alarms, so they get cancelled.
    public static func desired(_ input: NudgeInput, wake: Bool, entryAlarms: [PlannedAlarm] = [],
                               timeLabel: ((Date) -> String)? = nil) -> [PlannedAlarm] {
        let label = timeLabel ?? input.timeLabel ?? { NudgePlanner.clock($0, input.calendar) }
        var out: [PlannedAlarm] = []
        if wake {
            let upcoming = input.plan.wakePlans.filter { $0.wake > input.now }.sorted { $0.wake < $1.wake }
            var seen = Set<String>()
            for w in upcoming {
                let key = "wake.\(dayKey(w.wake, input.calendar))"
                guard seen.insert(key).inserted else { continue }
                out.append(PlannedAlarm(key: key, kind: .wake, at: w.wake, title: wakeTitle(w, timeLabel: label)))
                if out.count == wakeCount { break }
            }
        }
        var nudges = NudgePlanner.alarms(input)
        // A wake alarm already rings at that minute: a second one is noise.
        let wakeMinutes = Set(out.map { minute($0.at) })
        nudges.removeAll { wakeMinutes.contains(minute($0.at)) }
        let all = AlarmRules.apply(out + nudges, rules: input.alarmRules, items: input.items, plan: input.plan, dayRules: input.dayRules,
                                   now: input.now, calendar: input.calendar, startedBlock: input.startedBlockId, label: label)
        // Alarms an Entry asked for (`EntryAlerts`). One at the minute of another alarm is noise (a Sleep entry's wake
        // alarm and the planner's own wake alarm are the same alarm until the separate wake path goes, O4).
        var taken = Set(all.map { minute($0.at) })
        var extra: [PlannedAlarm] = []
        for a in entryAlarms.sorted(by: { ($0.at, $0.key) < ($1.at, $1.key) }) where a.at > input.now && taken.insert(minute(a.at)).inserted {
            extra.append(a)
        }
        return (all + extra).sorted { $0.at < $1.at }
    }

    static func minute(_ d: Date) -> Int { Int((d.timeIntervalSince1970 / 60).rounded(.down)) }
}

/// What Productium remembers about an alarm it scheduled: which wanted alarm it is.
public struct AlarmLedgerEntry: Codable, Hashable, Sendable {
    public var key: String
    public var at: Date
    public var title: String
    public init(key: String, at: Date, title: String) {
        self.key = key
        self.at = at
        self.title = title
    }
}

/// An alarm the device reports (AlarmKit `AlarmManager.shared.alarms`, which only lists this app's alarms).
public struct DeviceAlarm: Hashable, Sendable {
    public var id: UUID
    /// Ringing now. Never cancelled by a reschedule: that would silence an alarm while it rings.
    public var alerting: Bool
    public init(id: UUID, alerting: Bool = false) {
        self.id = id
        self.alerting = alerting
    }
}

public struct AlarmDiff: Hashable, Sendable {
    public var cancel: [UUID]
    public var add: [PlannedAlarm]
    /// The ledger once the cancels are done (adds are recorded as each one succeeds).
    public var ledger: [UUID: AlarmLedgerEntry]
    public var isEmpty: Bool { cancel.isEmpty && add.isEmpty }
}

public enum AlarmReconciler {
    /// Compares the wanted list with the device. The device is the truth: an alarm on it that the ledger doesn't
    /// know is an orphan and goes; a ledger entry the device no longer has is forgotten (it fired or was removed).
    public static func diff(desired: [PlannedAlarm], device: [DeviceAlarm], ledger: [UUID: AlarmLedgerEntry],
                            now: Date) -> AlarmDiff {
        let wanted = Dictionary(desired.filter { $0.at > now }.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var kept: [UUID: AlarmLedgerEntry] = [:]
        var keptKeys = Set<String>()
        var cancel: [UUID] = []
        // Oldest first so a duplicate pair keeps a stable survivor.
        for d in device.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            let entry = ledger[d.id]
            if d.alerting {
                if let entry { kept[d.id] = entry }
                continue
            }
            guard let entry, let w = wanted[entry.key], !keptKeys.contains(entry.key),
                  AlarmPlanner.minute(w.at) == AlarmPlanner.minute(entry.at), w.title == entry.title else {
                cancel.append(d.id)
                continue
            }
            kept[d.id] = entry
            keptKeys.insert(entry.key)
        }
        let add = desired.filter { $0.at > now && !keptKeys.contains($0.key) }
        var seen = Set<String>()
        return AlarmDiff(cancel: cancel, add: add.filter { seen.insert($0.key).inserted }, ledger: kept)
    }
}

extension AlarmLedgerEntry {
    public init(_ a: PlannedAlarm) { self.init(key: a.key, at: a.at, title: a.title) }
}
