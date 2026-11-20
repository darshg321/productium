import XCTest
@testable import ProductiumCore

/// v1.1 A1: which days something applies to, without code per case.
final class DayRuleTests: XCTestCase {
    let cal = Fx.cal
    func day(_ d: Int) -> Date { Fx.mon(0, plusDays: d) }   // day(0) = Monday 16 Nov 2026

    func school(_ book: DayRuleBook = DayRuleBook()) -> DayRuleBook {
        var b = book
        b.sequences.append(DaySequence(name: "school", rule: .all([.weekdays([2, 3, 4, 5, 6]), .not(.label("no-school"))]), anchor: day(0)))
        return b
    }

    func testParityAndRanges() {
        let e = DayRuleEvaluator(calendar: cal)
        XCTAssertTrue(e.matches(.dateParity(odd: false), on: day(0)), "16th is even")
        XCTAssertTrue(e.matches(.dateParity(odd: true), on: day(1)))
        XCTAssertTrue(e.matches(.dates(from: day(1), until: day(3)), on: Fx.mon(23, 59, plusDays: 3)), "until is inclusive")
        XCTAssertFalse(e.matches(.dates(from: day(1), until: day(3)), on: day(4)))
        XCTAssertTrue(e.matches(.dates(from: nil, until: nil), on: day(400)))
        XCTAssertTrue(e.matches(.on([Fx.mon(15, plusDays: 2)]), on: day(2)))
        XCTAssertFalse(e.matches(.except([day(2)]), on: Fx.mon(9, plusDays: 2)))
        XCTAssertFalse(e.matches(.weekdays([]), on: day(0)))
        XCTAssertTrue(e.matches(.always, on: day(0)))
        XCTAssertFalse(e.matches(.never, on: day(0)))
    }

    func testAlternatingWeeksAcrossDST() {
        let e = DayRuleEvaluator(calendar: cal)
        let even = DayRule.weekParity(anchor: day(2), odd: false)
        XCTAssertEqual((0..<35).filter { e.matches(even, on: day($0)) }.count, 21, "weeks 0, 2 and 4 of five")
        XCTAssertTrue(e.matches(even, on: day(0)), "the whole anchor week, not just the anchor day")
        XCTAssertFalse(e.matches(even, on: day(7)))
        XCTAssertTrue(e.matches(even, on: day(-14)), "backwards too")
        // Vancouver springs forward 14 March 2027: the week of 8 March and the week of 15 March differ.
        let spring = cal.date(from: DateComponents(year: 2027, month: 3, day: 8))!
        let r = DayRule.weekParity(anchor: spring, odd: false)
        XCTAssertTrue(e.matches(r, on: cal.date(from: DateComponents(year: 2027, month: 3, day: 14))!))
        XCTAssertFalse(e.matches(r, on: cal.date(from: DateComponents(year: 2027, month: 3, day: 15))!))
        XCTAssertTrue(e.matches(r, on: cal.date(from: DateComponents(year: 2027, month: 3, day: 22))!))
    }

    func testABDaysShiftOverAHoliday() {
        var book = school()
        let a = DayRule.nthOf(sequence: "school", mod: 2, eq: 0), b = DayRule.nthOf(sequence: "school", mod: 2, eq: 1)
        var e = DayRuleEvaluator(book: book, calendar: cal)
        // Mon A, Tue B, Wed A, Thu B, Fri A, (weekend), Mon B …
        XCTAssertEqual((0..<8).map { e.matches(a, on: day($0)) ? "A" : e.matches(b, on: day($0)) ? "B" : "-" },
                       ["A", "B", "A", "B", "A", "-", "-", "B"])
        // Wednesday is cancelled: it isn't counted, so Thursday becomes the A day and the rest shift.
        book.label("no-school", [day(2)], calendar: cal)
        e = DayRuleEvaluator(book: book, calendar: cal)
        XCTAssertEqual((0..<8).map { e.matches(a, on: day($0)) ? "A" : e.matches(b, on: day($0)) ? "B" : "-" },
                       ["A", "B", "-", "A", "B", "-", "-", "A"])
        XCTAssertEqual(e.index(in: "school", of: day(7)), 4)
        XCTAssertNil(e.index(in: "school", of: day(5)), "Saturday isn't a school day")
        XCTAssertEqual(e.index(in: "school", of: day(-3)), -1, "the Friday before the anchor")
        XCTAssertEqual(e.days(b, from: day(0), count: 3), [day(1), day(4), day(8)])
    }

    func testSixDayRotation() {
        let book = school()
        let e = DayRuleEvaluator(book: book, calendar: cal)
        let day3 = DayRule.nthOf(sequence: "school", mod: 6, eq: 2)
        // School days 0…: Mon16(0) Tue(1) Wed(2) Thu(3) Fri(4) Mon23(5) Tue24(6) Wed25(7) Thu26(8)
        XCTAssertEqual(e.days(day3, from: day(0), count: 3), [day(2), day(10), day(18)])
    }

    func testNestedRules() {
        var book = school()
        book.label("exam-week", (14..<19).map(day), calendar: cal)
        let e = DayRuleEvaluator(book: book, calendar: cal)
        // B days in exam week, or any Saturday, but never Thursday 3 December.
        let r = DayRule.all([.any([.all([.nthOf(sequence: "school", mod: 2, eq: 1), .label("exam-week")]), .weekdays([7])]),
                             .not(.on([day(17)]))])
        let hits = (0..<21).filter { e.matches(r, on: day($0)) }
        XCTAssertEqual(hits, [5, 12, 15, 19], "Sat 21, Sat 28, Tue 1 (school day 11: B), Sat 5; Thu 3 (B) is excluded")
    }

    func testCyclesAndEmptySequencesAreSafe() {
        let book = DayRuleBook(sequences: [DaySequence(name: "loop", rule: .nthOf(sequence: "loop", mod: 2, eq: 0), anchor: day(0)),
                                           DaySequence(name: "none", rule: .never, anchor: day(0))])
        let e = DayRuleEvaluator(book: book, calendar: cal)
        XCTAssertFalse(e.matches(.nthOf(sequence: "loop", mod: 2, eq: 0), on: day(3)))
        XCTAssertFalse(e.matches(.nthOf(sequence: "none", mod: 2, eq: 0), on: day(300)))
        XCTAssertFalse(e.matches(.nthOf(sequence: "missing", mod: 2, eq: 0), on: day(1)))
        XCTAssertFalse(e.matches(.nthOf(sequence: "loop", mod: 0, eq: 0), on: day(1)))
    }

    func testCodableIsCompactAndStable() throws {
        let r = DayRule.all([.weekdays([6, 2, 4]), .not(.label("no-school")), .nthOf(sequence: "school", mod: 2, eq: 1),
                             .weekParity(anchor: day(0), odd: true), .dates(from: day(0), until: nil), .dateParity(odd: true)])
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = .sortedKeys
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let data = try enc.encode(r)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.hasPrefix(#"{"all":[{"weekdays":[2,4,6]},{"not":{"label":"no-school"}},{"nthOf":{"eq":1,"mod":2,"sequence":"school"}}"#), json)
        XCTAssertEqual(try dec.decode(DayRule.self, from: data), r)
        XCTAssertEqual(try enc.encode(try dec.decode(DayRule.self, from: data)), data, "byte for byte")
        XCTAssertThrowsError(try dec.decode(DayRule.self, from: Data("[2,4]".utf8)), "bare v1.0 lists are gone")
        XCTAssertThrowsError(try dec.decode(DayRule.self, from: Data("{}".utf8)))
    }

    func testPlainWords() {
        XCTAssertEqual(DayRule.weekdays([2, 3, 4, 5, 6]).text(cal), "Mon–Fri")
        XCTAssertEqual(DayRule.nthOf(sequence: "school", mod: 2, eq: 1).text(cal), "B days (school)")
        XCTAssertEqual(DayRule.all([.weekdays([2, 4]), .not(.label("exam-week"))]).text(cal), "Mon, Wed and not exam-week")
    }
}
