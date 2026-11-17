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
        XCTAssertEqual(scroll.count, 1)
        XCTAssertEqual(scroll[0].start, Fx.mon(17))
        XCTAssertFalse(scroll[0].inferred)
        let totals = TimelineBuilder.totals(segs, screen: inputs.screen)
        XCTAssertEqual(totals[.screen], 60, "30 timed plus 30 estimated from the screenshot")
    }
}
