import Foundation
import HealthKit
import ProductiumCore

final class HealthService {
    static let shared = HealthService()
    let store = HKHealthStore()

    var available: Bool { HKHealthStore.isHealthDataAvailable() }

    private var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = [HKQuantityType(.stepCount), HKCategoryType(.sleepAnalysis), HKQuantityType(.timeInDaylight),
                                        HKQuantityType(.restingHeartRate), HKQuantityType(.appleExerciseTime), HKObjectType.workoutType()]
        if #available(iOS 18.0, *) { types.insert(HKObjectType.stateOfMindType()) }
        return types
    }

    private var shareTypes: Set<HKSampleType> {
        var types: Set<HKSampleType> = [HKCategoryType(.mindfulSession)]
        if #available(iOS 18.0, *) { types.insert(HKObjectType.stateOfMindType()) }
        return types
    }

    func requestAuthorization() async throws {
        guard available else { return }
        try await store.requestAuthorization(toShare: shareTypes, read: readTypes)
    }

    /// True when iOS still has to ask. It says nothing about whether read access was granted.
    func requestNeeded() async -> Bool {
        guard available else { return false }
        let status = try? await store.statusForAuthorizationRequest(toShare: shareTypes, read: readTypes)
        return status == .shouldRequest
    }

    func days(back n: Int, calendar cal: Calendar = .current) async -> [HealthDay] {
        guard available else { return [] }
        let today = cal.startOfDay(for: Date())
        guard let start = cal.date(byAdding: .day, value: -(n - 1), to: today),
              let end = cal.date(byAdding: .day, value: 1, to: today) else { return [] }
        async let steps = dailySum(.stepCount, unit: .count(), from: start, to: end, cal: cal)
        async let daylight = dailySum(.timeInDaylight, unit: .minute(), from: start, to: end, cal: cal)
        async let rhr = dailyAverage(.restingHeartRate, unit: HKUnit.count().unitDivided(by: .minute()), from: start, to: end, cal: cal)
        async let nights = sleepNights(from: start, to: end, cal: cal)
        async let exercise = dailySum(.appleExerciseTime, unit: .minute(), from: start, to: end, cal: cal)
        async let workouts = workoutMinutes(from: start, to: end, cal: cal)
        var (s, d, r, sl) = await (steps, daylight, rhr, nights)
        let (ex, wo) = await (exercise, workouts)
        // No Health permission for steps? The phone's own pedometer has the last 7 days.
        if s.isEmpty {
            for (day, n) in await MotionService.shared.stepsByDay(back: min(n, 7), calendar: cal) { s[day] = Double(n) }
        }
        var out: [HealthDay] = []
        var day = start
        while day < end {
            let night = sl[day]
            out.append(HealthDay(day: day, steps: s[day].map { Int($0) }, sleepMinutes: night?.minutes,
                                 bedtime: night?.bed, wake: night?.wake, daylightMinutes: d[day].map { Int($0) },
                                 restingHeartRate: r[day], exerciseMinutes: ex[day].map { Int($0) },
                                 workoutMinutes: wo[day].map { Int($0) }))
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

    /// Minutes of logged workouts per day.
    private func workoutMinutes(from: Date, to: Date, cal: Calendar) async -> [Date: Double] {
        let q = HKSampleQueryDescriptor(predicates: [.workout(HKQuery.predicateForSamples(withStart: from, end: to))],
                                        sortDescriptors: [SortDescriptor(\.startDate)])
        guard let ws = try? await q.result(for: store) else { return [:] }
        var out: [Date: Double] = [:]
        for w in ws { out[cal.startOfDay(for: w.startDate), default: 0] += w.duration / 60 }
        return out
    }

    /// Moods logged elsewhere (an Apple Watch, the Health app) as 1-5, for the last `n` days. iOS 18+.
    func stateOfMind(back n: Int) async -> [(Date, Int)] {
        guard available, #available(iOS 18.0, *) else { return [] }
        let start = Date().addingTimeInterval(-Double(n) * 86400)
        let samples: [HKSample] = await withCheckedContinuation { c in
            let q = HKSampleQuery(sampleType: HKObjectType.stateOfMindType(),
                                  predicate: HKQuery.predicateForSamples(withStart: start, end: Date()), limit: HKObjectQueryNoLimit,
                                  sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]) { _, results, _ in
                c.resume(returning: results ?? [])
            }
            store.execute(q)
        }
        return samples.compactMap { $0 as? HKStateOfMind }.filter { $0.metadata?["productium"] == nil }
            .map { ($0.startDate, Int((((($0.valence + 1) / 2) * 4) + 1).rounded())) }
    }

    /// Writes a mood logged in Productium to Health (valence -1...1). iOS 18+.
    func logStateOfMind(_ mood: Int, at date: Date = Date()) {
        guard available, #available(iOS 18.0, *) else { return }
        let valence = Double(max(1, min(5, mood)) - 3) / 2
        let s = HKStateOfMind(date: date, kind: .dailyMood, valence: valence, labels: [], associations: [],
                              metadata: ["productium": true])
        store.save(s) { _, _ in }
    }

    struct Night { var minutes: Int; var bed: Date; var wake: Date }

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
