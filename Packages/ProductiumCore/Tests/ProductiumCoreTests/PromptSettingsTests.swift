import XCTest
@testable import ProductiumCore

/// v1.3 Part E: one severity per kind of prompt; the planners read it.
final class PromptSettingsTests: XCTestCase {
    let cal = Fx.cal

    func testDefaultsAndWhatEachKindAllows() {
        let p = PromptSettings()
        XCTAssertEqual(p[.wake], .alarm)
        XCTAssertEqual(p[.leave], .notification)
        XCTAssertEqual(p[.untracked], .liveActivity)
        XCTAssertEqual(p[.celebrations], .quiet)
        var q = p
        q[.deadline] = .alarm
        XCTAssertEqual(q[.deadline], .alarm, "any kind can be an alarm")
        q[.deadline] = .notification
        q[.wake] = .alarm
        XCTAssertTrue(q.severity.isEmpty, "defaults aren't stored")
    }

    func testAlarmsNeedAllowingAndTheActivityFallsBack() {
        let p = PromptSettings([.bedtime: .alarm])
        XCTAssertEqual(p.effective(.bedtime, alarmsAllowed: false), .notification)
        XCTAssertTrue(p.rings(.bedtime, alarmsAllowed: true))
        XCTAssertFalse(p.rings(.bedtime, alarmsAllowed: false))
        XCTAssertFalse(p.notifies(.untracked))
        XCTAssertTrue(p.notifies(.untracked, liveActivity: false), "when the Now activity has ended")
    }

    func testPlannersReadIt() {
        let essay = WorkItem(title: "Essay", kind: .essay, due: Fx.mon(23, plusDays: 1), estimateMinutes: 120)
        let plan = Planner.plan(Fx.input(now: Fx.mon(12), items: [essay]))
        func input(_ p: PromptSettings, alarms: Bool = true) -> NudgeInput {
            NudgeInput(now: Fx.mon(12), calendar: cal, plan: plan, items: [essay], settings: NudgeSettings(), prompts: p, alarmsAllowed: alarms)
        }
        let all = NudgePlanner.plan(input(PromptSettings()))
        XCTAssertTrue(all.contains { $0.kind == .deadline })
        XCTAssertTrue(all.contains { $0.kind == .start })
        let quiet = NudgePlanner.plan(input(PromptSettings([.deadline: .off, .sessionStart: .quiet])))
        XCTAssertFalse(quiet.contains { $0.kind == .deadline || $0.kind == .start || $0.kind == .leadUp })
        XCTAssertTrue(NudgePlanner.alarms(input(PromptSettings())).isEmpty, "bedtime is a notification by default")
        let ring = PromptSettings([.bedtime: .alarm])
        XCTAssertTrue(NudgePlanner.alarms(input(ring)).contains { $0.kind == .bedtime })
        XCTAssertTrue(NudgePlanner.alarms(input(ring, alarms: false)).isEmpty, "not without alarms allowed")
        let deadline = PromptSettings([.deadline: .alarm])
        let rung = deadline.alarms(from: NudgePlanner.plan(input(deadline)), alarmsAllowed: true)
        XCTAssertTrue(rung.contains { $0.kind == .prompt && $0.title.contains("Essay") }, "a deadline set to Alarm rings")
        XCTAssertTrue(deadline.alarms(from: NudgePlanner.plan(input(deadline)), alarmsAllowed: false).isEmpty)
    }

    func testTheBoxCanChangeOne() {
        var s = DumpState(items: [], moods: [], screen: [], prefs: Preferences())
        guard case .changed = Knobs.set("prompt.deadline", "off", by: .student, in: &s) else { return XCTFail() }
        XCTAssertEqual(s.prefs.prompts[.deadline], .off)
        guard case .changed = Knobs.set("prompt.bedtime", "Alarm", by: .student, in: &s) else { return XCTFail() }
        XCTAssertEqual(s.prefs.prompts[.bedtime], .alarm)
        guard case .changed = Knobs.set("deadlineNudges", "on", by: .student, in: &s) else { return XCTFail() }
        XCTAssertEqual(s.prefs.prompts[.deadline], .notification, "the old toggles still work")
    }

    func testWakeAndSleepAreSettings() {
        var s = DumpState(items: [], moods: [], screen: [], prefs: Preferences())
        guard case .changed = Knobs.set("wake", "7:30 on school days", by: .box, in: &s) else { return XCTFail() }
        XCTAssertEqual(s.prefs.schoolDayWake, TimeOfDay(7, 30))
        XCTAssertFalse(s.prefs.autoWake)
        XCTAssertEqual(s.prefs.freeDayWake, TimeOfDay(8, 30))
        guard case .changed = Knobs.set("wake", "9am weekends", by: .box, in: &s) else { return XCTFail() }
        XCTAssertEqual(s.prefs.freeDayWake, TimeOfDay(9, 0))
        XCTAssertEqual(s.prefs.schoolDayWake, TimeOfDay(7, 30))
        guard case .changed = Knobs.set("sleep", "9.5h", by: .box, in: &s) else { return XCTFail() }
        XCTAssertEqual(s.prefs.sleepNeedMinutes, 570)
        guard case .refused = Knobs.set("wake", "soon", by: .box, in: &s) else { return XCTFail() }
    }
}
