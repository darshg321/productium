import XCTest
@testable import ProductiumCore

/// v1.1 D4: the insight pass's changes apply at once, within limits, and can be reverted or pinned.
final class ChangeLogTests: XCTestCase {
    let cal = Fx.cal
    let essay = WorkItem(title: "Waterloo AIF revision", kind: .application, due: Fx.mon(23, plusDays: 10))

    func state() -> DumpState {
        DumpState(items: [essay], commitments: [Fx.school], exceptions: [], oneOffs: [], markers: [], routines: Routine.defaults,
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

    func testSituationIsAdmittedStoredAndReverted() {
        var s = state()
        var log = ChangeLog()
        let sit = Situation(said: "A days run long", scope: .weekdays([2]), effects: [.setInput(path: "planner.maxBlockMinutes", value: 45)])
        // Nothing to check it against: refused. With an admit check that passes: applied; one that refuses: not.
        XCTAssertEqual(log.apply(run(), [draft(.situation(sit))], to: &s, now: Fx.mon(9)), ["Situations can't be checked here"])
        XCTAssertEqual(log.apply(run(), [draft(.situation(sit))], to: &s, now: Fx.mon(9), admitSituation: { _ in "breaks the sleep floor" }),
                       ["breaks the sleep floor"])
        XCTAssertTrue(s.situations.isEmpty)
        XCTAssertTrue(log.apply(run(), [draft(.situation(sit))], to: &s, now: Fx.mon(9), admitSituation: { _ in nil }).isEmpty)
        XCTAssertEqual(s.situations.count, 1)
        XCTAssertEqual(s.situations[0].source, .reflection)
        XCTAssertEqual(log.applied[0].title, "When it applies: A days run long")
        XCTAssertTrue(log.revert(log.applied[0].id, in: &s, now: Fx.mon(10)))
        XCTAssertTrue(s.situations.isEmpty)
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

    func testV1ProposalBookMigrates() throws {
        let applied = UUID(), rejected = UUID(), pending = UUID()
        func p(_ id: UUID, _ status: String) -> String {
            #"{"id":"\#(id)","runId":"\#(UUID())","change":{"knob":{"key":"planner.maxBlockMinutes","to":45}},"from":"55","to":"45","reason":"r","evidence":[],"model":"opus","at":"2026-11-10T12:00:00Z","status":"\#(status)","decidedAt":"2026-11-11T12:00:00Z","previous":55}"#
        }
        let json = #"{"proposals":{"proposals":[\#(p(applied, "approved")),\#(p(rejected, "rejected")),\#(p(pending, "pending")),\#(p(UUID(), "expired"))],"runs":[{"id":"\#(UUID())","at":"2026-11-10T12:00:00Z","note":"n","model":"opus"}],"pinned":["planner.capacityMultiplier"],"pausedUntil":"2026-11-20T00:00:00Z"},"reflectionAt":"2026-11-10T12:00:00Z"}"#
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let st = try dec.decode(AppState.self, from: Data(json.utf8))
        XCTAssertEqual(st.changes.changes.map(\.id), [applied, rejected])
        XCTAssertEqual(st.changes.changes.map(\.status), [.applied, .declined])
        XCTAssertEqual(st.changes.changes[0].previous, 55, "still revertable")
        XCTAssertEqual(st.changes.pinned, ["planner.capacityMultiplier"])
        XCTAssertEqual(st.changes.runs.count, 1)
        XCTAssertNotNil(st.insightAt)
        XCTAssertTrue(st.changes.feedback.first?.hasPrefix("Turned down") ?? false)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let again = try dec.decode(AppState.self, from: enc.encode(st))
        XCTAssertEqual(again.changes, st.changes, "round-trips in the new format")
    }
}

final class KnowledgeSummaryTests: XCTestCase {
    func testBoxAndWeeklyNoteSeeBeliefsAndChanges() {
        var log = ChangeLog()
        var s = DumpState(items: [], commitments: [], exceptions: [], oneOffs: [], markers: [], routines: Routine.defaults,
                          moods: [], screen: [], prefs: Preferences())
        XCTAssertNil(log.changeSummary(now: Fx.mon(10)))
        log.apply(InsightRun(at: Fx.mon(9), note: "n", model: "sonnet"),
                  [LoggedChange(runId: UUID(), change: .knob(key: "planner.maxBlockMinutes", to: 45), reason: "r", model: "sonnet", at: Fx.mon(9))],
                  to: &s, now: Fx.mon(10))
        let line = log.changeSummary(now: Fx.mon(11))
        XCTAssertTrue(line?.hasPrefix("Changes Productium made lately:") == true, line ?? "nil")
        let box = Prompts.dumpContext(DumpContextInput(now: Fx.mon(12), calendar: Fx.cal, state: s, changes: line))
        XCTAssertTrue(box.contains("routines.to_school 20 min assumed") && box.contains("Changes Productium made lately"))
        let weekly = Prompts.context(now: Fx.mon(12), items: [], plan: .empty, summary: nil, moods: [], taper: ScreenTaper(),
                                     learned: LearnedModel(), calendar: Fx.cal, beliefs: s.beliefs.summary(routines: s.routines), changes: line)
        XCTAssertTrue(weekly.contains("What the app believes:") && weekly.contains("Changes Productium made lately"))
    }
}
