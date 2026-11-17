import Foundation

public struct DayException: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var day: Date
    public var commitmentId: UUID?
    public var kind: CommitmentKind?
    public var cancelled: Bool
    public var start: TimeOfDay?
    public var end: TimeOfDay?
    public var wake: TimeOfDay?
    public var note: String?

    public init(id: UUID = UUID(), day: Date, commitmentId: UUID? = nil, kind: CommitmentKind? = nil,
                cancelled: Bool = false, start: TimeOfDay? = nil, end: TimeOfDay? = nil, wake: TimeOfDay? = nil,
                note: String? = nil) {
        self.id = id
        self.day = day
        self.commitmentId = commitmentId
        self.kind = kind
        self.cancelled = cancelled
        self.start = start
        self.end = end
        self.wake = wake
        self.note = note
    }

    func applies(to c: Commitment) -> Bool {
        if let id = commitmentId { return id == c.id }
        if let k = kind { return k == c.kind }
        return false
    }
}

public struct Occurrence: Hashable, Sendable {
    public var commitment: Commitment
    public var start: Date
    public var end: Date
}

extension Commitment {
    public func occurrence(on day: Date, exceptions: [DayException], calendar cal: Calendar) -> Occurrence? {
        let dayStart = cal.startOfDay(for: day)
        guard weekdays.contains(cal.component(.weekday, from: dayStart)) else { return nil }
        if let from = validFrom, dayStart < cal.startOfDay(for: from) { return nil }
        if let until = validUntil, dayStart > until { return nil }
        let todays = exceptions.filter { cal.isDate($0.day, inSameDayAs: dayStart) && $0.applies(to: self) }
        let ex = todays.first { $0.commitmentId != nil } ?? todays.first
        if ex?.cancelled == true { return nil }
        let s = ex?.start ?? start, e = ex?.end ?? end
        guard let sd = cal.date(bySettingHour: s.hour, minute: s.minute, second: 0, of: dayStart),
              let ed = cal.date(bySettingHour: e.hour, minute: e.minute, second: 0, of: dayStart), ed > sd else { return nil }
        return Occurrence(commitment: self, start: sd, end: ed)
    }

    public static func occurrences(_ list: [Commitment], on day: Date, exceptions: [DayException],
                                   calendar cal: Calendar) -> [Occurrence] {
        list.compactMap { $0.occurrence(on: day, exceptions: exceptions, calendar: cal) }.sorted { $0.start < $1.start }
    }
}

public enum SchoolDay {
    public static func isSchoolDay(_ day: Date, prefs: Preferences, commitments: [Commitment],
                                   exceptions: [DayException], calendar cal: Calendar) -> Bool {
        let school = commitments.filter { $0.kind == .school }
        if school.isEmpty { return prefs.schoolDays.contains(cal.component(.weekday, from: day)) }
        return !Commitment.occurrences(school, on: day, exceptions: exceptions, calendar: cal).isEmpty
    }
}

extension Array where Element == DayException {
    public func wakeOverride(on day: Date, calendar cal: Calendar) -> TimeOfDay? {
        last { cal.isDate($0.day, inSameDayAs: day) && $0.wake != nil }?.wake
    }
}
