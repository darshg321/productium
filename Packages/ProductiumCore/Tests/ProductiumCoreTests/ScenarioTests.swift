import XCTest
@testable import ProductiumCore

// The dev-build test scenarios are realistic enough to drive every screen: they round-trip, plan, score and learn.
final class ScenarioTests: XCTestCase {
    let cal = Fx.cal
    let now = Fx.mon(16, 40, plusDays: 2)   // a Wednesday afternoon

    func testEveryScenarioRoundTripsAndPlans() throws {
        for s in Scenario.allCases {
            let st = Scenarios.make(s, now: now, calendar: cal)
            let data = try JSONEncoder().encode(st)
            let back = try JSONDecoder().decode(AppState.self, from: data)
            XCTAssertEqual(back.onboarded, s != .fresh, s.rawValue)
            XCTAssertEqual(back.entries.count, st.entries.count, s.rawValue)
            XCTAssertFalse(st.integrations.notifications || st.integrations.health || st.integrations.location, "no permission prompts")
            guard s != .fresh else { continue }
            let plan = Planner.plan(Fx.input(now: now, items: st.items, entries: st.entries, categories: st.categories))
            XCTAssertFalse(plan.blocks.filter(\.isStudy).isEmpty, "\(s.rawValue) plans study")
        }
    }

    func testTodayHasARunningReadingAndHistoryFillsReview() {
        let t = Scenarios.make(.today, now: now, calendar: cal)
        XCTAssertEqual(TimeLog.running(t.entries)?.taskId, Scenarios.reading)
        let h = Scenarios.make(.history, now: now, calendar: cal)
        let yesterday = cal.date(byAdding: .day, value: -1, to: now)!
        let score = DayScore.make(yesterday, asked: h.dayPlans[DayKeys.key(yesterday, cal)] ?? [:], entries: h.entries, items: h.items,
                                  tree: h.categories, now: now, calendar: cal)
        XCTAssertGreaterThan(score.score, 20)
        XCTAssertGreaterThan(score.workMinutes, 0)
        var learned = LearnedModel()
        let read = AdherenceLearner.learn(&learned, history: h.planHistory, entries: h.entries, items: h.items, tree: h.categories,
                                          now: now, calendar: cal)
        XCTAssertGreaterThan(read.count, 20)
        XCTAssertGreaterThan(learned.hourReliability(16), learned.hourReliability(19), "16:30 is kept, 19:00 moves")
        XCTAssertNotNil(h.taskHistory.warning(for: h.items.first { $0.id == Scenarios.reading }!), "readings usually get dropped")
    }

    func testAlertsAndLeaderboardHaveWhatTheirScreensShow() {
        let a = Scenarios.make(.alerts, now: now, calendar: cal)
        XCTAssertEqual(a.approvals.count, 1)
        XCTAssertEqual(a.inference.pending.first?.question, "Were you out for a walk?")
        let plan = Planner.plan(Fx.input(now: now, items: a.items, entries: a.entries, categories: a.categories))
        XCTAssertFalse(plan.warnings.isEmpty, "the lab report can't fit")
        let l = Scenarios.make(.leaderboard, now: now, calendar: cal)
        let g = l.leaderboard.groups[0]
        let post = Leaderboard.post(name: "You", today: now, calendar: cal) {
            DayScore.make($0, asked: l.dayPlans[DayKeys.key($0, self.cal)] ?? [:], entries: l.entries, items: l.items,
                          tree: l.categories, now: self.now, calendar: self.cal)
        }
        let rows = Leaderboard.rows(Leaderboard.withYou(l.leaderboard.boards[g.id]!, you: g.memberId, post: post), metric: .score,
                                    you: g.memberId, today: now, calendar: cal)
        XCTAssertEqual(rows.count, 5)
        XCTAssertEqual(rows.filter(\.isYou).count, 1)
    }
}
