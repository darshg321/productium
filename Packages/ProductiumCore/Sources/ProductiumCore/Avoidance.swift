import Foundation

public enum DeferralKind: String, Codable, Sendable {
    case snoozed, cantToday, skipped, neverStarted, dueMoved
}

public struct DeferralEvent: Codable, Hashable, Sendable {
    public var at: Date
    public var kind: DeferralKind
    public var reason: String?
    public var blockId: UUID?

    public init(at: Date, kind: DeferralKind, reason: String? = nil, blockId: UUID? = nil) {
        self.at = at
        self.kind = kind
        self.reason = reason
        self.blockId = blockId
    }
}

extension WorkItem {
    public var deferrals: [DeferralEvent] { deferralLog ?? [] }
    public var deferralCount: Int { deferrals.count }
    public var lastDeferredAt: Date? { deferrals.map(\.at).max() }
    public var deferralReasons: [String] { deferrals.compactMap(\.reason) }

    /// "Put off 3×", shown on the task row and given to the box.
    public var putOffLabel: String? { deferralCount > 0 ? "Put off \(deferralCount)×" : nil }
}

public enum Avoidance {
    public static let keep = 30

    static func clean(_ reason: String?) -> String? {
        let t = reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? nil : String(t.prefix(120))
    }

    /// Records one deferral. A block counts once per kind: skipping or missing the same block twice is one put-off.
    @discardableResult
    public static func record(_ kind: DeferralKind, itemId: UUID?, in items: inout [WorkItem], at: Date,
                              reason: String? = nil, blockId: UUID? = nil) -> Bool {
        guard let itemId, let i = items.firstIndex(where: { $0.id == itemId }), items[i].isOpen else { return false }
        var log = items[i].deferrals
        if kind != .snoozed, let b = blockId, log.contains(where: { $0.blockId == b && $0.kind == kind }) { return false }
        log.append(DeferralEvent(at: at, kind: kind, reason: clean(reason), blockId: blockId))
        items[i].deferralLog = Array(log.suffix(keep))
        return true
    }

    /// A due date moved later counts as putting it off, with what the student said as the reason.
    public static func recordDueMoves(before: [WorkItem], after items: inout [WorkItem], at: Date, reason: String?) {
        let was = Dictionary(before.map { ($0.id, $0.due) }, uniquingKeysWith: { a, _ in a })
        for item in items where item.isOpen {
            if let old = was[item.id], item.due > old.addingTimeInterval(3600) {
                record(.dueMoved, itemId: item.id, in: &items, at: at, reason: reason)
            }
        }
    }

    /// Blocks that ended with no answer and no start, not yet counted.
    public static func recordMissed(_ blocks: [PlannedBlock], in items: inout [WorkItem], at: Date) {
        for b in blocks { record(.neverStarted, itemId: b.itemId, in: &items, at: at, blockId: b.id) }
    }
}
