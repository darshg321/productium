import XCTest
@testable import ProductiumCore

final class LearningTests: XCTestCase {
    let cal = Fx.cal

    func testMarkerParsing() {
        let c = [Fx.school, Fx.soccer]
        func p(_ s: String, _ h: Int = 8) -> [TimelineEvent] { MarkerParser.parse(s, at: Fx.mon(h), commitments: c, calendar: cal) }
        XCTAssertEqual(p("left home").first?.activity, "to_school")
        XCTAssertEqual(p("At school").map(\.activity), ["to_school", "school"])
        XCTAssertEqual(p("finished math class", 10).first?.phase, .end)
        XCTAssertEqual(p("finished math class", 10).first?.category, .school)
        XCTAssertEqual(p("starting soccer", 16).first?.category, .activities)
        XCTAssertEqual(p("finished homework", 19).first?.activity, "study")
        XCTAssertEqual(p("home", 16).first?.activity, "from_school")
        XCTAssertTrue(p("lol idk").isEmpty)
    }

    func testRoutineLearnsCommuteAndRejectsOutliers() {
        var routines = Routine.defaults
        for d in 0..<4 {
            let evs = MarkerParser.parse("left home", at: Fx.mon(8, 0, plusDays: d), commitments: [Fx.school], calendar: cal)
                + MarkerParser.parse("at school", at: Fx.mon(8, 22 + d, plusDays: d), commitments: [Fx.school], calendar: cal)
            routines = RoutineLearner.learn(day: evs, healthWake: Fx.mon(7, 10, plusDays: d), routines: routines)
        }
        let commute = routines.first { $0.id == "to_school" }!
        XCTAssertEqual(commute.samples, [22, 23, 24, 25])
        XCTAssertEqual(routines.first { $0.id == "get_ready" }!.minutes, 50)
        var r = commute
        XCTAssertFalse(r.observe(150), "forgot to tap until lunch")
    }

    func testTimelineInfersRoutinesWithoutCheckins() {
        var routines = Routine.defaults
        routines[1].samples = [25, 25, 25]
        let d = DayInputs(day: Fx.mon(12), events: [], entries: Fx.timetable, routines: routines,
                          outcomes: [], health: HealthDay(day: Fx.mon(0), sleepMinutes: 500, bedtime: Fx.mon(22, 30, plusDays: -1), wake: Fx.mon(6, 50)),
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
        let d = DayInputs(day: Fx.mon(12), events: evs, entries: Fx.schoolEntries, routines: Routine.defaults, outcomes: [],
                          health: nil, screen: nil, prefs: Preferences())
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

    func testLeitner() {
        var c = Flashcard(front: "Q", back: "A")
        c = Leitner.review(c, correct: true, now: Fx.mon(9))
        XCTAssertEqual(c.box, 2)
        XCTAssertEqual(c.due, Fx.mon(9, plusDays: 2))
        c = Leitner.review(c, correct: false, now: Fx.mon(9))
        XCTAssertEqual(c.box, 1)
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

    func testAIMapping() throws {
        let tz = TimeZone(identifier: "America/Vancouver")!
        let i = AIMapper.item(ParsedItem(title: "Math test", kind: "test", subject: "Math", due: "2026-11-20T08:00:00",
                                         estimateMinutes: 120, importance: 4, difficulty: 3, topics: ["ch 4"]), timeZone: tz)!
        XCTAssertEqual(i.due, Fx.mon(8, 0, plusDays: 4))
        XCTAssertNotNil(AIMapper.commitment(ParsedCommitment(title: "Soccer", kind: "extracurricular", weekdays: [2, 4], start: "16:00", end: "17:30")))
        XCTAssertNil(AIMapper.commitment(ParsedCommitment(title: "Bad", kind: "x", weekdays: [9], start: "16:00", end: "17:30")))
        let raw = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"items":[],"commitments":[],"markers":[],"completedTitles":["HW"],"reply":"ok"}"#.utf8))
        XCTAssertEqual(try raw.decode(QuickAddResult.self).completedTitles, ["HW"])
    }

    func testSuggestionStopsAfterLearning() {
        var routines = Routine.defaults
        XCTAssertEqual(CheckInSuggester.suggestion(now: Fx.mon(7, 50), todaysEvents: [], commitments: [Fx.school], routines: routines, calendar: cal), "Left home")
        routines[1].samples = [20, 20, 20, 20, 20]
        XCTAssertNil(CheckInSuggester.suggestion(now: Fx.mon(7, 50), todaysEvents: [], commitments: [Fx.school], routines: routines, calendar: cal))
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

final class MarkerCategoryTests: XCTestCase {
    func testCategoryComesFromTheNameNotTheModelsDefault() {
        let c = [Fx.school, Fx.soccer]
        XCTAssertEqual(MarkerCategory.infer(activity: "to_school", commitments: c, model: .free), .commute)
        XCTAssertEqual(MarkerCategory.infer(activity: "from_school", commitments: c), .commute)
        XCTAssertEqual(MarkerCategory.infer(activity: "in_bed", commitments: c, model: .free), .sleep)
        XCTAssertEqual(MarkerCategory.infer(activity: "wake", commitments: c, model: .free), .sleep)
        XCTAssertEqual(MarkerCategory.infer(activity: "get_ready", commitments: c, model: .free), .routine)
        XCTAssertEqual(MarkerCategory.infer(activity: "soccer", commitments: c, model: .free), .activities)
        XCTAssertEqual(MarkerCategory.infer(activity: "homework", commitments: c, model: .free), .study)
        XCTAssertEqual(MarkerCategory.infer(activity: "gaming", commitments: c, model: .screen), .screen)
        XCTAssertEqual(MarkerCategory.infer(activity: "gaming", commitments: c), .free)
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
    func testTheThreeLeftHomesBecomeOneAndTeachTheWalkOnce() {
        let day = Fx.mon(0)
        func at(_ h: Int, _ m: Int, _ sec: Int = 0) -> Date { day.addingTimeInterval(Double(h * 3600 + m * 60 + sec)) }
        func mk(_ t: Date, _ p: MarkerPhase, _ src: MarkerSource) -> TimelineEvent {
            TimelineEvent(at: t, phrase: "x", activity: "to_school", category: .commute, phase: p, source: src)
        }
        var log: [TimelineEvent] = []
        MarkerLog.add([mk(at(13, 4, 58), .start, .geofence)], to: &log)
        MarkerLog.add([mk(at(13, 5, 16), .start, .geofence)], to: &log)
        MarkerLog.add([mk(at(13, 2), .start, .voice)], to: &log)
        MarkerLog.add([mk(at(13, 16), .end, .voice)], to: &log)
        XCTAssertEqual(log.count, 2)
        let start = log.first { $0.phase == .start }!
        XCTAssertEqual(start.at, at(13, 2), "the earliest time is kept")
        XCTAssertEqual(start.source, .voice, "the best source is kept")
        var routines = RoutineLearner.learn(day: log, healthWake: nil, routines: Routine.defaults)
        routines = RoutineLearner.learn(day: log, healthWake: nil, routines: routines)
        XCTAssertEqual(routines.first { $0.id == "to_school" }?.samples, [14])
    }

    func testAMarkerFarFromTheFirstIsKept() {
        var log: [TimelineEvent] = []
        let a = TimelineEvent(at: Fx.mon(8), phrase: "x", activity: "study", category: .study, phase: .start)
        let b = TimelineEvent(at: Fx.mon(8, 10), phrase: "x", activity: "study", category: .study, phase: .start)
        MarkerLog.add([a, b], to: &log)
        XCTAssertEqual(log.count, 2)
        XCTAssertEqual(MarkerLog.merged([b, a, a]).count, 2)
    }
}
