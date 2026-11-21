import XCTest
@testable import ProductiumCore

/// v1.2 E2–E5: places from visits, names from entries, a renamed place keeps its visits, entries get their place.
final class PlaceBookTests: XCTestCase {
    let gym = (49.2606, -123.2460)
    let home = (49.2500, -123.1000)

    func visit(_ p: (Double, Double), _ d: Int, _ h: Int, _ h2: Int, jitter: Double = 0) -> PlaceVisit {
        PlaceVisit(latitude: p.0 + jitter, longitude: p.1, arrival: Fx.mon(h, plusDays: d), departure: Fx.mon(h2, plusDays: d))
    }

    func testClustersNamingAndRenameKeepsVisits() {
        var book = PlaceBook()
        let visits = (0..<6).map { visit(gym, -$0, 16, 18, jitter: Double($0) * 0.0003) } + [visit(home, 0, 19, 23)]
            + [PlaceVisit(latitude: 49.3, longitude: -123.2, arrival: Fx.mon(12), departure: Fx.mon(12, 5))]
        let made = book.cluster(visits, now: Fx.mon(23))
        XCTAssertEqual(made.count, 2, "the gym (6 visits within 150 m) and home; 5 minutes isn't a place")
        var entries = (0..<6).map { d in
            Entry(title: "Volleyball", start: Fx.mon(16, 5, plusDays: -d), end: Fx.mon(17, 50, plusDays: -d),
                  category: CategoryTree.extracurricular, source: .you)
        }
        XCTAssertEqual(EntryBuilder.places(&entries, visits: visits, book: book, since: Fx.mon(0, plusDays: -10), now: Fx.mon(23)), 6)
        let gymId = book.place(for: visits[0])!.id
        XCTAssertTrue(entries.allSatisfy { $0.placeId == gymId })
        XCTAssertEqual(book.suggestedName(gymId, entries: entries, tree: CategoryTree())?.count, 6)
        XCTAssertEqual(book.nameFromEntries(entries, tree: CategoryTree()), [gymId])
        XCTAssertEqual(book.places.first { $0.id == gymId }?.name, "Extracurricular")
        book.name(gymId, "Gym")
        XCTAssertEqual(book.place(for: visits[3])?.title, "Gym", "a renamed place keeps its visits")
        XCTAssertEqual(book.nameFromEntries(entries, tree: CategoryTree()), [], "your name is never replaced")
        let rows = Where.rows(visits: visits, book: book, entries: entries, range: DateInterval(start: Fx.mon(0, plusDays: -7), end: Fx.mon(23, 59)),
                              now: Fx.mon(23, 59))
        XCTAssertEqual(rows.first?.name, "Gym")
        XCTAssertEqual(rows.first?.minutes, 6 * 120)
        XCTAssertEqual(rows.first?.top.first?.0, CategoryTree.extracurricular)
        XCTAssertTrue(Where.csv(LocationTrace(), book: book).hasPrefix("arrival,departure"))
    }

    func testMergeAndForget() {
        var book = PlaceBook()
        book.cluster([visit(gym, 0, 16, 18)], now: Fx.mon(18))
        let a = book.places[0].id
        let b = Place(latitude: gym.0 + 0.01, longitude: gym.1, createdAt: Fx.mon(18))
        book.places.append(b)
        var es = [Entry(title: "x", start: Fx.mon(16), end: Fx.mon(17), category: CategoryTree.other, placeId: b.id, source: .you)]
        book.merge(a, b.id, entries: &es)
        XCTAssertEqual(es[0].placeId, a)
        XCTAssertEqual(book.places.count, 1)
        book.forget(a, entries: &es)
        XCTAssertNil(es[0].placeId)
        XCTAssertTrue(book.places.isEmpty)
    }

    func testTraceKeepsOnePointPerFiveMinutesAnd180Days() {
        var t = LocationTrace()
        XCTAssertTrue(t.add(TracePoint(at: Fx.mon(8), latitude: 1, longitude: 1, accuracy: 20)))
        XCTAssertFalse(t.add(TracePoint(at: Fx.mon(8, 3), latitude: 1, longitude: 1, accuracy: 20)))
        XCTAssertTrue(t.add(TracePoint(at: Fx.mon(8, 6), latitude: 1, longitude: 1, accuracy: 20)))
        t.add(PlaceVisit(latitude: 1, longitude: 1, arrival: Fx.mon(9)))
        t.add(PlaceVisit(latitude: 1, longitude: 1, arrival: Fx.mon(9), departure: Fx.mon(10)))
        XCTAssertEqual(t.visits.count, 1)
        XCTAssertEqual(t.visits[0].departure, Fx.mon(10))
        t.prune(now: Fx.mon(9, plusDays: 181))
        XCTAssertTrue(t.points.isEmpty && t.visits.isEmpty)
    }
}
