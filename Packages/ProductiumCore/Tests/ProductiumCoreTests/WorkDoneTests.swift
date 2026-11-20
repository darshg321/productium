import XCTest
@testable import ProductiumCore

final class WorkDoneTests: XCTestCase {
    let cal = Fx.cal

    func block(_ h: Int, _ m: Int, plusDays d: Int = 0) -> PlannedBlock {
        PlannedBlock(kind: .work, start: Fx.mon(h, 0, plusDays: d), end: Fx.mon(h, m, plusDays: d), title: "Essay")
    }

    func testFinishedDaysKeepWhatWasPlannedEvenWithoutAnswers() {
        let yesterday = Plan(generatedAt: Fx.mon(9), blocks: [block(16, 45), block(19, 30), block(12, 20, plusDays: 1)],
                             warnings: [], shortfalls: [:], sleepTradeoffMinutes: 0, loadFactor: 1)
        var history: [String: [PlannedBlock]] = [:]
        PlanHistory.record(previous: yesterday, into: &history, now: Fx.mon(7, plusDays: 1), calendar: cal)
        XCTAssertEqual(history.count, 1, "today's blocks are still live, not history")
        XCTAssertEqual(PlanHistory.plannedMinutes(on: Fx.mon(0), history: history, plan: .empty, calendar: cal), 75)
        XCTAssertEqual(PlanHistory.plannedMinutes(on: Fx.mon(0, plusDays: 1), history: history, plan: yesterday, calendar: cal), 20)
    }

    func testHistoryKeepsSixtyDays() {
        var history: [String: [PlannedBlock]] = [:]
        for i in 0..<70 {
            let plan = Plan(generatedAt: Fx.mon(9), blocks: [block(16, 30, plusDays: i)], warnings: [], shortfalls: [:],
                            sleepTradeoffMinutes: 0, loadFactor: 1)
            PlanHistory.record(previous: plan, into: &history, now: Fx.mon(7, plusDays: 80), calendar: cal)
        }
        XCTAssertEqual(history.count, 60)
    }

    func testWorkDoneIsTheLogWithoutDoubleCounting() {
        let task = UUID()
        let progress = [ProgressEntry(at: Fx.mon(18), minutes: 30, source: .evidence)]
        // A tracked session 16:00–16:40, a study check-in inside it, another one later, and planned (unstarted) time.
        let session = Entry(title: "Essay", start: Fx.mon(16), end: Fx.mon(16, 40), category: CategoryTree.studying, taskId: task,
                            source: .you, createdAt: Fx.mon(16, 40))
        let inside = Entry(title: "Study", start: Fx.mon(16, 10), end: Fx.mon(16, 35), category: CategoryTree.studying,
                           source: .you, createdAt: Fx.mon(16, 35))
        let later = Entry(title: "Study", start: Fx.mon(20), end: Fx.mon(20, 25), category: CategoryTree.studying,
                          source: .you, createdAt: Fx.mon(20, 25))
        let planned = Entry(title: "Essay", start: Fx.mon(21), end: Fx.mon(22), category: CategoryTree.studying, taskId: task,
                            source: .plan, createdAt: Fx.mon(9))
        let all = [session, inside, later, planned]
        XCTAssertEqual(WorkDone.minutes(on: Fx.mon(0), entries: all, tree: CategoryTree(), now: Fx.mon(23), progress: progress, calendar: cal),
                       40 + 30 + 25, "the check-in inside the session counts once; the planned hour hasn't been worked")
        XCTAssertEqual(WorkDone.minutes(on: Fx.mon(0), entries: [], tree: CategoryTree(), now: Fx.mon(23), progress: progress, calendar: cal), 30,
                       "'wrote two drafts' counts with no session at all")
        // A running session counts up to now; assumed time (a class) never counts.
        let running = Entry(title: "Essay", start: Fx.mon(21), end: nil, category: CategoryTree.studying, taskId: task, source: .you, createdAt: Fx.mon(21))
        XCTAssertEqual(WorkDone.minutes(on: Fx.mon(0), entries: [running], tree: CategoryTree(), now: Fx.mon(21, 20), progress: [], calendar: cal), 20)
        XCTAssertEqual(WorkDone.minutes(on: Fx.mon(0), entries: Fx.timetable, tree: CategoryTree(), now: Fx.mon(23), progress: [], calendar: cal), 0)
    }

    func testPendingSessionsAreBlocksNobodyWorkedOn() {
        let task = UUID()
        let b1 = PlannedBlock(kind: .work, start: Fx.mon(16), end: Fx.mon(16, 45), title: "Essay", itemId: task)
        let b2 = PlannedBlock(kind: .work, start: Fx.mon(18), end: Fx.mon(18, 45), title: "Essay", itemId: task)
        let plan = Plan(generatedAt: Fx.mon(9), blocks: [b1, b2], warnings: [], shortfalls: [:], sleepTradeoffMinutes: 0, loadFactor: 1)
        let did = Entry(title: "Essay", start: Fx.mon(16, 10), end: Fx.mon(16, 50), category: CategoryTree.studying, taskId: task,
                        source: .you, createdAt: Fx.mon(16, 50))
        XCTAssertEqual(Sessions.pending(plan: plan, entries: [did], now: Fx.mon(20)).map(\.id), [b2.id])
        XCTAssertEqual(Sessions.worked(plan: plan, entries: [did], now: Fx.mon(20)), [b1.id])
        // An hour you set aside for it ahead of time is a plan, not work.
        let pin = Entry(title: "Essay", start: Fx.mon(18), end: Fx.mon(19), category: CategoryTree.studying, taskId: task,
                        source: .you, createdAt: Fx.mon(8))
        XCTAssertEqual(Sessions.pending(plan: plan, entries: [pin], now: Fx.mon(20)).count, 2)
    }

    func testDayTotalsUseTheSameSource() {
        let progress = [ProgressEntry(at: Fx.mon(18), minutes: 90, source: .evidence)]
        let inputs = DayInputs(day: Fx.mon(0), routines: [], health: nil, screen: nil,
                               prefs: Preferences(), progress: progress)
        let t = Insights.dayTotals(inputs, plannedStudy: 120, moods: [], screenTarget: nil, calendar: cal, now: Fx.mon(21))
        XCTAssertEqual(t.doneStudy, 90)
        XCTAssertEqual(t.plannedStudy, 120)
    }
}
