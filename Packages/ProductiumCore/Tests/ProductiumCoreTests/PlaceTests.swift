import XCTest
@testable import ProductiumCore

final class PlaceTests: XCTestCase {
    let cal = Fx.cal
    let home = SavedPlace(id: "home", name: "Home", latitude: 43.6500, longitude: -79.3800)

    func marker(_ a: String, _ p: MarkerPhase) -> CheckIn {
        CheckIn(at: Fx.mon(8, 16), phrase: "", activity: a, category: .commute, phase: p)
    }

    func testAtSchoolWithNoSchoolPlaceOffersToSaveIt() {
        let offer = PlaceSuggester.offer(after: MarkerParser.parse("at school", at: Fx.mon(8, 16), commitments: [Fx.school], calendar: cal),
                                         places: [home], commitments: [Fx.school], declined: [])
        XCTAssertEqual(offer?.id, "school")
        XCTAssertEqual(offer?.name, "School")
        let saved = SavedPlace(id: "school", name: "School", latitude: 43.7, longitude: -79.4)
        XCTAssertNil(PlaceSuggester.offer(after: [marker("to_school", .end)], places: [home, saved], commitments: [], declined: []))
        XCTAssertNil(PlaceSuggester.offer(after: [marker("to_school", .end)], places: [home], commitments: [], declined: ["school"]),
                     "not asked again once turned down")
    }

    func testEndOfAnActivityOffersItsPlace() {
        let offer = PlaceSuggester.offer(after: [marker("soccer", .end)], places: [home], commitments: [Fx.soccer], declined: [])
        XCTAssertEqual(offer?.id, "soccer_practice")
        XCTAssertNil(PlaceSuggester.offer(after: [marker("study", .end)], places: [home], commitments: [Fx.soccer], declined: []))
    }

    func testRepeatVisitsProposeAPlaceThatNeedsAName() {
        func visit(_ d: Int, lat: Double = 43.7000, lon: Double = -79.4000, mins: Int = 60) -> PlaceVisit {
            PlaceVisit(latitude: lat, longitude: lon, arrival: Fx.mon(16, plusDays: d), departure: Fx.mon(16, mins, plusDays: d))
        }
        let two = [visit(0), visit(1)]
        XCTAssertNil(PlaceSuggester.frequent(two, places: [home], calendar: cal))
        let three = two + [visit(2), visit(2, lon: -79.4004)]
        let offer = PlaceSuggester.frequent(three, places: [home], calendar: cal)
        XCTAssertEqual(offer?.needsName, true)
        XCTAssertNotNil(offer?.latitude)
        XCTAssertNil(PlaceSuggester.frequent(three, places: [home, SavedPlace(id: "x", name: "X", latitude: 43.7, longitude: -79.4)], calendar: cal),
                     "already saved")
        XCTAssertNil(PlaceSuggester.frequent([visit(0, mins: 10), visit(1, mins: 10), visit(2, mins: 10)], places: [], calendar: cal),
                     "short pass-throughs aren't visits")
    }
}
