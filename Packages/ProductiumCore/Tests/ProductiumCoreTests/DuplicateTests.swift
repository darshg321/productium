import XCTest
@testable import ProductiumCore

final class DuplicateTests: XCTestCase {
    let cal = Fx.cal

    func testSimilarTitlesAndOverlap() {
        XCTAssertTrue(EventMatch.similarTitles("Math (P1)", "P1 Math"))
        XCTAssertTrue(EventMatch.similarTitles("P3 English", "English + Data Mgmt"))
        XCTAssertFalse(EventMatch.similarTitles("P1 Math", "P2 English"))
        XCTAssertEqual(EventMatch.overlap((Fx.mon(11, 10), Fx.mon(12)), (Fx.mon(10, 56), Fx.mon(12, 15))), 1, accuracy: 0.001)
    }

    func testCalendarEventsBecomeEntriesAndKeepYourMarksOnReimport() {
        let window = DateInterval(start: Fx.mon(0), end: Fx.mon(0, plusDays: 14))
        let dentist = FixedEvent(id: "g2", title: "Dentist", start: Fx.mon(11, 10, plusDays: 3), end: Fx.mon(12, plusDays: 3))
        let cs = FixedEvent(id: "g1", title: "CS Club Meeting", start: Fx.mon(11, 10, plusDays: 3), end: Fx.mon(12, plusDays: 3))
        let club = Entry(title: "CS club", start: Fx.mon(10, 56), end: Fx.mon(12, 15), category: CategoryTree.extracurricular,
                         repeats: .weekly([5]), source: .you)
        var entries = [club]
        CalendarEntries.merge([cs, dentist], into: &entries, window: window, now: Fx.mon(7), calendar: cal)
        let cal1 = entries.filter { $0.source == .calendar }
        XCTAssertEqual(cal1.count, 2)
        XCTAssertEqual(cal1.first { $0.title == "Dentist" }?.id, Entry.calendarId("g2"))
        let shown = Days.on(Fx.mon(12, plusDays: 3), entries, now: Fx.mon(7), calendar: cal).map(\.title)
        XCTAssertEqual(shown.sorted(), ["CS club", "Dentist"], "the twin counts once, as yours")
        // You skip the dentist; a re-import keeps it, and a vanished event goes.
        let i = entries.firstIndex { $0.title == "Dentist" }!
        entries[i].marks[DayKeys.key(dentist.start, cal)] = .skipped
        CalendarEntries.merge([dentist], into: &entries, window: window, now: Fx.mon(8), calendar: cal)
        XCTAssertEqual(entries.filter { $0.source == .calendar }.map(\.title), ["Dentist"])
        XCTAssertEqual(entries.first { $0.title == "Dentist" }?.marks[DayKeys.key(dentist.start, cal)], .skipped)
        // Outside the window: left alone.
        let old = FixedEvent(id: "g0", title: "Old", start: Fx.mon(9, plusDays: -3), end: Fx.mon(10, plusDays: -3))
        entries.append(Entry(id: Entry.calendarId(old.id), title: old.title, start: old.start, end: old.end, category: CategoryTree.other, source: .calendar))
        CalendarEntries.merge([dentist], into: &entries, window: window, now: Fx.mon(8), calendar: cal)
        XCTAssertTrue(entries.contains { $0.title == "Old" })
    }
}
