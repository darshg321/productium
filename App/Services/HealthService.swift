import Foundation
import HealthKit
import ProductiumCore

final class HealthService {
    static let shared = HealthService()
    let store = HKHealthStore()

    var available: Bool { HKHealthStore.isHealthDataAvailable() }

    private var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = [HKQuantityType(.stepCount), HKCategoryType(.sleepAnalysis), HKQuantityType(.timeInDaylight),
                                        HKQuantityType(.restingHeartRate), HKQuantityType(.appleExerciseTime), HKObjectType.workoutType(),
                                        HKQuantityType(.heartRateVariabilitySDNN)]
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

    /// What one read found, for telemetry and Settings → Sleep (A6).
    struct ReadReport { var sleepSamples = 0; var error: String?; var sleepSource: String? }

    func days(back n: Int, calendar cal: Calendar = .current) async -> (days: [HealthDay], report: ReadReport) {
        guard available else { return ([], ReadReport(error: "Health isn't available on this device")) }
        let today = cal.startOfDay(for: Date())
        guard let start = cal.date(byAdding: .day, value: -(n - 1), to: today),
              let end = cal.date(byAdding: .day, value: 1, to: today) else { return ([], ReadReport()) }
        async let steps = dailySum(.stepCount, unit: .count(), from: start, to: end, cal: cal)
        async let daylight = dailySum(.timeInDaylight, unit: .minute(), from: start, to: end, cal: cal)
        async let rhr = dailyAverage(.restingHeartRate, unit: HKUnit.count().unitDivided(by: .minute()), from: start, to: end, cal: cal)
        async let hrv = dailyAverage(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli), from: start, to: end, cal: cal)
        async let nights = sleepNights(from: start, to: end, cal: cal)
        async let exercise = dailySum(.appleExerciseTime, unit: .minute(), from: start, to: end, cal: cal)
        async let workouts = workoutMinutes(from: start, to: end, cal: cal)
        var (s, d, r, sl) = await (steps, daylight, rhr, nights)
        let (ex, wo, hv) = await (exercise, workouts, hrv)
        // No Health permission for steps? The phone's own pedometer has the last 7 days.
        if s.isEmpty {
            for (day, n) in await MotionService.shared.stepsByDay(back: min(n, 7), calendar: cal) { s[day] = Double(n) }
        }
        var out: [HealthDay] = []
        var day = start
        while day < end {
            let night = sl.nights[day]
            let device = night.map { $0.stagesKnown ? $0.source : "\($0.source) (in bed, no stages)" }
            out.append(HealthDay(day: day, steps: s[day].map { Int($0) }, sleepMinutes: night?.minutes,
                                 bedtime: night?.bed, wake: night?.wake, daylightMinutes: d[day].map { Int($0) },
                                 restingHeartRate: r[day], sleepSource: night == nil ? nil : .health,
                                 exerciseMinutes: ex[day].map { Int($0) }, workoutMinutes: wo[day].map { Int($0) },
                                 sleepDevice: device, naps: night.map { $0.naps }, hrv: hv[day]))
            day = cal.date(byAdding: .day, value: 1, to: day)!
        }
        let last = sl.nights.max { $0.key < $1.key }?.value
        return (out, ReadReport(sleepSamples: sl.samples, error: sl.error,
                                sleepSource: last.map { $0.stagesKnown ? $0.source : "\($0.source) (in bed, no stages)" }))
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

    /// Every sleep sample in the window, built into nights in core (`SleepNights`: one source per night, `inBed` when
    /// there are no stages, naps apart). A failed read is reported, never turned into "no sleep".
    private func sleepNights(from: Date, to: Date, cal: Calendar) async -> (nights: [Date: BuiltNight], samples: Int, error: String?) {
        let type = HKCategoryType(.sleepAnalysis)
        let windowStart = from.addingTimeInterval(-6 * 3600)
        let q = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: type, predicate: HKQuery.predicateForSamples(withStart: windowStart, end: to))],
            sortDescriptors: [SortDescriptor(\.startDate)])
        let raw: [HKCategorySample]
        do { raw = try await q.result(for: store) } catch { return ([:], 0, error.localizedDescription) }
        let samples = raw.compactMap { s -> SleepSample? in
            guard let v = HKCategoryValueSleepAnalysis(rawValue: s.value) else { return nil }
            let stage: SleepSample.Stage
            if HKCategoryValueSleepAnalysis.allAsleepValues.contains(v) { stage = .asleep }
            else if v == .inBed { stage = .inBed }
            else { stage = .awake }
            return SleepSample(start: s.startDate, end: s.endDate, stage: stage, source: s.sourceRevision.source.name)
        }
        var out: [Date: BuiltNight] = [:]
        var day = from
        while day < to {
            if let n = SleepNights.build(samples, day: day, calendar: cal) { out[day] = n }
            day = cal.date(byAdding: .day, value: 1, to: day)!
        }
        return (out, samples.count, nil)
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
