import XCTest
@testable import ProductiumCore

/// v1.3 review pass: "I'm showering", transition time, every app's sessions in the log, how much of tomorrow is
/// planned, the week's recap, and OCR rows.
final class ReviewDataTests: XCTestCase {
    let cal = Fx.cal

    func testImShoweringStartsTheShowerTile() {
        var tiles = QuickStarts()
        tiles.seedTemplates(at: Fx.mon(0))
        let c = QuickContext(now: Fx.mon(18), calendar: cal, entries: Fx.timetable, items: [], tiles: tiles.live)
        for s in ["im showering now", "I'm showering", "i am showering right now", "showering now"] {
            let r = QuickParse.parse(s, c)
            XCTAssertEqual(r?.kind, .start, s)
            XCTAssertEqual(r?.ops.first?.fields.title, "Shower", s)
            XCTAssertEqual(r?.ops.first?.fields.category, "essentials.shower", s)
        }
        XCTAssertEqual(QuickParse.parse("im napping", c)?.ops.first?.fields.title, "Nap")
        XCTAssertEqual(QuickParse.parse("i'm exercising now", c)?.ops.first?.fields.title, "Exercise")
        XCTAssertEqual(QuickParse.parse("im cooking dinner now", c)?.ops.first?.fields.title, "Cooking dinner")
        for s in ["im going to school", "i'm feeling tired", "im studying for my bio test", "showering", "im showering tomorrow"] {
            XCTAssertNil(QuickParse.parse(s, c), s)
        }
    }

    func testShortGapsBetweenThingsAreTransition() {
        let a = Entry(title: "Homework", start: Fx.mon(16), end: Fx.mon(17), category: CategoryTree.studying, source: .you)
        let b = Entry(title: "Dinner", start: Fx.mon(17, 4), end: Fx.mon(17, 30), category: CategoryTree.meals, source: .you)
        let c = Entry(title: "Gaming", start: Fx.mon(17, 40), end: Fx.mon(18), category: CategoryTree.free, source: .you)
        let slices = TimeLog.past([a, b, c], in: DateInterval(start: Fx.mon(16), end: Fx.mon(19)), now: Fx.mon(18, 3), calendar: cal)
        let t = slices.first { $0.start == Fx.mon(17) }
        XCTAssertEqual(t?.category, CategoryTree.transition)
        XCTAssertFalse(t?.assumed ?? true, "nothing to confirm")
        XCTAssertNil(slices.first { $0.start == Fx.mon(17, 30) }?.entry, "10 minutes is still Untracked")
        XCTAssertNil(slices.last?.entry, "the stretch up to now has nothing after it")
        XCTAssertTrue(TimeLog.assumed(slices).isEmpty)
    }

    func testEveryAppIsLoggedScrollingAppsGetTheirOwnCategoryMessagingIsMessaging() {
        var log = ScrollLog()
        log.seen("Instagram", at: Fx.mon(19), scrolling: true)
        log.opened("Instagram", at: Fx.mon(19, 0).addingTimeInterval(5), paused: true, calendar: cal)
        log.seen("Discord", at: Fx.mon(19, 20), scrolling: false)
        log.seen("Calculator", at: Fx.mon(19, 50), scrolling: false)
        log.closed(at: Fx.mon(19, 55))
        XCTAssertEqual(log.sessions.map(\.app), ["Instagram", "Discord", "Calculator"], "the pause automation's repeat is the same opening")
        XCTAssertEqual(log.today(Fx.mon(19), calendar: cal)?.opens, 1)

        var tree = CategoryTree()
        var entries: [Entry] = []
        let list = ["Instagram": true]
        EntryBuilder.apps(log.sessions, entries: &entries, now: Fx.mon(20), since: Fx.mon(0)) {
            AppKinds.category(for: $0, list: list, rules: CategoryRules(), tree: &tree)
        }
        XCTAssertEqual(entries.count, 2, "Calculator counts in Screen Time but isn't a log entry")
        let insta = entries.first { $0.title == "Instagram" }!
        XCTAssertEqual(tree.node(insta.category)?.name, "Instagram")
        XCTAssertTrue(tree.isUnder(insta.category, CategoryTree.scrolling))
        XCTAssertEqual(entries.first { $0.title == "Discord" }?.category, CategoryTree.messaging)

        // What you tracked wins over the phone's guess.
        let work = Entry(title: "Homework", start: Fx.mon(19, 15), end: Fx.mon(19, 50), category: CategoryTree.studying, source: .you)
        let slices = TimeLog.past(entries + [work], in: DateInterval(start: Fx.mon(19), end: Fx.mon(20)), now: Fx.mon(20), calendar: cal)
        XCTAssertEqual(slices.first { $0.start <= Fx.mon(19, 30) && $0.end > Fx.mon(19, 30) }?.entry?.title, "Homework",
                       "Discord during homework: the homework counts")
        XCTAssertTrue(slices.first { $0.start == Fx.mon(19) }?.assumed ?? false, "app time is assumed until you say yes")

        let day = log.screenDays(before: Fx.mon(8, plusDays: 1), calendar: cal).first
        XCTAssertEqual(day?.distractingMinutes, 20)
        XCTAssertEqual(day?.totalMinutes, 55)

        // Untick Instagram: its unconfirmed entry goes.
        EntryBuilder.apps(log.sessions, entries: &entries, now: Fx.mon(20), since: Fx.mon(0)) {
            AppKinds.category(for: $0, list: ["Instagram": false], rules: CategoryRules(), tree: &tree)
        }
        XCTAssertEqual(entries.map(\.title), ["Discord"])
    }

    func testTomorrowPlanned() {
        let sleep1 = Entry(title: "Sleep", start: Fx.mon(22, plusDays: -1), end: Fx.mon(7), category: CategoryTree.sleep, source: .plan)
        let sleep2 = Entry(title: "Sleep", start: Fx.mon(23), end: Fx.mon(7, plusDays: 1), category: CategoryTree.sleep, source: .plan)
        let school = Entry(title: "School", start: Fx.mon(8, 30), end: Fx.mon(15), category: CategoryTree.school, source: .you)
        let study = Entry(title: "Essay", start: Fx.mon(16), end: Fx.mon(17), category: CategoryTree.studying, taskId: UUID(), source: .plan)
        let share = PlannedShare.make(Fx.mon(0), entries: [sleep1, sleep2, school, study], tree: CategoryTree(), now: Fx.mon(0, plusDays: -1),
                                      calendar: cal)
        XCTAssertEqual(share.awakeMinutes, 16 * 60)
        XCTAssertEqual(share.plannedMinutes, 390 + 60)
        XCTAssertEqual(share.percent, 47)
    }

    func testWeekRecap() {
        let days = (0..<7).map { Fx.mon(0, plusDays: $0) }
        let scores = days.enumerated().map { i, _ in
            DayScore(wakingMinutes: 900, untrackedMinutes: 100, workMinutes: 60 + i * 10, askedMinutes: 90, deadlinesDue: i == 2 ? 1 : 0,
                     deadlinesMet: i == 2 ? 1 : 0, scrollingMinutes: 30)
        }
        let tiktok = Entry(title: "TikTok", start: Fx.mon(21), end: Fx.mon(21, 40), category: CategoryTree.scrolling, source: .sensor)
        let study = Entry(title: "Homework", start: Fx.mon(16), end: Fx.mon(18), category: CategoryTree.studying, source: .you)
        let r = WeekRecap.make(days: days, scores: scores, before: [], entries: [tiktok, study], tree: CategoryTree(),
                               moods: [MoodEntry(at: Fx.mon(12), mood: 4)], now: Fx.mon(23, plusDays: 6), calendar: cal)!
        XCTAssertEqual(r.trackedMinutes, 7 * 800)
        XCTAssertEqual(r.workMinutes, 7 * 60 + 210)
        XCTAssertEqual(r.top.first?.id, CategoryTree.studying)
        XCTAssertEqual(r.topApp?.name, "TikTok")
        XCTAssertEqual(r.topApp?.minutes, 40)
        XCTAssertEqual(r.deadlinesMet, 1)
        XCTAssertEqual(r.mood, 4)
        XCTAssertNil(r.usualWorkMinutes)
    }

    func testOCRRowsPairNameAndTime() {
        let boxes = [OCRLines.Box(text: "1h 36m", x: 0.8, y: 0.501, height: 0.02), OCRLines.Box(text: "Instagram", x: 0.2, y: 0.5, height: 0.02),
                     OCRLines.Box(text: "MOST USED", x: 0.1, y: 0.55, height: 0.02), OCRLines.Box(text: "48m", x: 0.85, y: 0.47, height: 0.02),
                     OCRLines.Box(text: "YouTube", x: 0.2, y: 0.468, height: 0.02), OCRLines.Box(text: "Screen Time", x: 0.4, y: 0.9, height: 0.03)]
        XCTAssertEqual(OCRLines.join(boxes), "Screen Time\nMOST USED\nInstagram 1h 36m\nYouTube 48m")
        let r = ScreenOCR.parse(OCRLines.join(boxes))
        XCTAssertEqual(r?.apps.map(\.name), ["Instagram", "YouTube"])
    }
}
