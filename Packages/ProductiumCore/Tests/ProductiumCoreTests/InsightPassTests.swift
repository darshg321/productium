import XCTest
@testable import ProductiumCore

/// v1.1 D3: one Sonnet pass writes the Weekly Note and quietly applies small changes.
final class InsightPassTests: XCTestCase {
    let cal = Fx.cal
    let essay = WorkItem(title: "Waterloo AIF revision", kind: .application, due: Fx.mon(23, plusDays: 10))

    func testTriggers() {
        let d = [Deferral(itemId: essay.id, title: essay.title, count: 3, lastAt: Fx.mon(9), reasons: [])]
        func t(_ last: Date? = nil, _ defs: [Deferral] = [], days: [DayRecord] = [], weekly: Bool = false, asked: Bool = false,
               budget: Bool = true) -> InsightTrigger? {
            InsightPass.trigger(now: Fx.mon(18), lastRun: last, deferrals: defs, days: days, weeklyDue: weekly, asked: asked,
                                budgetAllows: budget, calendar: cal)
        }
        XCTAssertEqual(t(nil, d), .deferrals)
        XCTAssertNil(t(Fx.mon(8), d), "the extra triggers run at most once a day")
        XCTAssertEqual(t(Fx.mon(8), d, weekly: true), .weekly, "the weekly note isn't held back by an earlier run that day")
        XCTAssertNil(t(nil, d, budget: false), "skips over budget")
        XCTAssertEqual(t(asked: true), .asked)
        XCTAssertNil(t(), "nothing to look at")
        let low = (1...3).map { DayRecord(day: Fx.mon(0, plusDays: -$0), isSchoolDay: true, planned: 120, done: 30) }
        XCTAssertEqual(t(days: low), .lowFollowThrough)
        var items = [essay]
        for i in 0..<3 { Avoidance.record(.skipped, itemId: essay.id, in: &items, at: Fx.mon(19, plusDays: -i), reason: "tired", blockId: UUID()) }
        XCTAssertEqual(InsightPass.deferrals(items: items, since: Fx.mon(0, plusDays: -14)).first?.count, 3)
        XCTAssertEqual(InsightPass.deferrals(items: items, since: Fx.mon(0, plusDays: -14)).first?.reasons, ["tired", "tired", "tired"])
    }

    func testRecordedReplyWritesTheNoteAndAppliesQuietly() throws {
        let ref = Ref.task(essay.id)
        let reply = """
        {"headline":"A steady week with one sticking point",
         "wins":["You finished 4 of 5 planned blocks before Thursday."],
         "suggestions":["Try a 15-minute start on the Waterloo revision right after school.","Phone out of the room for study.","A third one."],
         "changes":[
          {"type":"starter_step","task":"\(ref)","title":"Open the doc and fix one paragraph","minutes":15,"due":"2026-11-17T15:30",
           "reason":"Skipped 3 evening blocks this week","evidence":["Mon skipped","Wed skipped","Thu skipped"]},
          {"type":"intention","trigger":"time","weekdays":[3],"time":"15:30","text":"When you get home Tuesday, open the Waterloo doc",
           "task":"\(ref)","reason":"An if-then plan makes starting automatic"},
          {"type":"knob","knob":"planner.maxBlockMinutes","value":30,"reason":"Abandoned 40-minute blocks"},
          {"type":"knob","knob":"sleepNeedMinutes","value":450,"reason":"More time"}],
         "about_me":[{"section":"Patterns","text":"puts off university essays: deferred 3× this week"},
                     {"section":"Stated","text":"likes essays"}]}
        """
        let res = AIResponse(model: "claude-sonnet-5-5", text: reply, usage: nil)
        let out = try XCTUnwrap(res.decoded(InsightPass.Output.self, schema: InsightPass.schema))
        XCTAssertEqual(out.review.headline, "A steady week with one sticking point")
        XCTAssertEqual(out.review.suggestions.count, 2, "the note keeps at most 2 suggestions")
        let run = InsightRun(at: Fx.mon(9), note: out.headline, model: "sonnet")
        let drafts = InsightPass.drafts(out, runId: run.id, items: [essay], now: Fx.mon(9), model: "sonnet", calendar: cal)
        var s = DumpState(items: [essay], oneOffs: [], markers: [], routines: Routine.defaults,
                          moods: [], screen: [], prefs: Preferences())
        var log = ChangeLog()
        let problems = log.apply(run, drafts, to: &s, now: Fx.mon(9))
        XCTAssertEqual(log.applied.count, 4, "3 changes + the Patterns line, applied at once; \(problems)")
        XCTAssertEqual(problems.count, 2, "sleep need and the Stated line are refused: \(problems)")
        XCTAssertEqual(s.items.count, 2)
        XCTAssertEqual(s.policy.maxBlockMinutes, 45, "bounded: 55 → 30 asked, -10 applied")
        XCTAssertEqual(s.prefs.sleepNeedMinutes, 540, "sleep need is never Productium's to change")
        XCTAssertEqual(s.policy.intentions.first?.itemId, essay.id)
        XCTAssertEqual(s.aboutMe[.patterns].first?.text, "puts off university essays: deferred 3× this week")

        let text = InsightPass.request(InsightInput(now: Fx.mon(9), calendar: cal, trigger: .deferrals, aboutMe: s.aboutMe,
                                                    deferrals: [Deferral(itemId: essay.id, title: essay.title, count: 3, lastAt: nil, reasons: ["tired"])],
                                                    policy: s.policy, feedback: log.feedback + ["Reverted: x"],
                                                    changes: log.changeSummary(now: Fx.mon(9)), conversations: ["Waterloo drafts"],
                                                    items: [essay]))
        for needle in ["Put off: \(ref)", "tired", "planner.maxBlockMinutes 45", "Undone before", "About the student",
                       "Changes Productium made lately", "Task ids: \(ref)"] {
            XCTAssertTrue(text.contains(needle), needle)
        }
        XCTAssertFalse(text.contains("sleepNeedMinutes"), "forbidden knobs aren't offered")
        XCTAssertFalse(InsightPass.system().contains("approve"), "no approval step left in the prompt")
        XCTAssertTrue(AIFeature.review.isBackground, "stands down over budget")
    }
}

final class AvoidanceTests: XCTestCase {
    func item() -> WorkItem { WorkItem(title: "Waterloo revision", kind: .practice, due: Fx.mon(18, plusDays: 3)) }

    func testEveryWayOfPuttingOffCountsOnceAndShows() {
        var items = [item()]
        let id = items[0].id
        let b1 = UUID(), b2 = UUID()
        Avoidance.record(.snoozed, itemId: id, in: &items, at: Fx.mon(16), blockId: b1)
        Avoidance.record(.snoozed, itemId: id, in: &items, at: Fx.mon(16, 10), blockId: b1)
        Avoidance.record(.skipped, itemId: id, in: &items, at: Fx.mon(17), reason: "  too tired ", blockId: b1)
        Avoidance.record(.skipped, itemId: id, in: &items, at: Fx.mon(17, 1), blockId: b1)
        Avoidance.recordMissed([PlannedBlock(id: b2, kind: .work, start: Fx.mon(19), end: Fx.mon(20), title: "x", itemId: id)], in: &items, at: Fx.mon(21))
        Avoidance.recordMissed([PlannedBlock(id: b2, kind: .work, start: Fx.mon(19), end: Fx.mon(20), title: "x", itemId: id)], in: &items, at: Fx.mon(22))
        XCTAssertEqual(items[0].deferralCount, 4, "two snoozes, one skip, one missed; repeats of the same block don't recount")
        XCTAssertEqual(items[0].putOffLabel, "Put off 4×")
        XCTAssertEqual(items[0].deferralReasons, ["too tired"])
        XCTAssertEqual(items[0].lastDeferredAt, Fx.mon(21))
    }

    func testMovingTheDueDateLaterIsPuttingItOffWithYourWords() {
        var items = [item()]
        let before = items
        items[0].due = items[0].due.addingTimeInterval(2 * 86400)
        Avoidance.recordDueMoves(before: before, after: &items, at: Fx.mon(12), reason: "push it to the weekend, I'm swamped")
        XCTAssertEqual(items[0].deferrals.map(\.kind), [.dueMoved])
        XCTAssertEqual(items[0].deferralReasons, ["push it to the weekend, I'm swamped"])
        var earlier = items
        earlier[0].due = earlier[0].due.addingTimeInterval(-86400)
        Avoidance.recordDueMoves(before: items, after: &earlier, at: Fx.mon(13), reason: nil)
        XCTAssertEqual(earlier[0].deferralCount, 1, "an earlier date isn't a put-off")
    }

}

/// v1.1 A9: the insight pass can turn repeated one-day changes into one rule, or make a behaviour conditional.
final class InsightSituationTests: XCTestCase {
    let cal = Fx.cal


}

final class InsightAlarmTests: XCTestCase {
    let cal = Fx.cal
    func changes(_ cs: [InsightPass.Output.Change], items: [WorkItem] = []) -> (ChangeLog, DumpState, [String]) {
        let out = InsightPass.Output(headline: "h", wins: [], suggestions: [], changes: cs, about_me: nil)
        let drafts = InsightPass.drafts(out, runId: UUID(), items: items, now: Fx.mon(9), model: "sonnet", calendar: cal)
        var s = DumpState(items: items, oneOffs: [], markers: [], routines: Routine.defaults,
                          moods: [], screen: [], prefs: Preferences())
        var log = ChangeLog()
        let problems = log.apply(InsightRun(at: Fx.mon(9), note: "", model: "sonnet"), drafts, to: &s, now: Fx.mon(9))
        return (log, s, problems)
    }

    func testInsightPassCanAddAndMoveAlarmsButNotRemoveTheMorningOne() {
        let essay = WorkItem(title: "Essay", kind: .essay, due: Fx.mon(23, plusDays: 5))
        let t = Ref.task(essay.id)
        var (log, s, problems) = changes([
            .init(type: "alarm", task: t, minutes: 5, alarm_kind: "before_blocks", label: "Essay time", reason: "missed the last 4 Essay blocks"),
            .init(type: "alarm", minutes: -45, alarm_kind: "shift", alarm_target: "bedtime", scope: #"{"weekdays":[6]}"#, reason: "late nights on Fridays"),
            .init(type: "alarm", alarm_kind: "off", alarm_target: "wake", reason: "x")], items: [essay])
        XCTAssertEqual(s.alarmRules.count, 2, "\(problems)")
        XCTAssertEqual(s.alarmRules.first { (r: AlarmRule) in r.kind == AlarmRule.Kind.shift }?.minutes, -30, "at most 30 minutes")
        XCTAssertEqual(problems.count, 1, "removing the morning alarm is refused: \(problems)")
        XCTAssertTrue(s.alarmRules.allSatisfy { (r: AlarmRule) in r.source == Writer.reflection })
        XCTAssertTrue(log.revert(log.applied[0].id, in: &s, now: Fx.mon(10)))
        XCTAssertEqual(s.alarmRules.count, 1)
        _ = (log, problems)
    }
}
