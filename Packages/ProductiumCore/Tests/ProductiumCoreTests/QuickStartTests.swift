import XCTest
@testable import ProductiumCore

/// v1.2 D2 / D7: start buttons ranked from the log; habits get a slot in the plan.
final class QuickStartTests: XCTestCase {
    let cal = Fx.cal

    func told(_ title: String, _ cat: CategoryID, day: Int, _ h: Int, _ m: Int = 0, minutes: Int = 30, place: UUID? = nil) -> Entry {
        Entry(title: title, start: Fx.mon(h, m, plusDays: day), end: Fx.mon(h, m, plusDays: day).addingTimeInterval(Double(minutes) * 60),
              category: cat, placeId: place, source: .you, createdAt: Fx.mon(h, m, plusDays: day))
    }

    func buttons(_ titles: [(String, CategoryID)], at: Date = Fx.mon(0, plusDays: -20)) -> QuickStarts {
        var q = QuickStarts()
        for (t, c) in titles { q.noteStart(Entry(title: t, start: at, end: nil, category: c, source: .you), at: at) }
        return q
    }

    func testFirstTextStartMakesAButtonButTasksDont() {
        var q = QuickStarts()
        q.noteStart(Entry(title: "Shower", start: Fx.mon(21), end: nil, category: "essentials.shower", source: .you), at: Fx.mon(21))
        q.noteStart(Entry(title: "shower", start: Fx.mon(21, plusDays: 1), end: nil, category: "essentials.shower", source: .you), at: Fx.mon(21))
        q.noteStart(Entry(title: "Essay", start: Fx.mon(19), end: nil, category: CategoryTree.studying, taskId: UUID(), source: .you), at: Fx.mon(19))
        XCTAssertEqual(q.buttons.map(\.title), ["Shower"])
        q.remove(q.buttons[0].id)
        q.noteStart(Entry(title: "Shower", start: Fx.mon(21), end: nil, category: "essentials.shower", source: .you), at: Fx.mon(21))
        XCTAssertEqual(q.buttons.count, 1, "a removed button isn't made again")
        XCTAssertTrue(q.ranked(entries: [], now: Fx.mon(21), calendar: cal).row.isEmpty)
    }

    func testRankedByHourOfDay() {
        let q = buttons([("Shower", "essentials.shower"), ("Gaming", CategoryTree.free), ("Walk", CategoryTree.travel)])
        var log: [Entry] = []
        for d in -10 ..< 0 {
            log.append(told("Shower", "essentials.shower", day: d, 21, 30, minutes: 15))
            log.append(told("Walk", CategoryTree.travel, day: d, 7, 40, minutes: 20))
            log.append(told("Gaming", CategoryTree.free, day: d, 16, 0, minutes: 60))
        }
        XCTAssertEqual(q.ranked(entries: log, now: Fx.mon(21, 15), calendar: cal).row.first?.title, "Shower")
        XCTAssertEqual(q.ranked(entries: log, now: Fx.mon(7, 30), calendar: cal).row.first?.title, "Walk")
        XCTAssertEqual(q.ranked(entries: log, now: Fx.mon(16, 10), calendar: cal).row.first?.title, "Gaming")
    }

    func testPlaceBreaksATie() {
        let gym = UUID(), library = UUID()
        let q = buttons([("Volleyball", CategoryTree.extracurricular), ("Homework", CategoryTree.studying)])
        var log: [Entry] = []
        for d in -8 ..< 0 {
            log.append(told("Volleyball", CategoryTree.extracurricular, day: d, 16, place: gym))
            log.append(told("Homework", CategoryTree.studying, day: d, 16, 15, place: library))
        }
        XCTAssertEqual(q.ranked(entries: log, now: Fx.mon(16), place: gym, calendar: cal).row.first?.title, "Volleyball")
        XCTAssertEqual(q.ranked(entries: log, now: Fx.mon(16), place: library, calendar: cal).row.first?.title, "Homework")
    }

    func testUnusedFor21DaysGoesToMore() {
        var q = buttons([("Piano", CategoryTree.extracurricular)], at: Fx.mon(0, plusDays: -40))
        q.noteStart(Entry(title: "Shower", start: Fx.mon(9), end: nil, category: "essentials.shower", source: .you), at: Fx.mon(9))
        let log = [told("Piano", CategoryTree.extracurricular, day: -25, 17), told("Shower", "essentials.shower", day: -1, 21)]
        let r = q.ranked(entries: log, now: Fx.mon(17), calendar: cal)
        XCTAssertEqual(r.row.map(\.title), ["Shower"])
        XCTAssertEqual(r.more.map(\.title), ["Piano"])
    }

    func testHiddenWhenATaskOrAPlannedHabitCoversIt() {
        let q = buttons([("Reading", CategoryTree.studying), ("Shower", "essentials.shower"), ("Gaming", CategoryTree.free)])
        let reading = WorkItem(title: "Reading", kind: .reading, due: Fx.mon(23, plusDays: 2))
        let planned = [Entry(title: "Reading", start: Fx.mon(19), end: Fx.mon(19, 30), category: CategoryTree.studying, taskId: reading.id, source: .plan),
                       Entry(title: "Shower", start: Fx.mon(21, 30), end: Fx.mon(21, 45), category: "essentials.shower", note: Habits.note, source: .plan)]
        let covered = QuickStarts.covered(today: Fx.mon(12), items: [reading], planned: planned, calendar: cal)
        XCTAssertEqual(covered, ["reading", "shower"])
        let r = q.ranked(entries: [], now: Fx.mon(18), covered: covered, calendar: cal)
        XCTAssertEqual((r.row + r.more).map(\.title), ["Gaming"])
    }

    func testHabitsFromFourOfSevenDaysGetAPlannedSlot() {
        var log = Fx.timetable
        for d in [-6, -5, -3, -2, -1] { log.append(told("Shower", "essentials.shower", day: d, 21, 20 + d * -2, minutes: 15)) }
        log.append(told("Gaming", CategoryTree.free, day: -6, 16))
        log.append(told("Gaming", CategoryTree.free, day: -4, 20))
        log.append(told("Gaming", CategoryTree.free, day: -2, 12))
        log.append(told("Gaming", CategoryTree.free, day: -1, 17))
        let habits = Habits.detect(log, tree: CategoryTree(), now: Fx.mon(12), calendar: cal)
        XCTAssertEqual(habits.map(\.title), ["Shower"], "gaming is too scattered")
        XCTAssertEqual(habits[0].minutes, 15)
        XCTAssertEqual(habits[0].start.hour, 21)
        var input = Fx.input(now: Fx.mon(12), items: [], entries: Fx.timetable)
        input.habits = habits
        let plan = Planner.plan(input)
        let shower = plan.blocks.first { $0.title == "Shower" && cal.isDate($0.start, inSameDayAs: Fx.mon(12)) }
        XCTAssertNotNil(shower)
        let entries = PlanEntries.from(plan, items: [], now: Fx.mon(12), calendar: cal)
        let e = entries.first { $0.title == "Shower" }
        XCTAssertEqual(e?.category, "essentials.shower")
        XCTAssertEqual(e?.note, Habits.note)
        XCTAssertTrue(Days.expand([e!], in: Days.dayInterval(Fx.mon(12), cal), now: Fx.mon(23, 59), calendar: cal)[0].assumed,
                      "a planned routine counts unless you say no")
        // A series of your own isn't a habit to plan again.
        let mine = Entry(title: "Shower", start: Fx.mon(21, 30), end: Fx.mon(21, 45), category: "essentials.shower",
                         repeats: .weekly(Set(1...7)), source: .you)
        XCTAssertTrue(Habits.detect(log + [mine], tree: CategoryTree(), now: Fx.mon(12), calendar: cal).isEmpty)
    }
}
