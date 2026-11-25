import XCTest
@testable import ProductiumCore

/// v1.2 A5 / A6: nights from Health's raw samples, and reads that never wipe a night.
final class SleepNightTests: XCTestCase {
    let cal = Fx.cal
    /// Tuesday morning's night: Monday 22:00 onwards.
    let tue = Fx.mon(0, plusDays: 1)

    func s(_ h: Int, _ m: Int, _ h2: Int, _ m2: Int, _ stage: SleepSample.Stage, _ src: String, evening: Bool = true) -> SleepSample {
        let a = evening && h >= 18 ? Fx.mon(h, m) : Fx.mon(h, m, plusDays: 1)
        let b = evening && h2 >= 18 ? Fx.mon(h2, m2) : Fx.mon(h2, m2, plusDays: 1)
        return SleepSample(start: a, end: b, stage: stage, source: src)
    }

    func testWatchOnlyUsesAsleepStages() {
        let n = SleepNights.build([s(22, 40, 23, 0, .inBed, "watch"), s(23, 0, 3, 0, .asleep, "watch"), s(3, 0, 3, 20, .awake, "watch"),
                                   s(3, 20, 6, 50, .asleep, "watch")], day: tue, calendar: cal)!
        XCTAssertEqual(n.bed, Fx.mon(23))
        XCTAssertEqual(n.wake, Fx.mon(6, 50, plusDays: 1))
        XCTAssertEqual(n.minutes, 4 * 60 + 210, "the 20 minutes awake don't count")
        XCTAssertTrue(n.stagesKnown)
    }

    func testPhoneOnlyFallsBackToInBed() {
        let n = SleepNights.build([s(22, 30, 7, 0, .inBed, "iphone")], day: tue, calendar: cal)!
        XCTAssertEqual(n.minutes, 510)
        XCTAssertFalse(n.stagesKnown, "in bed (no stages)")
        XCTAssertEqual(n.source, "iphone")
    }

    func testBothSourcesPickTheBestOneNotTheUnion() {
        // The phone's in-bed runs late into the morning; the Watch has stages, so the Watch's night is used alone.
        let n = SleepNights.build([s(21, 0, 9, 30, .inBed, "iphone"), s(23, 10, 6, 40, .asleep, "watch"),
                                   s(23, 30, 1, 0, .asleep, "sleepapp")], day: tue, calendar: cal)!
        XCTAssertEqual(n.source, "watch")
        XCTAssertEqual(n.bed, Fx.mon(23, 10))
        XCTAssertEqual(n.wake, Fx.mon(6, 40, plusDays: 1))
    }

    func testNapIsSeparate() {
        let n = SleepNights.build([s(23, 0, 7, 0, .asleep, "watch"), s(13, 10, 13, 55, .asleep, "watch"),
                                   s(11, 0, 11, 10, .asleep, "watch")], day: tue, calendar: cal)!
        XCTAssertEqual(n.wake, Fx.mon(7, plusDays: 1), "the nap doesn't stretch the night")
        XCTAssertEqual(n.naps, [DateInterval(start: Fx.mon(13, 10, plusDays: 1), end: Fx.mon(13, 55, plusDays: 1))], "a 10-minute doze isn't a nap")
    }

    func testOvernightGapStaysOneNight() {
        let n = SleepNights.build([s(23, 0, 2, 0, .asleep, "watch"), s(2, 45, 7, 0, .asleep, "watch")], day: tue, calendar: cal)!
        XCTAssertEqual(n.bed, Fx.mon(23))
        XCTAssertEqual(n.wake, Fx.mon(7, plusDays: 1))
        XCTAssertEqual(n.minutes, 3 * 60 + 255)
        XCTAssertTrue(n.naps.isEmpty)
    }

    func testDaylightSavingNight() {
        // Fall back on Sunday 1 November 2026 in Vancouver: 23:00 to 7:00 is nine hours.
        let sun = cal.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        let bed = cal.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 23))!
        let wake = cal.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 7))!
        let n = SleepNights.build([SleepSample(start: bed, end: wake, stage: .asleep, source: "watch")], day: sun, calendar: cal)!
        XCTAssertEqual(n.minutes, 540)
    }

    func testNothingUsableIsNil() {
        XCTAssertNil(SleepNights.build([], day: tue, calendar: cal))
        XCTAssertNil(SleepNights.build([s(23, 0, 23, 40, .asleep, "watch")], day: tue, calendar: cal), "under an hour isn't a night")
    }

    func testAReadThatComesBackEmptyNeverWipesANight() {
        let night = HealthDay(day: tue, steps: 900, sleepMinutes: 470, bedtime: Fx.mon(23), wake: Fx.mon(7, plusDays: 1),
                              sleepSource: .health)
        // Locked phone: steps read, sleep didn't.
        let merged = [night].merging(fresh: [HealthDay(day: tue, steps: 1500)], calendar: cal)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].sleepMinutes, 470)
        XCTAssertEqual(merged[0].steps, 1500)
        // A late Watch sync updates the night.
        let later = merged.merging(fresh: [HealthDay(day: tue, sleepMinutes: 480, bedtime: Fx.mon(22, 50), wake: Fx.mon(7, plusDays: 1))], calendar: cal)
        XCTAssertEqual(later[0].sleepMinutes, 480)
        XCTAssertEqual(later[0].bedtime, Fx.mon(22, 50))
        // Steps never go down within a day (a read before the Watch synced).
        XCTAssertEqual(later.merging(fresh: [HealthDay(day: tue, steps: 200)], calendar: cal)[0].steps, 1500)
    }

    func testNightsBecomeSleepEntriesThatOutrankThePlan() {
        let night = HealthDay(day: tue, sleepMinutes: 470, bedtime: Fx.mon(23, 30), wake: Fx.mon(7, 20, plusDays: 1), sleepSource: .health,
                              sleepDevice: "Apple Watch",
                              naps: [DateInterval(start: Fx.mon(14, plusDays: 1), end: Fx.mon(14, 40, plusDays: 1))])
        let planned = Entry(title: "Sleep", start: Fx.mon(22, 30), end: Fx.mon(7, plusDays: 1), category: CategoryTree.sleep,
                            alert: .wake, source: .plan)
        var es = [planned]
        let ids = EntryBuilder.sleep([night], entries: &es, now: Fx.mon(18, plusDays: 1), calendar: cal)
        XCTAssertEqual(ids.count, 2)
        es[es.firstIndex { $0.id == ids[0] }!].marks["2026-11-16"] = .confirmed
        EntryBuilder.sleep([night], entries: &es, now: Fx.mon(18, plusDays: 1), calendar: cal)
        XCTAssertEqual(es.count, 3, "a re-read replaces, it doesn't add")
        XCTAssertEqual(es.first { $0.id == ids[0] }?.marks["2026-11-16"], .confirmed, "marks survive a re-read")
        let slices = TimeLog.past(es, in: DateInterval(start: Fx.mon(22), end: Fx.mon(8, plusDays: 1)), now: Fx.mon(18, plusDays: 1), calendar: cal)
        XCTAssertEqual(slices.first { $0.entry?.source == .health }?.start, Fx.mon(23, 30))
        XCTAssertFalse(slices.contains { $0.entry?.source == .plan }, "v1.6 A5: the measured night replaces the planned Sleep")
    }

    func testEstimatedNightIsASensorEntryAndCheckInNightsArentDuplicated() {
        let est = HealthDay(day: tue, sleepMinutes: 450, bedtime: Fx.mon(23), wake: Fx.mon(6, 30, plusDays: 1), sleepSource: .motion)
        let told = HealthDay(day: Fx.mon(0, plusDays: 2), sleepMinutes: 450, bedtime: Fx.mon(23, plusDays: 1), wake: Fx.mon(6, 30, plusDays: 2),
                             sleepSource: .checkIns)
        var es: [Entry] = []
        EntryBuilder.sleep([est, told], entries: &es, now: Fx.mon(12, plusDays: 2), calendar: cal)
        XCTAssertEqual(es.map(\.source), [.sensor])
    }
}
