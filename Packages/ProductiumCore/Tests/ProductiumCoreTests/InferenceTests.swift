import XCTest
@testable import ProductiumCore

/// v1.2 N2–N6 on the `Fx` week: home during school, left early, a morning walk, a late-alarm wake, arriving at the gym,
/// a workout; answers and the learner.
final class InferenceTests: XCTestCase {
    let cal = Fx.cal
    let homeLoc = (49.25, -123.10), schoolLoc = (49.264, -123.17), gymLoc = (49.26, -123.246)

    /// Places named Home, School, Gym; two weeks of visits to school in school hours.
    func world() -> (PlaceBook, [PlaceVisit], [Entry]) {
        var book = PlaceBook()
        let home = Place(id: Planner.stableUUID("home"), name: "Home", latitude: homeLoc.0, longitude: homeLoc.1, named: .you, createdAt: Fx.mon(0, plusDays: -30))
        let school = Place(id: Planner.stableUUID("school"), name: "School", latitude: schoolLoc.0, longitude: schoolLoc.1, named: .entries, createdAt: Fx.mon(0, plusDays: -30))
        let gym = Place(id: Planner.stableUUID("gym"), name: "Gym", latitude: gymLoc.0, longitude: gymLoc.1, named: .you, createdAt: Fx.mon(0, plusDays: -30))
        book.places = [home, school, gym]
        var visits: [PlaceVisit] = []
        for d in -14 ..< 0 where (2...6).contains(cal.component(.weekday, from: Fx.mon(12, plusDays: d))) {
            visits.append(PlaceVisit(latitude: schoolLoc.0, longitude: schoolLoc.1, arrival: Fx.mon(8, 20, plusDays: d), departure: Fx.mon(15, 5, plusDays: d)))
        }
        var tt = Fx.timetable
        for i in tt.indices { tt[i].repeats?.from = Fx.mon(0, plusDays: -35) }
        return (book, visits, tt)
    }

    func x(_ now: Date, visits extra: [PlaceVisit] = [], motion: [MotionSpan] = [], steps: [StepBucket] = [], alarms: [AlarmStop] = [],
           workouts: [WorkoutSample] = [], entries more: [Entry] = [], learner: InferenceLearner = InferenceLearner()) -> InferenceInput {
        let (book, visits, tt) = world()
        let sig = Signals.make(visits: visits + extra, book: book, motion: motion, steps: steps, alarms: alarms, workouts: workouts)
        return InferenceInput(now: now, calendar: cal, signals: sig, entries: tt + more, book: book, learner: learner)
    }

    func testHomeDuringSchoolAsksAndNoSchoolSkipsTodaysSchool() {
        let home = PlaceVisit(latitude: homeLoc.0, longitude: homeLoc.1, arrival: Fx.mon(7), departure: nil)
        let input = x(Fx.mon(11, 20), visits: [home])
        let c = InferenceEngine.run(input).first { $0.kind == .contradiction }
        XCTAssertEqual(c?.question, "You're at home, but school's on until 3. What happened?")
        XCTAssertEqual(c?.answers, ["Sick", "No school today", "Skipped"])
        XCTAssertEqual(c?.band, .ask)
        XCTAssertEqual(InferenceAnswers.next(InferenceEngine.run(input))?.kind, .contradiction, "contradictions jump the queue")
        // N3: "No school today" removes today's School from the log and the plan works around nothing.
        var s = BoxState(entries: input.entries)
        let r = BoxApplier.apply(InferenceAnswers.ops(for: "No school today", c!, calendar: cal), to: &s, now: Fx.mon(11, 20), calendar: cal)
        XCTAssertTrue(r.problems.isEmpty, "\(r.problems)")
        let today = TimeLog.past(s.entries, in: Days.dayInterval(Fx.mon(12), cal), now: Fx.mon(23), book: s.dayRules, calendar: cal)
        XCTAssertFalse(today.contains { $0.category == CategoryTree.school })
        let essay = WorkItem(title: "Essay", kind: .essay, due: Fx.mon(23, plusDays: 1), estimateMinutes: 120)
        let plan = Planner.plan(Fx.input(now: Fx.mon(11, 20), items: [essay], entries: s.entries))
        XCTAssertTrue(plan.study(for: essay.id).contains { $0.start < Fx.mon(15) && cal.isDate($0.start, inSameDayAs: Fx.mon(12)) },
                      "the freed school hours can hold the essay")
        // Sick also logs the time at home.
        let sick = InferenceAnswers.ops(for: "Sick", c!, calendar: cal)
        XCTAssertEqual(sick.last?.fields.title, "Sick")
        XCTAssertTrue(InferenceAnswers.ops(for: "Something else", c!, calendar: cal).isEmpty)
    }

    func testLeftEarly() {
        let v = PlaceVisit(latitude: schoolLoc.0, longitude: schoolLoc.1, arrival: Fx.mon(8, 20), departure: Fx.mon(13, 40))
        let i = InferenceEngine.run(x(Fx.mon(14, 10), visits: [v])).first { $0.kind == .leftEarly }
        XCTAssertEqual(i?.question, "Left school at 1:40: done for the day?")
    }

    func testMorningWalkToSchool() {
        let walk = MotionSpan(start: Fx.mon(7, 55), end: Fx.mon(8, 18), kind: .walking, confidence: 2)
        let steps = [StepBucket(start: Fx.mon(7, 55), end: Fx.mon(8, 18), steps: 2400)]
        let arrive = PlaceVisit(latitude: schoolLoc.0, longitude: schoolLoc.1, arrival: Fx.mon(8, 20), departure: nil)
        let w = InferenceEngine.run(x(Fx.mon(9), visits: [arrive], motion: [walk], steps: steps)).first { $0.kind == .walk }
        XCTAssertEqual(w?.proposal.first?.fields.title, "Walk to school")
        XCTAssertEqual(w?.proposal.first?.fields.category, "Travel › Walk to school")
        XCTAssertEqual(w?.band, .auto, "104 steps a minute: sure enough to log by itself")
        // A slow, stepless walk is only a question.
        let slow = InferenceEngine.run(x(Fx.mon(19), motion: [MotionSpan(start: Fx.mon(18), end: Fx.mon(18, 12), kind: .walking, confidence: 1)],
                                         steps: [StepBucket(start: Fx.mon(18), end: Fx.mon(18, 12), steps: 500)]))
            .first { $0.kind == .walk }
        XCTAssertEqual(slow?.band, .hint)
    }

    func testLateAlarmWakeCutsThePlannedNight() {
        let planned = Entry(title: "Sleep", start: Fx.mon(22, 30, plusDays: -1), end: Fx.mon(6, 40), category: CategoryTree.sleep, alert: .wake, source: .plan)
        let stop = AlarmStop(ringAt: Fx.mon(6, 40), stoppedAt: Fx.mon(7, 2))
        XCTAssertEqual(stop.snoozeMinutes, 22)
        let w = InferenceEngine.run(x(Fx.mon(7, 30), alarms: [stop], entries: [planned])).first { $0.kind == .wake }
        XCTAssertEqual(w?.evidence, ["woke 7:02, alarm stopped, 22 min after it first rang"])
        XCTAssertEqual(w?.proposal.first?.fields.end, "2026-11-16 07:02")
        XCTAssertEqual(w?.band, .auto)
    }

    func testArrivalAtTheGymStartsVolleyball() {
        let (book, _, _) = world()
        let gym = book.places.first { $0.name == "Gym" }!
        let past = (1...5).map { d in Entry(title: "Volleyball", start: Fx.mon(16, plusDays: -d), end: Fx.mon(18, plusDays: -d),
                                             category: CategoryTree.extracurricular, placeId: gym.id, source: .you) }
        let v = PlaceVisit(latitude: gymLoc.0, longitude: gymLoc.1, arrival: Fx.mon(16, 2), departure: nil)
        let a = InferenceEngine.run(x(Fx.mon(16, 10), visits: [v], entries: past)).first { $0.kind == .arrival }
        XCTAssertEqual(a?.question, "At Gym: start Volleyball?")
        XCTAssertEqual(a?.band, .auto)
        XCTAssertEqual(a?.proposal.first?.verb, .start)
    }

    func testWorkoutBecomesAnEntry() {
        let w = InferenceEngine.run(x(Fx.mon(19), workouts: [WorkoutSample(start: Fx.mon(17), end: Fx.mon(17, 45), type: "Running")]))
            .first { $0.kind == .workout }
        XCTAssertEqual(w?.band, .auto)
        XCTAssertEqual(w?.proposal.first?.fields.category, "Work › Extracurricular › Running")
    }

    func testFiveYesesMoveAKindUpThreeNoesDown() {
        var l = InferenceLearner()
        XCTAssertEqual(l.band(l.adjusted(0.6, .walk)), .ask)
        for _ in 0..<5 { l.answered(.walk, yes: true) }
        XCTAssertEqual(l.band(l.adjusted(0.6, .walk)), .auto)
        var m = InferenceLearner()
        for _ in 0..<3 { m.answered(.arrival, yes: false) }
        XCTAssertEqual(m.band(m.adjusted(0.6, .arrival)), .hint)
        XCTAssertEqual(m.band(m.adjusted(0.85, .arrival)), .ask)
    }

    func testAskedOnceOnly() {
        let home = PlaceVisit(latitude: homeLoc.0, longitude: homeLoc.1, arrival: Fx.mon(7), departure: nil)
        var input = x(Fx.mon(11), visits: [home])
        let c = InferenceEngine.run(input).first { $0.kind == .contradiction }!
        input.done = [c.id]
        XCTAssertNil(InferenceEngine.run(input).first { $0.kind == .contradiction })
    }
}

final class ScrollEntryTests: XCTestCase {
    func testScrollSessionsBecomeSensorScrollingThatYourCorrectionsSurvive() {
        let cal = Fx.cal
        let s = ScrollSession(app: "TikTok", openedAt: Fx.mon(21), endedAt: Fx.mon(21, 40), endSource: .closed)
        let tiny = ScrollSession(app: "Instagram", openedAt: Fx.mon(22), endedAt: Fx.mon(22, 0, plusDays: 0).addingTimeInterval(30), endSource: .closed)
        var es: [Entry] = []
        let ids = EntryBuilder.scrolling([s, tiny], entries: &es, now: Fx.mon(23), since: Fx.mon(0))
        XCTAssertEqual(ids.count, 1, "under a minute isn't a session")
        XCTAssertEqual(es[0].category, CategoryTree.scrolling)
        XCTAssertEqual(es[0].source, .sensor)
        es[0].category = CategoryTree.free
        es[0].filedByYou = true
        EntryBuilder.scrolling([s], entries: &es, now: Fx.mon(23), since: Fx.mon(0))
        XCTAssertEqual(es.count, 1)
        XCTAssertEqual(es[0].category, CategoryTree.free, "your correction stays")
        // It outranks a planned session, so the session shows as not done.
        let planned = Entry(title: "Essay", start: Fx.mon(21), end: Fx.mon(21, 45), category: CategoryTree.studying, taskId: UUID(), source: .plan)
        let slices = TimeLog.past(es + [planned], in: DateInterval(start: Fx.mon(21), end: Fx.mon(22)), now: Fx.mon(23), calendar: cal)
        XCTAssertEqual(slices.first?.entry?.title, "TikTok")
    }
}
