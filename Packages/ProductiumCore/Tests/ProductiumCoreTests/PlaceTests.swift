import XCTest
@testable import ProductiumCore

final class PlaceTests: XCTestCase {
    let cal = Fx.cal
    let home = SavedPlace(id: "home", name: "Home", latitude: 43.6500, longitude: -79.3800)

    func marker(_ a: String, _ p: MarkerPhase) -> CheckIn {
        CheckIn(at: Fx.mon(8, 16), phrase: "", activity: a, category: .commute, phase: p)
    }



}
