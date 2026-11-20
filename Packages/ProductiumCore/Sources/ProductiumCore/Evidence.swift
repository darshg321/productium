import Foundation

public struct ProgressEntry: Codable, Hashable, Identifiable, Sendable {
    public enum Source: String, Codable, Sendable { case task, evidence }

    public var id: UUID
    public var at: Date
    public var itemId: UUID?
    public var minutes: Int
    public var from: Int?
    public var to: Int?
    public var source: Source
    public var estimated: Bool
    public var note: String?
    public var turnId: UUID?

    public init(id: UUID = UUID(), at: Date, itemId: UUID? = nil, minutes: Int, from: Int? = nil, to: Int? = nil,
                source: Source, estimated: Bool = false, note: String? = nil, turnId: UUID? = nil) {
        self.id = id
        self.at = at
        self.itemId = itemId
        self.minutes = minutes
        self.from = from
        self.to = to
        self.source = source
        self.estimated = estimated
        self.note = note
        self.turnId = turnId
    }
}

extension Array where Element == ProgressEntry {
    public func minutes(on day: Date, calendar: Calendar) -> Int {
        Swift.max(0, filter { calendar.isDate($0.at, inSameDayAs: day) }.reduce(0) { $0 + $1.minutes })
    }
}
