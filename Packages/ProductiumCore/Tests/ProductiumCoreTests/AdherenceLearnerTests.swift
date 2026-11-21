import XCTest
@testable import ProductiumCore

// Follow-through and good hours come from the log once a day is over, each day read once.
final class AdherenceLearnerTests: XCTestCase {
    let cal = Fx.cal
    let essay = UUID(), math = UUID(), reading = UUID()

    func worked(_ task: UUID?, _ h: Int, _ m: Int, _ h2: Int, _ m2: Int, category: CategoryID = CategoryTree.studying) -> Entry {
        Entry(title: "w", start: Fx.mon(h, m), end: Fx.mon(h2, m2), category: category, taskId: task, source: .you, createdAt: Fx.mon(h2, m2))
    }

    var blocks: [PlannedBlock] {
        [PlannedBlock(kind: .work, start: Fx.mon(16), end: Fx.mon(17), title: "Essay", itemId: essay),
         PlannedBlock(kind: .work, start: Fx.mon(19), end: Fx.mon(20), title: "Math", itemId: math),
         PlannedBlock(kind: .work, start: Fx.mon(20, 30), end: Fx.mon(21), title: "Reading", itemId: reading)]
    }

    var entries: [Entry] {
        [worked(essay, 16, 10, 17, 0),          // on time
         worked(math, 23, 0, 23, 50),           // done, but after every window
         worked(nil, 7, 0, 7, 40)]              // studying with no task, nothing planned then
    }

    func testJudgedFromTheLog() {
        let d = AdherenceLearner.judge(day: Fx.mon(0), blocks: blocks, entries: entries, items: [], tree: CategoryTree(),
                                       now: Fx.mon(9, 0, plusDays: 1), calendar: cal)
        XCTAssertEqual(d.sessions.map(\.status), [.done, .done, .skipped], "done in any order still counts as done")
        XCTAssertEqual(d.sessions[0].onTimeScore ?? 0, 1, accuracy: 0.01)
        XCTAssertEqual(d.sessions[1].onTimeScore ?? 1, 0, accuracy: 0.01, "math happened after its hour")
        XCTAssertEqual(d.offPlan[7], 40)
        XCTAssertEqual(d.offPlan[23], 50)
        XCTAssertNil(d.offPlan[22])
        XCTAssertNil(d.offPlan[16], "on-plan work isn't counted twice")
    }

    func testEachDayIsLearnedOnceAndGoodHoursFollowTheWork() {
        var learned = LearnedModel()
        let now = Fx.mon(9, 0, plusDays: 1)
        let history = [CapacityLearner.dayKey(Fx.mon(0), cal): blocks]
        let first = AdherenceLearner.learn(&learned, history: history, entries: entries, items: [], tree: CategoryTree(), now: now, calendar: cal)
        XCTAssertEqual(first.count, 3)
        XCTAssertEqual(learned.adherenceSamples, 3)
        XCTAssertEqual(learned.learnedThrough, CapacityLearner.dayKey(Fx.mon(0), cal))
        let again = AdherenceLearner.learn(&learned, history: history, entries: entries, items: [], tree: CategoryTree(), now: now, calendar: cal)
        XCTAssertTrue(again.isEmpty)
        XCTAssertEqual(learned.adherenceSamples, 3)
        XCTAssertGreaterThan(learned.hourReliability(16), learned.hourReliability(19), "16:00 was kept, 19:00 wasn't")
        XCTAssertGreaterThan(learned.hourReliability(7), LearnedModel().hourReliability(7), "unplanned work teaches the hour too")
    }

    func testTypedAheadWithoutAYesIsNotWork() {
        let ahead = Entry(title: "w", start: Fx.mon(16), end: Fx.mon(17), category: CategoryTree.studying, taskId: essay,
                          source: .you, createdAt: Fx.mon(8))
        let d = AdherenceLearner.judge(day: Fx.mon(0), blocks: Array(blocks.prefix(1)), entries: [ahead], items: [], tree: CategoryTree(),
                                       now: Fx.mon(9, 0, plusDays: 1), calendar: cal)
        XCTAssertEqual(d.sessions.first?.status, .skipped)
    }
}
