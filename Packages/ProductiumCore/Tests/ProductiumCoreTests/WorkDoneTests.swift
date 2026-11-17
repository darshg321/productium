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
        XCTAssertEqual(PlanHistory.plannedMinutes(on: Fx.mon(0), history: history, plan: .empty, outcomes: [], calendar: cal), 75)
        XCTAssertEqual(PlanHistory.plannedMinutes(on: Fx.mon(0, plusDays: 1), history: history, plan: yesterday, outcomes: [], calendar: cal), 20)
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

    func testWorkDoneIsOneSourceWithoutDoubleCounting() {
        let outcome = BlockOutcome(blockId: UUID(), itemId: nil, kind: .essay, plannedStart: Fx.mon(16), plannedMinutes: 45,
                                   actualMinutes: 40, status: .done)
        let progress = [ProgressEntry(at: Fx.mon(18), minutes: 30, source: .evidence)]
        let overlapping = [TimelineEvent(at: Fx.mon(16, 10), phrase: "", activity: "study", category: .study, phase: .start),
                           TimelineEvent(at: Fx.mon(16, 35), phrase: "", activity: "study", category: .study, phase: .end)]
        let extra = [TimelineEvent(at: Fx.mon(20), phrase: "", activity: "study", category: .study, phase: .start),
                     TimelineEvent(at: Fx.mon(20, 25), phrase: "", activity: "study", category: .study, phase: .end)]
        XCTAssertEqual(WorkDone.minutes(on: Fx.mon(0), outcomes: [outcome], progress: progress, markers: overlapping + extra, calendar: cal),
                       40 + 30 + 25, "the 16:10-16:35 check-in sits inside the finished block")
        XCTAssertEqual(WorkDone.minutes(on: Fx.mon(0), outcomes: [], progress: progress, markers: [], calendar: cal), 30,
                       "'wrote two drafts' counts with no block at all")
    }

    func testDayTotalsUseTheSameSource() {
        let progress = [ProgressEntry(at: Fx.mon(18), minutes: 90, source: .evidence)]
        let inputs = DayInputs(day: Fx.mon(0), events: [], commitments: [], routines: [], outcomes: [], health: nil, screen: nil,
                               prefs: Preferences(), progress: progress)
        let t = Insights.dayTotals(inputs, plannedStudy: 120, moods: [], screenTarget: nil, calendar: cal, now: Fx.mon(21))
        XCTAssertEqual(t.doneStudy, 90)
        XCTAssertEqual(t.plannedStudy, 120)
    }
}
