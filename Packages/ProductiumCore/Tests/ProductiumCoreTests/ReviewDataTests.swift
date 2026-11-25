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
        let c = Entry(title: "Gaming", start: Fx.mon(17, 50), end: Fx.mon(18), category: CategoryTree.free, source: .you)
        let slices = TimeLog.past([a, b, c], in: DateInterval(start: Fx.mon(16), end: Fx.mon(19)), now: Fx.mon(18, 3), calendar: cal)
        let t = slices.first { $0.start == Fx.mon(17) }
        XCTAssertEqual(t?.category, CategoryTree.transition)
        XCTAssertFalse(t?.assumed ?? true, "nothing to confirm")
        XCTAssertNil(slices.first { $0.start == Fx.mon(17, 30) }?.entry, "over 15 minutes is Untracked")
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
            AppKinds.category(for: $0.app, list: list, rules: CategoryRules(), tree: &tree, pausedApp: $0.scrolling == nil)
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
            AppKinds.category(for: $0.app, list: ["Instagram": false], rules: CategoryRules(), tree: &tree, pausedApp: $0.scrolling == nil)
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

    /// iOS 26, Week, as Vision rows (transcribed from real screenshots, 2026-11-22).
    let ios26Week = """
    10:00
    D’s iPhone Devices
    Week Day
    Screen Time Show This Week
    Last Week’s Average
    6h 33min 18% from last week
    10h
    avg
    0
    S M T W T F S
    Social Utilities Productivity & Finance
    23h 25min 6h 33min 4h 55min
    Total Screen Time 45h 55min
    Updated today at 10:00 AM
    Most Used Show Categories
    Instagram
    13h 22min
    Discord
    9h 11min
    Firefox
    5h 46min
    Slack
    2h 46min
    Google Maps
    49min
    """
    let ios26Pickups = """
    10:00
    D’s iPhone Devices
    Last Week
    Show More
    Pickups
    Last Week’s Average
    108 5% from last week
    150
    avg
    0
    S M T W T F S
    Most Pickups Total Pickups
    Friday: 143 755
    First Used After Pickup
    Discord
    158
    Instagram
    141
    Show More
    Notifications
    """

    func testIOS26WeekScreenshotsAreDailyAverages() {
        let w = ScreenOCR.parse(ios26Week.replacingOccurrences(of: "’", with: "'"))!
        XCTAssertEqual(w.period, "week")
        XCTAssertEqual(w.dateLabel, "Last Week")
        XCTAssertEqual(w.minutes, 393)
        XCTAssertEqual(w.totalMinutes, 2755)
        XCTAssertEqual(w.apps.map(\.name), ["Instagram", "Discord", "Firefox", "Slack", "Google Maps"])
        XCTAssertEqual(w.apps.first?.minutes, 802)

        var s = AppState()
        var me = AboutMe.empty
        let now = Fx.mon(12, plusDays: 6)
        BoxSideOps.apply([BoxOp(.screen_time, .add, BoxFields(screen: w.box))], to: &s, aboutMe: &me, now: now, calendar: cal)
        let avg = s.screenAverages.first!
        XCTAssertEqual(avg.apps?.first { $0.name == "Instagram" }?.minutes, 114, "13h 22min a week is about 1h 54 a day")
        XCTAssertEqual(avg.distractingMinutes, 114, "Instagram is scrolling; Discord is messaging")
        XCTAssertEqual(avg.totalMinutes, 393)
        XCTAssertLessThan(avg.day, Fx.mon(0, plusDays: 6), "last week's average is filed on last week")

        let p = ScreenOCR.parse(ios26Pickups.replacingOccurrences(of: "’", with: "'"))!
        XCTAssertEqual(p.period, "week")
        XCTAssertEqual(p.pickups, 108)
        XCTAssertTrue(p.apps.isEmpty, "First Used After Pickup counts aren't minutes")
    }

    func testBackToBackSessionsOfOneAppAreOneEntryAndPauseSessionsAreScrolling() {
        var log = ScrollLog()
        for k in 0..<3 {
            log.opened("Scrolling app", at: Fx.mon(21, k * 4), paused: false, calendar: cal)
            log.closed(at: Fx.mon(21, k * 4 + 3))
        }
        var tree = CategoryTree()
        var entries: [Entry] = []
        EntryBuilder.apps(log.sessions, entries: &entries, now: Fx.mon(22), since: Fx.mon(0)) {
            AppKinds.category(for: $0.app, list: [:], rules: CategoryRules(), tree: &tree, pausedApp: $0.scrolling == nil)
        }
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.end, Fx.mon(21, 11))
        XCTAssertTrue(tree.isUnder(entries[0].category, CategoryTree.scrolling))
    }
}
