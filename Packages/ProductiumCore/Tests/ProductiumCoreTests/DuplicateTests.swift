import XCTest
@testable import ProductiumCore

final class DuplicateTests: XCTestCase {
    let cal = Fx.cal

    func state(_ commitments: [Commitment] = [Fx.school]) -> DumpState {
        DumpState(items: [], commitments: commitments, exceptions: [], oneOffs: [], markers: [],
                  routines: Routine.defaults, moods: [], screen: [], prefs: Preferences())
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


}
