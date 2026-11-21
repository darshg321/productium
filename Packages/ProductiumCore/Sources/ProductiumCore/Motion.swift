import Foundation

public enum MotionKind: String, Codable, CaseIterable, Sendable {
    case walking, running, cycling, automotive, stationary, unknown
}

public struct MotionSample: Hashable, Sendable {
    public var at: Date
    public var kind: MotionKind
    public var confidence: Int
    public init(at: Date, kind: MotionKind, confidence: Int) { self.at = at; self.kind = kind; self.confidence = confidence }
}

public struct MotionSpan: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var start: Date
    public var end: Date
    public var kind: MotionKind
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
    public static let minMinutes = 5
    public static let bridge: TimeInterval = 3 * 60

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
        return out.map { span in
            var s = span
            if let p = previous.first(where: { $0.kind == span.kind && abs($0.start.timeIntervalSince(span.start)) < 60 }) { s.id = p.id }
            return s
        }
    }

    public static func merge(_ old: [MotionSpan], with new: [MotionSpan], from windowStart: Date) -> [MotionSpan] {
        (old.filter { $0.end <= windowStart } + new).sorted { $0.start < $1.start }
    }

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

    public static func overnightStill(_ spans: [MotionSpan], morningOf day: Date, calendar cal: Calendar) -> MotionSpan? {
        let dayStart = cal.startOfDay(for: day)
        let from = dayStart.addingTimeInterval(-6 * 3600), to = dayStart.addingTimeInterval(12 * 3600)
        return spans.filter { $0.kind == .stationary && $0.end > from && $0.start < to && $0.minutes >= 180 }
            .max { $0.minutes < $1.minutes }
    }

    public static func summary(_ spans: [MotionSpan], on day: Date, calendar cal: Calendar) -> String? {
        let f = DateFormatter.local("HH:mm", cal)
        let parts = spans.filter { cal.isDate($0.start, inSameDayAs: day) }.compactMap { s -> String? in
            guard let (_, label) = segment(s) else { return nil }
            return "\(label.lowercased()) \(s.minutes) min \(f.string(from: s.start))"
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}
