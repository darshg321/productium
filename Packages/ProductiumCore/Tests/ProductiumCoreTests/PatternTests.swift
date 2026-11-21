import XCTest
@testable import ProductiumCore

/// v1.2 P1 on a four-week fixture.
final class PatternTests: XCTestCase {
    let cal = Fx.cal

    func testFindsTheFourKinds() {
        var log = Week4.timetable
        let task = UUID()
        for d in -28 ..< 0 {
            let day = Fx.mon(12, plusDays: d)
            let wd = cal.component(.weekday, from: day)
            if wd == 3 {
                log.append(Week4.e("Volleyball", CategoryTree.extracurricular, d, 16, 0, 17, 30))
                log.append(Week4.e("TikTok", CategoryTree.scrolling, d, 17, 35, 18, 15, src: .sensor))
            }
            if (2...6).contains(wd) {
                // Planned 16:00 and 21:00 sessions; the 4 pm one happens, the 9 pm one mostly doesn't.
                log.append(Entry(title: "Essay", start: Fx.mon(16, plusDays: d), end: Fx.mon(16, 30, plusDays: d), category: CategoryTree.studying,
                                 taskId: task, source: .plan, createdAt: Fx.mon(7, plusDays: d)))
                if wd != 3 {
                    log.append(Entry(title: "Essay", start: Fx.mon(16, 5, plusDays: d), end: Fx.mon(16, 30, plusDays: d), category: CategoryTree.studying,
                                     taskId: task, source: .you, createdAt: Fx.mon(16, 30, plusDays: d)))
                }
            }
            // Early starts on Mondays and Wednesdays: more study.
            if wd == 2 || wd == 4 { log.append(Week4.e("Homework", CategoryTree.studying, d, 9, 0, 11, 30)) }
            else if wd == 5 || wd == 6 { log.append(Week4.e("Homework", CategoryTree.studying, d, 19, 0, 19, 30)) }
        }
        let p = PatternFinder.find(entries: log, tree: CategoryTree(), now: Fx.mon(8), calendar: cal)
        let after = p.first { $0.kind == .after }
        XCTAssertEqual(after?.text, "You lose about 40m after extracurricular on Tuesdays (scrolling, 4 of the last 4)")
        XCTAssertEqual(after?.evidence.count, 4)
        XCTAssertTrue(p.contains { $0.kind == .earlyStart && $0.text.hasPrefix("Days you start before 10 have") })
        XCTAssertTrue(p.contains { $0.kind == .weekday })
        XCTAssertTrue(p.allSatisfy { !$0.evidence.isEmpty })
        // Nothing to say on a near-empty log.
        XCTAssertTrue(PatternFinder.find(entries: Week4.timetable, tree: CategoryTree(), now: Fx.mon(8), calendar: cal).isEmpty)
    }
}
