import XCTest
@testable import ProductiumCore

/// v1.2 Part H: outcomes kept after the task goes, similar tasks, the warning, and attention in the plan.
final class TaskHistoryTests: XCTestCase {
    let cal = Fx.cal

    func reading(_ n: Int, daysAgo: Int) -> WorkItem {
        WorkItem(title: "Chapter \(n) reading", kind: .reading, due: Fx.mon(9, plusDays: -daysAgo), createdAt: Fx.mon(9, plusDays: -daysAgo - 4))
    }

    func testOutcomesAndKeptAfterDelete() {
        var h = TaskHistory()
        var done = reading(1, daysAgo: 10); done.isDone = true
        let partly = reading(2, daysAgo: 9)
        let e = Entry(title: "Chapter 2 reading", start: Fx.mon(21, plusDays: -10), end: Fx.mon(21, 20, plusDays: -10),
                      category: CategoryTree.studying, taskId: partly.id, source: .you)
        h.add(TaskHistory.record(done, cleared: false, entries: [], now: Fx.mon(9, plusDays: -10), calendar: cal))
        h.add(TaskHistory.record(partly, cleared: true, why: "no time", entries: [e], now: Fx.mon(9, plusDays: -8), calendar: cal))
        XCTAssertEqual(h.records.map(\.outcome), [.done, .partly])
        XCTAssertEqual(h.records[1].actual, 20)
        XCTAssertEqual(h.records[1].hour, 21)
        XCTAssertEqual(h.records[1].why, "no time")
        // Expiry: past due by a day, never started → dropped, once.
        let old = reading(3, daysAgo: 3)
        XCTAssertEqual(h.expire([old], entries: [], now: Fx.mon(9), calendar: cal), [old.id])
        XCTAssertEqual(h.expire([old], entries: [], now: Fx.mon(10), calendar: cal), [])
        XCTAssertEqual(h.records.last?.outcome, .dropped)
    }

    func testWarningForAUsuallyDroppedKindButNotForAUsuallyDoneOne() {
        var h = TaskHistory()
        for n in 1...5 {
            var t = reading(n, daysAgo: 20 - n)
            t.deferralLog = [DeferralEvent(at: Fx.mon(9), kind: .snoozed), DeferralEvent(at: Fx.mon(10), kind: .skipped)]
            if n == 3 { t.isDone = true }
            let late = Entry(title: t.title, start: Fx.mon(21, 30, plusDays: -20 + n), end: Fx.mon(21, 40, plusDays: -20 + n),
                             category: CategoryTree.studying, taskId: t.id, source: .you)
            h.add(TaskHistory.record(t, cleared: n != 3, entries: n == 3 ? [] : [late], now: Fx.mon(9, plusDays: -19 + n), calendar: cal))
        }
        for n in 1...3 {
            var essay = WorkItem(title: "Essay \(n)", kind: .essay, due: Fx.mon(9, plusDays: -n))
            essay.isDone = true
            h.add(TaskHistory.record(essay, cleared: false, entries: [], now: Fx.mon(9, plusDays: -n), calendar: cal))
        }
        let next = WorkItem(title: "Chapter 6 reading", kind: .reading, due: Fx.mon(9, plusDays: 3))
        XCTAssertTrue(h.atRisk(next))
        XCTAssertEqual(h.warning(for: next), "You've dropped 4 of the last 5 reading tasks; they're usually put off to after 9 pm")
        let essay = WorkItem(title: "Essay 4", kind: .essay, due: Fx.mon(9, plusDays: 3))
        XCTAssertFalse(h.atRisk(essay))
        XCTAssertNil(h.warning(for: essay))
        XCTAssertEqual(h.summary().first, "reading: dropped 4 of 5, put off 2× on average, worked on after 21:00")
        XCTAssertEqual(h.note(for: [next], reply: "Added. Readings often slip, so here's a first step."),
                       "You've dropped 4 of the last 5 reading tasks; they're usually put off to after 9 pm.")
        XCTAssertNil(h.note(for: [next], reply: "You've dropped 4 of your last 5 readings, usually after 9 pm."), "already said")
        XCTAssertNil(h.note(for: [essay], reply: "Added."))
    }

    func testAtRiskTaskGetsAStarterFirst() {
        var t = WorkItem(title: "Brag sheet", kind: .application, due: Fx.mon(23, plusDays: 6), estimateMinutes: 180)
        t.firstStep = "List three things from this year"
        var input = Fx.input(now: Fx.mon(12), items: [t], entries: Fx.timetable)
        let base = Planner.plan(input)
        input.atRisk = [t.id]
        let risky = Planner.plan(input)
        let first = risky.study(for: t.id).min { $0.start < $1.start }!
        XCTAssertEqual(first.minutes, 15)
        XCTAssertEqual(first.hint, "Starter: List three things from this year")
        XCTAssertTrue(cal.isDate(first.start, inSameDayAs: Fx.mon(12)) || cal.isDate(first.start, inSameDayAs: Fx.mon(12, plusDays: 1)))
        XCTAssertLessThanOrEqual(first.start, base.study(for: t.id).map(\.start).min()!)
        XCTAssertEqual(risky.minutes(for: t.id), base.minutes(for: t.id), "same total, just started earlier")
    }
}
