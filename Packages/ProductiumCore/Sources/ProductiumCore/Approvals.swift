import Foundation

/// v1.2 0.3 / J: a change waiting for one Approve / Decline. The box holds risky ops (`BoxApplier.risk`); the insight
/// pass can only propose alarms (J4), never add them. Kept in `AppState.approvals` so a decision survives a relaunch,
/// and shown under the box turn, in the Weekly Note and in Settings → Alarms.
public struct Approval: Codable, Hashable, Identifiable, Sendable {
    public enum Source: String, Codable, Sendable { case box, insight }
    public var id: UUID
    public var ops: [BoxOp]
    public var why: String
    public var source: Source
    public var at: Date
    /// The box turn that made it (Undo / the receipt row).
    public var turnId: UUID?
    /// Proposals lapse: a week for the insight pass, a day for the box.
    public var expires: Date

    public init(id: UUID = UUID(), ops: [BoxOp], why: String, source: Source, at: Date, turnId: UUID? = nil, expires: Date? = nil) {
        self.id = id
        self.ops = ops
        self.why = why
        self.source = source
        self.at = at
        self.turnId = turnId
        self.expires = expires ?? at.addingTimeInterval(source == .insight ? 7 * 86400 : 86400)
    }

    /// Whether approving it adds a full-screen alarm (Allow then also turns Full-Screen Alarms on).
    public var addsAlarm: Bool { ops.contains { $0.fields.alert?.lowercased().hasPrefix("alarm") == true } }
}

public enum Approvals {
    /// Held box ops become one approval each (each has its own reason).
    public static func from(_ held: [HeldOp], turnId: UUID?, at: Date) -> [Approval] {
        held.map { Approval(ops: [$0.op], why: $0.why, source: .box, at: at, turnId: turnId) }
    }

    public static func live(_ list: [Approval], now: Date) -> [Approval] { list.filter { $0.expires > now } }
}
