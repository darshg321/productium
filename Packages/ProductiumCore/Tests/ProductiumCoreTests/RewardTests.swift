import XCTest
@testable import ProductiumCore

/// v1.1 F2: rewards for what you're trying to do, budgeted, reproducible, never for using the app.
final class RewardTests: XCTestCase {
    let cal = Fx.cal

    func focus(_ minutes: Int = 40, total: Int = 0, title: String? = "Essay", before: Int? = 40, after: Int? = 65,
               free: Int? = 120) -> RewardEvent {
        .focusEnded(status: .done, minutes: minutes, title: title, percentBefore: before, percentAfter: after,
                    freeAfterMinutes: free, totalFocusMinutesBefore: total)
    }

    func testNeverForUsingProductium() {
        var log = RewardLog()
        for e: RewardEvent in [.appOpened, .tabChanged, .timeInApp(minutes: 45)] {
            XCTAssertNil(Rewards.respond(to: e, log: &log, settings: RewardSettings(), now: Fx.mon(12), calendar: cal))
        }
        XCTAssertTrue(log.moments.isEmpty)
    }

    func testCopyComesFromWhatHappened() {
        var log = RewardLog()
        let s = RewardSettings(surpriseRate: 0)
        let m = Rewards.respond(to: focus(), log: &log, settings: s, now: Fx.mon(16), calendar: cal)!
        XCTAssertEqual(m.title, "Essay 40% → 65%")
        XCTAssertEqual(m.detail, "After this: 2h free")
        XCTAssertEqual(m.intensity, .small)
        let step = Rewards.respond(to: .itemDone(title: "Outline", isStep: true, stepsLeft: 2, daysEarly: 0), log: &log,
                                   settings: s, now: Fx.mon(17), calendar: cal)!
        XCTAssertEqual([step.title, step.detail], ["Outline done", "2 steps left"])
        let early = Rewards.respond(to: .itemDone(title: "Bio outline", isStep: false, stepsLeft: 0, daysEarly: 2), log: &log,
                                    settings: s, now: Fx.mon(18), calendar: cal)!
        XCTAssertEqual(early.detail, "2 days early")
        let scroll = Rewards.respond(to: .scrollClosedEarly(app: "Instagram", minutes: 6, usualMinutes: 10), log: &log,
                                     settings: s, now: Fx.mon(19), calendar: cal)!
        XCTAssertEqual([scroll.title, scroll.detail], ["Back in 6 min", "4 min shorter than your usual Instagram"])
        XCTAssertNil(Rewards.respond(to: .scrollClosedEarly(app: "Instagram", minutes: 9, usualMinutes: 10), log: &log,
                                     settings: s, now: Fx.mon(19, 30), calendar: cal), "a minute shorter isn't worth a note")
        XCTAssertNil(Rewards.respond(to: focus(3), log: &log, settings: s, now: Fx.mon(20), calendar: cal), "3 minutes isn't a session")
    }

    func testBudgetHoldsOverASimulatedMonth() {
        var log = RewardLog()
        var big = 0, mediumByWeek: [Int: Int] = [:]
        for d in 0..<30 {
            for h in [9, 11, 14, 16, 19] {
                let now = Fx.mon(h, plusDays: d)
                for e in [focus(), .itemDone(title: "Step", isStep: true, stepsLeft: 1, daysEarly: 0), .planFinished(freeMinutesLeft: 90)] {
                    guard let m = Rewards.respond(to: e, log: &log, settings: RewardSettings(), now: now, calendar: cal) else { continue }
                    if m.intensity == .big { big += 1 }
                }
            }
            XCTAssertLessThanOrEqual(log.moments.filter { cal.isDate($0.at, inSameDayAs: Fx.mon(0, plusDays: d)) && $0.intensity == .big }.count, 1)
        }
        XCTAssertEqual(big, 30, "one big moment a day: the plan finished, once")
        for d in 0..<30 {
            let end = Fx.mon(23, plusDays: d)
            let n = log.moments.filter { $0.intensity == .medium && $0.at > end.addingTimeInterval(-7 * 86400) && $0.at <= end }.count
            mediumByWeek[d] = n
            XCTAssertLessThanOrEqual(n, Rewards.mediumPerWeek, "day \(d)")
        }
        XCTAssertGreaterThan(mediumByWeek.values.reduce(0, +), 0, "surprise does happen")
    }

    func testSameSeedSameMoments() {
        func run() -> [RewardMoment] {
            var log = RewardLog()
            for d in 0..<10 { _ = Rewards.respond(to: focus(), log: &log, settings: RewardSettings(), now: Fx.mon(16, plusDays: d), calendar: cal) }
            return log.moments
        }
        XCTAssertEqual(run(), run())
        XCTAssertTrue(run().contains { $0.surprise }, "some small moments turn medium over 10 days")
    }

    func testMilestonesAndLevels() {
        var log = RewardLog()
        let m = Rewards.respond(to: focus(45, total: 9 * 60 + 30), log: &log, settings: RewardSettings(), now: Fx.mon(16), calendar: cal)!
        XCTAssertEqual(m.kind, .milestone)
        XCTAssertEqual(m.title, "10 focus hours")
        XCTAssertEqual(m.intensity, .big)
        let next = Rewards.respond(to: focus(45, total: 10 * 60 + 15), log: &log, settings: RewardSettings(surpriseRate: 0), now: Fx.mon(18), calendar: cal)!
        XCTAssertEqual(next.kind, .focusDone, "no rung crossed")
        var sub = RewardLog()
        XCTAssertEqual(Rewards.respond(to: .planFinished(freeMinutesLeft: 60), log: &sub, settings: RewardSettings(level: .subtle),
                                       now: Fx.mon(20), calendar: cal)?.intensity, .small)
        var off = RewardLog()
        XCTAssertNil(Rewards.respond(to: .planFinished(freeMinutesLeft: 60), log: &off, settings: RewardSettings(level: .off),
                                     now: Fx.mon(20), calendar: cal))
    }

}

/// v1.1 F6: celebrations that make no difference are turned down, and that is logged and revertible.
final class RewardImpactTests: XCTestCase {
    let cal = Fx.cal

    func scenario(boost: Int) -> (RewardLog, [Entry]) {
        var log = RewardLog()
        var outcomes: [Entry] = []
        for i in 0..<35 {
            let day = Fx.mon(10, plusDays: i - 35)
            if i % 2 == 0 {
                log.moments.append(RewardMoment(kind: .planFinished, intensity: .big, title: "x", detail: nil, at: day, surprise: false))
            }
            // The next day's focus: 30 minutes, plus `boost` after a celebrated day.
            let next = Fx.mon(10, plusDays: i - 34)
            let end = next.addingTimeInterval(Double(30 + (i % 2 == 0 ? boost : 0)) * 60)
            outcomes.append(Entry(title: "Essay", start: next, end: end, category: CategoryTree.studying, taskId: UUID(), source: .you,
                                  createdAt: end))
        }
        return (log, outcomes)
    }

    func testNoDifferenceTurnsCelebrationsDownAndItCanBeReverted() {
        let (log, outcomes) = scenario(boost: 0)
        let r = RewardImpact.evaluate(log: log, entries: outcomes, now: Fx.mon(10), calendar: cal)
        XCTAssertNotNil(r)
        XCTAssertFalse(r!.works)
        XCTAssertEqual(RewardImpact.turnDown(r, settings: RewardSettings()), .subtle)
        XCTAssertNil(RewardImpact.turnDown(r, settings: RewardSettings(level: .subtle)), "never below subtle, never to off")

        var s = DumpState(items: [], moods: [], screen: [], prefs: Preferences())
        var changes = ChangeLog()
        let draft = LoggedChange(runId: UUID(), change: .celebrations(to: .subtle, from: .full), reason: "No difference in focus the next day",
                                 model: "code", at: Fx.mon(10))
        XCTAssertTrue(changes.apply(InsightRun(at: Fx.mon(10), note: "", model: "code"), [draft], to: &s, now: Fx.mon(10)).isEmpty)
        XCTAssertEqual(s.rewardSettings.level, .subtle)
        XCTAssertTrue(changes.revert(changes.applied[0].id, in: &s, now: Fx.mon(11)))
        XCTAssertEqual(s.rewardSettings.level, .full)
    }

    func testRealEffectOrTooLittleDataLeavesThemAlone() {
        let (log, outcomes) = scenario(boost: 25)
        let r = RewardImpact.evaluate(log: log, entries: outcomes, now: Fx.mon(10), calendar: cal)
        XCTAssertTrue(r?.works ?? false)
        XCTAssertNil(RewardImpact.turnDown(r, settings: RewardSettings()))
        XCTAssertNil(RewardImpact.evaluate(log: log, entries: outcomes, now: Fx.mon(10, plusDays: -20), calendar: cal), "under four weeks of moments")
    }
}
