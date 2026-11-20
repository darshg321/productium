import XCTest
@testable import ProductiumCore

final class EvidenceTests: XCTestCase {
    let cal = Fx.cal

    func state(items: [WorkItem] = []) -> DumpState {
        DumpState(items: items,                   routines: Routine.defaults, moods: [], screen: [], prefs: Preferences())
    }






    func testDuplicateStartsGiveOneSampleOnce() {
        let day = Fx.mon(0)
        func at(_ h: Int, _ m: Int, _ sec: Int = 0) -> Date { day.addingTimeInterval(Double(h * 3600 + m * 60 + sec)) }
        let markers = [
            CheckIn(at: at(13, 2), phrase: "leaving for school", activity: "to_school", category: .commute, phase: .start, source: .voice),
            CheckIn(at: at(13, 7, 58), phrase: "left home", activity: "to_school", category: .commute, phase: .start, source: .geofence),
            CheckIn(at: at(13, 8, 16), phrase: "left home", activity: "to_school", category: .commute, phase: .start, source: .geofence),
            CheckIn(at: at(13, 16), phrase: "at school", activity: "to_school", category: .commute, phase: .end, source: .voice),
        ]
        var routines = RoutineLearner.learn(day: markers, healthWake: nil, routines: Routine.defaults)
        XCTAssertEqual(routines.first { $0.id == "to_school" }?.samples, [14])
        routines = RoutineLearner.learn(day: markers, healthWake: nil, routines: routines)
        XCTAssertEqual(routines.first { $0.id == "to_school" }?.samples, [14])
    }

}

final class MotionTests: XCTestCase {
    let cal = Fx.cal

    func samples(_ list: [(Int, Int, MotionKind)]) -> [MotionSample] {
        list.map { MotionSample(at: Fx.mon($0.0, $0.1), kind: $0.2, confidence: 2) }
    }

    func testSpansPaintSegmentsAndTeachTheWalk() {
        let recs = samples([(7, 0, .stationary), (8, 2, .walking), (8, 9, .walking), (8, 16, .stationary),
                            (12, 0, .walking), (12, 3, .stationary), (15, 5, .automotive), (15, 27, .stationary)])
        let spans = MotionTimeline.spans(recs, until: Fx.mon(18))
        let walk = spans.first { $0.kind == .walking }!
        XCTAssertEqual(walk.start, Fx.mon(8, 2))
        XCTAssertEqual(walk.end, Fx.mon(8, 16), "records of the same kind merge")
        let markers = [CheckIn(at: Fx.mon(15), phrase: "left school", activity: "from_school", category: .commute, phase: .start),
                       CheckIn(at: Fx.mon(15, 30), phrase: "home", activity: "from_school", category: .commute, phase: .end)]
        let segs = TimelineBuilder.segments(DayInputs(day: Fx.mon(12), entries: Fx.log(markers), routines: Routine.defaults,
                                                      health: nil, screen: nil, prefs: Preferences(), motion: spans),
                                            calendar: cal, now: Fx.mon(18))
        XCTAssertEqual(segs.first { $0.label == "Walk" }?.start, Fx.mon(8, 2))
        XCTAssertEqual(segs.first { $0.label == "Walk" }?.end, Fx.mon(8, 16))
        XCTAssertFalse(segs.contains { $0.label == "Walk" && $0.start == Fx.mon(12) }, "3 minutes isn't a walk")
        XCTAssertFalse(segs.contains { $0.label == "In a vehicle" }, "the check-in covers the ride home")
        XCTAssertTrue(segs.contains { $0.label == "Home from school" && !$0.inferred })
        XCTAssertFalse(segs.contains { $0.label == "To school" && $0.inferred && $0.start < Fx.mon(8, 16) && $0.end > Fx.mon(8, 2) },
                       "the walk beats the assumed routine")

        var routines = MotionTimeline.learnRoutines(spans, day: Fx.mon(0), commitments: [Fx.school], routines: Routine.defaults, calendar: cal)
        XCTAssertEqual(routines.first { $0.id == "to_school" }?.samples, [14])
        XCTAssertEqual(routines.first { $0.id == "from_school" }?.samples, [22])
        let again = MotionTimeline.spans(recs, until: Fx.mon(18), previous: spans)
        routines = MotionTimeline.learnRoutines(again, day: Fx.mon(0), commitments: [Fx.school], routines: routines, calendar: cal)
        XCTAssertEqual(routines.first { $0.id == "to_school" }?.samples, [14])
        XCTAssertEqual(MotionTimeline.summary(spans, on: Fx.mon(0), calendar: cal), "walk 14 min 08:02, in a vehicle 22 min 15:05")
    }

    func testOvernightStillnessIsFound() {
        let recs = [MotionSample(at: Fx.mon(0, 30), kind: .stationary, confidence: 2), MotionSample(at: Fx.mon(7, 20), kind: .walking, confidence: 2)]
        let spans = MotionTimeline.spans(recs, until: Fx.mon(8))
        XCTAssertEqual(MotionTimeline.overnightStill(spans, morningOf: Fx.mon(0), calendar: cal)?.minutes, 410)
    }
}

final class SleepTests: XCTestCase {
    let cal = Fx.cal


    func testStillnessThenPlanAndHealthWins() {
        let still = MotionTimeline.spans([MotionSample(at: Fx.mon(0, -60), kind: .stationary, confidence: 2),
                                          MotionSample(at: Fx.mon(7, 10), kind: .walking, confidence: 2)], until: Fx.mon(8))
        let phone = [Fx.mon(0, -30), Fx.mon(7)]
        let n = SleepEstimator.night(morningOf: Fx.mon(0), health: nil, markers: [], motion: still, phoneUse: phone,
                                     plannedWake: nil, sleepNeedMinutes: 540, calendar: cal)
        XCTAssertEqual(n?.source, .motion)
        XCTAssertEqual(n?.bedtime, Fx.mon(0, -30), "the last scroll before the stillness")
        XCTAssertEqual(n?.wake, Fx.mon(7))
        let measured = HealthDay(day: Fx.mon(0), sleepMinutes: 480, wake: Fx.mon(7, 30))
        XCTAssertEqual(SleepEstimator.night(morningOf: Fx.mon(0), health: measured, markers: [], plannedWake: nil,
                                            sleepNeedMinutes: 540, calendar: cal)?.source, .health)
        XCTAssertEqual(SleepEstimator.night(morningOf: Fx.mon(0), health: nil, markers: [], plannedWake: Fx.mon(7),
                                            sleepNeedMinutes: 540, calendar: cal)?.source, .plan)
        XCTAssertNil(SleepEstimator.fill([], days: [Fx.mon(0)], markers: [], motion: [], phoneUse: [], sleepNeedMinutes: 540,
                                         calendar: cal).first?.sleepMinutes)
    }
}

final class BeliefTests: XCTestCase {
    let cal = Fx.cal

    func testThreeWeeksMoveCapsTowardObservedBehaviour() {
        let now = Fx.mon(9)
        var days: [DayRecord] = []
        for i in 1...21 {
            let d = Fx.mon(0, plusDays: -i)
            let wd = cal.component(.weekday, from: d)
            let school = (2...6).contains(wd)
            days.append(DayRecord(day: d, isSchoolDay: school, planned: school ? 150 : 240,
                                  done: school ? 90 + (i % 4) * 10 : 200 + (i % 3) * 20, eveningFree: school ? 120 : 240))
        }
        let sessions = (1...8).map { i in
            Entry(title: "Essay", start: Fx.mon(19, plusDays: -i), end: Fx.mon(19, 30, plusDays: -i), category: CategoryTree.studying,
                  taskId: UUID(), source: .you, createdAt: Fx.mon(19, 30, plusDays: -i))
        }
        let dinner = (1...6).map { i in
            Entry(title: "Dinner", start: Fx.mon(19, 0, plusDays: -i), end: Fx.mon(19, 25, plusDays: -i), category: CategoryTree.meals,
                  topics: ["dinner"], source: .you, createdAt: Fx.mon(19, 25, plusDays: -i))
        }
        let b = CapacityLearner.learn(Beliefs(), days: days, entries: sessions + dinner, tree: CategoryTree(), now: now, calendar: cal)
        let school = b["study.schoolDayCapacity"]!
        XCTAssertEqual(school.samples, 15)
        XCTAssertLessThan(school.value, 180, "moved down from the prior")
        XCTAssertGreaterThan(school.value, 110, "toward the 75th percentile (~120), shrunk a little to the prior")
        XCTAssertEqual(school.confidence, .learned)
        XCTAssertLessThan(b.value("study.freeDayCapacity"), 300)
        XCTAssertGreaterThan(b.value("study.schoolDayFreeTime"), 60, "they keep more free time than the prior")
        XCTAssertEqual(b.value("study.focusMinutes"), (40 * 5 + 30 * 8) / 13.0, accuracy: 0.1)
        XCTAssertEqual(b.minutes("routines.dinnerTime"), 18 * 60 + 46, "from the 18:30 prior toward 19:00")
        let lazy = (1...21).map { DayRecord(day: Fx.mon(0, plusDays: -$0), isSchoolDay: true, planned: 100, done: 1) }
        XCTAssertGreaterThanOrEqual(CapacityLearner.learn(Beliefs(), days: lazy, now: now, calendar: cal).value("study.schoolDayCapacity"), 30)
        let essay = WorkItem(title: "Essay", kind: .essay, due: Fx.mon(23, plusDays: 4), estimateMinutes: 900)
        func monday(_ beliefs: Beliefs) -> Int {
            Planner.plan(PlannerInput(now: Fx.mon(6), calendar: cal, items: [essay], beliefs: beliefs, entries: Fx.schoolEntries))
                .blocks(on: Fx.mon(12), calendar: cal).filter(\.isStudy).reduce(0) { $0 + $1.minutes }
        }
        var low = Beliefs(); _ = low.state("study.schoolDayCapacity", 60, now: now)
        XCTAssertLessThan(monday(low), monday(Beliefs()), "\(monday(low)) vs \(monday(Beliefs()))")
    }

    func testStatedThenLearnedThenConfirmed() {
        var b = Beliefs()
        XCTAssertEqual(b["study.schoolDayCapacity"]?.confidence, .assumed)
        XCTAssertTrue(b.state("study.schoolDayCapacity", 120, now: Fx.mon(9)))
        XCTAssertEqual(b.value("study.schoolDayCapacity"), 120, "what they said wins until 3 samples")
        var x = b["study.schoolDayCapacity"]!
        x.samples = 5; x.value = 125
        b["study.schoolDayCapacity"] = x
        XCTAssertEqual(b["study.schoolDayCapacity"]?.confidence, .confirmed)
        x.value = 60; b["study.schoolDayCapacity"] = x
        XCTAssertEqual(b["study.schoolDayCapacity"]?.disagreement, "You said 2 h, it's been 1 h lately")
        b.reset("study.schoolDayCapacity")
        XCTAssertEqual(b["study.schoolDayCapacity"]?.confidence, .assumed)
        XCTAssertEqual(Beliefs.routines(Routine.defaults).first?.group, "routines")
    }
}

/// v1.1 H4: first pickup, charging and night activity feed the sleep estimate.
final class SleepSignalTests: XCTestCase {
    let cal = Fx.cal
    var still: [MotionSpan] {
        MotionTimeline.spans([MotionSample(at: Fx.mon(0, -90), kind: .stationary, confidence: 2),
                              MotionSample(at: Fx.mon(7, 40), kind: .walking, confidence: 2)], until: Fx.mon(9))
    }

    func testFirstPickupPullsTheWakeEarlierButNeverLater() {
        let a = SleepEstimator.night(morningOf: Fx.mon(0), health: nil, markers: [], motion: still, plannedWake: nil,
                                     sleepNeedMinutes: 540, calendar: cal, firstPickup: Fx.mon(6, 45))
        XCTAssertEqual(a?.wake, Fx.mon(6, 45))
        let b = SleepEstimator.night(morningOf: Fx.mon(0), health: nil, markers: [], motion: still, plannedWake: nil,
                                     sleepNeedMinutes: 540, calendar: cal, firstPickup: Fx.mon(9))
        XCTAssertEqual(b?.wake, Fx.mon(7, 40), "a later pickup says nothing about waking")
    }

    func testFirstPickupAloneMakesAnEstimateAndChargingStartsTheNight() {
        let a = SleepEstimator.night(morningOf: Fx.mon(0), health: nil, markers: [], motion: [], plannedWake: nil,
                                     sleepNeedMinutes: 540, calendar: cal, firstPickup: Fx.mon(7), charging: Fx.mon(22, plusDays: -1))
        XCTAssertEqual(a?.source, .motion)
        XCTAssertEqual(a?.bedtime, Fx.mon(22, plusDays: -1))
        XCTAssertEqual(a?.minutes, 540)
        let none = SleepEstimator.night(morningOf: Fx.mon(0), health: nil, markers: [], motion: [], plannedWake: nil,
                                        sleepNeedMinutes: 540, calendar: cal, firstPickup: Fx.mon(14))
        XCTAssertNil(none, "an afternoon pickup isn't a wake")
        let plug = SleepEstimator.night(morningOf: Fx.mon(0), health: nil, markers: [], motion: still, plannedWake: nil,
                                        sleepNeedMinutes: 540, calendar: cal, charging: Fx.mon(0, -100))
        XCTAssertEqual(plug?.bedtime, Fx.mon(0, -90), "stillness started after the plug-in")
    }

    func testNightActivityTakesTimeOffTheNight() {
        let burstsAtTwo = [Fx.mon(2, 0), Fx.mon(2, 5), Fx.mon(4, 30)]
        let n = SleepEstimator.night(morningOf: Fx.mon(0), health: nil, markers: [], motion: still, phoneUse: burstsAtTwo, plannedWake: nil,
                                     sleepNeedMinutes: 540, calendar: cal)
        let plain = SleepEstimator.night(morningOf: Fx.mon(0), health: nil, markers: [], motion: still, plannedWake: nil,
                                         sleepNeedMinutes: 540, calendar: cal)
        XCTAssertEqual(n?.awakeMinutes, 20, "two bursts (2:00 and 2:05 are one)")
        XCTAssertEqual((plain?.minutes ?? 0) - (n?.minutes ?? 0), 20 + 0)
    }
}
