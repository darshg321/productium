import XCTest
@testable import ProductiumCore

/// A four-week log: school days with homework after school and some scrolling, weekends with gaming.
enum Week4 {
    static let cal = Fx.cal
    /// School Mon–Fri 8:30–15:00, running since five weeks before the test's Monday.
    static let timetable: [Entry] = Fx.timetable.filter { $0.title == "School" }.map { e in
        var x = e
        x.repeats?.from = Fx.mon(0, plusDays: -35)
        return x
    }

    static func e(_ t: String, _ c: CategoryID, _ d: Int, _ h: Int, _ m: Int, _ h2: Int, _ m2: Int, src: EntrySource = .you) -> Entry {
        let s = Fx.mon(h, m, plusDays: d), end = Fx.mon(h2, m2, plusDays: d)
        return Entry(title: t, start: s, end: end, category: c, source: src, createdAt: end)
    }

    /// Days -28 … -1 before Monday 16 Nov (plus `extra` for today).
    static func log(scrollWeekday: Int = 60) -> [Entry] {
        var out = timetable
        for d in -28 ..< 0 {
            let day = Fx.mon(12, plusDays: d)
            let wd = cal.component(.weekday, from: day)
            out.append(e("Sleep", CategoryTree.sleep, d, 0, 0, 7, 0, src: .health))
            if (2...6).contains(wd) {
                out.append(e("Getting ready", CategoryTree.gettingReady, d, 7, 0, 7, 40))
                out.append(e("Walk", CategoryTree.travel, d, 8, 0, 8, 25, src: .sensor))
                out.append(e("Homework", CategoryTree.studying, d, 16, 0, 17, 30))
                out.append(e("Dinner", CategoryTree.meals, d, 18, 0, 18, 30))
                out.append(e("Scrolling", CategoryTree.scrolling, d, 21, 0, 21, scrollWeekday))
                out.append(e("Sleep", CategoryTree.sleep, d, 23, 0, 23, 59, src: .health))
            } else {
                out.append(e("Gaming", CategoryTree.free, d, 13, 0, 16, 0))
                out.append(e("Scrolling", CategoryTree.scrolling, d, 20, 0, 22, 0))
            }
        }
        return out
    }
}

final class GoalTests: XCTestCase {
    let cal = Fx.cal

    func testA31MinuteGapFailsTheTrackingGoal() {
        let es = Week4.timetable + [Week4.e("Homework", CategoryTree.studying, 0, 15, 31, 17, 0)]
        let p = Goals.progress(Goal.trackingGaps, entries: es, tree: CategoryTree(), items: [], now: Fx.mon(17), calendar: cal)
        // Midnight–8:30 is untracked too here (no sleep entry), so that's one; 15:00–15:31 is the other.
        XCTAssertEqual(p.value, 2)
        XCTAssertFalse(p.met)
        let ok = Week4.timetable + [Week4.e("Sleep", CategoryTree.sleep, 0, 0, 0, 7, 0, src: .health),
                                    Week4.e("Walk", CategoryTree.travel, 0, 7, 0, 8, 0, src: .sensor),
                                    Week4.e("Gap", CategoryTree.free, 0, 8, 0, 8, 0),
                                    Week4.e("Homework", CategoryTree.studying, 0, 15, 30, 17, 0)]
        let p2 = Goals.progress(Goal.trackingGaps, entries: ok, tree: CategoryTree(), items: [], now: Fx.mon(17), calendar: cal)
        XCTAssertEqual(p2.value, 0, "8:00–8:30 and 15:00–15:30 are exactly 30: fine. School, sleep and sensor time count as tracked")
        XCTAssertTrue(p2.met)
    }

    func testDayWeekUpperLimitAndTaskCount() {
        let log = Week4.log()
        let study = Goal(title: "Studying", measure: .category(CategoryTree.studying), period: .day, target: 120, createdAt: Fx.mon(0))
        let p = Goals.progress(study, entries: log, tree: CategoryTree(), items: [], now: Fx.mon(23, plusDays: -1), calendar: cal,
                               at: Fx.mon(12, plusDays: -3))
        XCTAssertEqual(p.value, 90)
        XCTAssertFalse(p.met)
        XCTAssertEqual(p.line, "Studying 1h 30m of 2h")
        let week = Goal(title: "Studying", measure: .category(CategoryTree.studying), period: .week, target: 360, createdAt: Fx.mon(0))
        let w = Goals.progress(week, entries: log, tree: CategoryTree(), items: [], now: Fx.mon(12, plusDays: -1), calendar: cal)
        XCTAssertEqual(w.value, 5 * 90)
        XCTAssertTrue(w.met)
        let scroll = Goal(title: "Scrolling", measure: .category(CategoryTree.scrolling), period: .day, target: 60, direction: .atMost,
                          createdAt: Fx.mon(0))
        XCTAssertTrue(Goals.progress(scroll, entries: log, tree: CategoryTree(), items: [], now: Fx.mon(12, plusDays: -3), calendar: cal,
                                     at: Fx.mon(12, plusDays: -3)).met)
        XCTAssertFalse(Goals.progress(scroll, entries: log, tree: CategoryTree(), items: [], now: Fx.mon(12, plusDays: -1), calendar: cal,
                                      at: Fx.mon(23, plusDays: -2)).met, "Saturday: 2h")
        var a = WorkItem(title: "A", kind: .chore, due: Fx.mon(20)); a.isDone = true; a.doneAt = Fx.mon(10)
        var b = WorkItem(title: "B", kind: .chore, due: Fx.mon(20)); b.isDone = true; b.doneAt = Fx.mon(11)
        let tasks = Goal(title: "Tasks", measure: .tasksDone, period: .day, target: 3, createdAt: Fx.mon(0))
        let t = Goals.progress(tasks, entries: [], tree: CategoryTree(), items: [a, b], now: Fx.mon(12), calendar: cal)
        XCTAssertEqual(t.line, "2 of 3 tasks")
        XCTAssertEqual(Goals.daysMet(study, days: (1...7).map { Fx.mon(12, plusDays: -$0) }, entries: log, tree: CategoryTree(),
                                     items: [], now: Fx.mon(8), calendar: cal), 0)
    }

    func testSuggestedGoalsAreJustAboveWhatYouDoAndOnlyAIGoalsMove() {
        let s = Goals.suggest(entries: Week4.log(), tree: CategoryTree(), existing: [], now: Fx.mon(8), calendar: cal)
        XCTAssertEqual(s.map(\.title), ["Studying", "Scrolling"])
        XCTAssertEqual(s[0].target, 105, "median day 90 × 1.1, rounded to 15")
        XCTAssertEqual(s[1].direction, .atMost)
        var ai = s[0]
        XCTAssertTrue(Goals.nudge(&ai, to: 200))
        XCTAssertEqual(ai.target, 116, "at most 10%")
        var mine = s[0]; mine.origin = .you
        XCTAssertFalse(Goals.nudge(&mine, to: 200))
        XCTAssertTrue(Goals.suggest(entries: Week4.timetable, tree: CategoryTree(), existing: [], now: Fx.mon(8), calendar: cal).isEmpty)
    }
}

final class RingTests: XCTestCase {
    let cal = Fx.cal

    func testTotalsAddUpForecastNeverOverlapsAndUntrackedCounts() {
        let log = Week4.log() + [Week4.e("Sleep", CategoryTree.sleep, 0, 0, 0, 7, 0, src: .health)]
        let day = Days.dayInterval(Fx.mon(12), cal)
        let r = RingModel.make(entries: log, tree: CategoryTree(), range: day, now: Fx.mon(16), calendar: cal)
        XCTAssertEqual(r.actualMinutes, 16 * 60, "midnight to now")
        XCTAssertEqual(r.groups.reduce(0) { $0 + $1.minutes }, r.actualMinutes)
        XCTAssertEqual(r.categories.reduce(0) { $0 + $1.minutes }, r.actualMinutes)
        XCTAssertEqual(r.untrackedMinutes, 90 + 60, "7:00–8:30 and 15:00–16:00")
        XCTAssertEqual(r.trackingGaps, 2)
        XCTAssertEqual(r.categories.first { $0.id == CategoryTree.school }?.minutes, 390)
        XCTAssertTrue(r.forecastMinutes <= 8 * 60, "only the hours left")
        let f = DayForecast.make(entries: log, tree: CategoryTree(), now: Fx.mon(16), isSchoolDay: { (2...6).contains(self.cal.component(.weekday, from: $0)) },
                                 calendar: cal)!
        XCTAssertEqual(f.rest.values.reduce(0, +), 8 * 60, "the forecast fills exactly the rest of the day")
        let rf = RingModel.make(entries: log, tree: CategoryTree(), range: day, now: Fx.mon(16), forecast: f.rest, calendar: cal)
        XCTAssertEqual(rf.actualMinutes + rf.forecastMinutes, 24 * 60)
    }

    func testDrillAndPreviousPeriod() {
        var tree = CategoryTree()
        let math = tree.add("Math", under: CategoryTree.studying)!
        var log = Week4.log()
        log.append(Week4.e("Math", math.id, -1, 19, 0, 20, 0))
        let week = DateInterval(start: Fx.mon(0, plusDays: -7), duration: 7 * 86400)
        let prev = DateInterval(start: Fx.mon(0, plusDays: -14), duration: 7 * 86400)
        let r = RingModel.make(entries: log, tree: tree, range: week, now: Fx.mon(0), previous: prev, calendar: cal)
        let studying = r.categories.first { $0.id == CategoryTree.studying }!
        XCTAssertEqual(studying.minutes, 5 * 90 + 60, "a leaf counts in its level-2 parent")
        XCTAssertEqual(studying.previous, 5 * 90)
        XCTAssertEqual(studying.delta, 60)
    }
}

final class ForecastTests: XCTestCase {
    let cal = Fx.cal
    func school(_ d: Date) -> Bool { (2...6).contains(cal.component(.weekday, from: d)) }

    func testSchoolDayVsWeekendAndUsesOnlyLaterHistoryAt4pm() {
        let log = Week4.log()
        let mon = DayForecast.make(entries: log, tree: CategoryTree(), now: Fx.mon(16), isSchoolDay: school, calendar: cal)!
        XCTAssertEqual(mon.rest[CategoryTree.studying], 90, "after 4 pm a school day has 1h 30 homework")
        XCTAssertNil(mon.rest[CategoryTree.gettingReady], "the morning isn't in a 4 pm forecast")
        XCTAssertEqual(mon.usual[CategoryTree.gettingReady], 40)
        XCTAssertGreaterThanOrEqual(mon.similarDays, 3)
        let sat = cal.date(byAdding: .day, value: 5, to: Fx.mon(12))!
        let log2 = log.filter { $0.start < cal.startOfDay(for: sat) || $0.repeats != nil }
        let s = DayForecast.make(entries: log2 + (0..<5).flatMap { d in
            [Week4.e("Sleep", CategoryTree.sleep, d, 0, 0, 7, 0, src: .health), Week4.e("Homework", CategoryTree.studying, d, 16, 0, 17, 30)]
        }, tree: CategoryTree(), now: cal.date(bySettingHour: 12, minute: 0, second: 0, of: sat)!, isSchoolDay: school, calendar: cal)!
        XCTAssertEqual(s.rest[CategoryTree.free], 180, "Saturday afternoon is gaming")
        XCTAssertNil(s.rest[CategoryTree.studying])
    }

    func testHiddenUnderThreeSimilarDays() {
        let few = Week4.timetable + [Week4.e("Homework", CategoryTree.studying, -7, 16, 0, 17, 0), Week4.e("Homework", CategoryTree.studying, -1, 16, 0, 17, 0)]
        XCTAssertNil(DayForecast.make(entries: few, tree: CategoryTree(), now: Fx.mon(16), isSchoolDay: school, calendar: cal))
    }

    func testVerdictBeatsOnStudyNeverCountsFreeTimeAndScrollingDownIsBetter() {
        var log = Week4.log()
        log.append(Week4.e("Sleep", CategoryTree.sleep, 0, 0, 0, 7, 0, src: .health))
        log.append(Week4.e("Getting ready", CategoryTree.gettingReady, 0, 7, 0, 7, 40))
        log.append(Week4.e("Walk", CategoryTree.travel, 0, 8, 0, 8, 25, src: .sensor))
        log.append(Week4.e("Homework", CategoryTree.studying, 0, 15, 0, 16, 0))
        log.append(Week4.e("Gaming", CategoryTree.free, 0, 12, 0, 12, 0))
        let f = DayForecast.make(entries: log, tree: CategoryTree(), now: Fx.mon(16), isSchoolDay: school, calendar: cal)!
        let so = TimeLog.totals(TimeLog.past(log, in: Days.dayInterval(Fx.mon(12), cal), now: Fx.mon(16), calendar: cal))
        let v = ForecastVerdict.make(f, actualSoFar: so, tree: CategoryTree(), goals: [], now: Fx.mon(16), calendar: cal)
        XCTAssertEqual(v.kind, .beat)
        XCTAssertTrue(v.line.hasPrefix("On track to beat your usual: Studying +1h"), v.line)
        XCTAssertFalse(v.differences.contains { $0.category == CategoryTree.free }, "free time is never something to beat")
        // A day with more scrolling than usual is behind, said plainly.
        var bad = Week4.log()
        bad.append(Week4.e("Sleep", CategoryTree.sleep, 0, 0, 0, 7, 0, src: .health))
        bad.append(Week4.e("Getting ready", CategoryTree.gettingReady, 0, 7, 0, 7, 40))
        bad.append(Week4.e("Walk", CategoryTree.travel, 0, 8, 0, 8, 25, src: .sensor))
        bad.append(Week4.e("Scrolling", CategoryTree.scrolling, 0, 15, 0, 16, 0))
        let f2 = DayForecast.make(entries: bad, tree: CategoryTree(), now: Fx.mon(16), isSchoolDay: school, calendar: cal)!
        let so2 = TimeLog.totals(TimeLog.past(bad, in: Days.dayInterval(Fx.mon(12), cal), now: Fx.mon(16), calendar: cal))
        let v2 = ForecastVerdict.make(f2, actualSoFar: so2, tree: CategoryTree(), goals: [], now: Fx.mon(16), calendar: cal)
        XCTAssertEqual(v2.kind, .behind)
        XCTAssertTrue(v2.line.contains("scrolling"), v2.line)
        XCTAssertTrue(v2.line.contains("hours left"), v2.line)
    }
}

final class UpNextTests: XCTestCase {
    let cal = Fx.cal

    func plan(_ blocks: [PlannedBlock], shortfalls: [UUID: Int] = [:]) -> Plan {
        Plan(generatedAt: Fx.mon(12), blocks: blocks, warnings: [], shortfalls: shortfalls, sleepTradeoffMinutes: 0, loadFactor: 1)
    }

    func testFits() {
        let essay = WorkItem(title: "Essay", kind: .essay, due: Fx.mon(9, plusDays: 3))
        let w = PlannedBlock(kind: .work, start: Fx.mon(19), end: Fx.mon(20), title: "Essay", itemId: essay.id)
        let wind = PlannedBlock(kind: .windDown, start: Fx.mon(22), end: Fx.mon(22, 30), title: "Wind down")
        let sleep = PlannedBlock(kind: .sleep, start: Fx.mon(22, 30), end: Fx.mon(7, plusDays: 1), title: "Sleep")
        let goal = Goal(title: "Studying", measure: .category(CategoryTree.studying), period: .day, target: 120, createdAt: Fx.mon(0))
        let done = Week4.e("Homework", CategoryTree.studying, 0, 16, 0, 17, 0)
        let s = UpNext.summary(plan: plan([w, wind, sleep]), items: [essay], entries: [done], goals: [goal], tree: CategoryTree(),
                               now: Fx.mon(18), calendar: cal)
        XCTAssertEqual(s, "Do these and you'll hit Studying 2h and still have 3h free before bed at 22:30.", "18:00–22:30 less the essay and wind-down")
    }

    func testDoesntFit() {
        let essay = WorkItem(title: "Gatsby essay", kind: .essay, due: Fx.mon(9, plusDays: 1))
        let s = UpNext.summary(plan: plan([], shortfalls: [essay.id: 60]), items: [essay], entries: [], goals: [], tree: CategoryTree(),
                               now: Fx.mon(18), calendar: cal)
        XCTAssertTrue(s.hasPrefix("Not enough time for all of this: Gatsby essay"), s)
    }

    func testNothingLeft() {
        let sleep = PlannedBlock(kind: .sleep, start: Fx.mon(22, 30), end: Fx.mon(7, plusDays: 1), title: "Sleep")
        XCTAssertEqual(UpNext.summary(plan: plan([sleep]), items: [], entries: [], goals: [], tree: CategoryTree(), now: Fx.mon(18), calendar: cal),
                       "Nothing left today. Free until bed at 22:30.")
    }
}

final class MoodMapTests: XCTestCase {
    func testHeatmapAndNoticedLine() {
        let cal = Fx.cal
        var moods: [MoodEntry] = []
        for d in 0..<10 {
            let day = Fx.mon(0, plusDays: -d - 1)
            guard (2...6).contains(cal.component(.weekday, from: day)) else { continue }
            moods.append(MoodEntry(at: day.addingTimeInterval(9 * 3600), mood: 4))
            moods.append(MoodEntry(at: day.addingTimeInterval(16 * 3600 + 1800), mood: 2))
            moods.append(MoodEntry(at: day.addingTimeInterval(20 * 3600), mood: 4))
        }
        let m = MoodMap.make(moods, since: Fx.mon(0, plusDays: -30), isSchoolDay: { (2...6).contains(cal.component(.weekday, from: $0)) },
                             calendar: cal)
        XCTAssertEqual(m.noticed, "Lowest around 4–6 pm on school days")
        XCTAssertEqual(m.cells[2]?[16], 2)
        XCTAssertNil(MoodMap.make(Array(moods.prefix(4)), since: .distantPast, isSchoolDay: { _ in true }, calendar: cal).noticed)
    }
}

final class GoalRewardTests: XCTestCase {
    func testGoalsAndBeatingYourUsualAreMomentsOncePerDay() {
        let cal = Fx.cal
        var log = RewardLog()
        let s = RewardSettings(level: .full, surpriseRate: 0)
        let a = Rewards.respond(to: .goalClosed(title: "Studying", weekly: false, daysThisMonth: 12), log: &log, settings: s, now: Fx.mon(19), calendar: cal)
        XCTAssertEqual(a?.title, "Studying goal reached")
        XCTAssertEqual(a?.detail, "12 days this month", "a count, never a streak")
        XCTAssertEqual(a?.intensity, .medium)
        XCTAssertNil(Rewards.respond(to: .goalClosed(title: "Studying", weekly: false, daysThisMonth: 12), log: &log, settings: s,
                                     now: Fx.mon(20), calendar: cal), "once a day")
        XCTAssertEqual(Rewards.respond(to: .goalClosed(title: "Extracurricular", weekly: true, daysThisMonth: nil), log: &log, settings: s,
                                       now: Fx.mon(20), calendar: cal)?.intensity, .big)
        let beat = Rewards.respond(to: .beatUsual(score: 78, usual: 64, label: "Usual Monday", differences: ["Studying +40m", "Scrolling −30m"]),
                                   log: &log, settings: s, now: Fx.mon(22), calendar: cal)
        XCTAssertEqual(beat?.title, "You beat your usual monday: 78 vs 64")
        XCTAssertNil(Rewards.respond(to: .beatUsual(score: 60, usual: 64, label: "Usual Monday", differences: []), log: &log, settings: s,
                                     now: Fx.mon(22, plusDays: 1), calendar: cal), "missing it is just not mentioned")
        XCTAssertEqual(Rewards.respond(to: .trackedDay(daysThisMonth: 5), log: &log, settings: s, now: Fx.mon(22, plusDays: 1),
                                       calendar: cal)?.detail, "5 days like this this month")
    }
}
