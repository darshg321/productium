import Foundation

/// What was planned for each finished day, kept so "planned vs done" can be told after the fact.
public enum PlanHistory {
    public static let keepDays = 60

    /// Days before today that the previous plan still holds get snapshotted: the study blocks as they stood.
    public static func record(previous: Plan, into history: inout [String: [PlannedBlock]], now: Date, calendar cal: Calendar) {
        let today = cal.startOfDay(for: now)
        let byDay = Dictionary(grouping: previous.blocks.filter(\.isStudy)) { cal.startOfDay(for: $0.start) }
        for (day, blocks) in byDay where day < today {
            history[CapacityLearner.dayKey(day, cal)] = blocks.sorted { $0.start < $1.start }
        }
        if history.count > keepDays {
            for key in history.keys.sorted().dropLast(keepDays) { history.removeValue(forKey: key) }
        }
    }

    /// Past days read the snapshot; today and later read the live plan; with neither, what the outcomes planned.
    public static func plannedMinutes(on day: Date, history: [String: [PlannedBlock]], plan: Plan, outcomes: [BlockOutcome],
                                      calendar cal: Calendar) -> Int {
        if let h = history[CapacityLearner.dayKey(day, cal)] { return h.reduce(0) { $0 + $1.minutes } }
        let live = plan.blocks(on: day, calendar: cal).filter(\.isStudy)
        if !live.isEmpty { return live.reduce(0) { $0 + $1.minutes } }
        return outcomes.filter { cal.isDate($0.plannedStart, inSameDayAs: day) }.reduce(0) { $0 + $1.plannedMinutes }
    }
}

/// The one answer to "how much work did I do that day": finished blocks and focus sessions, study check-ins,
/// and progress told to the box. Time that two sources both cover counts once.
public enum WorkDone {
    public static func minutes(on day: Date, outcomes: [BlockOutcome], progress: [ProgressEntry], markers: [TimelineEvent],
                               calendar cal: Calendar) -> Int {
        var spans: [(Date, Date)] = outcomes
            .filter { $0.status != .skipped && $0.actualMinutes > 0 && cal.isDate($0.plannedStart, inSameDayAs: day) }
            .map { ($0.plannedStart, $0.plannedStart.addingTimeInterval(Double($0.actualMinutes) * 60)) }
        let todays = markers.filter { cal.isDate($0.at, inSameDayAs: day) && $0.category == .study }.sorted { $0.at < $1.at }
        var open: Date?
        for m in todays {
            switch m.phase {
            case .start: open = open ?? m.at
            case .end:
                if let s = open, m.at > s { spans.append((s, min(m.at, s.addingTimeInterval(4 * 3600)))) }
                open = nil
            case .point: break
            }
        }
        var union = 0.0
        var cursor: Date?
        for (s, e) in spans.sorted(by: { $0.0 < $1.0 }) {
            let from = max(s, cursor ?? s)
            if e > from { union += e.timeIntervalSince(from) }
            cursor = max(cursor ?? e, e)
        }
        return Int((union / 60).rounded()) + progress.minutes(on: day, calendar: cal)
    }
}
