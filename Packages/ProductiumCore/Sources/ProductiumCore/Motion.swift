import Foundation

// MARK: - Motion and transit
//
// Core Motion keeps 7 days of activity history (walking, running, cycling, automotive,
// stationary), so it works even when the app wasn't running. The phone's activity records are
// turned into spans here; spans become inferred timeline segments, sleep backup and routine
// samples. Spans are evidence, not truth: they paint below explicit check-ins and above routine
// assumptions, and the AI only ever sees summaries.

public enum MotionKind: String, Codable, CaseIterable, Sendable {
    case walking, running, cycling, automotive, stationary, unknown
}

/// One activity record as the phone reports it (a change of activity at `at`).
public struct MotionSample: Hashable, Sendable {
    public var at: Date
    public var kind: MotionKind
    /// 0 low, 1 medium, 2 high.
    public var confidence: Int
    public init(at: Date, kind: MotionKind, confidence: Int) { self.at = at; self.kind = kind; self.confidence = confidence }
}

public struct MotionSpan: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var start: Date
    public var end: Date
    public var kind: MotionKind
    /// 0 low, 1 medium, 2 high (the lowest of the records it's made from).
    public var confidence: Int

    public init(id: UUID = UUID(), start: Date, end: Date, kind: MotionKind, confidence: Int) {
        self.id = id
        self.start = start
        self.end = max(end, start)
        self.kind = kind
        self.confidence = confidence
    }

    public var minutes: Int { Int(end.timeIntervalSince(start) / 60) }
    public var isTravel: Bool { [.walking, .running, .cycling, .automotive].contains(kind) }
}

public enum MotionTimeline {
    /// The shortest movement worth a segment.
    public static let minMinutes = 5
    /// Gaps up to this between records of the same kind are bridged (a red light in a car).
    public static let bridge: TimeInterval = 3 * 60

    /// Records → spans: each record lasts until the next; runs of the same kind merge, low-
    /// confidence records and unknowns are dropped. Spans carry stable ids across rebuilds when
    /// `previous` has a span with the same start and kind.
    public static func spans(_ samples: [MotionSample], until end: Date, previous: [MotionSpan] = []) -> [MotionSpan] {
        let sorted = samples.sorted { $0.at < $1.at }
        var out: [MotionSpan] = []
        for (i, s) in sorted.enumerated() where s.kind != .unknown && s.confidence >= 1 {
            let until = i + 1 < sorted.count ? sorted[i + 1].at : end
            guard until > s.at else { continue }
            if var last = out.last, last.kind == s.kind, s.at.timeIntervalSince(last.end) <= bridge {
                last.end = until
                last.confidence = min(last.confidence, s.confidence)
                out[out.count - 1] = last
            } else {
                out.append(MotionSpan(start: s.at, end: until, kind: s.kind, confidence: s.confidence))
            }
        }
        // Keep ids stable so learned spans aren't learned twice.
        return out.map { span in
            var s = span
            if let p = previous.first(where: { $0.kind == span.kind && abs($0.start.timeIntervalSince(span.start)) < 60 }) { s.id = p.id }
            return s
        }
    }

    /// Replaces the spans in the window the new ones cover; everything older is kept.
    public static func merge(_ old: [MotionSpan], with new: [MotionSpan], from windowStart: Date) -> [MotionSpan] {
        (old.filter { $0.end <= windowStart } + new).sorted { $0.start < $1.start }
    }

    /// The segment a span paints, if it's long enough to matter.
    public static func segment(_ s: MotionSpan) -> (TimeCategory, String)? {
        guard s.minutes >= minMinutes else { return nil }
        switch s.kind {
        case .automotive: return (.commute, "In a vehicle")
        case .cycling: return (.commute, "Cycling")
        case .walking: return (.commute, "Walk")
        case .running: return (.activities, "Run")
        case .stationary, .unknown: return nil
        }
    }

    /// The longest still span across the night of `day` (evening before → noon), for sleep.
    public static func overnightStill(_ spans: [MotionSpan], morningOf day: Date, calendar cal: Calendar) -> MotionSpan? {
        let dayStart = cal.startOfDay(for: day)
        let from = dayStart.addingTimeInterval(-6 * 3600), to = dayStart.addingTimeInterval(12 * 3600)
        return spans.filter { $0.kind == .stationary && $0.end > from && $0.start < to && $0.minutes >= 180 }
            .max { $0.minutes < $1.minutes }
    }

    /// A walk (or ride) on a school morning that ends near the first class teaches `to_school`;
    /// one after the last class teaches `from_school`. Each span teaches once.
    public static func learnRoutines(_ spans: [MotionSpan], day: Date, commitments: [Commitment], exceptions: [DayException] = [],
                                     routines: [Routine], calendar cal: Calendar) -> [Routine] {
        var out = routines
        let occ = Commitment.occurrences(commitments, on: cal.startOfDay(for: day), exceptions: exceptions, calendar: cal)
            .filter { $0.commitment.kind == .school }
        guard let first = occ.map(\.start).min(), let last = occ.map(\.end).max() else { return out }
        let todays = spans.filter { $0.isTravel && $0.minutes >= minMinutes && cal.isDate($0.start, inSameDayAs: day) }
        func teach(_ id: String, _ span: MotionSpan?) {
            guard let span, let i = out.firstIndex(where: { $0.id == id }), !out[i].learnedFrom.contains(span.id) else { return }
            if out[i].observe(span.minutes) { out[i].learnedFrom.insert(span.id) }
        }
        // Arrives between 45 min before and 10 min after the first class.
        teach("to_school", todays.last { $0.end >= first.addingTimeInterval(-45 * 60) && $0.end <= first.addingTimeInterval(10 * 60) })
        // Leaves within 30 min of the last class ending.
        teach("from_school", todays.first { $0.start >= last.addingTimeInterval(-5 * 60) && $0.start <= last.addingTimeInterval(30 * 60) })
        return out
    }

    /// A one-line summary for the AI ("walked 14 min 08:02, in a vehicle 22 min 16:10").
    public static func summary(_ spans: [MotionSpan], on day: Date, calendar cal: Calendar) -> String? {
        let f = DateFormatter(); f.calendar = cal; f.timeZone = cal.timeZone; f.dateFormat = "HH:mm"
        let parts = spans.filter { cal.isDate($0.start, inSameDayAs: day) }.compactMap { s -> String? in
            guard let (_, label) = segment(s) else { return nil }
            return "\(label.lowercased()) \(s.minutes) min \(f.string(from: s.start))"
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}
