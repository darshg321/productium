import XCTest
@testable import ProductiumCore

/// v1.1 I2: a day as an agenda list.
final class AgendaTests: XCTestCase {
    let cal = Fx.cal
    let essay = WorkItem(title: "Essay", kind: .essay, due: Fx.mon(15, plusDays: 1), estimateMinutes: 240)

    func rows(_ day: Int, items: [WorkItem]? = nil, now: Date = Fx.mon(6)) -> [AgendaRow] {
        let items = items ?? [essay]
        let plan = Planner.plan(Fx.input(now: now, items: items))
        return Agenda.rows(day: Fx.mon(0, plusDays: day), plan: plan, items: items, now: now, calendar: cal)
    }

    func testSchoolDayIsWakeFirstBedLastWithSchoolAsOneQuietRow() {
        let r = rows(1)
        XCTAssertEqual(r.first?.kind, .wake)
        XCTAssertEqual(r.last?.kind, .bed)
        XCTAssertEqual(r.map(\.start), r.map(\.start).sorted(), "in time order")
        let school = r.filter { $0.kind == .fixed && $0.title.contains("School") }
        XCTAssertEqual(school.count, 1, "\(r.map(\.title))")
        XCTAssertTrue(r.contains { $0.kind == .leave })
        XCTAssertTrue(r.contains { $0.kind == .due && $0.title == "Essay" }, "due inline")
        XCTAssertTrue(r.filter { $0.kind == .study }.allSatisfy { $0.itemId == essay.id && $0.blockId != nil }, "study rows open the task")
    }

    func testFreeTimeShowsAsGapsAndNothingOverlapsIt() {
        let r = rows(1)
        let free = r.filter { $0.kind == .free }
        XCTAssertFalse(free.isEmpty)
        XCTAssertTrue(free.allSatisfy { ($0.minutes ?? 0) >= Agenda.minFreeMinutes })
        for f in free {
            XCTAssertFalse(r.contains { $0.kind == .study && $0.start < f.end! && ($0.end ?? $0.start) > f.start }, "free \(f.start) overlaps study")
        }
    }

    func testNowMarkerOnlyOnToday() {
        let now = Fx.mon(16)
        XCTAssertEqual(rows(0, now: now).filter { $0.kind == .now }.count, 1)
        XCTAssertTrue(rows(1, now: now).filter { $0.kind == .now }.isEmpty)
    }


    func testPeriodsFoldIntoOneRow() {
        let blocks = [PlannedBlock(kind: .commitment, start: Fx.mon(8, 30), end: Fx.mon(10), title: "Math", sourceId: "school"),
                      PlannedBlock(kind: .commitment, start: Fx.mon(10), end: Fx.mon(12), title: "English", sourceId: "school")]
        var plan = Plan.empty
        plan.blocks = blocks
        let r = Agenda.rows(day: Fx.mon(0), plan: plan, items: [], now: Fx.mon(6), calendar: cal)
        let fixed = r.filter { $0.kind == .fixed }
        XCTAssertEqual(fixed.count, 1)
        XCTAssertEqual(fixed[0].children.map(\.title), ["Math", "English"])
        XCTAssertEqual(fixed[0].end, Fx.mon(12))
    }
}
