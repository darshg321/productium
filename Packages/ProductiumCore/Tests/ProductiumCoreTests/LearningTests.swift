import XCTest
@testable import ProductiumCore

final class LearningTests: XCTestCase {
    let cal = Fx.cal

    func testMarkerParsing() {
        let c = [Fx.school, Fx.soccer]
        func p(_ s: String, _ h: Int = 8) -> [CheckIn] { MarkerParser.parse(s, at: Fx.mon(h), commitments: c, calendar: cal) }
        XCTAssertEqual(p("left home").first?.activity, "to_school")
        XCTAssertEqual(p("At school").map(\.activity), ["to_school", "school"])
        XCTAssertEqual(p("finished math class", 10).first?.phase, .end)
        XCTAssertEqual(p("finished math class", 10).first?.category, .school)
        XCTAssertEqual(p("starting soccer", 16).first?.category, .activities)
        XCTAssertEqual(p("finished homework", 19).first?.activity, "study")
        XCTAssertEqual(p("home", 16).first?.activity, "from_school")
        XCTAssertTrue(p("lol idk").isEmpty)
    }

    func testRoutinesComeFromTheLog() {
        // Mon–Thu: told a 50-minute get-ready, a walk to school ending before 8:30, and the trip home.
        var es = Fx.timetable
        for d in 0..<4 {
            es.append(Entry(title: "Getting ready", start: Fx.mon(7, 10, plusDays: d), end: Fx.mon(8, 0, plusDays: d),
                            category: CategoryTree.gettingReady, source: .you, createdAt: Fx.mon(8, 0, plusDays: d)))
            es.append(Entry(title: "Walk to school", start: Fx.mon(8, 5, plusDays: d), end: Fx.mon(8, 27 + d, plusDays: d),
                            category: CategoryTree.travel, source: .sensor, createdAt: Fx.mon(9, plusDays: d)))
            es.append(Entry(title: "Bus home", start: Fx.mon(15, 5, plusDays: d), end: Fx.mon(15, 25, plusDays: d),
                            category: CategoryTree.travel, source: .you, createdAt: Fx.mon(16, plusDays: d)))
        }
        // A trip on Saturday doesn't count: there's no school.
        es.append(Entry(title: "Bus", start: Fx.mon(8, 0, plusDays: 5), end: Fx.mon(9, 0, plusDays: 5), category: CategoryTree.travel,
                        source: .you, createdAt: Fx.mon(10, plusDays: 5)))
        let r = Routine.fromLog(es, tree: CategoryTree(), now: Fx.mon(12, plusDays: 6), calendar: cal)
        func get(_ id: String) -> Routine { r.first { $0.id == id }! }
        XCTAssertEqual(get("to_school").samples, [22, 23, 24, 25])
        XCTAssertEqual(get("get_ready").minutes, 50)
        XCTAssertEqual(get("from_school").samples, [20, 20, 20, 20])
        var c = get("to_school")
        XCTAssertFalse(c.observe(150), "forgot to stop it until lunch")
        // Planned routines are a guess, not a sample.
        let planned = Entry(title: "To school", start: Fx.mon(8, 0, plusDays: 4), end: Fx.mon(8, 30, plusDays: 4),
                            category: CategoryTree.travel, source: .plan)
        XCTAssertEqual(Routine.fromLog(es + [planned], tree: CategoryTree(), now: Fx.mon(12, plusDays: 6), calendar: cal)
            .first { $0.id == "to_school" }!.samples.count, 4)
    }

    func testYourOwnRoutineEntryReplacesThePlannersOne() {
        let ready = Entry(title: "Get ready", start: Fx.mon(7), end: Fx.mon(7, 30), category: CategoryTree.gettingReady,
                          repeats: .weekly([2, 3, 4, 5, 6]), source: .you)
        let r = Routine.fromLog(Fx.timetable + [ready], tree: CategoryTree(), now: Fx.mon(12), calendar: cal)
        XCTAssertFalse(r.first { $0.id == "get_ready" }!.enabled)
        let plan = Planner.plan(Fx.input(now: Fx.mon(5), items: [], entries: Fx.timetable + [ready], routines: r))
        XCTAssertFalse(plan.blocks.contains { $0.kind == .routine && $0.title == "Get ready" })
        XCTAssertTrue(plan.blocks.contains { $0.kind == .routine && $0.title == "To school" })
    }

    func testOwnDinnerEntryReplacesTheLearnedDinner() {
        let dinner = Entry(title: "Dinner", start: Fx.mon(19, 30), end: Fx.mon(20), category: CategoryTree.meals,
                           repeats: .weekly(Set(1...7)), source: .you)
        let plan = Planner.plan(Fx.input(now: Fx.mon(5), items: [], entries: Fx.timetable + [dinner]))
        XCTAssertFalse(plan.blocks.contains { $0.kind == .meal && cal.isDate($0.start, inSameDayAs: Fx.mon(12)) },
                       "your 7:30 dinner is the dinner; no second one at 6:30")
    }

    func testTimelineInfersRoutinesWithoutCheckins() {
        var routines = Routine.defaults
        routines[1].samples = [25, 25, 25]
        let d = DayInputs(day: Fx.mon(12), entries: Fx.timetable, routines: routines,
                          health: HealthDay(day: Fx.mon(0), sleepMinutes: 500, bedtime: Fx.mon(22, 30, plusDays: -1), wake: Fx.mon(6, 50)),
                          screen: ScreenDay(day: Fx.mon(0), distractingMinutes: 90), prefs: Preferences())
        let segs = TimelineBuilder.segments(d, calendar: cal)
        XCTAssertTrue(segs.contains { $0.label == "To school" && $0.minutes == 25 && $0.inferred })
        let totals = TimelineBuilder.totals(segs, screen: d.screen)
        XCTAssertEqual(totals[.school], 390)
        XCTAssertEqual(totals[.screen], 90)
        XCTAssertEqual(totals.values.reduce(0, +), 1440)
    }

    func testCheckinsOverrideSchedule() {
        let evs = MarkerParser.parse("left school", at: Fx.mon(15, 0), commitments: [Fx.school], calendar: cal)
            + MarkerParser.parse("home", at: Fx.mon(15, 40), commitments: [Fx.school], calendar: cal)
        let d = DayInputs(day: Fx.mon(12), entries: Fx.log(evs), routines: Routine.defaults, health: nil, screen: nil, prefs: Preferences())
        let segs = TimelineBuilder.segments(d, calendar: cal)
        let trip = segs.first { $0.label == "Home from school" }!
        XCTAssertEqual(trip.minutes, 40)
        XCTAssertFalse(trip.inferred)
    }

    func testEstimateCalibration() {
        var m = LearnedModel()
        XCTAssertEqual(m.estimateFactor(for: .essay), 1.3, accuracy: 0.001)
        for _ in 0..<10 { m.recordCompletion(kind: .essay, estimated: 60, actual: 120) }
        XCTAssertGreaterThan(m.estimateFactor(for: .essay), 1.8)
        XCTAssertEqual(m.estimateFactor(for: .quiz), 1.3, accuracy: 0.001)
    }

    func testChronotypeFromSleepMidpoint() {
        XCTAssertEqual(LearnedModel.chronotype(fromFreeDaySleepMidpointsHours: [6, 5.8, 6.2]), .late)
        XCTAssertEqual(LearnedModel.chronotype(fromFreeDaySleepMidpointsHours: [3, 3.2, 3.1]), .early)
        XCTAssertNil(LearnedModel.chronotype(fromFreeDaySleepMidpointsHours: [5]))
    }

    func testScreenTaper() {
        var t = ScreenTaper()
        var days = (1...7).map { ScreenDay(day: Fx.mon(0, plusDays: -$0), distractingMinutes: 180) }
        XCTAssertNotNil(t.update(days: days, now: Fx.mon(9), calendar: cal))
        XCTAssertEqual(t.targetMinutes, 180)
        days += (0..<7).map { ScreenDay(day: Fx.mon(0, plusDays: $0), distractingMinutes: 150) }
        t.update(days: days, now: Fx.mon(9, plusDays: 7), calendar: cal)
        XCTAssertEqual(t.targetMinutes, 153)
        days += (7..<14).map { ScreenDay(day: Fx.mon(0, plusDays: $0), distractingMinutes: 300) }
        t.update(days: days, now: Fx.mon(9, plusDays: 14), calendar: cal)
        XCTAssertGreaterThanOrEqual(t.targetMinutes!, 153)
    }


    func testExportsAndBackupRoundTrip() throws {
        let csv = Exporter.csv(["a", "b"], [["x,y", "say \"hi\""]])
        XCTAssertEqual(csv, "a,b\n\"x,y\",\"say \"\"hi\"\"\"\n")
        let plan = Planner.plan(Fx.input(now: Fx.mon(7), items: [WorkItem(title: "HW, part 1", kind: .assignment, due: Fx.mon(23, plusDays: 2))]))
        let ics = Exporter.ics(plan)
        XCTAssertTrue(ics.contains("BEGIN:VEVENT") && ics.contains("HW\\, part 1"))
        let totals = DayTotals(day: Fx.mon(0), minutes: [.study: 30], plannedStudy: 40, doneStudy: 30, mood: 4, sleep: 500, screen: 60, screenTarget: 90, steps: 8000)
        let json = String(data: try Exporter.json(totals), encoding: .utf8)!
        XCTAssertTrue(json.contains("\"study\" : 30"), json)
    }

    func testAIMapping() {
        let tz = TimeZone(identifier: "America/Vancouver")!
        let i = AIMapper.item(ParsedItem(title: "Math test", kind: "test", subject: "Math", due: "2026-11-20T08:00:00",
                                         estimateMinutes: 120, importance: 4, difficulty: 3, topics: ["ch 4"]), timeZone: tz)!
        XCTAssertEqual(i.due, Fx.mon(8, 0, plusDays: 4))
    }

}

final class StabilityTests: XCTestCase {
    func testBlockIdsStableAcrossReplans() {
        let hw = WorkItem(title: "HW", kind: .assignment, due: Fx.mon(23, 0, plusDays: 2), estimateMinutes: 60)
        let a = Planner.plan(Fx.input(now: Fx.mon(7), items: [hw]))
        let b = Planner.plan(Fx.input(now: Fx.mon(7), items: [hw]))
        XCTAssertEqual(a.study(for: hw.id).map(\.id), b.study(for: hw.id).map(\.id))
    }

    func testPreferencesDecodeWithMissingKeys() throws {
        let p = try JSONDecoder().decode(Preferences.self, from: Data(#"{"sleepNeedMinutes": 500}"#.utf8))
        XCTAssertEqual(p.sleepNeedMinutes, 500)
        XCTAssertEqual(p.windDownMinutes, Preferences().windDownMinutes)
    }
}


final class StatedRoutineTests: XCTestCase {
    func testStatedIsThePriorUntilThreeSamplesThenTheMedianTakesOver() {
        var r = Routine(id: "to_school", name: "To school", anchor: .beforeFirstCommitment, category: .commute, defaultMinutes: 20)
        XCTAssertEqual(r.confidence, .assumed)
        r.stated = 25
        XCTAssertEqual(r.minutes, 25)
        XCTAssertEqual(r.confidence, .stated)
        r.observe(14)
        XCTAssertEqual(r.minutes, 25, "one real sample doesn't override what you said")
        r.observe(14); r.observe(15)
        XCTAssertEqual(r.minutes, 14)
        XCTAssertEqual(r.confidence, .learned)
        XCTAssertEqual(r.disagreement, "You said 25 min, it's been 14 min lately")
    }

    func testStatedAndLearnedAgreeIsConfirmed() {
        var r = Routine(id: "get_ready", name: "Get ready", anchor: .afterWake, category: .routine, defaultMinutes: 40, samples: [34, 35, 36])
        XCTAssertEqual(r.confidence, .learned)
        r.stated = 35
        XCTAssertEqual(r.confidence, .confirmed)
        XCTAssertNil(r.disagreement)
    }

}

final class MarkerMergeTests: XCTestCase {


}
