import XCTest
@testable import ProductiumCore

/// v1.1 A4 / A6: receipts show the day-by-day difference; invariants refuse with a reason; tiers by reach.
final class PreviewTests: XCTestCase {
    let cal = Fx.cal
    func day(_ d: Int) -> Date { Fx.mon(0, plusDays: d) }

    func input(_ items: [WorkItem] = [], now: Date = Fx.mon(6)) -> PlannerInput { Fx.input(now: now, items: items) }

    func essay() -> WorkItem { WorkItem(title: "Essay", kind: .essay, due: Fx.mon(23, plusDays: 6), estimateMinutes: 360, importance: 4) }

    func testReceiptShowsTheDifference() {
        let late = Situation(said: "school starts at 10 tomorrow", scope: .on([day(1)]),
                             effects: [.replace(commitment: Fx.school.id, with: [BlockSpec(title: "Classes", start: TimeOfDay(10), end: TimeOfDay(15))])],
                             createdAt: Fx.mon(6))
        let diffs = Preview.diff(input([essay()]), adding: late)
        XCTAssertEqual(diffs.map(\.day), [day(0), day(1)], "Monday night's bedtime and Tuesday")
        XCTAssertEqual(diffs[0].lines, ["bed 10:20 → 11:30"], "a later wake keeps 9 h of sleep: bed moves too")
        let lines = diffs[1].lines
        XCTAssertTrue(lines.contains("up 7:20 → 8:30"), "\(lines)")
        XCTAssertTrue(lines.contains("School 8:30–3:00 → 10:00–3:00"), "\(lines)")
        XCTAssertTrue(lines.contains { $0.hasPrefix("To school") }, "\(lines)")
        let r = Preview.receipt(diffs, calendar: cal)
        XCTAssertEqual(r[0], "Mon 16 Nov: bed 10:20 → 11:30")
        XCTAssertTrue(r[1].hasPrefix("Tue 17 Nov: up 7:20 → 8:30 · "), r[1])

        let sick = Situation(said: "sick today", scope: .on([day(0)]), effects: [.setInput(path: "planner.capacity", value: 0), .mute(nudges: nil)])
        let s = Preview.diff(input([essay()]), adding: sick)
        XCTAssertEqual(s.first?.day, day(0))
        XCTAssertTrue(s[0].lines.contains { $0.hasPrefix("no study (was ") }, "\(s[0].lines)")
        XCTAssertTrue(s[0].lines.contains("no reminders"))
        XCTAssertTrue(s.dropFirst().allSatisfy { cal.startOfDay(for: $0.day) > day(0) }, "work moves to later days")

        let none = Situation(said: "x", scope: .on([day(40)]), effects: [.busy(start: TimeOfDay(9), end: TimeOfDay(10), title: "x")])
        XCTAssertTrue(Preview.diff(input([essay()]), adding: none).isEmpty)
    }

    func testTiers() {
        let now = Fx.mon(6)
        let sick = Situation(said: "sick", scope: .always, effects: [.setInput(path: "planner.capacity", value: 0)], expires: day(2))
        XCTAssertEqual(SituationRules.tier(sick, now: now, calendar: cal), .short)
        let trip = Situation(said: "trip", scope: .dates(from: day(3), until: day(10)), effects: [.busy(start: TimeOfDay(8), end: TimeOfDay(20), title: "Trip")])
        XCTAssertEqual(SituationRules.tier(trip, now: now, calendar: cal), .short)
        let ab = Situation(said: "B days", scope: .nthOf(sequence: "school", mod: 2, eq: 1),
                           effects: [.replace(commitment: Fx.school.id, with: [BlockSpec(title: "Art", start: TimeOfDay(9), end: TimeOfDay(15))])])
        XCTAssertEqual(SituationRules.tier(ab, now: now, calendar: cal), .facts)
        let fridays = Situation(said: "lighter Fridays", scope: .weekdays([6]), effects: [.setInput(path: "planner.capacity", value: 0.8)])
        XCTAssertEqual(SituationRules.tier(fridays, now: now, calendar: cal), .behaviour)
        let farFuture = Situation(said: "x", scope: .dates(from: day(20), until: day(25)), effects: [.mute(nudges: nil)])
        XCTAssertEqual(SituationRules.tier(farFuture, now: now, calendar: cal), .behaviour, "ends more than 14 days out")
    }

    func testShortChangesApplyOpenEndedBehaviourOnlyFromTheInsightPass() {
        let sick = Situation(said: "sick", scope: .always, effects: [.setInput(path: "planner.capacity", value: 0), .mute(nudges: nil)], expires: day(2))
        XCTAssertEqual(try SituationRules.admit(sick, into: input(), writer: .box).get(), .short)
        let fridays = Situation(said: "lighter Fridays", scope: .weekdays([6]), effects: [.setInput(path: "planner.capacity", value: 0.8)])
        guard case .failure(let r) = SituationRules.admit(fridays, into: input(), writer: .box) else { return XCTFail("box may not") }
        XCTAssertEqual(r.rule, "behaviour")
        XCTAssertEqual(try SituationRules.admit(fridays, into: input(), writer: .reflection).get(), .behaviour)
        let big = Situation(said: "x", scope: .weekdays([6]), effects: [.setInput(path: "planner.capacity", value: 0.5)])
        guard case .failure(let step) = SituationRules.admit(big, into: input(), writer: .reflection) else { return XCTFail("step") }
        XCTAssertEqual(step.rule, "step", "open-ended behaviour moves in small steps")
    }

    func testEachInvariantRefusesWithAReason() {
        func refused(_ s: Situation, _ rule: String, events: [FixedEvent] = [], ids: Set<String> = [], file: StaticString = #filePath, line: UInt = #line) {
            var i = input([essay()])
            i.events = events
            switch SituationRules.admit(s, into: i, writer: .box, calendarEventIds: ids) {
            case .success(let t): XCTFail("admitted as \(t)", file: file, line: line)
            case .failure(let r):
                XCTAssertEqual(r.rule, rule, r.reason, file: file, line: line)
                XCTAssertFalse(r.reason.isEmpty, file: file, line: line)
            }
        }
        let tue = DayRule.on([day(1)])
        refused(Situation(said: "x", scope: tue, effects: [.setInput(path: "sleepNeedMinutes", value: 420)]), "input")
        refused(Situation(said: "x", scope: tue, effects: [.setInput(path: "wake", value: 100)]), "range")
        refused(Situation(said: "x", scope: tue, effects: [.hold(item: UUID())]), "item")
        refused(Situation(said: "x", scope: tue, effects: [.replace(commitment: UUID(), with: [])]), "activity")
        refused(Situation(said: "x", scope: tue, effects: [.busy(start: TimeOfDay(11), end: TimeOfDay(10), title: "x")]), "time")
        // Swim at 4 on Wednesday: 3 h out of Tuesday night's 9 leaves 6, under the 7 h floor.
        refused(Situation(said: "swim 4-7am Wed", scope: .on([day(2)]), effects: [.busy(start: TimeOfDay(4), end: TimeOfDay(7), title: "Swim")]), "sleep")
        let ev = FixedEvent(id: "cal-1", title: "Dentist", start: Fx.mon(10, plusDays: 1), end: Fx.mon(11, plusDays: 1))
        refused(Situation(said: "free 10-12", scope: tue, effects: [.free(start: TimeOfDay(10), end: TimeOfDay(12))]), "calendar",
                events: [ev], ids: ["cal-1"])
        // A short evening event that leaves enough sleep is fine.
        XCTAssertEqual(try SituationRules.admit(Situation(said: "concert", scope: tue, effects: [.busy(start: TimeOfDay(19), end: TimeOfDay(22, 30), title: "Concert")]),
                                                into: input(), writer: .box).get(), .short)
    }
}
