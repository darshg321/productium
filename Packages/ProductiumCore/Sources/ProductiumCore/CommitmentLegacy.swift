import Foundation

// What the older readers (motion routine learning, calendar twins) still need of a commitment: when it happens on a
// day. Entries are the source of truth (`Timetable`); these come from `Timetable.commitments(from:)` and go when
// those readers move to entries (steps 7 and 9).

public struct Occurrence: Hashable, Sendable {
    public var commitment: Commitment
    public var start: Date
    public var end: Date
}

extension Commitment {
    public func occurrence(on day: Date, calendar cal: Calendar) -> Occurrence? {
        let dayStart = cal.startOfDay(for: day)
        guard weekdays.contains(cal.component(.weekday, from: dayStart)) else { return nil }
        if let from = validFrom, dayStart < cal.startOfDay(for: from) { return nil }
        if let until = validUntil, dayStart > until { return nil }
        guard let sd = cal.date(bySettingHour: start.hour, minute: start.minute, second: 0, of: dayStart),
              let ed = cal.date(bySettingHour: end.hour, minute: end.minute, second: 0, of: dayStart), ed > sd else { return nil }
        return Occurrence(commitment: self, start: sd, end: ed)
    }

    public static func occurrences(_ list: [Commitment], on day: Date, calendar cal: Calendar) -> [Occurrence] {
        list.compactMap { $0.occurrence(on: day, calendar: cal) }.sorted { $0.start < $1.start }
    }
}
