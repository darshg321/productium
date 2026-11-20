import XCTest
@testable import ProductiumCore

final class GapTests: XCTestCase {
    let cal = Fx.cal

    func input(now: Date, markers: [CheckIn] = [], phone: [Date] = [Fx.mon(16)], scrolling: [ScrollSession] = [],
               plan: Plan = .empty, log: GapLog = GapLog(), focusing: Bool = false) -> GapInput {
        GapInput(now: now, day: DayInputs(day: Fx.mon(0), entries: Fx.log(markers, now: now), routines: Routine.defaults,
                                          health: nil, screen: nil, prefs: Preferences()),
                 scrolling: scrolling, phoneUse: phone, plan: plan, focusing: focusing, log: log)
    }

    func testOngoingGapIsAskedAt45Minutes() {
        XCTAssertNil(GapDetector.due(input(now: Fx.mon(16)), calendar: cal), "40 min so far: not yet")
        let g = GapDetector.due(input(now: Fx.mon(16, 10)), calendar: cal)
        XCTAssertEqual(g?.start, Fx.mon(15, 20))
        XCTAssertEqual(g?.ongoing, true)
        XCTAssertEqual(GapDetector.question(g!, calendar: cal), "What have you been doing since 3:20?")
        XCTAssertEqual(GapDetector.nextAsk(input(now: Fx.mon(15, 40)), calendar: cal)?.at, Fx.mon(16, 5))
    }

    func testEndedGapIsAskedTenMinutesAfterAndOnlyWhileFresh() {
        let m = [CheckIn(at: Fx.mon(16, 10), phrase: "starting soccer", activity: "soccer", category: .activities, phase: .start)]
        XCTAssertNil(GapDetector.due(input(now: Fx.mon(16, 15), markers: m), calendar: cal), "10 minutes after it ends, not before")
        let g = GapDetector.due(input(now: Fx.mon(16, 20), markers: m), calendar: cal)
        XCTAssertEqual(g?.end, Fx.mon(16, 10))
        XCTAssertEqual(g?.ongoing, false)
        XCTAssertEqual(GapDetector.question(g!, calendar: cal), "What were you doing 3:20–4:10?")
        XCTAssertNil(GapDetector.due(input(now: Fx.mon(17, 21), markers: m), calendar: cal), "over 2 h old: left unknown")
    }

    func testThresholdsAndWhatExplainsTime() {
        let m = [CheckIn(at: Fx.mon(15, 50), phrase: "starting homework", activity: "study", category: .study, phase: .start)]
        XCTAssertNil(GapDetector.due(input(now: Fx.mon(16, 40), markers: m), calendar: cal))
        let scroll = ScrollSession(app: "Instagram", openedAt: Fx.mon(15, 30), endedAt: Fx.mon(16, 0), endSource: .closed)
        XCTAssertNil(GapDetector.due(input(now: Fx.mon(16, 10), scrolling: [scroll]), calendar: cal))
        XCTAssertNil(GapDetector.due(input(now: Fx.mon(16, 10), phone: []), calendar: cal))
    }

    func testDailyCapFocusAndWindDown() {
        let asked = (0..<4).map { AskedGap(start: Fx.mon($0), end: Fx.mon($0, 50), askedAt: Fx.mon($0 + 1)) }
        XCTAssertNil(GapDetector.due(input(now: Fx.mon(16, 10), log: GapLog(asked: asked)), calendar: cal), "4 a day at most")
        XCTAssertNil(GapDetector.due(input(now: Fx.mon(16, 10), focusing: true), calendar: cal))
        let wind = Plan(generatedAt: Fx.mon(7), blocks: [PlannedBlock(kind: .windDown, start: Fx.mon(16), end: Fx.mon(16, 30), title: "Wind down")],
                        warnings: [], shortfalls: [:], sleepTradeoffMinutes: 0, loadFactor: 1)
        XCTAssertNil(GapDetector.due(input(now: Fx.mon(16, 10), plan: wind), calendar: cal))
        let once = GapLog(asked: [AskedGap(start: Fx.mon(15, 20), end: Fx.mon(16, 5), askedAt: Fx.mon(16, 5))])
        XCTAssertNil(GapDetector.due(input(now: Fx.mon(16, 10), log: once), calendar: cal))
    }

    func testReplyBecomesASegment() {
        let g = MysteryGap(start: Fx.mon(15, 20), end: Fx.mon(16, 10), ongoing: false)
        let m = GapAnswer.markers(for: "gym", gap: g, commitments: [Fx.school], known: [], calendar: cal)!
        XCTAssertEqual(m.map(\.activity), ["exercise", "exercise"])
        var tree = CategoryTree(), logged = Fx.schoolEntries
        CheckIns.apply(m, to: &logged, tree: &tree, now: Fx.mon(17), calendar: cal)
        let segs = TimelineBuilder.segments(DayInputs(day: Fx.mon(0), entries: logged, categories: tree, routines: Routine.defaults,
                                                      health: nil, screen: nil, prefs: Preferences()),
                                            calendar: cal, now: Fx.mon(17))
        let seg = segs.first { $0.category == .activities }
        XCTAssertEqual(seg?.start, Fx.mon(15, 20))
        XCTAssertEqual(seg?.end, Fx.mon(16, 10))
        XCTAssertNil(GapAnswer.markers(for: "finished the lab then went over to Sam's place", gap: g, commitments: [], known: [], calendar: cal),
                     "long answers go to the box")
        XCTAssertEqual(GapAnswer.boxText("lab then Sam's", gap: g, calendar: cal), "From 2026-11-16T15:20 to 2026-11-16T16:10 I was: lab then Sam's")
        let tue = (0..<3).map { AskedGap(start: Fx.mon(16, 5, plusDays: 1 + 7 * $0), end: Fx.mon(17, plusDays: 1 + 7 * $0),
                                         askedAt: Fx.mon(17, plusDays: 1 + 7 * $0), answer: "gym", activity: "exercise") }
        XCTAssertEqual(GapAnswer.repeated(tue, calendar: cal).first?.count, 3)
    }
}

final class GapExplainedTests: XCTestCase {
    let cal = Fx.cal
    func testAVisitOrWorkoutExplainsAGapSoNothingIsAsked() {
        let day = DayInputs(day: Fx.mon(0), entries: Fx.schoolEntries, routines: Routine.defaults, health: nil, screen: nil, prefs: Preferences())
        let plain = GapInput(now: Fx.mon(16, 10), day: day, phoneUse: [Fx.mon(16)])
        XCTAssertNotNil(GapDetector.due(plain, calendar: cal))
        let walk = GapInput(now: Fx.mon(16, 10), day: day, phoneUse: [Fx.mon(16)],
                            explained: [DateInterval(start: Fx.mon(15, 15), end: Fx.mon(16, 30))])
        XCTAssertNil(GapDetector.due(walk, calendar: cal))
    }
}
