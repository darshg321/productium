import XCTest
@testable import ProductiumCore

/// v1.1 C1/C2: which alarms should exist, and getting the device there without duplicates or orphans.
final class AlarmTests: XCTestCase {
    let cal = Fx.cal

    func plan(now: Date, exceptions: [DayException] = [], items: [WorkItem] = [], calendar: Calendar? = nil) -> Plan {
        var input = Fx.input(now: now, items: items)
        input.exceptions = exceptions
        if let calendar { input.calendar = calendar }
        return Planner.plan(input)
    }

    func desired(_ p: Plan, now: Date, wake: Bool = true, nudges: Bool = true, calendar: Calendar? = nil) -> [PlannedAlarm] {
        var s = NudgeSettings(); s.alarms = nudges
        let input = NudgeInput(now: now, calendar: calendar ?? cal, plan: p, items: [], settings: s)
        return AlarmPlanner.desired(input, wake: wake)
    }

    func hm(_ d: Date, _ c: Calendar? = nil) -> String {
        let x = (c ?? cal).dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", x.hour!, x.minute!)
    }

    // MARK: C1: the expected list

    func testWakeAlarmsOverTwoWeeks() {
        // Replanned every evening at 20:00 for 14 days: the next wake alarm is always tomorrow's, at the right time.
        for d in 0..<14 {
            let now = Fx.mon(20, plusDays: d)
            let a = desired(plan(now: now), now: now, nudges: false)
            XCTAssertEqual(a.filter { $0.kind == .wake }.count, 3, "day \(d)")
            let next = a.first { $0.kind == .wake }!
            let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
            XCTAssertEqual(next.key, "wake.\(AlarmPlanner.dayKey(tomorrow, cal))")
            let weekday = cal.component(.weekday, from: tomorrow)
            if (2...6).contains(weekday) {
                // School 8:30, leave at 8:00 (25 min safe trip + 5), 40 min to get ready.
                XCTAssertEqual(hm(next.at), "07:20", "school day \(d)")
                XCTAssertTrue(next.title.hasPrefix("Leave by"))
            } else {
                XCTAssertEqual(hm(next.at), "08:30", "free day \(d)")
                XCTAssertEqual(next.title, "Good morning")
            }
        }
    }

    func testTodaysWakeOnlyWhileItIsAhead() {
        let early = desired(plan(now: Fx.mon(6)), now: Fx.mon(6), nudges: false)
        XCTAssertEqual(early.first?.key, "wake.2026-11-16")
        let late = desired(plan(now: Fx.mon(9)), now: Fx.mon(9), nudges: false)
        XCTAssertEqual(late.first?.key, "wake.2026-11-17")
    }

    func testDayChangeAndSleepIn() {
        let tue = Fx.mon(0, plusDays: 1)
        let sleepIn = DayException(day: tue, wake: TimeOfDay(9, 15))
        let a = desired(plan(now: Fx.mon(20), exceptions: [sleepIn]), now: Fx.mon(20), nudges: false)
        XCTAssertEqual(hm(a[0].at), "09:15")
        XCTAssertEqual(a[0].title, "Good morning")
        let cancelled = DayException(day: tue, kind: .school, cancelled: true)
        let b = desired(plan(now: Fx.mon(20), exceptions: [cancelled]), now: Fx.mon(20), nudges: false)
        XCTAssertEqual(hm(b[0].at), "08:30", "no school: the free-day wake")
        let late = DayException(day: tue, kind: .school, start: TimeOfDay(10, 0))
        let c = desired(plan(now: Fx.mon(20), exceptions: [late]), now: Fx.mon(20), nudges: false)
        XCTAssertEqual(hm(c[0].at), "08:30", "late start: capped at the free-day wake, never later")
        XCTAssertEqual(c[0].title, "Leave by 9:30 AM")
    }

    func testDaylightSavingKeepsLocalTimes() {
        // Vancouver springs forward on Sunday 14 March 2027.
        let fri = cal.date(from: DateComponents(year: 2027, month: 3, day: 12, hour: 20))!
        let a = desired(plan(now: fri), now: fri, nudges: false)
        XCTAssertEqual(a.map(\.key), ["wake.2027-03-13", "wake.2027-03-14", "wake.2027-03-15"])
        XCTAssertEqual(a.map { hm($0.at) }, ["08:30", "08:30", "07:20"])
        // Fall back, Sunday 7 November 2027.
        let fri2 = cal.date(from: DateComponents(year: 2027, month: 11, day: 5, hour: 20))!
        XCTAssertEqual(desired(plan(now: fri2), now: fri2, nudges: false).map { hm($0.at) }, ["08:30", "08:30", "07:20"])
    }

    func testTimeZoneComesFromTheAppCalendar() {
        var toronto = Calendar(identifier: .gregorian)
        toronto.timeZone = TimeZone(identifier: "America/Toronto")!
        let now = toronto.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 20))!
        let a = desired(plan(now: now, calendar: toronto), now: now, nudges: false, calendar: toronto)
        XCTAssertEqual(hm(a[0].at, toronto), "07:20")
        XCTAssertEqual(a[0].key, "wake.2026-11-17")
    }

    func testKeysAndTimesAreStableAcrossReplans() {
        let essay = WorkItem(title: "Essay", kind: .essay, due: Fx.mon(9, plusDays: 4), estimateMinutes: 240)
        let a = desired(plan(now: Fx.mon(15, 40), items: [essay]), now: Fx.mon(15, 40))
        let b = desired(plan(now: Fx.mon(15, 45), items: [essay]), now: Fx.mon(15, 45))
        XCTAssertFalse(a.isEmpty)
        let wakeBed = { (xs: [PlannedAlarm]) in xs.filter { $0.kind != .missedStart }.map { "\($0.key)@\(Int($0.at.timeIntervalSince1970))" } }
        XCTAssertEqual(wakeBed(a), wakeBed(b), "a replan five minutes later changes nothing")
        XCTAssertTrue(a.contains { $0.kind == .bedtime && $0.key == "bed.2026-11-17" })
        XCTAssertTrue(a.contains { $0.kind == .leave && $0.key == "leave.2026-11-17" })
    }

    func testTogglesAreIndependent() {
        let p = plan(now: Fx.mon(20))
        XCTAssertTrue(desired(p, now: Fx.mon(20), wake: false, nudges: false).isEmpty)
        XCTAssertTrue(desired(p, now: Fx.mon(20), wake: true, nudges: false).allSatisfy { $0.kind == .wake })
        XCTAssertTrue(desired(p, now: Fx.mon(20), wake: false, nudges: true).allSatisfy { $0.kind != .wake })
    }

    // MARK: C2: reconciling with the device

    /// A fake AlarmKit: applies diffs the way the app's scheduler does.
    struct FakeDevice {
        var alarms: [UUID: PlannedAlarm] = [:]
        var alerting: Set<UUID> = []
        var ledger: [UUID: AlarmLedgerEntry] = [:]
        var failNextAdds = 0

        var listed: [DeviceAlarm] { alarms.keys.map { DeviceAlarm(id: $0, alerting: alerting.contains($0)) } }

        mutating func sync(_ desired: [PlannedAlarm], now: Date) {
            let d = AlarmReconciler.diff(desired: desired, device: listed, ledger: ledger, now: now)
            for id in d.cancel { alarms[id] = nil }
            ledger = d.ledger
            for a in d.add {
                if failNextAdds > 0 { failNextAdds -= 1; continue }
                let id = UUID()
                alarms[id] = a
                ledger[id] = AlarmLedgerEntry(a)
            }
        }
    }

    func testRepeatedReplansLeaveExactlyTheWantedAlarms() {
        var dev = FakeDevice()
        let essay = WorkItem(title: "Essay", kind: .essay, due: Fx.mon(9, plusDays: 3), estimateMinutes: 300)
        var last: [PlannedAlarm] = []
        for k in 0..<20 {
            let now = Fx.mon(12).addingTimeInterval(Double(k) * 90)
            last = desired(plan(now: now, items: [essay]), now: now)
            dev.sync(last, now: now)
            XCTAssertEqual(Set(dev.alarms.values.map(\.key)), Set(last.map(\.key)), "replan \(k)")
            XCTAssertEqual(dev.alarms.count, last.count, "no duplicates after replan \(k)")
        }
        let now = Fx.mon(12).addingTimeInterval(19 * 90)
        let again = AlarmReconciler.diff(desired: last, device: dev.listed, ledger: dev.ledger, now: now)
        XCTAssertTrue(again.isEmpty, "a sync with nothing new does nothing")
    }

    func testOrphansAndDuplicatesAreCancelled() {
        let now = Fx.mon(20)
        let want = desired(plan(now: now), now: now)
        var dev = FakeDevice()
        dev.sync(want, now: now)
        // An alarm scheduled before the app was killed, never saved in the ledger.
        let orphan = UUID()
        dev.alarms[orphan] = want[0]
        // A duplicate the old code could leave: same key, also in the ledger.
        let dup = UUID()
        dev.alarms[dup] = want[0]
        dev.ledger[dup] = AlarmLedgerEntry(want[0])
        let d = AlarmReconciler.diff(desired: want, device: dev.listed, ledger: dev.ledger, now: now)
        XCTAssertTrue(d.cancel.contains(orphan))
        XCTAssertEqual(d.cancel.count, 2, "the orphan and one of the two duplicates")
        XCTAssertTrue(d.add.isEmpty)
    }

    func testMovedAlarmIsReplacedAndTurningOffCancelsEverything() {
        let now = Fx.mon(20)
        var dev = FakeDevice()
        dev.sync(desired(plan(now: now), now: now), now: now)
        let tue = Fx.mon(0, plusDays: 1)
        let moved = desired(plan(now: now, exceptions: [DayException(day: tue, wake: TimeOfDay(6, 0))]), now: now)
        dev.sync(moved, now: now)
        XCTAssertEqual(dev.alarms.values.filter { $0.key == "wake.2026-11-17" }.map { hm($0.at) }, ["06:00"])
        dev.sync([], now: now)
        XCTAssertTrue(dev.alarms.isEmpty, "Wake-Up Alarms off: nothing left ringing")
        XCTAssertTrue(dev.ledger.isEmpty)
    }

    func testRingingAlarmIsNeverCancelledAndFailedAddsRetry() {
        let now = Fx.mon(20)
        var dev = FakeDevice()
        let want = desired(plan(now: now), now: now)
        dev.failNextAdds = 2
        dev.sync(want, now: now)
        XCTAssertEqual(dev.alarms.count, want.count - 2)
        dev.sync(want, now: now)
        XCTAssertEqual(dev.alarms.count, want.count, "the next sync adds what failed")
        let ringing = dev.alarms.first { $0.value.kind == .wake }!.key
        dev.alerting = [ringing]
        dev.sync([], now: now)
        XCTAssertEqual(Array(dev.alarms.keys), [ringing], "only the ringing one is left")
    }
}

/// The box and the insight pass can add, move, remove and tie alarms to tasks.
final class AlarmRuleTests: XCTestCase {
    let cal = Fx.cal
    let essay = WorkItem(title: "Essay", kind: .essay, due: Fx.mon(23, plusDays: 3), estimateMinutes: 240)

    func desired(_ rules: [AlarmRule], now: Date = Fx.mon(20), wake: Bool = true, nudges: Bool = true, book: DayRuleBook = DayRuleBook()) -> [PlannedAlarm] {
        var s = NudgeSettings(); s.alarms = nudges
        let plan = Planner.plan(Fx.input(now: now, items: [essay]))
        return AlarmPlanner.desired(NudgeInput(now: now, calendar: cal, plan: plan, items: [essay], settings: s, alarmRules: rules, dayRules: book), wake: wake)
    }

    func state() -> DumpState {
        var s = DumpState(items: [essay], commitments: [Fx.school], exceptions: [], oneOffs: [], markers: [], routines: Routine.defaults,
                          moods: [], screen: [], prefs: Preferences())
        s.alarmsAllowed = true
        return s
    }
    func run(_ s: inout DumpState, _ ops: [DumpOp]) -> DumpReport {
        DumpApplier.apply(DumpResult(ops: ops, reply: ""), to: &s, now: Fx.mon(20), calendar: cal, writer: .box)
    }
    func str(_ v: String) -> JSONValue { .string(v) }

    func testTaskAlarmIsBeforeDueAndGoesWhenTheTaskIsDone() {
        let rule = AlarmRule(kind: .beforeDue, itemId: essay.id, minutes: 60)
        let a = desired([rule]).first { $0.key.hasPrefix("rule.") }
        XCTAssertEqual(a?.at, essay.due.addingTimeInterval(-3600))
        XCTAssertEqual(a?.title, "Essay is due in 1h")
        var done = essay; done.isDone = true
        var s = NudgeSettings(); s.alarms = false
        let none = AlarmPlanner.desired(NudgeInput(now: Fx.mon(20), calendar: cal, plan: .empty, items: [done], settings: s, alarmRules: [rule]), wake: false)
        XCTAssertTrue(none.isEmpty)
    }

    func testBlockAlarmsFollowTheTasksStudyBlocks() {
        let rule = AlarmRule(kind: .beforeBlocks, itemId: essay.id, minutes: 5)
        let alarms = desired([rule], wake: false, nudges: false)
        XCTAssertFalse(alarms.isEmpty)
        XCTAssertTrue(alarms.allSatisfy { $0.blockId != nil && $0.key.hasPrefix("rule.") })
    }

    func testClockAlarmWithAndWithoutADayRule() {
        let once = AlarmRule(label: "Take medicine", kind: .clock, time: TimeOfDay(21))
        XCTAssertEqual(desired([once], wake: false, nudges: false).map(\.at), [Fx.mon(21)])
        let fridays = AlarmRule(label: "Call gran", kind: .clock, time: TimeOfDay(17), when: .weekdays([6]))
        let a = desired([fridays], wake: false, nudges: false)
        XCTAssertEqual(a.count, 2, "two Fridays inside 14 days")
        XCTAssertTrue(a.allSatisfy { cal.component(.weekday, from: $0.at) == 6 && $0.title == "Call gran" })
        let off = AlarmRule(kind: .clock, time: TimeOfDay(21), enabled: false)
        XCTAssertTrue(desired([off], wake: false, nudges: false).isEmpty)
    }

    func testMoveAndRemoveTheGeneratedAlarms() {
        let base = desired([])
        let bed = base.first { $0.kind == .bedtime }!
        let earlier = desired([AlarmRule(kind: .shift, minutes: -20, target: .bedtime)])
        XCTAssertEqual(earlier.first { $0.key == bed.key }?.at, bed.at.addingTimeInterval(-20 * 60))
        let noWake = desired([AlarmRule(kind: .suppress, target: .wake)])
        XCTAssertTrue(noWake.filter { $0.kind == .wake }.isEmpty)
        XCTAssertFalse(noWake.filter { $0.kind == .bedtime }.isEmpty, "only the wake alarms go")
        // Only on Tuesdays.
        let tue = desired([AlarmRule(kind: .suppress, target: .wake, when: .weekdays([3]))]).filter { $0.kind == .wake }
        XCTAssertTrue(tue.allSatisfy { cal.component(.weekday, from: $0.at) != 3 })
        XCTAssertEqual(tue.count, base.filter { $0.kind == .wake }.count - (base.contains { $0.kind == .wake && cal.component(.weekday, from: $0.at) == 3 } ? 1 : 0))
    }

    func testBoxCreatesTaskAlarmsAndStandaloneOnes() {
        var s = state()
        let t = Ref.task(essay.id)
        var r = run(&s, [.upsert("task", id: t, ["alarm": .number(60), "blockAlarm": .number(10)])])
        XCTAssertEqual(s.alarmRules.count, 2, "\(r.problems)")
        XCTAssertTrue(r.changes.contains { $0.contains("before Essay is due") || $0.contains("before") }, "\(r.changes)")
        // A plain clock alarm tied to nothing, only on weekdays, then moved.
        r = run(&s, [.upsert("alarm", ["kind": str("clock"), "label": str("Pack bag"), "time": str("21:30"), "scope": str(#"{"weekdays":[1,2,3,4,5]}"#)])])
        XCTAssertTrue(r.problems.isEmpty, "\(r.problems)")
        let id = Ref.alarm(s.alarmRules.last!.id)
        r = run(&s, [.upsert("alarm", id: id, ["time": str("21:00")])])
        XCTAssertEqual(s.alarmRules.last?.time, TimeOfDay(21), "\(r.problems)")
        XCTAssertEqual(s.alarmRules.count, 3)
        // Remove the task's due alarm (-1), then delete the standalone one, then the task takes the rest.
        run(&s, [.upsert("task", id: t, ["alarm": .number(-1)])])
        XCTAssertEqual(s.alarmRules.filter { $0.kind == .beforeDue }.count, 0)
        run(&s, [DumpOp("delete", entity: "alarm", id: id)])
        XCTAssertEqual(s.alarmRules.count, 1)
        run(&s, [DumpOp("delete", entity: "task", id: t)])
        XCTAssertTrue(s.alarmRules.isEmpty, "a task's alarms go with it")
    }

    func testBoxMovesProductiumsOwnAlarmsAndTogglesWakeAlarms() {
        var s = state()
        var r = run(&s, [.upsert("alarm", ["kind": str("shift"), "alarmKind": str("bedtime"), "minutes": .number(-15), "scope": str(#"{"weekdays":[6]}"#)])])
        XCTAssertEqual(s.alarmRules.first?.minutes, -15, "\(r.problems)")
        r = run(&s, [.upsert("alarm", ["kind": str("off"), "alarmKind": str("leave"), "scope": str(#"{"weekdays":[4]}"#)])])
        XCTAssertEqual(s.alarmRules.count, 2, "\(r.problems)")
        r = run(&s, [.upsert("alarm", ["kind": str("shift"), "alarmKind": str("bedtime")])])
        XCTAssertFalse(r.problems.isEmpty, "a shift needs minutes")
        r = run(&s, [.set("wakeAlarms", "off")])
        XCTAssertFalse(s.prefs.wakeAlarms, "\(r.problems)")
        s.alarmsAllowed = false
        r = run(&s, [.set("wakeAlarms", "on")])
        XCTAssertFalse(s.prefs.wakeAlarms, "the box can't grant the permission: \(r.problems)")
        s.alarmsAllowed = true
        run(&s, [.set("wakeAlarms", "on"), .set("celebrations", "subtle"), .set("movementNudges", "off"), .set("scrollingApps", "Instagram:on, Slack:off")])
        XCTAssertTrue(s.prefs.wakeAlarms)
        XCTAssertEqual(s.rewardSettings.level, .subtle)
        XCTAssertFalse(s.prefs.nudges.movement)
        XCTAssertEqual(s.scrollingApps["Instagram"], true)
        XCTAssertEqual(s.scrollingApps["Slack"], false)
    }
}

final class BoxPowerTests: XCTestCase {
    let cal = Fx.cal
    func run(_ s: inout DumpState, _ ops: [DumpOp]) -> DumpReport {
        DumpApplier.apply(DumpResult(ops: ops, reply: ""), to: &s, now: Fx.mon(20), calendar: cal, writer: .box)
    }
    func testRemindersAndReviewTilesFromTheBox() {
        var s = DumpState(items: [], commitments: [], exceptions: [], oneOffs: [], markers: [], routines: [], moods: [], screen: [], prefs: Preferences())
        var r = run(&s, [.upsert("reminder", ["text": .string("Pack my bag"), "time": .string("21:00"), "weekdays": .array([.number(2), .number(3)])])])
        XCTAssertEqual(s.policy.intentions.first?.byStudent, true, "\(r.problems)")
        XCTAssertEqual(s.policy.intentions.first?.weekdays, [2, 3])
        let id = Ref.reminder(s.policy.intentions[0].id)
        r = run(&s, [.upsert("reminder", id: id, ["time": .string("20:45")])])
        XCTAssertEqual(s.policy.intentions.first?.time, TimeOfDay(20, 45))
        XCTAssertTrue(Prompts.dumpContext(DumpContextInput(now: Fx.mon(20), calendar: cal, state: s, plan: .empty, warnings: [])).contains("id \(id) \"Pack my bag\" at \(TimeOfDay(20, 45).label)"))
        run(&s, [DumpOp("delete", entity: "reminder", id: id)])
        XCTAssertTrue(s.policy.intentions.isEmpty)
        r = run(&s, [.set("metricTiles", "sleep, focus, mood, sleep")])
        XCTAssertEqual(s.metricTiles, [.sleep, .focus, .mood], "\(r.problems)")
    }
}
