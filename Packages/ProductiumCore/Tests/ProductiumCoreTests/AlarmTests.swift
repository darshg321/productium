import XCTest
@testable import ProductiumCore

/// v1.1 C1/C2, v1.2 O4: which alarms should exist, and getting the device there without duplicates or orphans.
/// The wake alarm is the planned Sleep entry's `alert` (no separate wake path).
final class AlarmTests: XCTestCase {
    let cal = Fx.cal

    /// The log after replanning at each of `times` (past plan entries stay, the future is renewed), like the app.
    func entries(replannedAt times: [Date], items: [WorkItem] = [], calendar: Calendar? = nil) -> [Entry] {
        let c = calendar ?? cal
        var es = Fx.timetable(in: c)
        for now in times {
            var input = Fx.input(now: now, items: items)
            input.calendar = c
            input.entries = es
            PlanEntries.replace(in: &es, with: PlanEntries.from(Planner.plan(input), items: items, now: now, calendar: c), now: now)
        }
        return es
    }

    func desired(at now: Date, items: [WorkItem] = [], wake: Bool = true, nudges: Bool = true, calendar: Calendar? = nil,
                 replans: [Date]? = nil) -> [PlannedAlarm] {
        let c = calendar ?? cal
        var s = NudgeSettings(); s.alarms = nudges
        var input = Fx.input(now: now, items: items)
        input.calendar = c
        let es = entries(replannedAt: replans ?? [now], items: items, calendar: c)
        input.entries = es
        let n = NudgeInput(now: now, calendar: c, plan: Planner.plan(input), items: items, settings: s)
        return AlarmPlanner.desired(n, entryAlarms: AlarmPlanner.entryAlarms(es, now: now, allowed: true, wake: wake, calendar: c))
    }

    func wakes(_ a: [PlannedAlarm]) -> [PlannedAlarm] { a.filter { $0.kind == .entry } }

    func hm(_ d: Date, _ c: Calendar? = nil) -> String {
        let x = (c ?? cal).dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", x.hour!, x.minute!)
    }

    // MARK: C1: the expected list

    func testWakeAlarmsOverTwoWeeks() {
        // Replanned every evening at 20:00 for 14 days: the next wake alarm is always tomorrow's, at the right time.
        for d in 0..<14 {
            let now = Fx.mon(20, plusDays: d)
            let a = wakes(desired(at: now, nudges: false))
            XCTAssertEqual(a.count, 3, "day \(d)")
            let next = a[0]
            let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
            XCTAssertTrue(cal.isDate(next.at, inSameDayAs: tomorrow), "day \(d)")
            XCTAssertTrue(next.key.hasPrefix("entry.") && next.key.hasSuffix(".end"))
            let weekday = cal.component(.weekday, from: tomorrow)
            if (2...6).contains(weekday) {
                // School 8:30, leave at 8:00 (25 min safe trip + 5), 40 min to get ready.
                XCTAssertEqual(hm(next.at), "07:20", "school day \(d)")
                XCTAssertEqual(next.title, "Leave by 8:00 AM")
            } else {
                XCTAssertEqual(hm(next.at), "08:30", "free day \(d)")
                XCTAssertEqual(next.title, "Good morning")
            }
        }
    }

    func testTodaysWakeOnlyWhileItIsAhead() {
        // Last night's Sleep was planned on Sunday evening and stays in the log; its alarm rings until it's past.
        let sunday = Fx.mon(20, plusDays: -1)
        let early = wakes(desired(at: Fx.mon(6), nudges: false, replans: [sunday, Fx.mon(6)]))
        XCTAssertEqual(early.first.map { hm($0.at) }, "07:20")
        XCTAssertTrue(cal.isDate(early[0].at, inSameDayAs: Fx.mon(6)))
        let late = wakes(desired(at: Fx.mon(9), nudges: false, replans: [sunday, Fx.mon(9)]))
        XCTAssertTrue(cal.isDate(late[0].at, inSameDayAs: Fx.mon(9, plusDays: 1)))
    }

    func testDaylightSavingKeepsLocalTimes() {
        // Vancouver springs forward on Sunday 14 March 2027.
        let fri = cal.date(from: DateComponents(year: 2027, month: 3, day: 12, hour: 20))!
        let a = wakes(desired(at: fri, nudges: false))
        XCTAssertEqual(a.map { AlarmPlanner.dayKey($0.at, cal) }, ["2027-03-13", "2027-03-14", "2027-03-15"])
        XCTAssertEqual(a.map { hm($0.at) }, ["08:30", "08:30", "07:20"])
        // Fall back, Sunday 7 November 2027.
        let fri2 = cal.date(from: DateComponents(year: 2027, month: 11, day: 5, hour: 20))!
        XCTAssertEqual(wakes(desired(at: fri2, nudges: false)).map { hm($0.at) }, ["08:30", "08:30", "07:20"])
    }

    func testTimeZoneComesFromTheAppCalendar() {
        var toronto = Calendar(identifier: .gregorian)
        toronto.timeZone = TimeZone(identifier: "America/Toronto")!
        let now = toronto.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 20))!
        let a = wakes(desired(at: now, nudges: false, calendar: toronto))
        XCTAssertEqual(hm(a[0].at, toronto), "07:20")
        XCTAssertEqual(AlarmPlanner.dayKey(a[0].at, toronto), "2026-11-17")
    }

    func testKeysAndTimesAreStableAcrossReplans() {
        let essay = WorkItem(title: "Essay", kind: .essay, due: Fx.mon(9, plusDays: 4), estimateMinutes: 240)
        let a = desired(at: Fx.mon(15, 40), items: [essay])
        let b = desired(at: Fx.mon(15, 45), items: [essay], replans: [Fx.mon(15, 40), Fx.mon(15, 45)])
        XCTAssertFalse(a.isEmpty)
        let wakeBed = { (xs: [PlannedAlarm]) in xs.filter { $0.kind != .missedStart }.map { "\($0.key)@\(Int($0.at.timeIntervalSince1970))" } }
        XCTAssertEqual(wakeBed(a), wakeBed(b), "a replan five minutes later changes nothing")
        XCTAssertTrue(a.contains { $0.kind == .bedtime && $0.key == "bed.2026-11-17" })
        // The leave alarm rings with the wake alarm's title now, so it's the same minute only once.
        XCTAssertTrue(a.contains { $0.kind == .leave && $0.key == "leave.2026-11-17" })
    }

    func testTogglesAreIndependent() {
        XCTAssertTrue(desired(at: Fx.mon(20), wake: false, nudges: false).isEmpty)
        XCTAssertTrue(desired(at: Fx.mon(20), wake: true, nudges: false).allSatisfy { $0.kind == .entry })
        XCTAssertTrue(desired(at: Fx.mon(20), wake: false, nudges: true).allSatisfy { $0.kind != .entry })
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
            last = desired(at: now, items: [essay])
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
        let want = desired(at: now)
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


    func testRingingAlarmIsNeverCancelledAndFailedAddsRetry() {
        let now = Fx.mon(20)
        var dev = FakeDevice()
        let want = desired(at: now)
        dev.failNextAdds = 2
        dev.sync(want, now: now)
        XCTAssertEqual(dev.alarms.count, want.count - 2)
        dev.sync(want, now: now)
        XCTAssertEqual(dev.alarms.count, want.count, "the next sync adds what failed")
        let ringing = dev.alarms.first { $0.value.kind == .entry }!.key
        dev.alerting = [ringing]
        dev.sync([], now: now)
        XCTAssertEqual(Array(dev.alarms.keys), [ringing], "only the ringing one is left")
    }
}

/// v1.2 J: alarms on entries ring only once approved; the insight pass only proposes them.
final class EntryAlarmTests: XCTestCase {
    let cal = Fx.cal

    func medicine(approved: Bool) -> Entry {
        Entry(title: "Take medicine", start: Fx.mon(21), end: Fx.mon(21), category: CategoryTree.other,
              repeats: .weekly([1, 2, 3, 4, 5, 6, 7]), alert: Alert(.alarm, approved: approved), source: .you)
    }

    func testApprovedEntryAlarmsRingDailyUnapprovedOnesDont() {
        let a = AlarmPlanner.entryAlarms([medicine(approved: true)], now: Fx.mon(20), allowed: true, wake: true, calendar: cal)
        XCTAssertEqual(a.map(\.at), [Fx.mon(21), Fx.mon(21, plusDays: 1), Fx.mon(21, plusDays: 2)])
        XCTAssertTrue(a.allSatisfy { $0.title == "Take medicine" })
        XCTAssertTrue(AlarmPlanner.entryAlarms([medicine(approved: false)], now: Fx.mon(20), allowed: true, wake: true, calendar: cal).isEmpty)
        XCTAssertTrue(AlarmPlanner.entryAlarms([medicine(approved: true)], now: Fx.mon(20), allowed: false, wake: true, calendar: cal).isEmpty,
                      "Full-Screen Alarms off: none")
    }

    func testSkippingOneDayRemovesThatAlarmOnly() {
        var e = medicine(approved: true)
        e.marks["2026-11-17"] = .skipped
        let a = AlarmPlanner.entryAlarms([e], now: Fx.mon(20), allowed: true, wake: true, calendar: cal)
        XCTAssertEqual(a.map(\.at), [Fx.mon(21), Fx.mon(21, plusDays: 2)])
    }

    func testBoxAlarmIsHeldThenApprovedRings() {
        var s = BoxState()
        let op = BoxOp(.entry, .add, BoxFields(title: "Wake up", start: "06:40", end: "06:40", day: "2026-11-17", alert: "alarm"))
        let r = BoxApplier.apply([op], to: &s, now: Fx.mon(20), calendar: cal)
        XCTAssertEqual(r.held.count, 1)
        XCTAssertTrue(s.entries.isEmpty)
        let ok = BoxApplier.apply(r.held.map(\.op), to: &s, now: Fx.mon(20), calendar: cal, approved: true)
        XCTAssertTrue(ok.problems.isEmpty, "\(ok.problems)")
        let a = AlarmPlanner.entryAlarms(s.entries, now: Fx.mon(20), allowed: true, wake: true, calendar: cal)
        XCTAssertEqual(a.map(\.at), [Fx.mon(6, 40, plusDays: 1)])
        XCTAssertEqual(TimeLog.past(s.entries, in: Days.dayInterval(Fx.mon(0, plusDays: 1), cal), now: Fx.mon(8, plusDays: 1), calendar: cal)
            .filter { $0.entry != nil }.count, 0, "a moment counts no time")
    }

    func testInsightPassProposesAlarmsInsteadOfAddingThem() {
        let essay = WorkItem(title: "Essay", kind: .essay, due: Fx.mon(23, plusDays: 3), estimateMinutes: 240)
        let out = InsightPass.Output(headline: "Week", wins: [], suggestions: [], changes: [
            .init(type: "alarm", time: "16:55", alarm_kind: "clock", label: "Reading at 5", scope: #"{"weekdays":[2,3,4,5,6]}"#, reason: "Missed 4 of 5"),
            .init(type: "alarm", task: Ref.task(essay.id), minutes: 60, alarm_kind: "before_due", reason: "Due tonight"),
        ])
        let p = InsightPass.proposals(out, items: [essay], now: Fx.mon(20), calendar: cal)
        XCTAssertEqual(p.count, 1, "one a run")
        XCTAssertEqual(p[0].source, .insight)
        XCTAssertTrue(p[0].addsAlarm)
        XCTAssertEqual(p[0].ops[0].fields.start, "2026-11-17 16:55", "16:55 has passed today, so tomorrow")
        XCTAssertTrue(InsightPass.drafts(out, runId: UUID(), items: [essay], now: Fx.mon(20), model: "m", calendar: cal).isEmpty,
                      "never applied as a change")
        var s = BoxState()
        let r = BoxApplier.apply(p[0].ops, to: &s, now: Fx.mon(20), calendar: cal, approved: true)
        XCTAssertTrue(r.problems.isEmpty, "\(r.problems)")
        XCTAssertEqual(s.entries.first?.repeats?.days, .weekdays([2, 3, 4, 5, 6]))
    }
}

final class EntryAlarmWiringTests: XCTestCase {
    func testEntryAlarmsJoinTheWantedListOnce() {
        let cal = Fx.cal
        let sleep = Entry(title: "Sleep", start: Fx.mon(23), end: Fx.mon(7, plusDays: 1), category: CategoryTree.sleep,
                          alert: .wake, source: .plan)
        let occ = Days.expand([sleep], in: DateInterval(start: Fx.mon(12), duration: 3 * 86400), now: Fx.mon(12), calendar: cal)
        let entryAlarms = EntryAlerts.alarms(occ, now: Fx.mon(12), allowed: true)
        XCTAssertEqual(entryAlarms.count, 1)
        let input = NudgeInput(now: Fx.mon(12), calendar: cal, plan: .empty, items: [], settings: NudgeSettings())
        let wanted = AlarmPlanner.desired(input, entryAlarms: entryAlarms)
        XCTAssertEqual(wanted.map(\.at), [Fx.mon(7, plusDays: 1)])
        XCTAssertEqual(AlarmPlanner.desired(input, entryAlarms: []).count, 0)
        XCTAssertTrue(EntryAlerts.alarms(occ, now: Fx.mon(12), allowed: false).isEmpty)
    }
}
