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
