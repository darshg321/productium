import XCTest
@testable import ProductiumCore

final class ScreenTimeTests: XCTestCase {
    let cal = Fx.cal

    func state() -> DumpState {
        DumpState(items: [], commitments: [Fx.school], exceptions: [], oneOffs: [], markers: [],
                  routines: Routine.defaults, moods: [], screen: [], prefs: Preferences())
    }

    func app(_ n: String, _ m: Int, _ c: String? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["name": .string(n), "minutes": .number(Double(m))]
        if let c { o["category"] = .string(c) }
        return .object(o)
    }

    func shot(_ extra: [String: JSONValue]) -> DumpOp {
        var f: [String: JSONValue] = ["date": .string("2026-11-16"), "period": .string("day"), "screenMinutes": .number(202),
                                      "apps": .array([app("Firefox", 97), app("Instagram", 96, "Social"), app("Slack", 50), app("Discord", 35)])]
        for (k, v) in extra { f[k] = v }
        return .upsert("screen_time", f)
    }

    func testTheScreenshotFromTheBugReportScrollsExactly131AndIsFlagged() {
        var s = state()
        let rep = DumpApplier.apply(DumpResult(ops: [shot(["distractingMinutes": .number(68)])], reply: ""), to: &s, now: Fx.mon(20, plusDays: 1), calendar: cal)
        let d = s.screen[0]
        XCTAssertEqual(d.distractingMinutes, 131, "the model's 68 is ignored")
        XCTAssertEqual(d.appsTotal, 278)
        XCTAssertFalse(d.addsUp)
        XCTAssertEqual(rep.problems.count, 1)
        XCTAssertTrue(rep.problems[0].contains("doesn't add up"), rep.problems[0])
        XCTAssertEqual(rep.changes, ["Mon 16 Nov: 3 h 22 total, scrolling 2 h 11 (Instagram 1 h 36, Discord 35 min)"])
    }

    func testYourListDecidesWhatScrolls() {
        var s = state()
        s.scrollingApps = ["Firefox": true, "Instagram": false]
        DumpApplier.apply(DumpResult(ops: [shot(["screenMinutes": .number(300)])], reply: ""), to: &s, now: Fx.mon(20, plusDays: 1), calendar: cal)
        XCTAssertEqual(s.screen[0].distractingMinutes, 97 + 35)
        XCTAssertTrue(s.screen[0].addsUp)
        XCTAssertEqual(s.scrollingApps["Slack"], false)
        XCTAssertEqual(s.scrollingApps["Discord"], true)
        XCTAssertEqual(s.scrollingApps["Instagram"], false, "a choice you made is never overwritten")
    }

    func testWeekViewIsStoredAsAnAverageNotADay() {
        var s = state()
        DumpApplier.apply(DumpResult(ops: [shot(["period": .string("week")])], reply: ""), to: &s, now: Fx.mon(20), calendar: cal)
        XCTAssertTrue(s.screen.isEmpty)
        XCTAssertEqual(s.screenAverages.count, 1)
    }

    func testTodayLabelBeatsAWrongDate() {
        var s = state()
        DumpApplier.apply(DumpResult(ops: [shot(["dateLabelShown": .string("Yesterday"), "date": .string("2026-11-01")])], reply: ""),
                          to: &s, now: Fx.mon(9, plusDays: 1), calendar: cal)
        XCTAssertEqual(cal.startOfDay(for: s.screen[0].day), Fx.mon(0))
    }

    func testPickupsFirstPickupAndNotificationsAreStoredAndReceipted() {
        var s = state()
        let a = shot(["screenMinutes": .number(200), "pickups": .number(84), "firstPickup": .string("6:42 AM"),
                      "notifications": .number(150), "apps": .array([app("Instagram", 60)])])
        let rep = DumpApplier.apply(DumpResult(ops: [a], reply: ""), to: &s, now: Fx.mon(20, plusDays: 1), calendar: cal)
        XCTAssertEqual(s.screen[0].pickups, 84)
        XCTAssertEqual(s.screen[0].firstPickup, 6 * 60 + 42)
        XCTAssertEqual(s.screen[0].notifications, 150)
        XCTAssertTrue(rep.changes.joined().contains("84 pickups"), "\(rep.changes)")
        // A second screenshot of the same day keeps the larger counts and the earlier first pickup.
        let b = shot(["screenMinutes": .number(200), "pickups": .number(90), "firstPickup": .string("06:30"),
                      "apps": .array([app("Instagram", 60)])])
        DumpApplier.apply(DumpResult(ops: [b], reply: ""), to: &s, now: Fx.mon(20, plusDays: 1), calendar: cal)
        XCTAssertEqual(s.screen[0].pickups, 90)
        XCTAssertEqual(s.screen[0].firstPickup, 6 * 60 + 30)
        XCTAssertEqual(s.screen[0].notifications, 150)
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
        let x = MetricsInput(days: [day], screen: [], screenDays: [d], health: [], moods: [], items: [], outcomes: [],
                             progress: [], markers: [], planned: [:], sleepNeed: 540)
        let series = MetricsBuilder.series(x, calendar: cal)
        XCTAssertEqual(series[.pickups]?.points[day]?.value, 70)
        XCTAssertEqual(series[.firstPickup]?.points[day]?.value, 420)
        XCTAssertEqual(series[.notifications]?.points[day]?.value, 120)
    }

    func testTwoScreenshotsOfOneDayMergePerAppByMax() {
        var s = state()
        let a = shot(["screenMinutes": .number(300), "partial": .bool(true), "apps": .array([app("Instagram", 60), app("Slack", 50)])])
        let b = shot(["screenMinutes": .number(300), "partial": .bool(true), "apps": .array([app("Instagram", 96), app("Discord", 35)])])
        DumpApplier.apply(DumpResult(ops: [a], reply: ""), to: &s, now: Fx.mon(20, plusDays: 1), calendar: cal)
        DumpApplier.apply(DumpResult(ops: [b], reply: ""), to: &s, now: Fx.mon(20, plusDays: 1), calendar: cal)
        XCTAssertEqual(s.screen.count, 1)
        let apps = Dictionary(uniqueKeysWithValues: s.screen[0].apps!.map { ($0.name, $0.minutes) })
        XCTAssertEqual(apps, ["Instagram": 96, "Slack": 50, "Discord": 35])
        XCTAssertEqual(s.screen[0].distractingMinutes, 131)
    }

    func testScrollingSessionsPaintExactlyAndScreenshotMinutesAreEstimated() {
        let sessions = [ScrollSession(app: "Instagram", openedAt: Fx.mon(17), endedAt: Fx.mon(17, 30), endSource: .closed),
                        ScrollSession(app: "Slack", openedAt: Fx.mon(18), endedAt: Fx.mon(18, 20), endSource: .closed)]
        let inputs = DayInputs(day: Fx.mon(0), events: [], commitments: [Fx.school], routines: [], outcomes: [], health: nil,
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
        let inputs = DayInputs(day: Fx.mon(0), events: [], commitments: [Fx.school], routines: [], outcomes: [], health: nil,
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

    func applyShot(_ extra: [String: JSONValue], now: Date, into s: inout DumpState) -> DumpReport {
        DumpApplier.apply(DumpResult(ops: [base.shot(extra)], reply: ""), to: &s, now: now, calendar: cal)
    }

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

    func testEveryScreenshotKindShowsInTheWeek() {
        let wed = Fx.mon(20, plusDays: 2)
        var s = base.state()
        // A "yesterday" screenshot, one labelled with a weekday name, and today's.
        _ = applyShot(["dateLabelShown": .string("Yesterday"), "date": .null], now: wed, into: &s)
        _ = applyShot(["dateLabelShown": .string("Monday"), "date": .null], now: wed, into: &s)
        _ = applyShot(["dateLabelShown": .string("Today"), "date": .null], now: wed, into: &s)
        let pts = ScreenSeries.daily(screen: s.screen, averages: s.screenAverages, days: week(ending: wed), calendar: cal)
        XCTAssertEqual(pts.compactMap { $0 }.map { $0.day }, [Fx.mon(0), Fx.mon(0, plusDays: 1), Fx.mon(0, plusDays: 2)])
        let sum = ScreenSeries.summary(pts)!
        XCTAssertEqual(sum.scrolling, 131)
        XCTAssertEqual(sum.total, 202)
        XCTAssertEqual(sum.line, "2h 11m of scrolling a day (3h 22m total), from Screen Time")
    }

    func testAWeekAverageFillsDaysWithoutBetterData() {
        let wed = Fx.mon(20, plusDays: 2)
        var s = base.state()
        _ = applyShot(["period": .string("week"), "screenMinutes": .number(240),
                       "apps": .array([base.app("TikTok", 90), base.app("Notes", 30)])], now: wed, into: &s)
        XCTAssertTrue(s.screen.isEmpty)
        var pts = ScreenSeries.daily(screen: s.screen, averages: s.screenAverages, days: week(ending: wed), calendar: cal)
        XCTAssertEqual(pts.compactMap { $0 }.count, 7)
        XCTAssertEqual(ScreenSeries.summary(pts)?.line, "1h 30m of scrolling a day (4h total), daily average from Screen Time")
        _ = applyShot(["dateLabelShown": .string("Today")], now: wed, into: &s)
        pts = ScreenSeries.daily(screen: s.screen, averages: s.screenAverages, days: week(ending: wed), calendar: cal)
        XCTAssertEqual(pts.last??.source, .screenshot, "a day screenshot beats the average")
        XCTAssertEqual(pts.first??.source, .average)
        // A week later the average no longer covers anything.
        let later = week(ending: Fx.mon(20, plusDays: 10))
        XCTAssertTrue(ScreenSeries.daily(screen: [], averages: s.screenAverages, days: later, calendar: cal).allSatisfy { $0 == nil })
    }

    func testNoScrollingAppsStillShowsTheTotal() {
        var s = base.state()
        _ = applyShot(["dateLabelShown": .string("Today"), "apps": .array([base.app("Notes", 60), base.app("Slack", 40)]),
                       "screenMinutes": .number(110)], now: Fx.mon(20), into: &s)
        let sum = ScreenSeries.summary(ScreenSeries.daily(screen: s.screen, averages: [], days: [Fx.mon(0)], calendar: cal))!
        XCTAssertEqual(sum.line, "0m of scrolling a day (1h 50m total), from Screen Time")
    }

    func testScreenshotsWinOverShortcutsAndOldNumbersAreRecomputed() {
        let shot = ScreenDay(day: Fx.mon(0), distractingMinutes: 68, totalMinutes: 202,
                             apps: [AppUsage(name: "Instagram", minutes: 96, distracting: true),
                                    AppUsage(name: "Discord", minutes: 35, distracting: true),
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
        DumpState(items: [], commitments: [Fx.school], exceptions: [], oneOffs: [], markers: [],
                  routines: Routine.defaults, moods: [], screen: [], prefs: Preferences())
    }

    static func app(_ n: String, _ m: Int, _ c: String? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["name": .string(n), "minutes": .number(Double(m))]
        if let c { o["category"] = .string(c) }
        return .object(o)
    }

    static func shot(_ extra: [String: JSONValue]) -> DumpOp {
        var f: [String: JSONValue] = ["date": .string("2026-11-16"), "period": .string("day"), "screenMinutes": .number(202),
                                      "apps": .array([app("Firefox", 97), app("Instagram", 96, "Social"), app("Slack", 50), app("Discord", 35)])]
        for (k, v) in extra { f[k] = v }
        return .upsert("screen_time", f)
    }
}
