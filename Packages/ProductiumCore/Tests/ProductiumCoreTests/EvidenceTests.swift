import XCTest
@testable import ProductiumCore

/// Every prompt teaches the app: facts go to about-me.md, evidence to check-ins, routines and work done.
final class EvidenceTests: XCTestCase {
    let cal = Fx.cal

    func state(items: [WorkItem] = []) -> DumpState {
        DumpState(items: items, commitments: [Fx.school], exceptions: [], oneOffs: [], markers: [],
                  routines: Routine.defaults, moods: [], screen: [], prefs: Preferences())
    }

    @discardableResult
    func run(_ s: inout DumpState, _ r: DumpResult, now: Date = Fx.mon(12)) -> DumpReport {
        DumpApplier.apply(r, to: &s, now: now, calendar: cal)
    }

    /// "i left at 8:02 and got to school 8:16": one routine sample and one Travel segment.
    func testTravelEvidenceTeachesTheRoutineAndPaintsTravel() {
        var s = state()
        let answer = DumpResult(ops: [], reply: "Nice, 14 minutes.", evidence: [
            DumpEvidence(what: "walked to school", start: "2026-11-16T08:02", end: "2026-11-16T08:16", kind: "travel"),
        ])
        let rep = run(&s, answer)
        let walk = s.routines.first { $0.id == "to_school" }!
        XCTAssertEqual(walk.samples, [14])
        XCTAssertTrue(rep.changes.contains("Learned: to school took 14 min"), "\(rep.changes)")
        let segs = TimelineBuilder.segments(DayInputs(day: Fx.mon(12), events: s.markers, commitments: s.commitments,
                                                      routines: s.routines, outcomes: [], health: nil, screen: nil, prefs: s.prefs),
                                            calendar: cal, now: Fx.mon(12))
        let travel = segs.filter { $0.category == .commute && !$0.inferred }
        XCTAssertEqual(travel.count, 1)
        XCTAssertEqual(travel.first?.start, Fx.mon(8, 2))
        XCTAssertEqual(travel.first?.end, Fx.mon(8, 16))
        // Said again: no second sample, no second pair of markers.
        run(&s, answer)
        XCTAssertEqual(s.routines.first { $0.id == "to_school" }!.samples, [14])
        XCTAssertEqual(s.markers.count, 2)
    }

    /// "i've written two drafts": work done today, even without a study block.
    func testWorkWithoutABlockCountsAsWorkDone() {
        let drafts = WorkItem(title: "Waterloo AIF drafts", kind: .application, due: Fx.mon(23, plusDays: 20))
        var s = state(items: [drafts])
        run(&s, DumpResult(ops: [], reply: "Two drafts down.", evidence: [
            DumpEvidence(what: "wrote two drafts", minutes: 90, task: Ref.task(drafts.id), kind: "study", estimated: true),
        ]))
        XCTAssertEqual(s.progress.minutes(on: Fx.mon(0), calendar: cal), 90)
        XCTAssertEqual(s.progress.first?.estimated, true)
        XCTAssertEqual(s.progress.first?.itemId, drafts.id)
    }

    /// Minutes set on a task are logged once; evidence for the same work isn't counted again, and a
    /// correction counts against the day.
    func testTaskMinutesAreLoggedOnceAndCorrectionsCount() {
        let apps = WorkItem(title: "University applications", kind: .application, due: Fx.mon(23, plusDays: 40))
        var s = state(items: [apps])
        let ref = Ref.task(apps.id)
        run(&s, DumpResult(ops: [.upsert("task", id: ref, ["doneMinutes": 400])], reply: "",
                           evidence: [DumpEvidence(what: "worked on applications", minutes: 400, task: ref, kind: "study")]))
        XCTAssertEqual(s.progress.count, 1, "the evidence is the same work as the minutes")
        run(&s, DumpResult(ops: [.upsert("task", id: ref, ["doneMinutes": 200])], reply: ""))
        XCTAssertEqual(s.items[0].completedMinutes, 200)
        XCTAssertEqual(s.progress.minutes(on: Fx.mon(0), calendar: cal), 200)
        run(&s, DumpResult(ops: [.upsert("task", id: ref, ["doneMinutes": 200])], reply: ""))
        XCTAssertEqual(s.progress.count, 2, "re-stating 200 changes nothing")
    }

    func testFactsGoToAboutMe() {
        var s = state()
        let rep = run(&s, DumpResult(ops: [], reply: "", facts: [
            AboutMeFact(section: "Stated", text: "CS club is Thursdays at lunch"),
            AboutMeFact(section: "Patterns", text: "Avoids essays"),
        ]))
        XCTAssertEqual(s.aboutMe[.stated].map(\.text), ["CS club is Thursdays at lunch"])
        XCTAssertTrue(s.aboutMe[.patterns].isEmpty, "the box can't write patterns")
        XCTAssertEqual(rep.problems.count, 1)
    }

    /// B1: voice start 13:02, two geofence starts, voice end 13:16. One 14-minute sample, learned the
    /// same day, and replaying the day (or learning it again tomorrow) doesn't add it twice.
    func testDuplicateStartsGiveOneSampleOnce() {
        let day = Fx.mon(0)
        func at(_ h: Int, _ m: Int, _ sec: Int = 0) -> Date { day.addingTimeInterval(Double(h * 3600 + m * 60 + sec)) }
        let markers = [
            TimelineEvent(at: at(13, 2), phrase: "leaving for school", activity: "to_school", category: .commute, phase: .start, source: .voice),
            TimelineEvent(at: at(13, 7, 58), phrase: "left home", activity: "to_school", category: .commute, phase: .start, source: .geofence),
            TimelineEvent(at: at(13, 8, 16), phrase: "left home", activity: "to_school", category: .commute, phase: .start, source: .geofence),
            TimelineEvent(at: at(13, 16), phrase: "at school", activity: "to_school", category: .commute, phase: .end, source: .voice),
        ]
        var routines = RoutineLearner.learn(day: markers, healthWake: nil, routines: Routine.defaults)
        XCTAssertEqual(routines.first { $0.id == "to_school" }?.samples, [14])
        routines = RoutineLearner.learn(day: markers, healthWake: nil, routines: routines)
        XCTAssertEqual(routines.first { $0.id == "to_school" }?.samples, [14])
    }

    func testEvidenceSchemaIsInTheBoxAnswer() throws {
        let json = #"{"ops":[],"reply":"ok","facts":[{"text":"Walks to school"}],"evidence":[{"what":"walk","start":"2026-11-16T08:02","end":"2026-11-16T08:16","kind":"travel"}]}"#
        let r = try XCTUnwrap(DumpResult.read(AIResponse(model: nil, text: json, usage: nil)))
        XCTAssertEqual(r.facts.first?.text, "Walks to school")
        XCTAssertEqual(r.evidence.first?.kind, "travel")
        XCTAssertNotNil(DumpResult.read(AIResponse(model: nil, text: #"{"ops":[],"reply":"","evidence":[{"what":"slept","minutes":400}]}"#, usage: nil)),
                        "evidence alone is an answer")
    }
}

final class MotionTests: XCTestCase {
    let cal = Fx.cal

    func samples(_ list: [(Int, Int, MotionKind)]) -> [MotionSample] {
        list.map { MotionSample(at: Fx.mon($0.0, $0.1), kind: $0.2, confidence: 2) }
    }

    /// A fixture of motion spans plus markers gives the expected segments, and a morning walk
    /// teaches to_school.
    func testSpansPaintSegmentsAndTeachTheWalk() {
        let recs = samples([(7, 0, .stationary), (8, 2, .walking), (8, 9, .walking), (8, 16, .stationary),
                            (12, 0, .walking), (12, 3, .stationary), (15, 5, .automotive), (15, 27, .stationary)])
        let spans = MotionTimeline.spans(recs, until: Fx.mon(18))
        let walk = spans.first { $0.kind == .walking }!
        XCTAssertEqual(walk.start, Fx.mon(8, 2))
        XCTAssertEqual(walk.end, Fx.mon(8, 16), "records of the same kind merge")
        // A check-in at 15:00 ("left school") is truth; the ride after it is painted by motion.
        let markers = [TimelineEvent(at: Fx.mon(15), phrase: "left school", activity: "from_school", category: .commute, phase: .start),
                       TimelineEvent(at: Fx.mon(15, 30), phrase: "home", activity: "from_school", category: .commute, phase: .end)]
        let segs = TimelineBuilder.segments(DayInputs(day: Fx.mon(12), events: markers, commitments: [Fx.school], routines: Routine.defaults,
                                                      outcomes: [], health: nil, screen: nil, prefs: Preferences(), motion: spans),
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
        // Rebuilt from the same records (ids kept), it isn't learned twice.
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

    /// B2: in_bed 00:59 + sleep end 07:25 is 6 h 26 for that night, and the planner's short-night
    /// logic uses it.
    func testCheckInsMeasureTheNight() {
        var s = DumpState(items: [], commitments: [Fx.school], exceptions: [], oneOffs: [], markers: [],
                          routines: Routine.defaults, moods: [], screen: [], prefs: Preferences())
        DumpApplier.apply(DumpResult(ops: [
            .upsert("marker", ["activity": "in_bed", "phase": "start", "at": "2026-11-16T00:59", "category": "free"]),
            .upsert("marker", ["activity": "sleep", "phase": "end", "at": "2026-11-16T07:25"]),
        ], reply: ""), to: &s, now: Fx.mon(12), calendar: cal)
        XCTAssertEqual(s.markers[0].activity, "sleep")
        XCTAssertEqual(s.markers[0].category, .sleep)
        let health = SleepEstimator.fill([HealthDay(day: Fx.mon(0), steps: 5000)], days: [Fx.mon(0)], markers: s.markers,
                                         motion: [], phoneUse: [], sleepNeedMinutes: 540, calendar: cal)
        XCTAssertEqual(health.first?.sleepMinutes, 386)
        XCTAssertEqual(health.first?.sleepSource, .checkIns)
        XCTAssertEqual(health.first?.steps, 5000)
        XCTAssertEqual(SleepSource.checkIns.label, "from your check-ins")
        let plan = Planner.plan(PlannerInput(now: Fx.mon(12), calendar: cal, items: [], commitments: [Fx.school], health: health))
        XCTAssertTrue(plan.warnings.contains { $0.message.hasPrefix("Short night (6h 26m)") }, "\(plan.warnings)")
    }

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
        // An assumed night is never stored as if it were measured.
        XCTAssertNil(SleepEstimator.fill([], days: [Fx.mon(0)], markers: [], motion: [], phoneUse: [], sleepNeedMinutes: 540,
                                         calendar: cal).first?.sleepMinutes)
    }
}
