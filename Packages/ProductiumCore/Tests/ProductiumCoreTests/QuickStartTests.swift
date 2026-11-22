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

    // MARK: v1.3 A

    func testAFreshInstallHasAFullGridInTemplateOrder() {
        var q = QuickStarts()
        q.seedTemplates(at: Fx.mon(8), skip: ["class", "nap"])
        XCTAssertEqual(q.buttons.count, QuickStartTemplate.all.count)
        let r = q.ranked(entries: [], now: Fx.mon(9), calendar: cal)
        XCTAssertEqual(r.row.count, QuickStarts.gridSize)
        XCTAssertEqual(r.row.prefix(3).map(\.title), ["Eating", "Walking", "Commute"])
        XCTAssertFalse((r.row + r.more).contains { $0.title == "Class" || $0.title == "Nap" }, "unticked in onboarding")
        q.seedTemplates(at: Fx.mon(9))
        XCTAssertEqual(q.buttons.count, QuickStartTemplate.all.count, "seeding twice adds nothing; hidden stay hidden")
    }

    func testAfterTwoWeeksTheFirstTileIsWhatYouUsuallyStartNow() {
        var q = QuickStarts()
        q.seedTemplates(at: Fx.mon(0, plusDays: -15))
        var log: [Entry] = []
        for d in -14 ..< 0 {
            let weekday = cal.component(.weekday, from: Fx.mon(12, plusDays: d))
            let school = (2...6).contains(weekday)
            // School days: commute at 7:45, homework at 16:30; weekends: gaming at 16:30. One odd day of reading at 16:40.
            if school {
                log.append(told("Commute", CategoryTree.travel, day: d, 7, 45))
                log.append(told("Homework", CategoryTree.studying, day: d, 16, 30, minutes: 60))
            } else {
                log.append(told("Gaming", CategoryTree.free, day: d, 16, 20, minutes: 90))
            }
            if d == -2 { log.append(told("Reading", CategoryTree.studying, day: d, 16, 40)) }
        }
        let monday = q.ranked(entries: log, now: Fx.mon(16, 25), calendar: cal)
        XCTAssertEqual(monday.row.first?.title, "Homework")
        XCTAssertEqual(q.ranked(entries: log, now: Fx.mon(7, 40), calendar: cal).row.first?.title, "Commute")
        let saturday = Fx.mon(16, 25, plusDays: 5)
        XCTAssertEqual(q.ranked(entries: log, now: saturday, calendar: cal).row.first?.title, "Gaming", "the kind of day counts")
        var book = DayRuleBook()
        book.label("no-school", [Fx.mon(12)], calendar: cal)
        XCTAssertEqual(q.ranked(entries: log, now: Fx.mon(16, 25), book: book, calendar: cal).row.first?.title, "Gaming",
                       "a day off school is ranked like a weekend")
        XCTAssertEqual(monday.top.count, QuickStarts.topSize)
    }

    func testRecentDaysOutweighOldOnes() {
        let q = buttons([("Piano", CategoryTree.extracurricular), ("Guitar", CategoryTree.extracurricular)], at: Fx.mon(0, plusDays: -80))
        var log: [Entry] = []
        for d in -70 ..< -50 { log.append(told("Piano", CategoryTree.extracurricular, day: d, 17)) }
        for d in -10 ..< -1 where d % 2 == 0 { log.append(told("Guitar", CategoryTree.extracurricular, day: d, 17)) }
        XCTAssertEqual(q.ranked(entries: log, now: Fx.mon(17), calendar: cal).row.first?.title, "Guitar")
    }

    func testPinnedTilesKeepTheirSlot() {
        var q = QuickStarts()
        q.seedTemplates(at: Fx.mon(0, plusDays: -15))
        let shower = q.button(for: "Shower")!
        q.pin(shower.id, at: 0)
        var log: [Entry] = []
        for d in -10 ..< 0 { log.append(told("Homework", CategoryTree.studying, day: d, 16, 30)) }
        let r = q.ranked(entries: log, now: Fx.mon(16, 30), calendar: cal)
        XCTAssertEqual(r.row.first?.title, "Shower")
        XCTAssertEqual(r.row[1].title, "Homework")
        XCTAssertEqual(r.top.first?.title, "Homework", "the Lock Screen gets the likeliest, not the pinned")
        XCTAssertTrue(q.button(for: "Shower")!.edited, "a pinned tile is yours")
    }

    func testTheAITidiesTheGridButNeverUndoesYourEdit() {
        var st = AppState()
        st.quickStarts.seedTemplates(at: Fx.mon(0, plusDays: -40))
        st.quickStarts.noteStart(Entry(title: "Lunch", start: Fx.mon(12, plusDays: -3), end: nil, category: CategoryTree.meals, source: .you),
                                 at: Fx.mon(12, plusDays: -3))
        for d in -5 ..< 0 {
            st.entries.append(told("Bus home", CategoryTree.travel, day: d, 15, 10))
            st.entries.append(told("Lunch", CategoryTree.meals, day: d, 12))
        }
        let practice = st.quickStarts.button(for: "Practice")!
        st.quickStarts.rename(practice.id, to: "Piano")
        let summary = GridTidy.summary(st.quickStarts, entries: st.entries, now: Fx.mon(12)).joined(separator: "\n")
        XCTAssertTrue(summary.contains("Typed often with no tile: Bus home 5×"), summary)
        XCTAssertTrue(summary.contains("Piano (theirs)"), summary)

        let now = Fx.mon(12)
        let run = InsightRun(at: now, note: "n", model: "m")
        func draft(_ g: GridChange) -> LoggedChange { LoggedChange(runId: run.id, change: .grid(g), reason: "r", model: "m", at: now) }
        var ds = st.dumpState
        let problems = st.changes.apply(run, [
            draft(.add(title: "Bus home", category: CategoryTree.travel, symbol: "bus")),
            draft(.merge(from: "Lunch", into: "Eating")),
            draft(.rename(from: "Piano", to: "Practice")),
            draft(.hide(title: "Gaming")),
            draft(.hide(title: "Eating")),
            draft(.add(title: "Space", category: "nope", symbol: nil)),
        ], to: &ds, now: now)
        st.dumpState = ds
        XCTAssertEqual(problems.count, 3, problems.joined(separator: "; "))
        XCTAssertTrue(problems.contains { $0.contains("Piano is yours") })
        XCTAssertTrue(problems.contains { $0.contains("Eating") }, "merged in this run, so the same target twice or used")
        XCTAssertEqual(st.quickStarts.button(for: "Bus home")?.origin, .ai)
        XCTAssertEqual(st.quickStarts.button(for: "Lunch")?.title, "Eating", "Lunch starts Eating now")
        XCTAssertEqual(st.quickStarts.buttons.first { $0.title == "Lunch" }?.removed, true)
        XCTAssertEqual(st.quickStarts.button(for: "Gaming")?.removed, true)
        XCTAssertEqual(st.quickStarts.button(for: "Piano")?.title, "Piano")
        XCTAssertEqual(st.changes.history.filter { $0.change.isGrid }.count, 3)
        XCTAssertTrue(st.changes.history.contains { $0.title == "Merged Lunch into Eating" })

        // Undo the merge from Changes.
        let merge = st.changes.history.first { $0.title.hasPrefix("Merged") }!
        ds = st.dumpState
        XCTAssertTrue(st.changes.revert(merge.id, in: &ds, now: now))
        st.dumpState = ds
        XCTAssertEqual(st.quickStarts.buttons.first { $0.title == "Lunch" }?.removed, false)
        XCTAssertTrue(st.quickStarts.button(for: "Eating")!.aliases.isEmpty)
        // A tile used in the last 30 days can't be hidden; a grid of 40 gets no more.
        XCTAssertNotNil(GridTidy.refusal(.hide(title: "Bus home"), grid: st.quickStarts, lastUse: st.quickStarts.lastUse(st.entries),
                                         tree: st.categories, now: now))
        var full = st.quickStarts
        while full.live.count < GridTidy.maxLive { full.buttons.append(QuickStart(title: "T\(full.buttons.count)", category: CategoryTree.other, createdAt: now)) }
        XCTAssertEqual(GridTidy.refusal(.add(title: "One more", category: CategoryTree.other, symbol: nil), grid: full, lastUse: [:],
                                        tree: st.categories, now: now), "The grid has 40 tiles")
    }

    func testInsightPassGridLinesBecomeDrafts() throws {
        let json = #"{"headline":"h","wins":[],"suggestions":[],"changes":[],"grid":[{"action":"add","title":"Bus home","category":"travel","symbol":"bus","reason":"typed 5×"},{"action":"merge","title":"Lunch","to":"Eating","reason":"same"},{"action":"rename","title":"x","reason":"no to"}]}"#
        let out = try JSONDecoder().decode(InsightPass.Output.self, from: Data(json.utf8))
        let d = InsightPass.drafts(out, runId: UUID(), items: [], now: Fx.mon(12), model: "m", calendar: cal)
        XCTAssertEqual(d.map(\.change), [.grid(.add(title: "Bus home", category: "travel", symbol: "bus")), .grid(.merge(from: "Lunch", into: "Eating"))])
        XCTAssertTrue(InsightPass.system().contains("grid:"))
    }

    func testOldTilesDecodeAsYours() throws {
        let old = #"{"buttons":[{"id":"19F19549-6E43-4F86-985D-60A533CAFA27","title":"Bus","category":"travel","topics":[],"createdAt":"2026-11-21T12:00:00Z","removed":false}]}"#
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        let q = try d.decode(QuickStarts.self, from: Data(old.utf8))
        XCTAssertEqual(q.buttons.first?.origin, .you)
        XCTAssertFalse(q.buttons.first!.edited)
    }
}
