import XCTest
@testable import ProductiumCore

/// v1.2 C3 / E3 / I2: categories, places and goals through the box, with Undo.
final class BoxNounTests: XCTestCase {
    let cal = Fx.cal

    func testGoalAddChangeRemoveAndContext() {
        var s = BoxState(entries: Fx.timetable)
        let r = BoxApplier.apply([BoxOp(.goal, .add, BoxFields(category: "Work › Studying", target: 600, period: "week"))], to: &s, now: Fx.mon(9), calendar: cal)
        XCTAssertEqual(r.lines, ["Goal: Studying at least 10h a week"])
        XCTAssertEqual(s.goals.first?.measure, .category(CategoryTree.studying))
        let ctx = BoxContext.make(BoxContextInput(now: Fx.mon(9), calendar: cal, state: s))
        XCTAssertTrue(ctx.contains("Goals: \(s.goals[0].ref) Studying 0m of 10h (week)"), ctx)
        BoxApplier.apply([BoxOp(.goal, .add, BoxFields(category: "unproductive", target: 60, atMost: true))], to: &s, now: Fx.mon(9), calendar: cal)
        XCTAssertEqual(s.goals.last?.measure, .group(.unproductive))
        let ch = BoxApplier.apply([BoxOp(.goal, .change, ref: s.goals[0].ref, BoxFields(target: 480))], to: &s, now: Fx.mon(9), calendar: cal)
        XCTAssertEqual(s.goals[0].target, 480)
        BoxApplier.undo(ch, in: &s)
        XCTAssertEqual(s.goals[0].target, 600)
        BoxApplier.apply([BoxOp(.goal, .remove, ref: s.goals[0].ref)], to: &s, now: Fx.mon(9), calendar: cal)
        XCTAssertEqual(s.goals.count, 1)
        XCTAssertEqual(BoxApplier.apply([BoxOp(.goal, .add, BoxFields(category: "tasks", target: 3))], to: &s, now: Fx.mon(9), calendar: cal).lines,
                       ["Goal: Tasks done at least 3 a day"])
    }

    func testThisIsTheLibrary() {
        var s = BoxState()
        let none = BoxApplier.apply([BoxOp(.place, .add, BoxFields(title: "Library"))], to: &s, now: Fx.mon(16), calendar: cal)
        XCTAssertEqual(none.problems.count, 1, "no location: says so")
        s.here = PlaceVisit(latitude: 49.26, longitude: -123.25, arrival: Fx.mon(15, 30))
        let r = BoxApplier.apply([BoxOp(.place, .add, BoxFields(title: "Library"))], to: &s, now: Fx.mon(16), calendar: cal)
        XCTAssertEqual(r.lines, ["Named this place Library"])
        XCTAssertEqual(s.places.place(for: s.here!)?.title, "Library")
        let ctx = BoxContext.make(BoxContextInput(now: Fx.mon(16), calendar: cal, state: s))
        XCTAssertTrue(ctx.contains("Library (here)"))
        let ref = s.places.places[0].ref
        BoxApplier.apply([BoxOp(.place, .change, ref: ref, BoxFields(title: "Koerner Library"))], to: &s, now: Fx.mon(16), calendar: cal)
        XCTAssertEqual(s.places.places[0].name, "Koerner Library")
        let gone = BoxApplier.apply([BoxOp(.place, .remove, ref: ref)], to: &s, now: Fx.mon(16), calendar: cal)
        XCTAssertTrue(s.places.places.isEmpty)
        BoxApplier.undo(gone, in: &s)
        XCTAssertEqual(s.places.places.count, 1)
    }

    func testPutVolleyballUnderExtracurricularAndMerge() {
        var s = BoxState()
        s.categories.add("Volleyball", under: CategoryTree.free)
        s.categories.add("Vball", under: CategoryTree.free)
        s.entries = [Entry(title: "vball", start: Fx.mon(16), end: Fx.mon(17), category: "free.vball", source: .you)]
        let r = BoxApplier.apply([BoxOp(.category, .change, ref: "free.volleyball", BoxFields(category: CategoryTree.extracurricular)),
                                  BoxOp(.category, .remove, ref: "free.vball", BoxFields(category: "free.volleyball"))],
                                 to: &s, now: Fx.mon(18), calendar: cal)
        XCTAssertTrue(r.problems.isEmpty, "\(r.problems)")
        XCTAssertEqual(s.categories.pathText("free.volleyball"), "Work › Extracurricular › Volleyball")
        XCTAssertTrue(s.categories.node("free.volleyball")!.yours, "the taxonomy pass leaves it alone now")
        XCTAssertEqual(s.entries[0].category, "free.volleyball", "no time lost in the merge")
        XCTAssertNil(s.categories.node("free.vball"))
        XCTAssertEqual(BoxApplier.apply([BoxOp(.category, .remove, ref: CategoryTree.scrolling)], to: &s, now: Fx.mon(18), calendar: cal).problems.count, 1)
        BoxApplier.undo(r, in: &s)
        XCTAssertEqual(s.entries[0].category, "free.vball")
        XCTAssertNotNil(s.categories.node("free.vball"))
    }

    func testTrackRecordIsInTheContext() {
        var c = BoxContextInput(now: Fx.mon(9), calendar: cal, state: BoxState())
        c.trackRecord = ["reading: dropped 4 of 5"]
        XCTAssertTrue(BoxContext.make(c).contains("Track record: reading: dropped 4 of 5"))
    }
}
