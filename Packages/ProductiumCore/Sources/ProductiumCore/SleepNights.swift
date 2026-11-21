import Foundation

// v1.2 A5: building a night from Health's raw sleep samples, in core so it's tested. Before this the App unioned
// every source's "asleep" samples and dropped `inBed`, so an iPhone without a Watch (which only writes `inBed`) had
// no sleep at all, and a stray sample from a second app stretched bed and wake.

/// One HealthKit sleep sample, reduced to what the night needs.
public struct SleepSample: Hashable, Sendable {
    public enum Stage: String, Sendable { case inBed, asleep, awake }
    public var start: Date
    public var end: Date
    public var stage: Stage
    /// Where it came from (the source's bundle id or name). Nights use one source, never a mix.
    public var source: String

    public init(start: Date, end: Date, stage: Stage, source: String) {
        self.start = start
        self.end = end
        self.stage = stage
        self.source = source
    }
}

public struct BuiltNight: Hashable, Sendable {
    public var day: Date
    public var bed: Date
    public var wake: Date
    /// Asleep minutes (with stages), or minutes in bed (without).
    public var minutes: Int
    public var source: String
    /// False: only `inBed` was written (an iPhone without a Watch): "in bed (no stages)".
    public var stagesKnown: Bool
    /// Sleep outside the night (an afternoon nap), each ≥20 minutes.
    public var naps: [DateInterval]
}

public enum SleepNights {
    /// Samples further apart than this are separate sleeps.
    static let joinGap: TimeInterval = 60 * 60
    static let minNap: TimeInterval = 20 * 60

    /// The night ending on the morning of `day`: from 18:00 the evening before to 15:00. With stages, the source with
    /// the most asleep minutes wins; otherwise the source with the most time in bed. Naps come back separately.
    public static func build(_ samples: [SleepSample], day: Date, calendar cal: Calendar) -> BuiltNight? {
        let d = cal.startOfDay(for: day)
        guard let from = cal.date(byAdding: .hour, value: -6, to: d), let to = cal.date(byAdding: .hour, value: 15, to: d) else { return nil }
        let inWindow = samples.filter { $0.end > from && $0.start < to && $0.end > $0.start }
            .map { s -> SleepSample in var c = s; c.start = max(s.start, from); c.end = min(s.end, to); return c }
        func minutes(_ xs: [SleepSample]) -> Double { merge(xs.map { ($0.start, $0.end) }).reduce(0) { $0 + $1.1.timeIntervalSince($1.0) } / 60 }
        let bySource = Dictionary(grouping: inWindow, by: \.source)
        let staged = bySource.mapValues { $0.filter { $0.stage == .asleep } }.filter { !$0.value.isEmpty }
        let chosen: (source: String, samples: [SleepSample], stages: Bool)
        if let best = staged.max(by: { (minutes($0.value), $1.key) < (minutes($1.value), $0.key) }) {
            chosen = (best.key, best.value, true)
        } else {
            let beds = bySource.mapValues { $0.filter { $0.stage == .inBed } }.filter { !$0.value.isEmpty }
            guard let best = beds.max(by: { (minutes($0.value), $1.key) < (minutes($1.value), $0.key) }) else { return nil }
            chosen = (best.key, best.value, false)
        }
        // Clusters of sleep: the longest is the night, the rest are naps (or noise under 20 minutes).
        let clusters = merge(chosen.samples.map { ($0.start, $0.end) }, gap: joinGap)
        guard let night = clusters.max(by: { $0.1.timeIntervalSince($0.0) < $1.1.timeIntervalSince($1.0) }) else { return nil }
        let inNight = merge(chosen.samples.filter { $0.end > night.0 && $0.start < night.1 }.map { ($0.start, $0.end) })
        let mins = Int((inNight.reduce(0) { $0 + $1.1.timeIntervalSince($1.0) } / 60).rounded())
        guard mins >= 60 else { return nil }
        let naps = clusters.filter { $0 != night && $0.1.timeIntervalSince($0.0) >= minNap }.map { DateInterval(start: $0.0, end: $0.1) }
        return BuiltNight(day: d, bed: night.0, wake: night.1, minutes: mins, source: chosen.source, stagesKnown: chosen.stages, naps: naps)
    }

    static func merge(_ xs: [(Date, Date)], gap: TimeInterval = 0) -> [(Date, Date)] {
        var out: [(Date, Date)] = []
        for iv in xs.sorted(by: { $0.0 < $1.0 }) {
            if let last = out.last, iv.0 <= last.1.addingTimeInterval(gap) { out[out.count - 1].1 = max(last.1, iv.1) } else { out.append(iv) }
        }
        return out
    }
}

/// v1.2 A6: what the last Health reads did, so Settings → Sleep and the backup can say why sleep is missing.
public struct HealthReadLog: Codable, Hashable, Sendable {
    public var lastSuccess: Date?
    public var lastError: String?
    public var lastErrorAt: Date?
    /// Sleep samples the last read saw (0 = nothing to read: no Watch, no Sleep schedule, or still locked).
    public var lastSleepSamples: Int?
    /// The source the last night came from, e.g. "Apple Watch" or "iPhone (in bed, no stages)".
    public var lastSleepSource: String?
    public init() {}
}

extension HealthDay {
    /// Field by field: a fresh read never clears what an earlier read found (a locked phone or a late Watch sync
    /// reads as empty), it only fills in and updates.
    public func merged(with fresh: HealthDay) -> HealthDay {
        var o = self
        if let v = fresh.steps { o.steps = max(v, o.steps ?? 0) }
        if fresh.sleepMinutes != nil, fresh.wake != nil {
            o.sleepMinutes = fresh.sleepMinutes
            o.bedtime = fresh.bedtime
            o.wake = fresh.wake
            o.sleepSource = fresh.sleepSource ?? .health
            o.sleepDevice = fresh.sleepDevice ?? o.sleepDevice
            o.naps = fresh.naps ?? o.naps
        }
        if let v = fresh.daylightMinutes { o.daylightMinutes = v }
        if let v = fresh.restingHeartRate { o.restingHeartRate = v }
        if let v = fresh.exerciseMinutes { o.exerciseMinutes = v }
        if let v = fresh.workoutMinutes { o.workoutMinutes = v }
        if let v = fresh.hrv { o.hrv = v }
        return o
    }
}

extension Array where Element == HealthDay {
    /// Merges a fresh read into what's stored (A6).
    public func merging(fresh: [HealthDay], calendar cal: Calendar) -> [HealthDay] {
        var byDay = Dictionary(map { (cal.startOfDay(for: $0.day), $0) }, uniquingKeysWith: { $1 })
        for f in fresh {
            let d = cal.startOfDay(for: f.day)
            byDay[d] = byDay[d].map { $0.merged(with: f) } ?? f
        }
        return byDay.values.sorted { $0.day < $1.day }
    }
}
