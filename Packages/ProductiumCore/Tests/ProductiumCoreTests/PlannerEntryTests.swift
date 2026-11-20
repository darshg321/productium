import XCTest
@testable import ProductiumCore

// v1.2 O3: the planner reading fixed Entries and Rules, task sessions as Entries, stable "n of m" numbering.
final class PlannerEntryTests: XCTestCase {
    let cal = Fx.cal

    var timetable: [Entry] { Fx.timetable }

    func input(now: Date, items: [WorkItem], entries: [Entry], rules: [Rule] = [], horizon: Int = 7) -> PlannerInput {
        PlannerInput(now: now, calendar: cal, items: items, routines: [], horizonDays: horizon, entries: entries, rules: rules)
    }

    func overlaps(_ a: PlannedBlock, _ d: DayEntry) -> Bool { a.start < d.end && d.start < a.end }

    func testStudyNeverLandsOnFixedEntries() {
        let essay = WorkItem(title: "Essay", kind: .essay, due: Fx.mon(9, plusDays: 4), estimateMinutes: 300)
        let plan = Planner.plan(input(now: Fx.mon(7), items: [essay], entries: timetable))
        let study = plan.study(for: essay.id)
        XCTAssertFalse(study.isEmpty)
        let fixed = Days.expand(timetable, in: DateInterval(start: Fx.mon(0), end: Fx.mon(0, plusDays: 7)), now: Fx.mon(7), calendar: cal)
        for b in study { XCTAssertFalse(fixed.contains { overlaps(b, $0) }, "\(b.title) \(b.start)") }
        XCTAssertTrue(plan.blocks.contains { $0.sourceId?.hasPrefix("entry:") == true && $0.title == "School" })
    }

    func testSchoolDayComesFromEntries() {
        var tt = timetable
        tt[0].marks["2026-11-17"] = .skipped
        let plan = Planner.plan(input(now: Fx.mon(5), items: [], entries: tt))
        let tue = plan.wakePlans.first { cal.isDate($0.day, inSameDayAs: Fx.mon(0, plusDays: 1)) }
        let wed = plan.wakePlans.first { cal.isDate($0.day, inSameDayAs: Fx.mon(0, plusDays: 2)) }
        XCTAssertNotNil(tue?.wake); XCTAssertNotNil(wed?.wake)
        XCTAssertGreaterThan(tue!.wake.timeIntervalSince(cal.startOfDay(for: tue!.day)),
                             wed!.wake.timeIntervalSince(cal.startOfDay(for: wed!.day)), "a skipped school day sleeps in")
        XCTAssertNotNil(wed?.leaveBy, "school's first entry sets leave-by")
    }

    func testPinnedSessionCountsAndIsNumbered() {
        let reading = WorkItem(title: "Reading", kind: .reading, due: Fx.mon(20, plusDays: 4), estimateMinutes: 150)
        let pin = Entry(title: "Reading", start: Fx.mon(18, plusDays: 1), end: Fx.mon(18, 45, plusDays: 1),
                        category: CategoryTree.studying, taskId: reading.id, source: .you, createdAt: Fx.mon(7))
        let plan = Planner.plan(input(now: Fx.mon(7), items: [reading], entries: timetable + [pin]))
        let study = plan.study(for: reading.id).sorted { $0.start < $1.start }
        XCTAssertTrue(study.contains { $0.start == pin.start }, "the pinned session is in the plan")
        let titles = study.map(\.title)
        XCTAssertEqual(titles, (1...study.count).map { "Reading · \($0) of \(study.count)" })
        let without = Planner.plan(input(now: Fx.mon(7), items: [reading], entries: timetable))
        XCTAssertEqual(Double(plan.minutes(for: reading.id)), Double(without.minutes(for: reading.id)), accuracy: 15,
                       "the pin counts toward the task, it isn't scheduled on top")
    }

    func testNotBeforeAndNumberingAfterMovingToTomorrow() {
        // A2 regression: "I missed reading, move it to tomorrow" keeps the order and the numbers.
        var reading = WorkItem(title: "Reading", kind: .reading, due: Fx.mon(20, plusDays: 5), estimateMinutes: 180)
        let done = Entry(title: "Reading", start: Fx.mon(8), end: Fx.mon(8, 40), category: CategoryTree.studying,
                         taskId: reading.id, source: .you, createdAt: Fx.mon(8))
        reading.completedMinutes = 40
        reading.notBefore = cal.startOfDay(for: Fx.mon(0, plusDays: 1))
        let plan = Planner.plan(input(now: Fx.mon(16), items: [reading], entries: timetable + [done]))
        let study = plan.study(for: reading.id).sorted { $0.start < $1.start }
        XCTAssertFalse(study.isEmpty)
        XCTAssertTrue(study.allSatisfy { $0.start >= reading.notBefore! }, "nothing today")
        XCTAssertEqual(study.first?.title, "Reading · 2 of \(study.count + 1)", "the session already done is 1")
    }

    func testRuleLimitsShapeTheDay() {
        let essay = WorkItem(title: "Essay", kind: .essay, due: Fx.mon(9, plusDays: 5), estimateMinutes: 400)
        let rule = Rule(text: "No study after 8, 30 minute blocks", limits: PlannerLimits(maxBlockMinutes: 30, noStudyAfter: TimeOfDay(20)))
        let plan = Planner.plan(input(now: Fx.mon(7), items: [essay], entries: timetable, rules: [rule]))
        let study = plan.study(for: essay.id)
        XCTAssertFalse(study.isEmpty)
        for b in study {
            XCTAssertLessThanOrEqual(b.minutes, 30)
            let end = cal.dateComponents([.hour, .minute], from: b.end)
            XCTAssertLessThanOrEqual(end.hour! * 60 + end.minute!, 20 * 60, "\(b.title) ends \(b.end)")
        }
        let mute = Rule(text: "No reminders Tuesday", days: .weekdays([3]), limits: PlannerLimits(muteAll: true))
        let p2 = Planner.plan(input(now: Fx.mon(7), items: [], entries: timetable, rules: [mute]))
        XCTAssertTrue(p2.isMuted(.start, at: Fx.mon(12, plusDays: 1), calendar: cal))
        XCTAssertFalse(p2.isMuted(.start, at: Fx.mon(12), calendar: cal))
    }

    func testPlanBecomesEntries() {
        let essay = WorkItem(title: "Essay", kind: .essay, due: Fx.mon(9, plusDays: 4), estimateMinutes: 120)
        let plan = Planner.plan(input(now: Fx.mon(7), items: [essay], entries: timetable))
        let entries = PlanEntries.from(plan, items: [essay], now: Fx.mon(7))
        XCTAssertTrue(entries.allSatisfy { $0.source == .plan })
        XCTAssertFalse(entries.contains { $0.title == "School" }, "fixed entries aren't copied")
        XCTAssertTrue(entries.contains { $0.taskId == essay.id && $0.category == CategoryTree.studying })
        XCTAssertTrue(entries.contains { $0.category == CategoryTree.sleep && $0.alert == .wake })
        XCTAssertFalse(entries.contains { $0.title == "Free" })
    }

    func testOpenTimeTakesOnlyLightWorkAndMaxPerDay() {
        // "Spare periods should be used for easy work", "no more than 45 min of reading a day" (2026-11-18 backup).
        let spare = Entry(title: "Spare", start: Fx.mon(9, 38), end: Fx.mon(10, 58), category: CategoryTree.school,
                          repeats: .weekly([2, 3, 4, 5, 6]), open: true, source: .you)
        let classes = Entry(title: "Classes", start: Fx.mon(8, 26), end: Fx.mon(9, 38), category: CategoryTree.school,
                            repeats: .weekly([2, 3, 4, 5, 6]), source: .you)
        let rest = Entry(title: "Classes", start: Fx.mon(10, 58), end: Fx.mon(14, 46), category: CategoryTree.school,
                         repeats: .weekly([2, 3, 4, 5, 6]), source: .you)
        var reading = WorkItem(title: "Frankenstein", kind: .reading, due: Fx.mon(23, plusDays: 5), estimateMinutes: 225, difficulty: 1)
        reading.maxMinutesPerDay = 45
        let essay = WorkItem(title: "Essay", kind: .essay, due: Fx.mon(23, plusDays: 5), estimateMinutes: 240, difficulty: 3)
        let plan = Planner.plan(input(now: Fx.mon(6), items: [reading, essay], entries: [classes, spare, rest]))
        let inSpare = { (b: PlannedBlock) in
            Days.expand([spare], in: DateInterval(start: Fx.mon(0), end: Fx.mon(0, plusDays: 7)), now: Fx.mon(6), calendar: self.cal)
                .contains { $0.start < b.end && b.start < $0.end }
        }
        XCTAssertFalse(plan.study(for: essay.id).contains(where: inSpare), "hard work never goes in a spare")
        let byDay = Dictionary(grouping: plan.study(for: reading.id), by: { DayKeys.key($0.start, cal) }).mapValues { $0.reduce(0) { $0 + $1.minutes } }
        XCTAssertFalse(byDay.isEmpty)
        XCTAssertTrue(byDay.values.allSatisfy { $0 <= 45 }, byDay.description)
    }
}
