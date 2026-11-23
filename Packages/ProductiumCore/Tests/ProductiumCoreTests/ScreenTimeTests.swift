import XCTest
@testable import ProductiumCore

final class ScreenTimeTests: XCTestCase {
    let cal = Fx.cal

    func state() -> DumpState {
        DumpState(items: [], moods: [], screen: [], prefs: Preferences())
    }

    func app(_ n: String, _ m: Int, _ c: String? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["name": .string(n), "minutes": .number(Double(m))]
        if let c { o["category"] = .string(c) }
        return .object(o)
    }







    func testJunkRowsAndMoreThanADayAreRefused() {
        var st = AppState()
        var me = AboutMe()
        var sc = BoxScreen()
        sc.period = "day"
        sc.apps = [BoxScreen.App(name: ":2h", minutes: 120), BoxScreen.App(name: ">", minutes: 5), BoxScreen.App(name: "Instagram", minutes: 30)]
        let ok = BoxSideOps.apply([BoxOp(.screen_time, .add, BoxFields(screen: sc))], to: &st, aboutMe: &me, now: Fx.mon(20), calendar: cal)
        XCTAssertEqual(st.screen.last?.apps?.map(\.name), ["Instagram"], ok.problems.description)
        sc.apps = [BoxScreen.App(name: "Instagram", minutes: 802), BoxScreen.App(name: "Discord", minutes: 551), BoxScreen.App(name: "Safari", minutes: 300)]
        var st2 = AppState()
        let r = BoxSideOps.apply([BoxOp(.screen_time, .add, BoxFields(screen: sc))], to: &st2, aboutMe: &me, now: Fx.mon(20), calendar: cal)
        XCTAssertTrue(st2.screen.isEmpty)
        XCTAssertTrue(r.problems.first?.contains("more than a day") ?? false)
    }

    func testAppLiteralIsIgnored() {
        for name in ["App", " app ", "", "Scrolling app", "Shortcut Input"] { XCTAssertTrue(AppKinds.isPlaceholder(name), name) }
        for name in ["Instagram", "App Store", "Apple TV"] { XCTAssertFalse(AppKinds.isPlaceholder(name), name) }
    }

    func testClockParsing() {
        XCTAssertEqual(ScreenReceipt.parseClock("6:42 AM"), 402)
        XCTAssertEqual(ScreenReceipt.parseClock("12:05 am"), 5)
        XCTAssertEqual(ScreenReceipt.parseClock("12:30 PM"), 750)
        XCTAssertEqual(ScreenReceipt.parseClock("18:05"), 1085)
        XCTAssertNil(ScreenReceipt.parseClock("later"))
        XCTAssertNil(ScreenReceipt.parseClock("25:00"))
    }

    func testPickupsBecomeMetricPoints() {
        let day = Fx.mon(0)
        let d = ScreenDay(day: day, distractingMinutes: 30, source: "screenshot", pickups: 70, firstPickup: 420, notifications: 120)
        let x = MetricsInput(days: [day], screen: [], screenDays: [d], health: [], moods: [], items: [],
                             progress: [], entries: [], now: Fx.mon(22), planned: [:], sleepNeed: 540)
        let series = MetricsBuilder.series(x, calendar: cal)
        XCTAssertEqual(series[.pickups]?.points[day]?.value, 70)
        XCTAssertEqual(series[.firstPickup]?.points[day]?.value, 420)
        XCTAssertEqual(series[.notifications]?.points[day]?.value, 120)
    }


    func testScrollingSessionsPaintExactlyAndScreenshotMinutesAreEstimated() {
        let sessions = [ScrollSession(app: "Instagram", openedAt: Fx.mon(17), endedAt: Fx.mon(17, 30), endSource: .closed),
                        ScrollSession(app: "Slack", openedAt: Fx.mon(18), endedAt: Fx.mon(18, 20), endSource: .closed)]
        let inputs = DayInputs(day: Fx.mon(0), entries: Fx.schoolEntries, routines: [], health: nil,
                               screen: ScreenDay(day: Fx.mon(0), distractingMinutes: 60), prefs: Preferences(),
                               scrollSessions: sessions, scrollingApps: ["Instagram": true, "Slack": false])
        let segs = TimelineBuilder.segments(inputs, calendar: cal)
        let scroll = segs.filter { $0.category == .screen }
        XCTAssertEqual(scroll.count, 2)
        XCTAssertEqual(scroll[0].start, Fx.mon(17))
        XCTAssertFalse(scroll[0].inferred)
        XCTAssertTrue(scroll[1].inferred, "the 30 minutes no session explains are painted, marked estimated")
        XCTAssertEqual(scroll[1].minutes, 30)
        let totals = TimelineBuilder.totals(segs, screen: inputs.screen)
        XCTAssertEqual(totals[.screen], 60, "30 timed plus 30 estimated from the screenshot")
    }

    func testScreenshotMinutesWithoutSessionsAreShownInTheEvening() {
        let inputs = DayInputs(day: Fx.mon(0), entries: Fx.schoolEntries, routines: [], health: nil,
                               screen: ScreenDay(day: Fx.mon(0), distractingMinutes: 90), prefs: Preferences())
        let segs = TimelineBuilder.segments(inputs, calendar: cal)
        let scroll = segs.filter { $0.category == .screen }
        XCTAssertEqual(scroll.map(\.minutes).reduce(0, +), 90)
        XCTAssertTrue(scroll.allSatisfy(\.inferred))
        XCTAssertEqual(TimelineBuilder.totals(segs, screen: inputs.screen)[.screen], 90)
    }
}

/// v1.1 C6/C8: every kind of Screen Time screenshot reaches the numbers Review shows.
final class ScreenSeriesTests: XCTestCase {
    let cal = Fx.cal
    let base = ShotFx.self


    func week(ending now: Date) -> [Date] {
        (0..<7).reversed().map { cal.date(byAdding: .day, value: -$0, to: cal.startOfDay(for: now))! }
    }

    func testWeekdayNameAndShortDateLabels() {
        let wed = Fx.mon(20, plusDays: 2)
        XCTAssertEqual(ScreenDates.resolve(label: "Monday", date: nil, now: wed, calendar: cal), Fx.mon(0))
        XCTAssertEqual(ScreenDates.resolve(label: "Wednesday", date: nil, now: wed, calendar: cal), Fx.mon(0, plusDays: 2))
        XCTAssertEqual(ScreenDates.resolve(label: "Thu", date: nil, now: wed, calendar: cal), Fx.mon(0, plusDays: -4),
                       "last Thursday, never a day ahead")
        XCTAssertEqual(ScreenDates.resolve(label: "Mon 16 Nov", date: nil, now: wed, calendar: cal), Fx.mon(0))
        XCTAssertEqual(ScreenDates.resolve(label: "Nov 16", date: nil, now: wed, calendar: cal), Fx.mon(0))
        XCTAssertEqual(ScreenDates.resolve(label: nil, date: Fx.mon(12, plusDays: 5), now: wed, calendar: cal),
                       cal.startOfDay(for: wed), "a future date falls back to today")
        let jan = cal.date(from: DateComponents(year: 2027, month: 1, day: 2, hour: 9))!
        XCTAssertEqual(ScreenDates.resolve(label: "Wed 30 Dec", date: nil, now: jan, calendar: cal),
                       cal.date(from: DateComponents(year: 2026, month: 12, day: 30)), "across New Year")
    }




    func testScreenshotsWinOverShortcutsAndOldNumbersAreRecomputed() {
        let shot = ScreenDay(day: Fx.mon(0), distractingMinutes: 68, totalMinutes: 202,
                             apps: [AppUsage(name: "Instagram", minutes: 96, distracting: true),
                                    AppUsage(name: "Snapchat", minutes: 35, distracting: true),
                                    AppUsage(name: "Firefox", minutes: 97, distracting: false)], source: "screenshot")
        let est = ScreenDay(day: Fx.mon(0), distractingMinutes: 20, source: "shortcuts")
        let est2 = ScreenDay(day: Fx.mon(0, plusDays: 1), distractingMinutes: 25, source: "shortcuts")
        let merged = [shot].merging(measured: [est, est2], calendar: cal).recomputed([:])
        XCTAssertEqual(merged.map(\.distractingMinutes), [131, 25], "the backup's stale 68 becomes 131; the estimate only fills Tuesday")
        let pts = ScreenSeries.daily(screen: merged, averages: [], days: [Fx.mon(0), Fx.mon(0, plusDays: 1)], calendar: cal)
        XCTAssertEqual(pts.map { $0?.source }, [.screenshot, .shortcuts])
    }
}

enum ShotFx {
    static func state() -> DumpState {
        DumpState(items: [], moods: [], screen: [], prefs: Preferences())
    }

    static func app(_ n: String, _ m: Int, _ c: String? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["name": .string(n), "minutes": .number(Double(m))]
        if let c { o["category"] = .string(c) }
        return .object(o)
    }

}
