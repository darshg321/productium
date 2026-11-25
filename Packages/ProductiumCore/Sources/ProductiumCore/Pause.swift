import Foundation

/// v1.6 C1: a paused session. Pausing ends the running entry at that moment; Resume starts a new entry of the same
/// thing, with the countdown carrying on from the time that was left. Stop or Done clears it (nothing after the pause
/// is logged).
public struct PausedSession: Codable, Hashable, Sendable {
    public var taskId: UUID?
    public var title: String
    public var category: CategoryID
    public var topics: [String]
    public var pausedAt: Date
    /// Seconds left of the planned session when it was paused (nil: it wasn't a planned session).
    public var left: TimeInterval?

    public init(taskId: UUID?, title: String, category: CategoryID, topics: [String] = [], pausedAt: Date, left: TimeInterval? = nil) {
        self.taskId = taskId
        self.title = title
        self.category = category
        self.topics = topics
        self.pausedAt = pausedAt
        self.left = left
    }

    /// Pauses what's running: it ends now. The session's planned end (if any) gives the time left.
    public static func pause(entries: inout [Entry], plannedEnd: Date?, now: Date, calendar cal: Calendar) -> PausedSession? {
        guard let r = TimeLog.running(entries) else { return nil }
        TimeLog.stop(at: now, entries: &entries, calendar: cal)
        return PausedSession(taskId: r.taskId, title: r.title, category: r.category, topics: r.topics, pausedAt: now,
                             left: plannedEnd.map { max(0, $0.timeIntervalSince(now)) })
    }

    /// The op that resumes it, and when its countdown ends.
    public func resume(now: Date) -> (op: BoxOp, ends: Date?) {
        let op = taskId.map { BoxOp(.task, .start, ref: Ref.task($0)) }
            ?? BoxOp(.entry, .start, BoxFields(title: title, category: category, topics: topics.isEmpty ? nil : topics))
        return (op, left.map { now.addingTimeInterval($0) })
    }
}
