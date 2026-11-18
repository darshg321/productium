import XCTest
@testable import ProductiumCore

/// v1.1 G1/G2: like-for-like comparisons, noise bands, coverage, and "noticed together".
final class MetricsTests: XCTestCase {
    let cal = Fx.cal

    func day(_ d: Int) -> Date { Fx.mon(0, plusDays: d) }

    func series(_ id: MetricID, _ values: [Int: Double], source: MetricSource = .measured, def: MetricDef? = nil,
                soFar: ((Date, Date) -> Double?)? = nil) -> MetricSeries {
        MetricSeries(def: def ?? .of(id), points: values.map { MetricPoint(day: day($0.key), value: $0.value, source: source) },
                     calendar: cal, soFar: soFar)
    }

    func testRangesAreLikeForLike() {
        // Wednesday 18 Nov 2026 (weeks start Monday in the fixtures).
        let wed = Fx.mon(15, plusDays: 2)
        let w = Metrics.range(.week, now: wed, calendar: cal)
        XCTAssertEqual(w.current, [day(0), day(1), day(2)])
        XCTAssertEqual(w.previous, [day(-7), day(-6), day(-5)])
        let m = Metrics.range(.month, now: wed, calendar: cal)
        XCTAssertEqual(m.current.count, 18)
        XCTAssertEqual(m.previous.first, cal.date(from: DateComponents(year: 2026, month: 10, day: 1)))
        XCTAssertEqual(m.previous.count, 18)
        // 31 March compares with all of February, not 3 days of March.
        let mar31 = cal.date(from: DateComponents(year: 2027, month: 3, day: 31, hour: 12))!
        XCTAssertEqual(Metrics.range(.month, now: mar31, calendar: cal).previous.count, 28)
    }

    func testTodaySoFarComparesWithYesterdayAtTheSameTime() {
        // Focus: 40 min done by 3pm today; yesterday 40 min by 3pm and 80 more in the evening.
        let now = Fx.mon(15, plusDays: 1)
        let full: [Int: Double] = [0: 120, 1: 40]
        let s = series(.focus, full, soFar: { d, cutoff in
            if self.cal.isDate(d, inSameDayAs: self.day(0)) { return cutoff <= Fx.mon(15, 0) ? 40 : 120 }
            return full[1]
        })
        let c = Metrics.compare(s, period: .day, now: now, calendar: cal)
        XCTAssertEqual(c.previous, 40, "yesterday until 3pm, not all of yesterday")
        XCTAssertEqual(c.verdict, .same)
        XCTAssertEqual(c.arrow, .flat)
    }

    func testCumulativeWithoutTimesWaitsForTheDayToEnd() {
        let s = series(.scrolling, [0: 90, 1: 30], source: .screenshot)
        let c = Metrics.compare(s, period: .day, now: Fx.mon(15, plusDays: 1), calendar: cal)
        XCTAssertEqual(c.verdict, .notEnoughData)
        XCTAssertEqual(c.note, "Compared once today is over")
        // A week compares the finished days only: Mon–Tue vs last Mon–Tue, today and last Wednesday left out.
        let w = series(.scrolling, [-7: 100, -6: 100, -5: 10, 0: 60, 1: 60, 2: 500], source: .screenshot)
        let cw = Metrics.compare(w, period: .week, now: Fx.mon(15, plusDays: 2), calendar: cal)
        XCTAssertEqual(cw.current, 60)
        XCTAssertEqual(cw.previous, 100)
        XCTAssertEqual(cw.verdict, .better)
        XCTAssertEqual(cw.arrow, .down)
    }

    func testNoiseBandTurnsSmallChangesGray() {
        func focus(_ v: [Int: Double]) -> MetricSeries {
            series(.focus, v, soFar: { d, _ in v[self.cal.dateComponents([.day], from: self.day(0), to: d).day!] })
        }
        // Four weeks of focus bouncing 60 ↔ 140 (SD ≈ 40): a 15-minute drop from yesterday is noise.
        var bouncy: [Int: Double] = [:]
        for d in -30 ... -2 { bouncy[d] = d % 2 == 0 ? 60 : 140 }
        bouncy[-1] = 100; bouncy[0] = 85
        let c = Metrics.compare(focus(bouncy), period: .day, now: Fx.mon(22), calendar: cal)
        XCTAssertEqual(c.verdict, .same)
        XCTAssertEqual(c.arrow, .flat)
        XCTAssertGreaterThan(c.band, 15)
        // The same drop is real when days are steady (the band falls to the 10-minute floor).
        var steady: [Int: Double] = [:]
        for d in -30 ... -1 { steady[d] = 100 }
        steady[0] = 85
        let c2 = Metrics.compare(focus(steady), period: .day, now: Fx.mon(22), calendar: cal)
        XCTAssertEqual(c2.verdict, .worse)
        XCTAssertEqual(c2.arrow, .down)
        let day = Metrics.compare(series(.mood, [0: 3.0, -1: 3.2, -2: 3.1, -3: 3.0, -4: 3.2, -5: 3.1, -6: 3.0]),
                                  period: .day, now: Fx.mon(20), calendar: cal)
        XCTAssertEqual(day.verdict, .same, "0.2 of a point is under mood's 0.3 floor")
        let big = Metrics.compare(series(.mood, [0: 4.5, -1: 3.0, -2: 3.1, -3: 3.0, -4: 3.2, -5: 3.1, -6: 3.0]),
                                  period: .day, now: Fx.mon(20), calendar: cal)
        XCTAssertEqual(big.verdict, .better)
        XCTAssertEqual(big.arrow, .up)
    }

    func testMissingDaysAreNotZeros() {
        // Mood logged on 2 of last week's days and 2 of this week's: means of logged days only.
        let s = series(.mood, [-7: 2, -5: 2, 0: 4, 1: 4], source: .stated)
        let c = Metrics.compare(s, period: .week, now: Fx.mon(20, plusDays: 2), calendar: cal)
        XCTAssertEqual(c.current, 4)
        XCTAssertEqual(c.previous, 2)
        XCTAssertEqual(c.currentDays, 2)
        XCTAssertEqual(c.verdict, .better)
        let thin = Metrics.compare(series(.mood, [-7: 2, 0: 4], source: .stated), period: .week, now: Fx.mon(20, plusDays: 2), calendar: cal)
        XCTAssertEqual(thin.verdict, .notEnoughData)
        XCTAssertEqual(thin.arrow, .none)
        let none = Metrics.daily(s, last: 3, now: Fx.mon(20, plusDays: 2), calendar: cal)
        XCTAssertEqual(none.map(\.1), [4, 4, nil], "no point is nil, never 0")
    }

    func testSleepIsBetterCloserToYourNeedNotMore() {
        let def = MetricDef.sleep(need: 540)
        func cmp(_ y: Double, _ t: Double) -> MetricVerdict {
            Metrics.compare(series(.sleep, [-1: y, 0: t], def: def), period: .day, now: Fx.mon(20), calendar: cal).verdict
        }
        XCTAssertEqual(cmp(500, 580), .same, "both inside 8–10 h")
        XCTAssertEqual(cmp(400, 470), .better)
        XCTAssertEqual(cmp(470, 400), .worse)
        XCTAssertEqual(cmp(620, 700), .worse, "11h40 is further from the range than 10h20")
        XCTAssertEqual(cmp(700, 560), .better)
    }

    func testRegularityIsAWeekThing() {
        let s = series(.sleepRegularity, [-7: 600, -6: 700, -5: 540, -4: 690, 0: 620, 1: 625, 2: 630, 3: 622])
        XCTAssertEqual(Metrics.compare(s, period: .day, now: Fx.mon(20, plusDays: 3), calendar: cal).verdict, .notEnoughData)
        let w = Metrics.compare(s, period: .week, now: Fx.mon(20, plusDays: 3), calendar: cal)
        XCTAssertEqual(w.verdict, .better, "nights moved ±4 min this week vs ±70 last week")
    }

    func testBuilderSkipsAssumedSleepAndEmptyDays() {
        let days = (0..<3).map { day($0) }
        let health = [HealthDay(day: day(0), steps: 9000, sleepMinutes: 500, sleepSource: .health),
                      HealthDay(day: day(1), sleepMinutes: 540, sleepSource: .plan),
                      HealthDay(day: day(2), steps: 4000, sleepMinutes: 420, sleepSource: .checkIns)]
        let o = BlockOutcome(blockId: UUID(), itemId: nil, kind: .essay, plannedStart: Fx.mon(16), plannedMinutes: 60,
                             actualMinutes: 45, status: .partial, loggedAt: Fx.mon(17))
        let x = MetricsInput(days: days, screen: [nil, nil, nil], health: health, moods: [MoodEntry(at: Fx.mon(20), mood: 4)],
                             items: [], outcomes: [o], progress: [], markers: [], planned: [day(0): 60], sleepNeed: 540)
        let s = MetricsBuilder.series(x, calendar: cal)
        XCTAssertEqual(s[.sleep]!.points.count, 2, "the plan's assumed 9 h isn't a night of data")
        XCTAssertEqual(s[.sleep]!.points[day(2)]?.source, .stated)
        XCTAssertEqual(s[.steps]!.points.count, 2)
        XCTAssertEqual(s[.focus]!.points.count, 1, "days with nothing planned or done have no focus number")
        XCTAssertEqual(s[.planDone]!.points[day(0)]?.value, 75)
        XCTAssertEqual(s[.mood]!.points[day(0)]?.value, 4)
        XCTAssertTrue(s[.scrolling]!.points.isEmpty)
    }

    // MARK: G2

    struct Rng {
        var s: UInt64
        mutating func next() -> Double {
            s &+= 0x9E3779B97F4A7C15
            var z = s
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
        }
    }

    func noticed(days n: Int, planted: Bool, seed: UInt64 = 7) -> [NoticedTogether] {
        var r = Rng(s: seed)
        var sleep: [Int: Double] = [:], focus: [Int: Double] = [:]
        for d in 0..<n {
            let s = 420 + r.next() * 120
            sleep[-d] = s
            focus[-d] = (planted ? (s >= 480 ? 90 : 50) : 70) + r.next() * 30 - 15
        }
        return Noticed.find([.sleep: series(.sleep, sleep), .focus: series(.focus, focus)], pairs: [(.sleep, .focus)])
    }

    func testNoticedTogetherNeedsDaysAndARealEffect() {
        XCTAssertTrue(noticed(days: 13, planted: true).isEmpty, "13 days isn't enough")
        let found = noticed(days: 21, planted: true)
        XCTAssertEqual(found.count, 1)
        XCTAssertTrue(found[0].text.hasPrefix("Noticed: On days with 8h+ of sleep, you had "), found[0].text)
        XCTAssertTrue(found[0].text.contains("more focus"), found[0].text)
        for seed: UInt64 in 1...20 {
            XCTAssertTrue(noticed(days: 28, planted: false, seed: seed).isEmpty, "noise, seed \(seed)")
        }
    }
}

final class MetricsExportTests: XCTestCase {
    let cal = Fx.cal
    func testCsvAndAiSummary() {
        let days = (0..<14).map { Fx.mon(0, plusDays: $0 - 9) }   // 7 Nov … 20 Nov
        let pts = days.enumerated().map { MetricPoint(day: $1, value: Double(60 + ($0 < 9 ? 40 : 0)), source: .screenshot) }
        let series: [MetricID: MetricSeries] = [.scrolling: MetricSeries(def: .of(.scrolling), points: pts, calendar: cal)]
        let csv = MetricsExport.csv(series, calendar: cal)
        XCTAssertTrue(csv.hasPrefix("day,metric,value,source\n"))
        XCTAssertEqual(csv.split(separator: "\n").count, 15)
        XCTAssertTrue(csv.contains(",scrolling,60,screenshot"))
        let text = MetricsExport.summary(series, now: Fx.mon(12, plusDays: 4), calendar: cal) ?? ""
        XCTAssertTrue(text.hasPrefix("Life metrics, this week so far: Scrolling"), text)
        XCTAssertTrue(text.contains("better"), text)
        XCTAssertNil(MetricsExport.summary([:], now: Fx.mon(12), calendar: cal))
    }
}

/// v1.1 H: time out, in-bed-on-time and exercise get points.
final class SensorMetricsTests: XCTestCase {
    let cal = Fx.cal
    func day(_ d: Int) -> Date { Fx.mon(0, plusDays: d) }

    func testAwayMinutesSkipHomeAndSplitMidnight() {
        let home = SavedPlace(id: "home", name: "Home", latitude: 43.6, longitude: -79.4)
        let visits = [PlaceVisit(latitude: 43.6001, longitude: -79.4, arrival: Fx.mon(8), departure: Fx.mon(18)),   // at home
                      PlaceVisit(latitude: 43.7, longitude: -79.4, arrival: Fx.mon(8, 30), departure: Fx.mon(15)),
                      PlaceVisit(latitude: 43.7, longitude: -79.4, arrival: Fx.mon(23), departure: Fx.mon(1, plusDays: 1))]
        let a = PlaceTime.awayMinutes(visits: visits, home: home, now: Fx.mon(12, plusDays: 3), calendar: cal)
        XCTAssertEqual(a[day(0)], 390 + 60)
        XCTAssertEqual(a[day(1)], 60)
    }

    func testBedOnTimeComparesWithThePlannedBedtime() {
        var plan = Planner.plan(Fx.input(now: Fx.mon(6), items: []))
        var bed: [String: Date] = [:]
        PlanHistory.recordBedtimes(plan: plan, into: &bed, now: Fx.mon(12, plusDays: 3), calendar: cal)
        XCTAssertFalse(bed.isEmpty)
        plan.blocks.removeAll()
        let night = day(1)
        let key = CapacityLearner.dayKey(night, cal)
        let planned = bed[key]!
        let health = [HealthDay(day: night, sleepMinutes: 480, bedtime: planned.addingTimeInterval(10 * 60), wake: night.addingTimeInterval(7 * 3600), sleepSource: .health),
                      HealthDay(day: day(2), sleepMinutes: 480, bedtime: bed[CapacityLearner.dayKey(day(2), cal)]!.addingTimeInterval(90 * 60),
                                wake: day(2).addingTimeInterval(8 * 3600), sleepSource: .health)]
        let x = MetricsInput(days: [night, day(2)], screen: [nil, nil], health: health, moods: [], items: [], outcomes: [], progress: [],
                             markers: [], planned: [:], sleepNeed: 540, away: [night: 120], plannedBed: bed)
        let s = MetricsBuilder.series(x, calendar: cal)
        XCTAssertEqual(s[.bedOnTime]?.points[night]?.value, 100)
        XCTAssertEqual(s[.bedOnTime]?.points[day(2)]?.value, 0)
        XCTAssertEqual(s[.outside]?.points[night]?.value, 120)
    }

    func testExerciseUsesTheLargerOfRingsAndWorkouts() {
        let h = [HealthDay(day: day(0), exerciseMinutes: 20, workoutMinutes: 45), HealthDay(day: day(1))]
        let x = MetricsInput(days: [day(0), day(1)], screen: [nil, nil], health: h, moods: [], items: [], outcomes: [], progress: [],
                             markers: [], planned: [:], sleepNeed: 540)
        let s = MetricsBuilder.series(x, calendar: cal)
        XCTAssertEqual(s[.exercise]?.points.count, 1)
        XCTAssertEqual(s[.exercise]?.points[day(0)]?.value, 45)
    }
}
