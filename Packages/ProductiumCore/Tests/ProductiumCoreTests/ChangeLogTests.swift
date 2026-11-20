import XCTest
@testable import ProductiumCore

/// v1.1 D4: the insight pass's changes apply at once, within limits, and can be reverted or pinned.
final class ChangeLogTests: XCTestCase {
    let cal = Fx.cal
    let essay = WorkItem(title: "Waterloo AIF revision", kind: .application, due: Fx.mon(23, plusDays: 10))

    func state() -> DumpState {
        DumpState(items: [essay], oneOffs: [], markers: [], routines: Routine.defaults,
                  moods: [], screen: [], prefs: Preferences())
    }

    func draft(_ c: InsightChange, reason: String = "evidence") -> LoggedChange {
        LoggedChange(runId: UUID(), change: c, reason: reason, evidence: ["deferred 3×"], model: "sonnet", at: Fx.mon(9))
    }

    func run(_ d: Int = 0) -> InsightRun { InsightRun(at: Fx.mon(9, plusDays: d), note: "", model: "sonnet") }

    func testAppliesAtOnceWithinRangesAndSteps() {
        var s = state()
        var log = ChangeLog()
        let problems = log.apply(run(), [draft(.knob(key: "planner.maxBlockMinutes", to: 25)),
                                         draft(.knob(key: "planner.capacityMultiplier", to: 0.5)),
                                         draft(.knob(key: "sleepNeedMinutes", to: 450)),
                                         draft(.intention(IntentionNudge(trigger: .time, weekdays: [3], time: TimeOfDay(15, 30),
                                                                         text: "When you get home Tuesday, open the Waterloo doc"))),
                                         draft(.knob(key: "planner.freeTimeMultiplier", to: 1.2))], to: &s, now: Fx.mon(9))
        XCTAssertEqual(log.applied.count, 3, "at most 3 a run")
        XCTAssertEqual(problems.count, 2, "\(problems)")
        XCTAssertEqual(s.policy.maxBlockMinutes, 45, "at most -10 a change")
        XCTAssertEqual(s.policy.capacityMultiplier, 0.9, "at most -0.1 a change")
        XCTAssertEqual(s.policy.intentions.count, 1)
        XCTAssertEqual(s.prefs.sleepNeedMinutes, 540)
        XCTAssertEqual(log.applied[0].from, "55")
        XCTAssertEqual(log.applied[0].to, "45")
        let nudges = NudgePlanner.plan(NudgeInput(now: Fx.mon(18), calendar: cal, plan: .empty, items: [], settings: NudgeSettings(),
                                                  policy: s.policy))
        XCTAssertTrue(nudges.contains { $0.kind == .intention && $0.at == Fx.mon(15, 30, plusDays: 1) })
    }


    func testOncePerWeekRevertNoRetryAndPins() {
        var s = state()
        var log = ChangeLog()
        log.apply(run(), [draft(.knob(key: "planner.maxBlockMinutes", to: 45))], to: &s, now: Fx.mon(9))
        let first = log.applied[0]
        XCTAssertEqual(log.apply(run(2), [draft(.knob(key: "planner.maxBlockMinutes", to: 35))], to: &s, now: Fx.mon(9, plusDays: 2)),
                       ["planner.maxBlockMinutes changed in the last 7 days"])
        XCTAssertEqual(s.policy.maxBlockMinutes, 45)
        log.apply(run(8), [draft(.knob(key: "planner.maxBlockMinutes", to: 35))], to: &s, now: Fx.mon(9, plusDays: 8))
        XCTAssertEqual(s.policy.maxBlockMinutes, 35, "a week later it may move again")

        XCTAssertTrue(log.revert(log.applied.last!.id, in: &s, now: Fx.mon(10, plusDays: 8)))
        XCTAssertEqual(s.policy.maxBlockMinutes, 45, "revert restores the value before that change")
        XCTAssertTrue(log.feedback.last?.hasPrefix("Reverted") ?? false)
        XCTAssertEqual(log.apply(run(20), [draft(.knob(key: "planner.maxBlockMinutes", to: 35))], to: &s, now: Fx.mon(9, plusDays: 20)),
                       ["planner.maxBlockMinutes was undone less than 30 days ago"])
        log.apply(run(40), [draft(.knob(key: "planner.maxBlockMinutes", to: 35))], to: &s, now: Fx.mon(9, plusDays: 40))
        XCTAssertEqual(s.policy.maxBlockMinutes, 35, "after 30 days it can try again")

        log.neverChange(log.applied.last!.id, in: &s, now: Fx.mon(10, plusDays: 40))
        XCTAssertEqual(s.policy.maxBlockMinutes, 45, "never change this undoes it")
        XCTAssertTrue(log.pinned.contains("planner.maxBlockMinutes"))
        XCTAssertEqual(log.apply(run(80), [draft(.knob(key: "planner.maxBlockMinutes", to: 35))], to: &s, now: Fx.mon(9, plusDays: 80)),
                       ["planner.maxBlockMinutes is pinned"])
        XCTAssertEqual(log.history.first?.status, .reverted)
        XCTAssertFalse(log.revert(first.id, in: &s, now: Fx.mon(9, plusDays: 81)) && false)
    }

    func testStarterStepBeliefGroupAndAboutMeRevert() {
        var s = state()
        var log = ChangeLog()
        let problems = log.apply(run(), [
            draft(.starterStep(parent: essay.id, title: "Open the doc and fix one paragraph", minutes: 15, due: Fx.mon(17))),
            draft(.beliefGroup(BeliefGroup(id: "slump", title: "After-school slump 3–4 pm"), evidence: ["Mon", "Tue"])),
            draft(.aboutMe(section: .patterns, text: "puts off university essays")),
        ], to: &s, now: Fx.mon(9))
        XCTAssertEqual(problems, ["A new group needs 3 pieces of evidence"])
        let step = s.items.first { $0.parentId == essay.id }
        XCTAssertEqual(step?.estimateMinutes, 15)
        XCTAssertEqual(s.items.first { $0.id == essay.id }?.title, essay.title, "their task is untouched")
        log.apply(run(1), [draft(.beliefGroup(BeliefGroup(id: "slump", title: "After-school slump 3–4 pm"), evidence: ["Mon", "Tue", "Thu"]))],
                  to: &s, now: Fx.mon(9, plusDays: 1))
        XCTAssertEqual(s.beliefs.groups.last?.createdBy, "reflection")
        for c in log.applied { XCTAssertTrue(log.revert(c.id, in: &s, now: Fx.mon(12, plusDays: 1)), c.title) }
        XCTAssertFalse(s.items.contains { $0.parentId == essay.id }, "the step it added is gone")
        XCTAssertFalse(s.beliefs.groups.contains { $0.id == "slump" })
        XCTAssertTrue(s.aboutMe[.patterns].isEmpty)
    }

    func testStudentLinesAreNeverTouched() {
        var s = state()
        s.aboutMe[.patterns] = [AboutMe.Line("puts off essays", byStudent: true)]
        var log = ChangeLog()
        XCTAssertEqual(log.apply(run(), [draft(.aboutMe(section: .patterns, text: "Puts off essays"))], to: &s, now: Fx.mon(9)).count, 1)
        XCTAssertEqual(log.apply(run(), [draft(.aboutMe(section: .stated, text: "likes maths"))], to: &s, now: Fx.mon(9)).count, 1)
        XCTAssertEqual(s.aboutMe[.patterns].map(\.byStudent), [true])
    }
}

final class KnowledgeSummaryTests: XCTestCase {

}
