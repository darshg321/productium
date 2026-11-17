import XCTest
@testable import ProductiumCore

final class DuplicateTests: XCTestCase {
    let cal = Fx.cal

    func state(_ commitments: [Commitment] = [Fx.school]) -> DumpState {
        DumpState(items: [], commitments: commitments, exceptions: [], oneOffs: [], markers: [],
                  routines: Routine.defaults, moods: [], screen: [], prefs: Preferences())
    }

    func event(_ title: String, _ d: Int = 1) -> DumpOp {
        .upsert("event", ["title": .string(title), "date": .string("2026-11-17"), "start": .string("08:30"), "end": .string("09:30")])
    }

    func testRewordedPeriodIsAnUpdateNotASecondEvent() {
        var s = state()
        DumpApplier.apply(DumpResult(ops: [event("P1 Math")], reply: ""), to: &s, now: Fx.mon(7), calendar: cal)
        DumpApplier.apply(DumpResult(ops: [event("Math (P1)")], reply: ""), to: &s, now: Fx.mon(7), calendar: cal)
        XCTAssertEqual(s.oneOffs.count, 1)
        XCTAssertEqual(s.oneOffs[0].title, "Math (P1)")
        DumpApplier.apply(DumpResult(ops: [event("English + Data Mgmt")], reply: ""), to: &s, now: Fx.mon(7), calendar: cal)
        XCTAssertEqual(s.oneOffs.count, 2, "a different class in the same slot is a different event")
    }

    func testSimilarTitlesAndOverlap() {
        XCTAssertTrue(EventMatch.similarTitles("Math (P1)", "P1 Math"))
        XCTAssertTrue(EventMatch.similarTitles("P3 English", "English + Data Mgmt"))
        XCTAssertFalse(EventMatch.similarTitles("P1 Math", "P2 English"))
        XCTAssertEqual(EventMatch.overlap((Fx.mon(11, 10), Fx.mon(12)), (Fx.mon(10, 56), Fx.mon(12, 15))), 1, accuracy: 0.001)
    }

    func testCalendarEventThatIsAnActivityIsShownOnce() {
        let club = Commitment(title: "CS club", kind: .extracurricular, weekdays: [5], start: TimeOfDay(10, 56), end: TimeOfDay(12, 15))
        let thu = Fx.mon(0, plusDays: 3)
        let cs = FixedEvent(id: "g1", title: "CS Club Meeting", start: Fx.mon(11, 10, plusDays: 3), end: Fx.mon(12, plusDays: 3))
        let dentist = FixedEvent(id: "g2", title: "Dentist", start: Fx.mon(11, 10, plusDays: 3), end: Fx.mon(12, plusDays: 3))
        let shown = EventMatch.withoutActivityTwins([cs, dentist], commitments: [club], exceptions: [], calendar: cal)
        XCTAssertEqual(shown.map(\.title), ["Dentist"])
        _ = thu
    }

    func testDayChangeThatChangesNothingIsRefused() {
        var s = state()
        let id = Ref.activity(s.commitments[0].id)
        let rep = DumpApplier.apply(DumpResult(ops: [.upsert("day_change", ["date": .string("2026-11-18"), "activity": .string(id), "cancelled": .bool(false)])],
                                               reply: ""), to: &s, now: Fx.mon(7), calendar: cal)
        XCTAssertTrue(s.exceptions.isEmpty)
        XCTAssertEqual(rep.problems.count, 1)
        DumpApplier.apply(DumpResult(ops: [.upsert("day_change", ["date": .string("2026-11-18"), "activity": .string(id), "start": .string("10:00")])],
                                     reply: ""), to: &s, now: Fx.mon(7), calendar: cal)
        XCTAssertEqual(s.exceptions.count, 1)
    }

    func testTimetableLivesInThePeriodsAndPaintsInTheWeek() {
        var s = state()
        let id = Ref.activity(s.commitments[0].id)
        let periods: JSONValue = .array([
            .object(["title": .string("P1 Math"), "start": .string("08:30"), "end": .string("09:40")]),
            .object(["title": .string("P2 English"), "start": .string("09:45"), "end": .string("10:55"), "weekdays": .array([.number(2)])]),
        ])
        DumpApplier.apply(DumpResult(ops: [.upsert("activity", id: id, ["periods": periods])], reply: ""),
                          to: &s, now: Fx.mon(7), calendar: cal)
        XCTAssertEqual(s.commitments[0].periods?.count, 2)
        XCTAssertTrue(s.oneOffs.isEmpty)
        let segs = TimelineBuilder.segments(DayInputs(day: Fx.mon(0), events: [], commitments: s.commitments, routines: [], outcomes: [],
                                                      health: nil, screen: nil, prefs: Preferences()), calendar: cal)
        XCTAssertEqual(segs.first { $0.label == "P1 Math" }?.start, Fx.mon(8, 30))
        XCTAssertEqual(segs.first { $0.label == "P2 English" }?.category, .school)
        XCTAssertTrue(Prompts.dumpContext(DumpContextInput(now: Fx.mon(7), calendar: cal, state: s)).contains("periods: P1 Math 8:30-9:40"))
    }
}
