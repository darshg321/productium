import XCTest
@testable import ProductiumCore

/// v1.3 Part D: the three rings from the `history` scenario.
final class DayRingsTests: XCTestCase {
    let cal = Fx.cal
    let now = Fx.mon(16, 40, plusDays: 2)

    func rings(_ st: AppState, _ day: Date) -> DayRings {
        DayRings.make(day, asked: st.dayPlans[DayKeys.key(day, cal)] ?? [:], entries: st.entries, items: st.items, tree: st.categories,
                      limit: DayRings.limit(goals: st.goals, taper: st.taper, tree: st.categories), now: now, calendar: cal)
    }

    func testHistoryDaysHaveThreeRings() {
        let h = Scenarios.make(.history, now: now, calendar: cal)
        let yesterday = cal.date(byAdding: .day, value: -1, to: now)!
        let r = rings(h, yesterday)
        XCTAssertEqual(r.workGoal, 120, "two sessions of an hour were asked")
        XCTAssertGreaterThan(r.workMinutes, 0)
        XCTAssertGreaterThan(r.wakingMinutes, 10 * 60)
        XCTAssertGreaterThan(r.tracked, 0.3)
        XCTAssertLessThanOrEqual(r.tracked, 1)
        XCTAssertEqual(r.limitGoal, DayRings.defaultLimit)
        XCTAssertGreaterThanOrEqual(r.limitMinutes, 20, "the scrolling each evening")
        // The same numbers the day score uses.
        let score = DayScore.make(yesterday, asked: h.dayPlans[DayKeys.key(yesterday, cal)] ?? [:], entries: h.entries, items: h.items,
                                  tree: h.categories, now: now, calendar: cal)
        XCTAssertEqual(r.workMinutes, score.workMinutes)
        XCTAssertEqual(r.workGoal, score.askedMinutes)
        XCTAssertEqual(r.wakingMinutes - r.trackedMinutes, score.untrackedMinutes)
        XCTAssertTrue(r.limitLabel.hasSuffix("of 60 min"))
    }

    func testUsualDayIsTheMedianOfTheSameKind() {
        let h = Scenarios.make(.history, now: now, calendar: cal)
        let school = { (d: Date) in (2...6).contains(self.cal.component(.weekday, from: d)) }
        let usual = DayRings.usual(before: now, isSchoolDay: school, rings: { self.rings(h, $0) }, calendar: cal)
        XCTAssertNotNil(usual)
        XCTAssertEqual(usual?.workGoal, 120)
        XCTAssertNil(DayRings.usual(before: now, isSchoolDay: school, rings: { _ in DayRings(workMinutes: 0, workGoal: 0, wakingMinutes: 0, trackedMinutes: 0, gaps: 0, limitMinutes: 0, limitGoal: 60) },
                                    calendar: cal).map { $0.workGoal > 0 ? $0 : nil } ?? nil)
    }

    func testProgressLabelsAndClosing() {
        let r = DayRings(workMinutes: 150, workGoal: 120, wakingMinutes: 900, trackedMinutes: 897, gaps: 0, limitMinutes: 18, limitGoal: 60)
        XCTAssertEqual(r.work, 1.25, accuracy: 0.001, "a second lap")
        XCTAssertTrue(r.workClosed)
        XCTAssertTrue(r.trackedClosed)
        XCTAssertFalse(r.limitClosed)
        XCTAssertEqual(r.limitLabel, "18 of 60 min")
        XCTAssertEqual(r.workLabel, "2h 30m of 2h")
        XCTAssertEqual(r.trackedSubtitle, "No gap over 30 min")
        let none = DayRings(workMinutes: 0, workGoal: 0, wakingMinutes: 0, trackedMinutes: 0, gaps: 0, limitMinutes: 0, limitGoal: 60)
        XCTAssertEqual(none.workLabel, "0m · nothing asked")
        XCTAssertFalse(none.workClosed)
    }

    func testTheLimitComesFromAGoalOrTheTaper() {
        let tree = CategoryTree()
        var taper = ScreenTaper()
        XCTAssertEqual(DayRings.limit(goals: [], taper: taper, tree: tree), 60)
        taper.targetMinutes = 75
        XCTAssertEqual(DayRings.limit(goals: [], taper: taper, tree: tree), 75)
        let g = Goal(title: "Scrolling", measure: .category(CategoryTree.scrolling), period: .day, target: 45, direction: .atMost,
                     origin: .you, createdAt: now)
        XCTAssertEqual(DayRings.limit(goals: [g], taper: taper, tree: tree), 45)
    }

    func testWhatChangedAndTheBestAndWorstHour() {
        let h = Scenarios.make(.history, now: now, calendar: cal)
        let day = cal.date(byAdding: .day, value: -1, to: now)!
        let mins = { (d: Date) in DayCompare.minutes(d, entries: h.entries, tree: h.categories, now: self.now, calendar: self.cal) }
        var today = mins(day)
        let usual = (1...4).compactMap { cal.date(byAdding: .day, value: -7 * $0, to: day) }.map(mins)
        today[CategoryTree.studying, default: 0] += 90
        let c = DayCompare.changes(today: today, usual: usual, tree: h.categories)
        XCTAssertEqual(c.first?.name, "Studying")
        XCTAssertGreaterThanOrEqual(c.first?.minutes ?? 0, 60)
        XCTAssertTrue(DayCompare.line(c)!.hasPrefix("Studying +"))
        XCTAssertNil(DayCompare.line([]))
        let hours = DayCompare.hours(day, entries: h.entries, tree: h.categories, now: now, calendar: cal)
        XCTAssertNotNil(hours.best)
        XCTAssertEqual(hours.worst, 20, "the evening scrolling")
    }
}
