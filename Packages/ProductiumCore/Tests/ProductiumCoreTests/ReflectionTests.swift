import XCTest
@testable import ProductiumCore

final class ReflectionTests: XCTestCase {
    let cal = Fx.cal
    let essay = WorkItem(title: "Waterloo AIF revision", kind: .application, due: Fx.mon(23, plusDays: 10))

    func testTriggersAreGatedToOnceADay() {
        let d = [Deferral(itemId: essay.id, title: essay.title, count: 3, lastAt: Fx.mon(9), reasons: [])]
        func t(_ last: Date? = nil, _ defs: [Deferral] = [], days: [DayRecord] = [], weekly: Bool = false, asked: Bool = false,
               paused: Bool = false, budget: Bool = true) -> ReflectionTrigger? {
            Reflection.trigger(now: Fx.mon(18), lastRun: last, deferrals: defs, days: days, weeklyDue: weekly, asked: asked,
                               paused: paused, budgetAllows: budget, calendar: cal)
        }
        XCTAssertEqual(t(nil, d), .deferrals)
        XCTAssertNil(t(Fx.mon(8), d), "once a day")
        XCTAssertNil(t(nil, d, budget: false), "skips over budget")
        XCTAssertNil(t(nil, d, paused: true))
        XCTAssertEqual(t(asked: true), .asked)
        XCTAssertNil(t(), "nothing to reflect on")
        let low = (1...3).map { DayRecord(day: Fx.mon(0, plusDays: -$0), isSchoolDay: true, planned: 120, done: 30) }
        XCTAssertEqual(t(days: low), .lowFollowThrough)
        XCTAssertEqual(t(weekly: true), .weekly)
        var items = [essay]
        for i in 0..<3 { Avoidance.record(.skipped, itemId: essay.id, in: &items, at: Fx.mon(19, plusDays: -i), reason: "tired", blockId: UUID()) }
        XCTAssertEqual(Reflection.deferrals(items: items, since: Fx.mon(0, plusDays: -14)).first?.count, 3)
        XCTAssertEqual(Reflection.deferrals(items: items, since: Fx.mon(0, plusDays: -14)).first?.reasons, ["tired", "tired", "tired"])
    }

    func testRecordedReplyBecomesProposals() throws {
        let ref = Ref.task(essay.id)
        let reply = """
        {"note":"You've put off the Waterloo revision 3 times. Make it a 15-minute first step right after school?",
         "proposals":[
          {"type":"starter_step","task":"\(ref)","title":"Open the doc and fix one paragraph","minutes":15,"due":"2026-11-17T15:30",
           "reason":"Skipped 3 evening blocks this week","evidence":["Mon skipped","Wed skipped","Thu skipped"]},
          {"type":"intention","trigger":"time","weekdays":[3],"time":"15:30","text":"When you get home Tuesday, open the Waterloo doc",
           "task":"\(ref)","reason":"An if-then plan makes starting automatic"},
          {"type":"knob","knob":"planner.maxBlockMinutes","value":30,"reason":"Abandoned 40-minute blocks"},
          {"type":"knob","knob":"sleepNeedMinutes","value":450,"reason":"More time"}],
         "about_me":[{"section":"Patterns","text":"puts off university essays: deferred 3× this week"},
                     {"section":"Stated","text":"likes essays"}]}
        """
        let res = AIResponse(model: "claude-opus-5-5", text: reply, usage: nil)
        let out = try XCTUnwrap(res.decoded(Reflection.Output.self, schema: Reflection.schema))
        let run = ReflectionRun(at: Fx.mon(9), note: out.note, model: "opus")
        let drafts = Reflection.drafts(out, runId: run.id, items: [essay], now: Fx.mon(9), model: "opus", calendar: cal)
        var s = DumpState(items: [essay], commitments: [Fx.school], exceptions: [], oneOffs: [], markers: [], routines: Routine.defaults,
                          moods: [], screen: [], prefs: Preferences())
        var book = ProposalBook()
        let problems = book.submit(run, drafts, state: s, now: Fx.mon(9))
        XCTAssertEqual(book.pending.count, 4, "3 changes + the Patterns line; \(problems)")
        XCTAssertEqual(problems.count, 2, "sleep need and the Stated line are refused: \(problems)")
        XCTAssertEqual(s.items.count, 1, "nothing applied yet")
        XCTAssertTrue(s.aboutMe[.patterns].isEmpty)
        for p in book.pending { XCTAssertTrue(book.approve(p.id, in: &s, now: Fx.mon(10), calendar: cal), p.title) }
        XCTAssertEqual(s.items.count, 2)
        XCTAssertEqual(s.policy.maxBlockMinutes, 45, "bounded: 55 → 30 asked, -10 applied")
        XCTAssertEqual(s.policy.intentions.first?.itemId, essay.id)
        XCTAssertEqual(s.aboutMe[.patterns].first?.text, "puts off university essays: deferred 3× this week")
        let text = Reflection.request(now: Fx.mon(9), aboutMe: s.aboutMe, beliefs: Beliefs(), routines: Routine.defaults,
                                      deferrals: [Deferral(itemId: essay.id, title: essay.title, count: 3, lastAt: nil, reasons: [])],
                                      days: [], policy: s.policy, feedback: ["Rejected: x"], conversations: ["Waterloo drafts"],
                                      items: [essay], trigger: .deferrals, question: nil, calendar: cal)
        for needle in ["Put off: \(ref)", "planner.maxBlockMinutes 45", "Turned down before", "About the student"] {
            XCTAssertTrue(text.contains(needle), needle)
        }
        let req = AIRequest(model: AIModel.opus, system: Reflection.system(), messages: [AIMessage(role: "user", content: text)],
                            schema: Reflection.schema, maxTokens: 1500, effort: "medium")
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(req)) as! [String: Any]
        XCTAssertEqual((body["output_config"] as? [String: Any])?["effort"] as? String, "medium")
        XCTAssertEqual(body["model"] as? String, "opus")
        XCTAssertEqual(AIFeature.reflection.title, "Opus · reflection")
        XCTAssertTrue(AIFeature.reflection.isBackground, "stands down over budget")
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

    func testBoxContextShowsPutOff() {
        var items = [item()]
        for i in 0..<3 { Avoidance.record(.skipped, itemId: items[0].id, in: &items, at: Fx.mon(8 + i), blockId: UUID()) }
        let s = DumpState(items: items, commitments: [], exceptions: [], oneOffs: [], markers: [], routines: [], moods: [], screen: [], prefs: Preferences())
        XCTAssertTrue(Prompts.dumpContext(DumpContextInput(now: Fx.mon(12), calendar: Fx.cal, state: s)).contains("put off 3×"))
    }
}
