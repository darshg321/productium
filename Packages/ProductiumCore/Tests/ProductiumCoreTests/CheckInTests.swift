import XCTest
@testable import ProductiumCore

final class CheckInTests: XCTestCase {
    let cal = Fx.cal
    func p(_ s: String, _ h: Int, _ m: Int = 0) -> [CheckIn] { MarkerParser.parse(s, at: Fx.mon(h, m), commitments: [], calendar: cal) }

    func testStartAndEndMakeOneEntryAndAVoiceDuplicateIsFolded() {
        var es: [Entry] = [], tree = CategoryTree()
        CheckIns.apply(p("left home", 7, 40), to: &es, tree: &tree, now: Fx.mon(7, 40), calendar: cal)
        XCTAssertEqual(es.count, 1)
        XCTAssertTrue(es[0].isRunning)
        XCTAssertEqual(es[0].title, "To school")
        XCTAssertEqual(es[0].category, CategoryTree.travel)
        CheckIns.apply(p("heading out", 7, 41), to: &es, tree: &tree, now: Fx.mon(7, 41), calendar: cal)
        XCTAssertEqual(es.count, 1, "the same transition within 3 minutes is one")
        CheckIns.apply(p("at school", 8, 5), to: &es, tree: &tree, now: Fx.mon(8, 5), calendar: cal)
        let trip = es.first { $0.title == "To school" }!
        XCTAssertEqual(trip.end, Fx.mon(8, 5))
        XCTAssertEqual(trip.minutes(), 25)
        XCTAssertTrue(es.contains { $0.title == "School" && $0.isRunning }, "and the next thing starts")
    }

    func testWakeEndsTheNightAndDerivesBackToInstants() {
        var es: [Entry] = [], tree = CategoryTree()
        CheckIns.apply(p("going to bed", 23), to: &es, tree: &tree, now: Fx.mon(23), calendar: cal)
        CheckIns.apply(MarkerParser.parse("woke up", at: Fx.mon(6, 50, plusDays: 1), commitments: [], calendar: cal), to: &es, tree: &tree,
                       now: Fx.mon(6, 50, plusDays: 1), calendar: cal)
        XCTAssertEqual(es.count, 1)
        XCTAssertEqual(es[0].category, CategoryTree.sleep)
        XCTAssertEqual(es[0].end, Fx.mon(6, 50, plusDays: 1))
        let ci = CheckIns.derive(es, tree: tree, in: DateInterval(start: Fx.mon(20), end: Fx.mon(12, plusDays: 1)), now: Fx.mon(12, plusDays: 1), calendar: cal)
        XCTAssertEqual(ci.map(\.phase), [.start, .end])
        XCTAssertEqual(ci.map(\.category), [.sleep, .sleep])
        // The estimator reads them as it always did.
        let n = SleepEstimator.night(morningOf: Fx.mon(0, plusDays: 1), health: nil, markers: ci, plannedWake: nil, sleepNeedMinutes: 540, calendar: cal)
        XCTAssertEqual(n?.source, .checkIns)
        XCTAssertEqual(n?.bedtime, Fx.mon(23))
    }

    func testFinishedAClassConfirmsToday() {
        var tree = CategoryTree()
        var es = Fx.schoolEntries
        es[0].title = "Math"
        es[0].category = tree.add("Math", under: CategoryTree.school)!.id
        CheckIns.apply(MarkerParser.parse("finished math", at: Fx.mon(14, 30), commitments: Timetable.commitments(from: es, tree: tree, calendar: cal), calendar: cal),
                       to: &es, tree: &tree, now: Fx.mon(14, 30), calendar: cal)
        XCTAssertEqual(es[0].marks["2026-11-16"], .skipped, "today's occurrence became its own entry")
        let one = es.first { $0.repeats == nil && $0.title == "Math" }
        XCTAssertEqual(one?.end, Fx.mon(14, 30))
        XCTAssertEqual(one?.marks["2026-11-16"], .confirmed)
    }
}
