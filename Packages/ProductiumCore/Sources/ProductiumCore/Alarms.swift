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

    /// The whole wanted list: alarms Entries asked for (the wake alarm is the planned Sleep's `alert`, O4), plus
    /// bedtime / leave / missed-start (Alarms for the Important Ones). An off toggle means none of its alarms, so
    /// they get cancelled. Entries' alarms ring only once approved (Part J): `EntryAlerts.alarms` drops the rest.
    public static func desired(_ input: NudgeInput, entryAlarms: [PlannedAlarm] = [],
                               timeLabel: ((Date) -> String)? = nil) -> [PlannedAlarm] {
        var out: [PlannedAlarm] = []
        var taken = Set<Int>()
        // Entry alarms first: a wake alarm at the minute of a leave alarm is the same alarm.
        for a in entryAlarms.sorted(by: { ($0.at, $0.key) < ($1.at, $1.key) }) where a.at > input.now && taken.insert(minute(a.at)).inserted {
            out.append(a)
        }
        for a in NudgePlanner.alarms(input) where taken.insert(minute(a.at)).inserted { out.append(a) }
        return out.sorted { ($0.at, $0.key) < ($1.at, $1.key) }
    }

    /// The next `wakeCount` days of entry alarms (wake alarms and the ones you set), as the device should have them.
    public static func entryAlarms(_ entries: [Entry], now: Date, allowed: Bool, wake: Bool, book: DayRuleBook = DayRuleBook(),
                                   calendar cal: Calendar) -> [PlannedAlarm] {
        let soon = DateInterval(start: now, duration: Double(wakeCount) * 86400)
        let wanted = entries.filter { wake || !($0.source == .plan && $0.category == CategoryTree.sleep) }
        return EntryAlerts.alarms(Days.expand(wanted, in: soon, now: now, book: book, calendar: cal), now: now, allowed: allowed)
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
