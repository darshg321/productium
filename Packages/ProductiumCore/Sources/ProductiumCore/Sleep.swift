import Foundation

// MARK: - Sleep without a sleep tracker
//
// Nothing on many phones records sleep (Health has steps but no sleep samples). The night is
// estimated from the best source there is, in order:
//   1. HealthKit sleep samples.
//   2. Check-ins: in bed / going to bed / sleep start → woke up / sleep end.
//   3. Overnight stillness (Core Motion) bounded by the last and first phone use.
//   4. The plan (assumed).

public enum SleepSource: String, Codable, Sendable {
    case health, checkIns, motion, plan

    public var label: String {
        switch self {
        case .health: return "from Health"
        case .checkIns: return "from your check-ins"
        case .motion: return "from phone stillness"
        case .plan: return "assumed from the plan"
        }
    }
}

public struct SleepNight: Hashable, Sendable {
    /// The morning the night ended on.
    public var day: Date
    public var bedtime: Date
    public var wake: Date
    public var source: SleepSource
    public var minutes: Int { max(0, Int(wake.timeIntervalSince(bedtime) / 60)) }
}

public enum SleepEstimator {
    /// Marker activity names that mean "went to bed" (start) or "got up" (end), however they were logged.
    static let bedWords: Set<String> = ["sleep", "in_bed", "inbed", "bed", "going_to_bed", "goingtobed", "bedtime", "asleep", "nap_night"]
    static let wakeWords: Set<String> = ["wake", "woke", "woke_up", "wakeup", "up", "awake", "got_up"]

    static func key(_ a: String) -> String { a.lowercased().replacingOccurrences(of: " ", with: "_") }

    /// True for a check-in that starts the night.
    public static func isBedtime(_ m: TimelineEvent) -> Bool {
        let k = key(m.activity)
        return (bedWords.contains(k) && m.phase != .end) || (k.contains("bed") && m.phase != .end)
    }

    /// True for a check-in that ends the night.
    public static func isWake(_ m: TimelineEvent) -> Bool {
        let k = key(m.activity)
        return wakeWords.contains(k) || (bedWords.contains(k) && m.phase == .end)
    }

    /// The canonical marker for a sleep-ish activity the AI logged ("in_bed" start → sleep start),
    /// or nil when it isn't one.
    public static func normalised(activity: String, phase: MarkerPhase) -> (String, MarkerPhase)? {
        let probe = TimelineEvent(at: Date(), phrase: "", activity: activity, category: .sleep, phase: phase)
        if isWake(probe) { return ("sleep", .end) }
        if isBedtime(probe) { return ("sleep", .start) }
        return nil
    }

    /// The night that ended on the morning of `day`.
    /// - scrollEnds/scrollStarts: phone use (ends of sessions bound bedtime, starts bound wake).
    public static func night(morningOf day: Date, health: HealthDay?, markers: [TimelineEvent], motion: [MotionSpan] = [],
                             phoneUse: [Date] = [], plannedWake: Date?, sleepNeedMinutes: Int,
                             calendar cal: Calendar) -> SleepNight? {
        let dayStart = cal.startOfDay(for: day)
        if let h = health, let wake = h.wake, let mins = h.sleepMinutes, h.sleepSource == nil || h.sleepSource == .health {
            return SleepNight(day: dayStart, bedtime: h.bedtime ?? wake.addingTimeInterval(-Double(mins) * 60), wake: wake, source: .health)
        }
        // Check-ins: the latest "in bed" from the evening before, then the first wake after it.
        let from = dayStart.addingTimeInterval(-6 * 3600), to = dayStart.addingTimeInterval(14 * 3600)
        let window = markers.filter { $0.at >= from && $0.at < to }.sorted { $0.at < $1.at }
        let wakes = window.filter(isWake)
        let beds = window.filter(isBedtime)
        if let wake = wakes.first(where: { w in beds.contains { $0.at < w.at } }),
           let bed = beds.last(where: { $0.at < wake.at }), wake.at.timeIntervalSince(bed.at) <= 16 * 3600 {
            return SleepNight(day: dayStart, bedtime: bed.at, wake: wake.at, source: .checkIns)
        }
        // A wake check-in alone: bedtime from stillness or the sleep need.
        let still = MotionTimeline.overnightStill(motion, morningOf: dayStart, calendar: cal)
        if let w = wakes.first, w.at > dayStart {
            let bed = still.map { min($0.start, w.at) } ?? w.at.addingTimeInterval(-Double(sleepNeedMinutes) * 60)
            return SleepNight(day: dayStart, bedtime: bed, wake: w.at, source: still == nil ? .plan : .checkIns)
        }
        // Stillness, trimmed to the last phone use before it and the first after it.
        if let s = still {
            let lastUse = phoneUse.filter { $0 <= s.start.addingTimeInterval(30 * 60) && $0 > s.start.addingTimeInterval(-3 * 3600) }.max()
            let firstUse = phoneUse.filter { $0 >= s.end.addingTimeInterval(-30 * 60) && $0 < s.end.addingTimeInterval(3 * 3600) }.min()
            let bed = max(s.start, lastUse ?? s.start)
            let wake = min(s.end, firstUse ?? s.end)
            if wake > bed { return SleepNight(day: dayStart, bedtime: bed, wake: wake, source: .motion) }
        }
        guard let w = plannedWake else { return nil }
        return SleepNight(day: dayStart, bedtime: w.addingTimeInterval(-Double(sleepNeedMinutes) * 60), wake: w, source: .plan)
    }

    /// Health days with the estimated night filled in where Health had no sleep. Measured nights
    /// are never replaced; an assumed (plan) night isn't stored, so it can't look measured.
    public static func fill(_ health: [HealthDay], days: [Date], markers: [TimelineEvent], motion: [MotionSpan],
                            phoneUse: [Date], sleepNeedMinutes: Int, calendar cal: Calendar) -> [HealthDay] {
        var byDay = Dictionary(health.map { (cal.startOfDay(for: $0.day), $0) }, uniquingKeysWith: { $1 })
        for d in days.map({ cal.startOfDay(for: $0) }) {
            var h = byDay[d] ?? HealthDay(day: d)
            if h.sleepMinutes != nil && (h.sleepSource == nil || h.sleepSource == .health) { continue }
            guard let n = night(morningOf: d, health: nil, markers: markers, motion: motion, phoneUse: phoneUse,
                                plannedWake: nil, sleepNeedMinutes: sleepNeedMinutes, calendar: cal), n.source != .plan else {
                if h.sleepSource != nil && h.sleepSource != .health {
                    // An estimate whose evidence is gone (an undone check-in): drop it.
                    h.sleepMinutes = nil; h.bedtime = nil; h.wake = nil; h.sleepSource = nil
                    byDay[d] = h
                }
                continue
            }
            h.sleepMinutes = n.minutes
            h.bedtime = n.bedtime
            h.wake = n.wake
            h.sleepSource = n.source
            byDay[d] = h
        }
        return byDay.values.sorted { $0.day < $1.day }
    }
}
