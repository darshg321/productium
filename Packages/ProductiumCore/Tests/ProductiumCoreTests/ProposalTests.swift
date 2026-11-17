import XCTest
@testable import ProductiumCore

final class ProposalTests: XCTestCase {
    let cal = Fx.cal
    let essay = WorkItem(title: "Waterloo AIF revision", kind: .application, due: Fx.mon(23, plusDays: 10))

    func state() -> DumpState {
        DumpState(items: [essay], commitments: [Fx.school], exceptions: [], oneOffs: [], markers: [], routines: Routine.defaults,
                  moods: [], screen: [], prefs: Preferences())
    }

    func draft(_ c: ProposalChange, reason: String = "evidence") -> BehaviourProposal {
        BehaviourProposal(runId: UUID(), change: c, from: "", to: "", reason: reason, evidence: ["deferred 3×"], model: "opus", at: Fx.mon(9))
    }

    func testNothingChangesUntilApprovedAndChangesAreBounded() {
        var s = state()
        var book = ProposalBook()
        let run = ReflectionRun(at: Fx.mon(9), note: "Shorter blocks?", model: "opus")
        let problems = book.submit(run, [draft(.knob(key: "planner.maxBlockMinutes", to: 25)),
                                         draft(.knob(key: "planner.capacityMultiplier", to: 0.5)),
                                         draft(.knob(key: "sleepNeedMinutes", to: 450)),
                                         draft(.intention(IntentionNudge(trigger: .time, weekdays: [3], time: TimeOfDay(15, 30),
                                                                         text: "When you get home Tuesday, open the Waterloo doc"))),
                                         draft(.knob(key: "planner.freeTimeMultiplier", to: 1.2))], state: s, now: Fx.mon(9))
        XCTAssertEqual(book.pending.count, 3, "at most 3 a run")
        XCTAssertEqual(problems.count, 2, "\(problems)")
        XCTAssertEqual(s.policy, BehaviourPolicy(), "nothing changed yet")
        let block = book.pending[0]
        XCTAssertEqual(block.from, "55")
        XCTAssertEqual(block.to, "45", "at most -10 a change")
        XCTAssertEqual(book.pending[1].to, "0.9", "at most -0.1 a change")

        XCTAssertTrue(book.approve(block.id, in: &s, now: Fx.mon(10), calendar: cal))
        XCTAssertEqual(s.policy.maxBlockMinutes, 45)
        XCTAssertTrue(book.approve(book.pending[1].id, in: &s, now: Fx.mon(10), calendar: cal), "intention")
        XCTAssertEqual(s.policy.intentions.count, 1)
        let nudges = NudgePlanner.plan(NudgeInput(now: Fx.mon(18), calendar: cal, plan: .empty, items: [], settings: NudgeSettings(),
                                                  policy: s.policy))
        XCTAssertTrue(nudges.contains { $0.kind == .intention && $0.at == Fx.mon(15, 30, plusDays: 1) })

        book.submit(ReflectionRun(at: Fx.mon(9, plusDays: 2), note: "", model: "opus"),
                    [draft(.knob(key: "planner.maxBlockMinutes", to: 35))], state: s, now: Fx.mon(9, plusDays: 2))
        XCTAssertTrue(book.pending.allSatisfy { $0.change.target != "planner.maxBlockMinutes" })

        XCTAssertTrue(book.revert(block.id, in: &s, now: Fx.mon(11)))
        XCTAssertEqual(s.policy.maxBlockMinutes, 55)
        XCTAssertEqual(book.history.first?.status, .reverted)
        XCTAssertTrue(book.feedback.first?.hasPrefix("Reverted") ?? false)
    }

    func testRejectPinExpireAndPause() {
        var s = state()
        var book = ProposalBook()
        let r1 = ReflectionRun(at: Fx.mon(9), note: "", model: "opus")
        book.submit(r1, [draft(.knob(key: "planner.freeTimeMultiplier", to: 1.3))], state: s, now: Fx.mon(9))
        book.reject(book.pending[0].id, now: Fx.mon(10))
        let again = book.submit(ReflectionRun(at: Fx.mon(9, plusDays: 8), note: "", model: "opus"),
                                [draft(.knob(key: "planner.freeTimeMultiplier", to: 1.1))], state: s, now: Fx.mon(9, plusDays: 8))
        XCTAssertEqual(again.count, 1)
        XCTAssertTrue(book.feedback.first?.hasPrefix("Rejected") ?? false)
        let r2 = ReflectionRun(at: Fx.mon(9, plusDays: 9), note: "", model: "opus")
        book.submit(r2, [draft(.knob(key: "planner.capacityMultiplier", to: 0.9))], state: s, now: Fx.mon(9, plusDays: 9))
        book.neverChange(book.pending[0].id, now: Fx.mon(10, plusDays: 9))
        XCTAssertTrue(book.isPaused(now: Fx.mon(10, plusDays: 10)))
        XCTAssertFalse(book.isPaused(now: Fx.mon(11, plusDays: 16)))
        XCTAssertTrue(book.pinned.contains("planner.capacityMultiplier"))
        let pinned = book.submit(ReflectionRun(at: Fx.mon(9, plusDays: 40), note: "", model: "opus"),
                                 [draft(.knob(key: "planner.capacityMultiplier", to: 0.9))], state: s, now: Fx.mon(9, plusDays: 40))
        XCTAssertEqual(pinned, ["planner.capacityMultiplier is pinned"])
        book.submit(ReflectionRun(at: Fx.mon(9, plusDays: 40), note: "", model: "opus"),
                    [draft(.knob(key: "planner.maxBlockMinutes", to: 45))], state: s, now: Fx.mon(9, plusDays: 40))
        book.expire(now: Fx.mon(9, plusDays: 48))
        XCTAssertTrue(book.pending.isEmpty)
        _ = s
    }

    func testStarterStepAndBeliefGroup() {
        var s = state()
        var book = ProposalBook()
        let run = ReflectionRun(at: Fx.mon(9), note: "Put off 3 times: make it a 15-minute first step?", model: "opus")
        book.submit(run, [
            draft(.starterStep(parent: essay.id, title: "Open the doc and fix one paragraph", minutes: 15, due: Fx.mon(17))),
            draft(.beliefGroup(BeliefGroup(id: "slump", title: "After-school slump 3–4 pm"), evidence: ["Mon", "Tue"])),
        ], state: s, now: Fx.mon(9))
        XCTAssertEqual(book.pending.count, 1, "a group needs 3 pieces of evidence")
        XCTAssertTrue(book.approve(book.pending[0].id, in: &s, now: Fx.mon(10), calendar: cal))
        let step = s.items.first { $0.parentId == essay.id }
        XCTAssertEqual(step?.estimateMinutes, 15)
        XCTAssertEqual(s.items.first { $0.id == essay.id }?.title, essay.title, "their task is untouched")
        book.submit(ReflectionRun(at: Fx.mon(9, plusDays: 1), note: "", model: "opus"),
                    [draft(.beliefGroup(BeliefGroup(id: "slump", title: "After-school slump 3–4 pm"), evidence: ["Mon", "Tue", "Thu"]))],
                    state: s, now: Fx.mon(9, plusDays: 1))
        XCTAssertTrue(book.approve(book.pending[0].id, in: &s, now: Fx.mon(10, plusDays: 1), calendar: cal))
        XCTAssertEqual(s.beliefs.groups.last?.createdBy, "reflection")
    }
}

final class KnowledgeSummaryTests: XCTestCase {
    func testBoxAndWeeklyNoteSeeBeliefsAndApprovedChanges() {
        var book = ProposalBook()
        let run = ReflectionRun(at: Fx.mon(9), note: "n", model: "opus")
        var s = DumpState(items: [], commitments: [], exceptions: [], oneOffs: [], markers: [], routines: Routine.defaults,
                          moods: [], screen: [], prefs: Preferences())
        book.submit(run, [BehaviourProposal(runId: run.id, change: .knob(key: "planner.maxBlockMinutes", to: 45), from: "55", to: "45",
                                            reason: "r", evidence: [], model: "opus", at: Fx.mon(9))], state: s, now: Fx.mon(9))
        XCTAssertEqual(book.changeSummary(now: Fx.mon(10)), "1 suggested change waiting for their approval")
        _ = book.approve(book.pending[0].id, in: &s, now: Fx.mon(10), calendar: Fx.cal)
        let line = book.changeSummary(now: Fx.mon(11))
        XCTAssertTrue(line?.hasPrefix("Changes the student approved:") == true, line ?? "nil")
        let box = Prompts.dumpContext(DumpContextInput(now: Fx.mon(12), calendar: Fx.cal, state: s, changes: line))
        XCTAssertTrue(box.contains("routines.to_school 20 min assumed") && box.contains("Changes the student approved"))
        let weekly = Prompts.context(now: Fx.mon(12), items: [], plan: .empty, summary: nil, moods: [], taper: ScreenTaper(),
                                     learned: LearnedModel(), calendar: Fx.cal, beliefs: s.beliefs.summary(routines: s.routines), changes: line)
        XCTAssertTrue(weekly.contains("What the app believes:") && weekly.contains("Changes the student approved"))
    }
}
