import XCTest
@testable import ProductiumCore

// v1.2 B1: the time log, and what a day asked for vs what got done.
final class TimeLogTests: XCTestCase {
    let cal = Fx.cal

    func told(_ title: String, _ s: Date, _ e: Date?, cat: CategoryID = CategoryTree.free, task: UUID? = nil) -> Entry {
        Entry(title: title, start: s, end: e, category: cat, taskId: task, source: .you, createdAt: e ?? s)
    }

    func testStartClosesTheRunningEntry() {
        var log: [Entry] = []
        TimeLog.start(told("Shower", Fx.mon(21), nil), at: Fx.mon(21), entries: &log, calendar: cal)
        let r = TimeLog.start(told("Reading", Fx.mon(21, 20), nil), at: Fx.mon(21, 20), entries: &log, calendar: cal)
        XCTAssertEqual(log.filter(\.isRunning).map(\.title), ["Reading"])
        XCTAssertEqual(log.first { $0.title == "Shower" }?.end, Fx.mon(21, 20))
        XCTAssertTrue(r.lines.contains { $0.hasPrefix("Stopped Shower") })
        TimeLog.stop(at: Fx.mon(22), entries: &log, calendar: cal)
        XCTAssertNil(TimeLog.running(log))
    }

    func testYourEntriesTrimAndSplitOlderOnes() {
        var log = [told("Homework", Fx.mon(15), Fx.mon(18))]
        let r = TimeLog.insert(told("Volleyball", Fx.mon(16), Fx.mon(17)), entries: &log, calendar: cal)
        let hw = log.filter { $0.title == "Homework" }.sorted { $0.start < $1.start }
        XCTAssertEqual(hw.map(\.start), [Fx.mon(15), Fx.mon(17)])
        XCTAssertEqual(hw.map(\.end), [Fx.mon(16), Fx.mon(18)])
        XCTAssertTrue(r.lines.first?.hasPrefix("Trimmed Homework to 15:00–16:00 and 17:00–18:00") ?? false, r.lines.description)
    }

    func testFocusIsAskedOnceForFinishedWork() {
        var hw = told("Essay", Fx.mon(16), Fx.mon(16, 45), cat: CategoryTree.studying)
        let walk = told("Walk", Fx.mon(16, 45), Fx.mon(17), cat: CategoryTree.travel)
        XCTAssertEqual(TimeLog.unratedWork([hw, walk], tree: CategoryTree(), now: Fx.mon(17, 30))?.title, "Essay")
        hw.focus = 3
        XCTAssertNil(TimeLog.unratedWork([hw, walk], tree: CategoryTree(), now: Fx.mon(17, 30)))
        XCTAssertEqual(TimeLog.focusMinutes([hw], in: Days.dayInterval(Fx.mon(12), cal)), [3: 45])
    }

    func testFocusStatsByPartOfDay() {
        var morning = told("Math", Fx.mon(9), Fx.mon(10), cat: CategoryTree.studying)
        var evening = told("Essay", Fx.mon(19), Fx.mon(20, 30), cat: CategoryTree.studying)
        morning.focus = 3
        evening.focus = 1
        let f = TimeLog.focusStats([morning, evening], in: Days.dayInterval(Fx.mon(12), cal), calendar: cal)
        XCTAssertEqual(f.total, 150)
        XCTAssertEqual(f.focused, 60)
        XCTAssertEqual(f.best, "morning")
        XCTAssertEqual(f.line(days: 14), "Focus ratings (14 days): 2h 30m rated, 40% normal or very; morning 100% of 1h, evening 0% of 1h 30m")
        XCTAssertNil(TimeLog.focusStats([], in: Days.dayInterval(Fx.mon(12), cal), calendar: cal).line(days: 14))
    }

    func testTrackedWalkReplacesThePlannedOne() {
        let planned = Entry(title: "Walk home", start: Fx.mon(15), end: Fx.mon(15, 20), category: CategoryTree.travel, source: .plan)
        let ready = Entry(title: "Get ready", start: Fx.mon(7), end: Fx.mon(7, 40), category: CategoryTree.gettingReady, source: .plan)
        let walked = told("Walking", Fx.mon(15, 36), Fx.mon(16, 17), cat: "travel.walking")
        let day = Days.on(Fx.mon(12), [planned, ready, walked], now: Fx.mon(23), calendar: cal)
        XCTAssertEqual(day.map(\.title), ["Get ready", "Walking"])
        let far = told("Walking", Fx.mon(18), Fx.mon(18, 30), cat: CategoryTree.travel)
        XCTAssertEqual(Days.on(Fx.mon(12), [planned, far], now: Fx.mon(23), calendar: cal).count, 2, "a walk hours later is another walk")
        let blip = told("Walking", Fx.mon(15, 5), Fx.mon(15, 6), cat: CategoryTree.travel)
        XCTAssertEqual(Days.on(Fx.mon(12), [planned, blip], now: Fx.mon(23), calendar: cal).count, 2, "a mistaken tap doesn't count")
        let lunch = told("Homework", Fx.mon(15), Fx.mon(15, 30), cat: CategoryTree.studying)
        XCTAssertEqual(Days.on(Fx.mon(12), [planned, lunch], now: Fx.mon(23), calendar: cal).count, 2)
    }

    func testPastResolvesByRankWithUntrackedGaps() {
        let math = Entry(title: "Math", start: Fx.mon(9), end: Fx.mon(10, 15), category: CategoryTree.school,
                         repeats: .weekly([2, 4, 6]), source: .you, createdAt: Fx.mon(7))
        let doctor = told("Doctor", Fx.mon(9, 30), Fx.mon(11), cat: CategoryTree.other)
        let walk = Entry(title: "Walk", start: Fx.mon(10, 45), end: Fx.mon(11, 30), category: CategoryTree.travel, source: .sensor)
        let session = Entry(title: "Essay", start: Fx.mon(12), end: Fx.mon(13), category: CategoryTree.studying,
                            taskId: UUID(), source: .plan)
        let s = TimeLog.past([math, doctor, walk, session], in: DateInterval(start: Fx.mon(9), end: Fx.mon(14)), now: Fx.mon(23),
                             calendar: cal)
        XCTAssertEqual(s.map(\.category), [CategoryTree.school, CategoryTree.other, CategoryTree.travel, CategoryTree.untracked])
        XCTAssertEqual(s.map(\.minutes), [30, 90, 30, 150], "the planned essay that wasn't tracked is Untracked")
        XCTAssertEqual(s.map(\.assumed), [true, false, true, false])
        XCTAssertEqual(TimeLog.untracked(s, atLeast: 30).count, 1)
        XCTAssertEqual(TimeLog.assumed(s).map(\.title), ["Math", "Walk"])
        XCTAssertEqual(TimeLog.totals(s).values.reduce(0, +), 300, "every minute counted once")
        XCTAssertTrue(TimeLog.past([math], in: DateInterval(start: Fx.mon(9), end: Fx.mon(14)), now: Fx.mon(8), calendar: cal).isEmpty,
                      "nothing in the future")
    }

    func testSplit() {
        var log = [told("Study", Fx.mon(15), Fx.mon(17))]
        XCTAssertNotNil(TimeLog.split(log[0].id, at: Fx.mon(16), entries: &log))
        XCTAssertEqual(log.map { $0.minutes() }, [60, 60])
    }

    // MARK: Accountability

    func testDifferentOrderStillMeetsTheDay() {
        let reading = WorkItem(title: "Reading", kind: .reading, due: Fx.mon(20, plusDays: 3))
        let essay = WorkItem(title: "Essay", kind: .essay, due: Fx.mon(20, plusDays: 2))
        // Planned: reading 45 + essay 45. Did: essay 90, at different times than planned.
        let log = [told("Essay", Fx.mon(15), Fx.mon(16), cat: CategoryTree.studying, task: essay.id),
                   told("Essay", Fx.mon(20), Fx.mon(20, 30), cat: CategoryTree.studying, task: essay.id)]
        let a = Accountability.day(Fx.mon(0), asked: [reading.id: 45, essay.id: 45], entries: log, items: [reading, essay],
                                   now: Fx.mon(23, 30), calendar: cal)
        XCTAssertEqual(a.asked, 90)
        XCTAssertEqual(a.did, 90)
        XCTAssertTrue(a.met)
        XCTAssertTrue(a.behind.isEmpty, "not punished for the order")
    }

    func testShortDayNamesWhatWasBehindAndDeferralIsNotMissed() {
        var reading = WorkItem(title: "Reading", kind: .reading, due: Fx.mon(20, plusDays: 3))
        var essay = WorkItem(title: "Essay", kind: .essay, due: Fx.mon(20, plusDays: 2))
        var brag = WorkItem(title: "Brag sheet", kind: .application, due: Fx.mon(23, 59))
        brag.isDone = true
        brag.doneAt = Fx.mon(22)
        let log = [told("Brag", Fx.mon(21, 50), Fx.mon(22), cat: CategoryTree.studying, task: brag.id),
                   told("Essay", Fx.mon(15), Fx.mon(15, 20), cat: CategoryTree.studying, task: essay.id)]
        essay.notBefore = nil
        reading.notBefore = Fx.mon(0, plusDays: 1)   // "move reading to tomorrow"
        let a = Accountability.day(Fx.mon(0), asked: [reading.id: 45, essay.id: 60, brag.id: 45], entries: log,
                                   items: [reading, essay, brag], now: Fx.mon(23, 30), calendar: cal)
        XCTAssertEqual(a.deferred, 45)
        XCTAssertEqual(a.asked, 70, "essay 60 + brag sheet capped at the 10 it took")
        XCTAssertEqual(a.short, 40)
        XCTAssertEqual(a.behind, [essay.id])
    }

    func testRulesLimitsNewerWinsPerField() {
        let ev = DayRuleEvaluator(calendar: cal)
        let a = Rule(text: "Exam week: 45 min blocks, half the work", from: Fx.mon(0), until: Fx.mon(0, plusDays: 4),
                     limits: PlannerLimits(capacityFactor: 0.5, maxBlockMinutes: 45), createdAt: Fx.mon(8))
        let b = Rule(text: "Phone taken at 10 on school nights", days: .weekdays([1, 2, 3, 4, 5]),
                     limits: PlannerLimits(maxBlockMinutes: 30, noStudyAfter: TimeOfDay(21, 45)), createdAt: Fx.mon(9))
        let mon = Rules.limits([b, a], on: Fx.mon(0), ev)
        XCTAssertEqual(mon.capacityFactor, 0.5)
        XCTAssertEqual(mon.maxBlockMinutes, 30)
        XCTAssertTrue(Rules.limits([a, b], on: Fx.mon(0, plusDays: 5), ev).isEmpty)
    }

    func testTelemetryIsBounded() {
        var t = Telemetry()
        for i in 0..<(Telemetry.maxEvents + 1100) { t.record(.planner, "run", at: Fx.mon(0).addingTimeInterval(Double(i))) }
        XCTAssertLessThanOrEqual(t.events.count, Telemetry.maxEvents + 1000)
        t.prune(now: Fx.mon(0, plusDays: Telemetry.maxAgeDays + 5))
        XCTAssertTrue(t.events.isEmpty)
        t.record(.error, "health_fetch", level: .error, at: Fx.mon(9), ["error": String(repeating: "x", count: 5000)])
        XCTAssertEqual(t.events[0].detail["error"]?.count, Telemetry.maxValueLength)
        var s = AppState()
        s.telemetry = t
        let d = Diagnostics.snapshot(s, now: Fx.mon(10), calendar: cal)
        XCTAssertTrue(d["lastError"]?.hasPrefix("error.health_fetch") ?? false)
        XCTAssertNotNil(d["coverage.2026-11-16"])
    }

    func testDeadlinesMissedOnlyWhenTheDuePasses() {
        var brag = WorkItem(title: "Brag sheet", kind: .application, due: Fx.mon(23, 59))
        let essay = WorkItem(title: "Essay", kind: .essay, due: Fx.mon(23, 59))
        var claim = WorkItem(title: "Claim", kind: .assignment, due: Fx.mon(17))
        claim.isDone = true
        claim.doneAt = Fx.mon(16)
        brag.due = Fx.mon(23, 59, plusDays: 1)   // "can be due tomorrow": moved, not missed
        let a = Accountability.day(Fx.mon(0), asked: [:], entries: [], items: [brag, essay, claim], now: Fx.mon(0, plusDays: 1),
                                   calendar: cal)
        XCTAssertEqual(a.deadlinesMet, [claim.id])
        XCTAssertEqual(a.deadlinesMissed, [essay.id])
        let early = Accountability.day(Fx.mon(0), asked: [:], entries: [], items: [essay], now: Fx.mon(20), calendar: cal)
        XCTAssertTrue(early.deadlinesMissed.isEmpty, "not missed before the due time")
    }

    func testDayScore() {
        let essay = WorkItem(title: "Essay", kind: .essay, due: Fx.mon(20, plusDays: 2))
        var quiz = WorkItem(title: "Quiz", kind: .quiz, due: Fx.mon(12))
        quiz.isDone = true
        quiz.doneAt = Fx.mon(11)
        let sleep = Entry(title: "Sleep", start: Fx.mon(0), end: Fx.mon(7), category: CategoryTree.sleep, source: .health)
        let school = Entry(title: "School", start: Fx.mon(8), end: Fx.mon(15), category: CategoryTree.school, source: .you,
                           createdAt: Fx.mon(7))
        let study = told("Essay", Fx.mon(15), Fx.mon(16), cat: CategoryTree.studying, task: essay.id)
        let scroll = told("TikTok", Fx.mon(16), Fx.mon(17), cat: CategoryTree.scrolling)
        let night = Entry(title: "Sleep", start: Fx.mon(22), end: Fx.mon(7, plusDays: 1), category: CategoryTree.sleep, source: .health)
        let s = DayScore.make(Fx.mon(0), asked: [essay.id: 90], entries: [sleep, school, study, scroll, night], items: [essay, quiz],
                              tree: CategoryTree(), now: Fx.mon(0, plusDays: 1), calendar: cal)
        XCTAssertEqual(s.wakingMinutes, 15 * 60)
        XCTAssertEqual(s.untrackedMinutes, 6 * 60, "7–8 and 17–22")
        XCTAssertEqual(s.workMinutes, 60)
        XCTAssertEqual(s.deadlinesMet, 1)
        XCTAssertEqual(s.scrollingMinutes, 60)
        // 30 × 9/15 + 40 × 60/90 + 30 − 10 = 18 + 26.7 + 30 − 10
        XCTAssertEqual(s.score, 65)
    }

    func testSwipeConfirmsAMorning() {
        let math = Entry(title: "Math", start: Fx.mon(8, 26), end: Fx.mon(9, 38), category: CategoryTree.school,
                         repeats: .weekly([2, 3, 4, 5, 6]), source: .you, createdAt: Fx.mon(7))
        let spare = Entry(title: "Spare", start: Fx.mon(9, 38), end: Fx.mon(10, 58), category: CategoryTree.school,
                          repeats: .weekly([2, 3, 4, 5, 6]), open: true, source: .you, createdAt: Fx.mon(7))
        let walk = Entry(title: "Walk", start: Fx.mon(8), end: Fx.mon(8, 20), category: CategoryTree.travel, source: .sensor)
        var es = [math, spare, walk]
        let refs = Days.confirm(in: DateInterval(start: Fx.mon(7), end: Fx.mon(12)), entries: &es, now: Fx.mon(10), calendar: cal)
        XCTAssertEqual(refs.count, 3, "only up to now: the spare had started")
        let after = TimeLog.past(es, in: DateInterval(start: Fx.mon(7), end: Fx.mon(10)), now: Fx.mon(10), calendar: cal)
        XCTAssertTrue(TimeLog.assumed(after).isEmpty)
        XCTAssertNil(es[0].marks["2026-11-17"], "only what's already happened is confirmed")
    }
}
