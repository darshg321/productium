import XCTest
@testable import ProductiumCore

final class TimetableTests: XCTestCase {
    let cal = Fx.cal

    func school() -> Commitment {
        Commitment(title: "School", kind: .school, weekdays: [2, 3, 4, 5, 6], start: TimeOfDay(8, 30), end: TimeOfDay(15),
                   periods: [ActivityPeriod(title: "P1 Math", start: TimeOfDay(8, 30), end: TimeOfDay(9, 45)),
                             ActivityPeriod(title: "P2 Spare", start: TimeOfDay(9, 45), end: TimeOfDay(11)),
                             ActivityPeriod(title: "P3 Lunch", start: TimeOfDay(11), end: TimeOfDay(12)),
                             ActivityPeriod(title: "P4 English", start: TimeOfDay(12), end: TimeOfDay(15), weekdays: [2, 4])])
    }

    func testOneRepeatingEntryPerPeriodUnderSchoolWithSparesOpen() {
        var tree = CategoryTree(), entries: [Entry] = []
        Timetable.write(school(), into: &entries, tree: &tree, anchor: Fx.mon(0), calendar: cal)
        XCTAssertEqual(entries.map(\.title), ["P1 Math", "P2 Spare", "P3 Lunch", "P4 English"])
        XCTAssertTrue(entries.allSatisfy { $0.source == .you && $0.repeats != nil && tree.isUnder($0.category, CategoryTree.school) })
        XCTAssertEqual(entries.map(\.open), [false, true, true, false])
        XCTAssertEqual(entries[0].topics, ["math"])
        XCTAssertEqual(tree.pathText(entries[0].category), "School › Math")
        XCTAssertEqual(Timetable.className("2: Biology"), "Biology")
        XCTAssertEqual(Timetable.className("Soccer"), "Soccer")
        // The English period runs Mon / Wed only.
        let tue = Days.on(Fx.mon(12, plusDays: 1), entries, now: Fx.mon(7), calendar: cal)
        XCTAssertFalse(tue.contains { $0.title == "P4 English" })
        XCTAssertTrue(Days.on(Fx.mon(12, plusDays: 2), entries, now: Fx.mon(7), calendar: cal).contains { $0.title == "P4 English" })
    }

    func testEditingReplacesAndKeepsMarks() {
        var tree = CategoryTree(), entries: [Entry] = []
        var soccer = Commitment(title: "Soccer", kind: .extracurricular, weekdays: [2, 4], start: TimeOfDay(16), end: TimeOfDay(17, 30))
        Timetable.write(soccer, into: &entries, tree: &tree, anchor: Fx.mon(0), calendar: cal)
        entries[0].marks["2026-11-16"] = .skipped
        soccer.end = TimeOfDay(18)
        Timetable.write(soccer, into: &entries, tree: &tree, anchor: Fx.mon(0), calendar: cal)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].marks["2026-11-16"], .skipped)
        XCTAssertEqual(entries[0].end, Fx.mon(18))
        XCTAssertEqual(tree.pathText(entries[0].category), "Work › Extracurricular › Soccer")
    }

    func testRoundTripBackToTheEditorShapeAndWithARule() {
        var tree = CategoryTree(), entries: [Entry] = []
        let odd = Commitment(title: "Chem lab", kind: .school, weekdays: [3, 5], start: TimeOfDay(13), end: TimeOfDay(14),
                             when: .dateParity(odd: true))
        Timetable.write(odd, into: &entries, tree: &tree, anchor: Fx.mon(0), calendar: cal)
        let back = Timetable.commitments(from: entries, tree: tree, calendar: cal)
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back[0].weekdays, [3, 5])
        XCTAssertEqual(back[0].when, .dateParity(odd: true))
        XCTAssertEqual(back[0].kind, .school)
        XCTAssertEqual(back[0].start, TimeOfDay(13))
    }

    func testPlannerWorksAroundTheTimetableAndFindsSchoolDays() {
        var tree = CategoryTree(), entries: [Entry] = []
        Timetable.write(school(), into: &entries, tree: &tree, anchor: Fx.mon(0), calendar: cal)
        let essay = WorkItem(title: "Essay", kind: .essay, due: Fx.mon(9, plusDays: 4), estimateMinutes: 200)
        let plan = Planner.plan(Fx.input(now: Fx.mon(7), items: [essay], entries: entries, categories: tree))
        let fixed = Days.expand(entries, in: DateInterval(start: Fx.mon(0), end: Fx.mon(0, plusDays: 7)), now: Fx.mon(7), calendar: cal)
        for b in plan.study(for: essay.id) { XCTAssertFalse(fixed.contains { $0.busy && b.start < $0.end && $0.start < b.end }, "\(b.start)") }
        XCTAssertTrue(Days.isSchoolDay(Fx.mon(12), entries: entries, tree: tree, prefs: Preferences(), calendar: cal))
        XCTAssertFalse(Days.isSchoolDay(Fx.mon(12, plusDays: 5), entries: entries, tree: tree, prefs: Preferences(), calendar: cal))
        // No timetable yet: Settings' school days decide.
        XCTAssertTrue(Days.isSchoolDay(Fx.mon(12), entries: [], tree: tree, prefs: Preferences(), calendar: cal))
    }
}
