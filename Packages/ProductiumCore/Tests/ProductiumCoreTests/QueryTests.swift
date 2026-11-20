import XCTest
@testable import ProductiumCore

/// A 28-day fixture: Math (9:00–10:00) and English (10:00–11:00) every weekday from `Fx.timetable`'s week, one absence
/// (Wed 25 Nov, Math skipped), three Math days confirmed, Math homework Mon / Wed evenings, scrolling Tue / Thu nights.
final class QueryTests: XCTestCase {
    let cal = Fx.cal
    var tree = CategoryTree()
    var entries: [Entry] = []
    var math = "", english = ""
    /// Sunday 13 Dec 2026, evening: the 28 days are Mon 16 Nov … Sun 13 Dec.
    let now = Fx.mon(20, plusDays: 27)

    override func setUp() {
        math = tree.add("Math", under: CategoryTree.school)!.id
        english = tree.add("English", under: CategoryTree.school)!.id
        var m = Entry(title: "Math", start: Fx.mon(9), end: Fx.mon(10), category: math, repeats: .weekly([2, 3, 4, 5, 6]), source: .you)
        m.marks["2026-11-25"] = .skipped
        for d in ["2026-11-16", "2026-11-17", "2026-11-18"] { m.marks[d] = .confirmed }
        let e = Entry(title: "English", start: Fx.mon(10), end: Fx.mon(11), category: english, repeats: .weekly([2, 3, 4, 5, 6]), source: .you)
        entries = [m, e]
        for week in 0..<4 {
            for dow in [0, 2] {   // Monday, Wednesday
                entries.append(Entry(title: "Math homework", start: Fx.mon(19, plusDays: week * 7 + dow), end: Fx.mon(19, 45, plusDays: week * 7 + dow),
                                     category: CategoryTree.studying, filedByYou: true, topics: ["math"], source: .you))
            }
            for dow in [1, 3] {   // Tuesday, Thursday
                entries.append(Entry(title: "TikTok", start: Fx.mon(22, plusDays: week * 7 + dow), end: Fx.mon(22, 30, plusDays: week * 7 + dow),
                                     category: CategoryTree.scrolling, filedByYou: true, topics: ["tiktok"], source: .you))
            }
        }
    }

    func run(_ q: TimeQuery) -> QueryResult {
        TimeQueryEngine.run(q, entries: entries, tree: tree, now: now, calendar: cal)
    }

    func testMathClassOnly() {
        let r = run(TimeQuery(id: "q1", range: .init(last: "28d"), filter: .init(categories: ["School › Math"])))
        XCTAssertEqual(r.total, 19 * 60, "20 weekdays, one absence")
        XCTAssertTrue(r.problems.isEmpty, "\(r.problems)")
        XCTAssertEqual(r.coverage.days, 28)
        XCTAssertEqual(r.coverage.daysWithData, 19)
        XCTAssertEqual(QueryText.fill("{q1.total}", [r]), "19h")
    }

    func testAllMathAddsHomeworkToTheClass() {
        let r = run(TimeQuery(id: "q1", range: .init(last: "28d"), filter: .init(topics: ["math"]), groupBy: "category2"))
        XCTAssertEqual(r.total, 19 * 60 + 8 * 45)
        XCTAssertEqual(r.rows.first { $0.key == math }?.value, 19 * 60)
        XCTAssertEqual(r.rows.first { $0.key == CategoryTree.studying }?.value, 8 * 45)
    }

    func testByHourPutsMathInTheNineOClockHour() {
        let r = run(TimeQuery(id: "q1", range: .init(last: "28d"), filter: .init(categories: [math]), groupBy: "hour"))
        XCTAssertEqual(r.rows.count, 1)
        XCTAssertEqual(r.rows.first?.value, 19 * 60)
        let evening = run(TimeQuery(id: "q2", range: .init(last: "28d"), filter: .init(groups: ["unproductive"]), groupBy: "hour"))
        XCTAssertEqual(evening.total, 8 * 30, "scrolling, 22:00–22:30 eight times")
        XCTAssertEqual(evening.rows.map(\.value), [240])
    }

    func testWeekdaysFilter() {
        let mondays = run(TimeQuery(id: "q1", range: .init(last: "28d"), filter: .init(categories: [math], weekdays: [2])))
        XCTAssertEqual(mondays.total, 4 * 60)
        let wednesdays = run(TimeQuery(id: "q2", range: .init(last: "28d"), filter: .init(categories: [math], weekdays: [4])))
        XCTAssertEqual(wednesdays.total, 3 * 60, "one Wednesday was an absence")
    }

    func testConfirmedOnlyLeavesOutAssumedClasses() {
        let r = run(TimeQuery(id: "q1", range: .init(last: "28d"), filter: .init(categories: [math], confirmedOnly: true)))
        XCTAssertEqual(r.total, 3 * 60)
        let all = run(TimeQuery(id: "q2", range: .init(last: "28d"), filter: .init(categories: [math])))
        XCTAssertEqual(all.coverage.assumedMinutes, 16 * 60, "the other 16 classes are assumed")
    }

    func testComparePreviousPeriod() {
        let r = run(TimeQuery(id: "q1", range: .init(last: "14d"), filter: .init(categories: [math]), compare: "previous"))
        XCTAssertEqual(r.total, 10 * 60)
        XCTAssertEqual(r.previousTotal, 9 * 60, "the earlier fortnight has the absence")
        XCTAssertEqual(QueryText.fill("{q1.previous}", [r]), "9h")
    }

    func testCountAndAveragePerDay() {
        let count = run(TimeQuery(id: "q1", range: .init(last: "28d"), filter: .init(titles: ["homework"]), measure: "count"))
        XCTAssertEqual(count.total, 8)
        let avg = run(TimeQuery(id: "q2", range: .init(last: "28d"), filter: .init(categories: [math]), measure: "avgPerDay"))
        XCTAssertEqual(avg.total, Double(19 * 60) / 28, accuracy: 0.01)
    }
}

final class PinnedChartTests: XCTestCase {
    func testPinnedChartKeepsTheQueryAndSurvivesTheBackup() throws {
        var s = AppState()
        s.pinnedCharts = [PinnedChart(title: "Math class", query: TimeQuery(id: "q1", range: .init(last: "28d"),
                                                                           filter: .init(categories: ["School › Math"]), chart: "bar"),
                                      pinnedAt: Fx.mon(12))]
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(AppState.self, from: enc.encode(s))
        XCTAssertEqual(back.pinnedCharts, s.pinnedCharts)
    }
}
