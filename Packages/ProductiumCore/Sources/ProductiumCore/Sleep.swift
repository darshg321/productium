import Foundation

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
    public var day: Date
    public var bedtime: Date
    public var wake: Date
    public var source: SleepSource
    /// Time awake in the night (steps or phone use between bed and wake), taken off the total.
    public var awakeMinutes: Int = 0
    public var minutes: Int { max(0, Int(wake.timeIntervalSince(bedtime) / 60) - awakeMinutes) }
}

public enum SleepEstimator {
    static let bedWords: Set<String> = ["sleep", "inbed", "bed", "goingtobed", "bedtime", "asleep", "nightnap"]
    static let wakeWords: Set<String> = ["wake", "woke", "wokeup", "wakeup", "up", "awake", "gotup"]

    /// "in_bed" start → sleep start, "woke" → sleep end; nil when it isn't about sleep.
    public static func normalised(activity: String, phase: MarkerPhase) -> (String, MarkerPhase)? {
        let k = activity.plainKey
        if wakeWords.contains(k) || (bedWords.contains(k) && phase == .end) { return ("sleep", .end) }
        if (bedWords.contains(k) || k.contains("bed")) && phase != .end { return ("sleep", .start) }
        return nil
    }

    public static func isBedtime(_ m: CheckIn) -> Bool { normalised(activity: m.activity, phase: m.phase)?.1 == .start }
    public static func isWake(_ m: CheckIn) -> Bool { normalised(activity: m.activity, phase: m.phase)?.1 == .end }


    public static func night(morningOf day: Date, health: HealthDay?, markers: [CheckIn], motion: [MotionSpan] = [],
                             phoneUse: [Date] = [], plannedWake: Date?, sleepNeedMinutes: Int,
                             calendar cal: Calendar, firstPickup: Date? = nil, charging: Date? = nil,
                             awakeBursts: [Date] = [], awake: [Date] = []) -> SleepNight? {
        var n = nightBase(morningOf: day, health: health, markers: markers, motion: motion, phoneUse: phoneUse, plannedWake: plannedWake,
                          sleepNeedMinutes: sleepNeedMinutes, calendar: cal, firstPickup: firstPickup, charging: charging, awake: awake)
        // Steps or phone use in the middle of the night mean you were up: the gaps come off, one 10 minute block per burst.
        if var night = n, night.source == .motion || night.source == .plan || night.source == .checkIns {
            var blocks = 0
            var last: Date?
            for t in (awakeBursts.isEmpty ? phoneUse : awakeBursts).sorted() where t > night.bedtime.addingTimeInterval(20 * 60) && t < night.wake.addingTimeInterval(-20 * 60) {
                if let l = last, t.timeIntervalSince(l) < 15 * 60 { continue }
                blocks += 1
                last = t
            }
            night.awakeMinutes = min(blocks * 10, 120)
            n = night
        }
        return n
    }

    static func nightBase(morningOf day: Date, health: HealthDay?, markers: [CheckIn], motion: [MotionSpan],
                          phoneUse: [Date], plannedWake: Date?, sleepNeedMinutes: Int, calendar cal: Calendar,
                          firstPickup: Date?, charging: Date?, awake: [Date] = []) -> SleepNight? {
        let dayStart = cal.startOfDay(for: day)
        if let h = health, let wake = h.wake, let mins = h.sleepMinutes, h.sleepSource == nil || h.sleepSource == .health {
            return SleepNight(day: dayStart, bedtime: h.bedtime ?? wake.addingTimeInterval(-Double(mins) * 60), wake: wake, source: .health)
        }
        let from = dayStart.addingTimeInterval(-6 * 3600), to = dayStart.addingTimeInterval(14 * 3600)
        let window = markers.filter { $0.at >= from && $0.at < to }.sorted { $0.at < $1.at }
        let wakes = window.filter(isWake)
        let beds = window.filter(isBedtime)
        if let wake = wakes.first(where: { w in beds.contains { $0.at < w.at } }),
           let bed = beds.last(where: { $0.at < wake.at }), wake.at.timeIntervalSince(bed.at) <= 16 * 3600 {
            return SleepNight(day: dayStart, bedtime: bed.at, wake: wake.at, source: .checkIns)
        }
        let still = MotionTimeline.overnightStill(motion, morningOf: dayStart, calendar: cal)
        if let w = wakes.first, w.at > dayStart {
            let bed = still.map { min($0.start, w.at) } ?? w.at.addingTimeInterval(-Double(sleepNeedMinutes) * 60)
            return SleepNight(day: dayStart, bedtime: bed, wake: w.at, source: still == nil ? .plan : .checkIns)
        }
        if let s = still {
            // v1.6 A5: lying still while tracking work isn't asleep: the night starts after the last thing you tracked
            // in its first half, and after any phone use up to 30 min past it.
            let mid = s.start.addingTimeInterval(s.end.timeIntervalSince(s.start) / 2)
            let upUntil = awake.filter { $0 > s.start && $0 < mid }.max() ?? s.start
            let lastUse = phoneUse.filter { $0 <= upUntil.addingTimeInterval(30 * 60) && $0 > s.start.addingTimeInterval(-3 * 3600) }.max()
                .map { max($0, upUntil) } ?? (upUntil > s.start ? upUntil : nil)
            let firstUse = phoneUse.filter { $0 >= s.end.addingTimeInterval(-30 * 60) && $0 < s.end.addingTimeInterval(3 * 3600) }.min()
            // The phone going on the charger is another sign the night began (v1.1 H4).
            let plug = charging.flatMap { $0 > s.start.addingTimeInterval(-3 * 3600) && $0 < s.start.addingTimeInterval(3600) ? $0 : nil }
            let bed = max(s.start, lastUse ?? plug ?? s.start)
            // The first pickup of the day is never before you woke, so it can only pull the wake time earlier.
            let pickup = firstPickup.flatMap { $0 > bed ? $0 : nil }
            let wake = min(s.end, firstUse ?? s.end, pickup ?? s.end)
            if wake > bed { return SleepNight(day: dayStart, bedtime: bed, wake: wake, source: .motion) }
        }
        if let p = firstPickup, p > dayStart.addingTimeInterval(3 * 3600), p < dayStart.addingTimeInterval(12 * 3600) {
            let bed = charging.flatMap { $0 < p.addingTimeInterval(-4 * 3600) && $0 > p.addingTimeInterval(-14 * 3600) ? $0 : nil }
                ?? p.addingTimeInterval(-Double(sleepNeedMinutes) * 60)
            return SleepNight(day: dayStart, bedtime: bed, wake: p, source: .motion)
        }
        guard let w = plannedWake else { return nil }
        return SleepNight(day: dayStart, bedtime: w.addingTimeInterval(-Double(sleepNeedMinutes) * 60), wake: w, source: .plan)
    }

    public static func fill(_ health: [HealthDay], days: [Date], markers: [CheckIn], motion: [MotionSpan],
                            phoneUse: [Date], sleepNeedMinutes: Int, calendar cal: Calendar,
                            firstPickups: [Date: Date] = [:], charging: [Date: Date] = [:], awake: [Date] = []) -> [HealthDay] {
        var byDay = Dictionary(health.map { (cal.startOfDay(for: $0.day), $0) }, uniquingKeysWith: { $1 })
        for d in days.map({ cal.startOfDay(for: $0) }) {
            var h = byDay[d] ?? HealthDay(day: d)
            if h.sleepMinutes != nil && (h.sleepSource == nil || h.sleepSource == .health) { continue }
            guard let n = night(morningOf: d, health: nil, markers: markers, motion: motion, phoneUse: phoneUse,
                                plannedWake: nil, sleepNeedMinutes: sleepNeedMinutes, calendar: cal,
                                firstPickup: firstPickups[d], charging: charging[d], awake: awake), n.source != .plan else {
                if h.sleepSource != nil && h.sleepSource != .health {
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
