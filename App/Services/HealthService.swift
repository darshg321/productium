import Foundation
import HealthKit
import ProductiumCore

/// Reads sleep, steps, daylight and resting heart rate. Data stays on device.
/// Only daily totals are ever summarised for the AI.
final class HealthService {
    static let shared = HealthService()
    let store = HKHealthStore()

    var available: Bool { HKHealthStore.isHealthDataAvailable() }

    private var readTypes: Set<HKObjectType> {
        [HKQuantityType(.stepCount), HKCategoryType(.sleepAnalysis), HKQuantityType(.timeInDaylight),
         HKQuantityType(.restingHeartRate)]
    }

    func requestAuthorization() async throws {
        guard available else { return }
        try await store.requestAuthorization(toShare: [HKCategoryType(.mindfulSession)], read: readTypes)
    }

    /// One `HealthDay` per calendar day; `sleep*` describe the night that ended that morning.
    func days(back n: Int, calendar cal: Calendar = .current) async -> [HealthDay] {
        guard available else { return [] }
        let today = cal.startOfDay(for: Date())
        guard let start = cal.date(byAdding: .day, value: -(n - 1), to: today),
              let end = cal.date(byAdding: .day, value: 1, to: today) else { return [] }
        async let steps = dailySum(.stepCount, unit: .count(), from: start, to: end, cal: cal)
        async let daylight = dailySum(.timeInDaylight, unit: .minute(), from: start, to: end, cal: cal)
        async let rhr = dailyAverage(.restingHeartRate, unit: HKUnit.count().unitDivided(by: .minute()), from: start, to: end, cal: cal)
        async let nights = sleepNights(from: start, to: end, cal: cal)
        let (s, d, r, sl) = await (steps, daylight, rhr, nights)
        var out: [HealthDay] = []
        var day = start
        while day < end {
            let night = sl[day]
            out.append(HealthDay(day: day, steps: s[day].map { Int($0) }, sleepMinutes: night?.minutes,
                                 bedtime: night?.bed, wake: night?.wake, daylightMinutes: d[day].map { Int($0) },
                                 restingHeartRate: r[day]))
            day = cal.date(byAdding: .day, value: 1, to: day)!
        }
        return out
    }

    private func dailySum(_ id: HKQuantityTypeIdentifier, unit: HKUnit, from: Date, to: Date, cal: Calendar) async -> [Date: Double] {
        await statistics(id, options: .cumulativeSum, from: from, to: to, cal: cal) { $0.sumQuantity()?.doubleValue(for: unit) }
    }

    private func dailyAverage(_ id: HKQuantityTypeIdentifier, unit: HKUnit, from: Date, to: Date, cal: Calendar) async -> [Date: Double] {
        await statistics(id, options: .discreteAverage, from: from, to: to, cal: cal) { $0.averageQuantity()?.doubleValue(for: unit) }
    }

    private func statistics(_ id: HKQuantityTypeIdentifier, options: HKStatisticsOptions, from: Date, to: Date, cal: Calendar,
                            value: @escaping (HKStatistics) -> Double?) async -> [Date: Double] {
        let type = HKQuantityType(id)
        let pred = HKSamplePredicate.quantitySample(type: type, predicate: HKQuery.predicateForSamples(withStart: from, end: to))
        let q = HKStatisticsCollectionQueryDescriptor(predicate: pred, options: options, anchorDate: from,
                                                      intervalComponents: DateComponents(day: 1))
        guard let coll = try? await q.result(for: store) else { return [:] }
        var out: [Date: Double] = [:]
        coll.enumerateStatistics(from: from, to: to) { stats, _ in
            if let v = value(stats) { out[cal.startOfDay(for: stats.startDate)] = v }
        }
        return out
    }

    struct Night { var minutes: Int; var bed: Date; var wake: Date }

    /// Night ending on day D = asleep samples between D-1 18:00 and D 15:00. Overlapping
    /// samples from several sources (Watch + iPhone) are merged so nothing counts twice.
    private func sleepNights(from: Date, to: Date, cal: Calendar) async -> [Date: Night] {
        let type = HKCategoryType(.sleepAnalysis)
        let windowStart = from.addingTimeInterval(-6 * 3600)
        let q = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: type, predicate: HKQuery.predicateForSamples(withStart: windowStart, end: to))],
            sortDescriptors: [SortDescriptor(\.startDate)])
        guard let samples = try? await q.result(for: store) else { return [:] }
        let asleep = samples.filter { s in
            guard let v = HKCategoryValueSleepAnalysis(rawValue: s.value) else { return false }
            return HKCategoryValueSleepAnalysis.allAsleepValues.contains(v)
        }
        var out: [Date: Night] = [:]
        var day = from
        while day < to {
            let ws = day.addingTimeInterval(-6 * 3600), we = day.addingTimeInterval(15 * 3600)
            let intervals = asleep.filter { $0.endDate > ws && $0.startDate < we }
                .map { (max($0.startDate, ws), min($0.endDate, we)) }.sorted { $0.0 < $1.0 }
            var merged: [(Date, Date)] = []
            for iv in intervals {
                if let last = merged.last, iv.0 <= last.1 { merged[merged.count - 1].1 = max(last.1, iv.1) } else { merged.append(iv) }
            }
            if let first = merged.first, let last = merged.last {
                let mins = merged.reduce(0.0) { $0 + $1.1.timeIntervalSince($1.0) } / 60
                if mins >= 60 { out[day] = Night(minutes: Int(mins), bed: first.0, wake: last.1) }
            }
            day = cal.date(byAdding: .day, value: 1, to: day)!
        }
        return out
    }

    /// Wakes the app when new sleep data arrives (i.e. on waking) so the day is replanned early.
    func observeSleep(_ handler: @escaping () -> Void) {
        guard available else { return }
        let type = HKCategoryType(.sleepAnalysis)
        let q = HKObserverQuery(sampleType: type, predicate: nil) { _, completion, _ in
            handler()
            completion()
        }
        store.execute(q)
        store.enableBackgroundDelivery(for: type, frequency: .immediate) { _, _ in }
    }

    func logMindful(start: Date, end: Date) {
        guard available else { return }
        let s = HKCategorySample(type: HKCategoryType(.mindfulSession), value: HKCategoryValue.notApplicable.rawValue, start: start, end: end)
        store.save(s) { _, _ in }
    }

    /// Sleep midpoints (hours after midnight) on nights before free days, for chronotype (MCTQ).
    static func freeDayMidpoints(_ days: [HealthDay], prefs: Preferences, cal: Calendar) -> [Double] {
        days.compactMap { d in
            guard let bed = d.bedtime, let wake = d.wake, !prefs.schoolDays.contains(cal.component(.weekday, from: d.day)) else { return nil }
            let mid = bed.addingTimeInterval(wake.timeIntervalSince(bed) / 2)
            let comps = cal.dateComponents([.hour, .minute], from: mid)
            var h = Double(comps.hour ?? 0) + Double(comps.minute ?? 0) / 60
            if h > 18 { h -= 24 }
            return h
        }
    }
}
