import XCTest
@testable import ProductiumCore

/// v1.1 A3: situations override the planner's inputs over any days; every row of the plan's A.2 table.
final class SituationTests: XCTestCase {
    let cal = Fx.cal
    func day(_ d: Int) -> Date { Fx.mon(0, plusDays: d) }   // Monday 16 Nov 2026

    func plan(now: Date = Fx.mon(6), items: [WorkItem] = [], situations: [Situation], book: DayRuleBook = DayRuleBook(),
              exceptions: [DayException] = [], horizon: Int = 14) -> Plan {
        var input = Fx.input(now: now, items: items, horizon: horizon)
        input.exceptions = exceptions
        input.situations = situations
        input.dayRules = book
        return Planner.plan(input)
    }

    func blocks(_ p: Plan, _ d: Int, _ kind: BlockKind? = nil) -> [PlannedBlock] {
        p.blocks(on: day(d), calendar: cal).filter { kind == nil || $0.kind == kind }
    }

    func hm(_ d: Date) -> String {
        let c = cal.dateComponents([.hour, .minute], from: d)
        return String(format: "%d:%02d", c.hour!, c.minute!)
    }

    func bigEssay(_ due: Int = 13) -> WorkItem {
        WorkItem(title: "Essay", kind: .essay, due: Fx.mon(23, plusDays: due), estimateMinutes: 900, importance: 4)
    }

    func testABTimetable() {
        var book = DayRuleBook()
        book.sequences = [DaySequence(name: "school", rule: .all([.weekdays([2, 3, 4, 5, 6]), .not(.label("no-school"))]), anchor: day(0))]
        let a = [BlockSpec(title: "Math", start: TimeOfDay(8, 30), end: TimeOfDay(10)), BlockSpec(title: "Lunch", start: TimeOfDay(11, 30), end: TimeOfDay(12, 15)),
                 BlockSpec(title: "Bio", start: TimeOfDay(12, 15), end: TimeOfDay(14, 0))]
        let b = [BlockSpec(title: "English", start: TimeOfDay(9, 15), end: TimeOfDay(11)), BlockSpec(title: "Lunch", start: TimeOfDay(12, 30), end: TimeOfDay(13)),
                 BlockSpec(title: "Art", start: TimeOfDay(13), end: TimeOfDay(15, 30))]
        let sits = [Situation(said: "A days: Math, Bio, out at 2", scope: .nthOf(sequence: "school", mod: 2, eq: 0),
                              effects: [.replace(commitment: Fx.school.id, with: a)], createdAt: Fx.mon(0)),
                    Situation(said: "B days start 9:15, out 3:30", scope: .nthOf(sequence: "school", mod: 2, eq: 1),
                              effects: [.replace(commitment: Fx.school.id, with: b)], createdAt: Fx.mon(0))]
        let p = plan(situations: sits, book: book)
        func school(_ d: Int) -> String {
            let s = blocks(p, d, .commitment).first { $0.title == "School" }!
            return "\(hm(s.start))-\(hm(s.end))"
        }
        XCTAssertEqual((0..<5).map(school), ["8:30-14:00", "9:15-15:30", "8:30-14:00", "9:15-15:30", "8:30-14:00"])
        XCTAssertEqual(school(7), "9:15-15:30", "Monday 23rd is the 6th school day: B")
        XCTAssertEqual(hm(p.wakePlans.first { cal.isDate($0.day, inSameDayAs: day(1)) }!.wake), "8:05", "a later start lets you sleep in")
        // An errand at school uses that day's lunch.
        let ask = WorkItem(title: "Ask Ms Lee about the lab", kind: .chore, due: Fx.mon(23, plusDays: 1), estimateMinutes: 5)
        let p2 = plan(items: [ask], situations: sits, book: book)
        XCTAssertEqual(p2.blocks.first { $0.itemId == ask.id }.map { hm($0.start) }, "11:30", "Monday is an A day: A lunch")
        // Tuesday cancelled (a day change, which also labels it no-school): the rotation after it shifts by itself.
        book.label("no-school", [day(1)], calendar: cal)
        let p3 = plan(situations: sits, book: book, exceptions: [DayException(day: day(1), kind: .school, cancelled: true)])
        XCTAssertTrue(blocks(p3, 1, .commitment).filter { $0.title == "School" }.isEmpty)
        let wed = blocks(p3, 2, .commitment).first { $0.title == "School" }!
        XCTAssertEqual(hm(wed.end), "15:30", "Wednesday became the B day")
    }

    func testSickForThreeDays() {
        let sick = Situation(said: "I'm sick, staying home till Wednesday", scope: .dates(from: day(0), until: nil),
                             effects: [.mute(nudges: nil), .setInput(path: "planner.capacity", value: 0)], expires: day(2), createdAt: Fx.mon(6))
        let p = plan(items: [bigEssay()], situations: [sick])
        for d in 0...2 { XCTAssertTrue(blocks(p, d).filter(\.isStudy).isEmpty, "no study on sick day \(d)") }
        XCTAssertFalse(blocks(p, 3).filter(\.isStudy).isEmpty, "back to normal Thursday")
        XCTAssertEqual(p.mutes?.map { cal.startOfDay(for: $0.day) }, [day(0), day(1), day(2)])
        let n = NudgePlanner.plan(NudgeInput(now: Fx.mon(6), calendar: cal, plan: p, items: [bigEssay()], settings: NudgeSettings()))
        XCTAssertTrue(n.allSatisfy { !cal.isDate($0.at, inSameDayAs: day(0)) && !cal.isDate($0.at, inSameDayAs: day(1)) },
                      "no reminders while sick")
        var s = NudgeSettings(); s.alarms = true
        XCTAssertTrue(NudgePlanner.alarms(NudgeInput(now: Fx.mon(6), calendar: cal, plan: p, items: [], settings: s)).isEmpty)
    }

    func testGrandmaVisiting() {
        let visit = Situation(said: "Grandma's here this weekend, out with her 10 to 6", scope: .weekdays([1, 7]),
                              effects: [.busy(start: TimeOfDay(10), end: TimeOfDay(18), title: "Grandma"),
                                        .setInput(path: "planner.freeTimeMultiplier", value: 1.3)],
                              expires: day(6), createdAt: Fx.mon(6))
        let p = plan(items: [bigEssay()], situations: [visit])
        for d in [5, 6] {
            let g = blocks(p, d, .event).filter { $0.title == "Grandma" }
            XCTAssertEqual(g.map { "\(hm($0.start))-\(hm($0.end))" }, ["10:00-18:00"])
            XCTAssertTrue(blocks(p, d).filter { $0.isStudy && $0.end > Fx.mon(10, plusDays: d) && $0.start < Fx.mon(18, plusDays: d) }.isEmpty)
        }
        XCTAssertTrue(blocks(p, 12, .event).filter { $0.title == "Grandma" }.isEmpty, "expired by the next weekend")
    }

    func testAnkleSprainShortensTheCommuteForAWeek() {
        let ankle = Situation(said: "sprained my ankle, mom's driving me this week", scope: .dates(from: day(0), until: nil),
                              effects: [.setInput(path: "routines.to_school.minutes", value: 10)], expires: day(6), createdAt: Fx.mon(6))
        let p = plan(now: Fx.mon(5), situations: [ankle])
        let wake = { (d: Int) in self.hm(p.wakePlans.first { self.cal.isDate($0.day, inSameDayAs: self.day(d)) }!.wake) }
        XCTAssertEqual(wake(1), "7:30", "13 min safe drive + 5, 40 to get ready")
        XCTAssertEqual(wake(7), "7:20", "back to the 25-min trip")
        let toSchool = blocks(p, 1, .routine).first { $0.title == "To school" }!
        XCTAssertEqual(Int(toSchool.end.timeIntervalSince(toSchool.start) / 60), 10)
    }

    func testExamWeekShortBlocks() {
        var book = DayRuleBook()
        book.label("exam-week", (7...11).map(day), calendar: cal)
        let exam = Situation(said: "exam week next week, keep sessions short", scope: .label("exam-week"),
                             effects: [.setInput(path: "planner.maxBlockMinutes", value: 45)], createdAt: Fx.mon(6))
        let p = plan(items: [bigEssay()], situations: [exam], book: book)
        let inExam = (7...11).flatMap { blocks(p, $0).filter(\.isStudy) }
        XCTAssertFalse(inExam.isEmpty)
        XCTAssertTrue(inExam.allSatisfy { $0.minutes <= 45 }, inExam.map(\.minutes).description)
        XCTAssertTrue((0...4).flatMap { blocks(p, $0).filter(\.isStudy) }.contains { $0.minutes > 45 }, "other weeks keep longer blocks")
    }

    func testFreePeriodOpensSchoolTime() {
        let spare = Situation(said: "Wednesday 10-11 is a spare now", scope: .weekdays([4]),
                              effects: [.free(start: TimeOfDay(10), end: TimeOfDay(11))], createdAt: Fx.mon(6))
        let p = plan(items: [bigEssay(3)], situations: [spare])
        let school = blocks(p, 2, .commitment).filter { $0.title == "School" }.map { "\(hm($0.start))-\(hm($0.end))" }
        XCTAssertEqual(school, ["8:30-10:00", "11:00-15:00"])
        XCTAssertTrue(blocks(p, 2).contains { $0.isStudy && $0.start >= Fx.mon(9, 50, plusDays: 2) && $0.end <= Fx.mon(11, plusDays: 2) },
                      "the spare gets used for the essay due in 3 days")
    }

    func testHoldAndBoost() {
        let essay = bigEssay()
        let p0 = plan(items: [essay], situations: [])
        XCTAssertFalse(blocks(p0, 1).filter { $0.itemId == essay.id }.isEmpty)
        let hold = Situation(said: "not touching the essay Tuesday", scope: .on([day(1)]), effects: [.hold(item: essay.id)], createdAt: Fx.mon(6))
        XCTAssertTrue(blocks(plan(items: [essay], situations: [hold]), 1).filter { $0.itemId == essay.id }.isEmpty)
        let other = WorkItem(title: "Reading", kind: .reading, due: Fx.mon(23, plusDays: 6), estimateMinutes: 120, importance: 2)
        let boost = Situation(said: "do the reading first on Wednesday", scope: .on([day(2)]), effects: [.boost(item: other.id)], createdAt: Fx.mon(6))
        let p = plan(items: [essay, other], situations: [boost])
        let wed = blocks(p, 2).filter(\.isStudy).sorted { $0.start < $1.start }
        XCTAssertEqual(wed.first?.itemId, other.id, "boosted: it's Wednesday's first block")
    }

    func testNoMatchingDaysChangesNothing() {
        let items = [bigEssay(), WorkItem(title: "Quiz", kind: .quiz, due: Fx.mon(9, plusDays: 4))]
        let none = Situation(said: "nothing", scope: .on([day(60)]), effects: [.setInput(path: "planner.capacity", value: 0),
                                                                                 .busy(start: TimeOfDay(16), end: TimeOfDay(20), title: "x")])
        let expired = Situation(said: "old", scope: .weekdays([1, 2, 3, 4, 5, 6, 7]), effects: [.setInput(path: "planner.capacity", value: 0)],
                                expires: day(-1))
        let a = plan(items: items, situations: []), b = plan(items: items, situations: [none, expired])
        // Free and gap blocks get fresh ids every run, so compare what they are, not their ids.
        let shape = { (p: Plan) in p.blocks.map { "\($0.kind) \($0.start) \($0.end) \($0.title) \($0.itemId?.uuidString ?? "")" } }
        XCTAssertEqual(shape(a), shape(b))
        XCTAssertNil(a.mutes, "no situations: plans look exactly as before")
        XCTAssertEqual(a.wakePlans, b.wakePlans)
    }

    func testInputsAreRangedAndLaterSituationsWin() {
        let r = SituationResolver(situations: [
            Situation(said: "second", scope: .always, effects: [.setInput(path: "wake", value: 480)], createdAt: Fx.mon(8)),
            Situation(said: "first", scope: .always, effects: [.setInput(path: "wake", value: 400), .setInput(path: "planner.capacity", value: 9),
                                                              .setInput(path: "made.up", value: 1), .note("phone goes at 10")], createdAt: Fx.mon(7)),
        ], calendar: cal)
        let o = r.day(day(0))
        XCTAssertEqual(o.input("wake"), 480)
        XCTAssertEqual(o.inputBy["wake"], "second")
        XCTAssertEqual(o.input("planner.capacity"), 2, "clamped to the range")
        XCTAssertNil(o.input("made.up"), "only registered inputs")
        XCTAssertEqual(r.activeNotes(from: Fx.mon(9)), ["phone goes at 10 (every day)"])
    }

    func testCodableRoundTrip() throws {
        let s = Situation(said: "B days", scope: .nthOf(sequence: "school", mod: 2, eq: 1),
                          effects: [.replace(commitment: Fx.school.id, with: [BlockSpec(title: "Art", start: TimeOfDay(13), end: TimeOfDay(15, 30))]),
                                    .busy(start: TimeOfDay(9), end: TimeOfDay(10), title: "Dentist"), .free(start: TimeOfDay(10), end: TimeOfDay(11)),
                                    .setInput(path: "wake", value: 450), .hold(item: Fx.school.id), .boost(item: Fx.soccer.id),
                                    .mute(nudges: nil), .mute(nudges: .bedtime), .note("x")],
                          expires: day(3), createdAt: Fx.mon(6))
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = .sortedKeys
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let data = try enc.encode(s)
        XCTAssertEqual(try dec.decode(Situation.self, from: data), s)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(#"{"busy":{"end":"10:00","start":"9:00","title":"Dentist"}}"#))
        let fromAI = #"{"busy":{"start":"14:30","end":"4pm"}}"#
        XCTAssertEqual(try dec.decode(Effect.self, from: Data(fromAI.utf8)), .busy(start: TimeOfDay(14, 30), end: TimeOfDay(16), title: "Busy"))
    }

    // A2: an activity or period can carry its own rule; a cancelled school day moves the rotation by itself.
    func testPeriodsWithRulesGiveAandBTimetables() {
        let seq = DaySequence(name: "school", rule: .weekdays([2, 3, 4, 5, 6]), anchor: day(0))
        var book = DayRuleBook(sequences: [seq])
        var school = Fx.school
        school.periods = [ActivityPeriod(title: "A: Math", start: TimeOfDay(8, 30), end: TimeOfDay(12), when: .nthOf(sequence: "school", mod: 2, eq: 0)),
                          ActivityPeriod(title: "B: Art", start: TimeOfDay(8, 30), end: TimeOfDay(12), when: .nthOf(sequence: "school", mod: 2, eq: 1))]
        let r = SituationResolver(situations: [], book: book, calendar: cal)
        XCTAssertEqual(r.commitments([school], on: day(0))[0].periods?.map(\.title), ["A: Math"])
        XCTAssertEqual(r.commitments([school], on: day(1))[0].periods?.map(\.title), ["B: Art"])
        // Wednesday is cancelled: Thursday becomes the A day.
        let ex = [DayException(day: day(2), kind: .school, cancelled: true)]
        book.syncNoSchool(exceptions: ex, commitments: [school], calendar: cal)
        XCTAssertEqual(book.labels["no-school"], [CapacityLearner.dayKey(day(2), cal)])
        book.sequences = [DaySequence(name: "school", rule: .all([.weekdays([2, 3, 4, 5, 6]), .not(.label("no-school"))]), anchor: day(0))]
        let r2 = SituationResolver(situations: [], book: book, calendar: cal)
        XCTAssertEqual(r2.commitments([school], on: day(3))[0].periods?.map(\.title), ["A: Math"])
    }

    func testActivityWithARuleOnlyRunsThoseDays() {
        let seq = DaySequence(name: "school", rule: .weekdays([2, 3, 4, 5, 6]), anchor: day(0))
        var club = Commitment(title: "Odd club", kind: .extracurricular, weekdays: [2, 3, 4, 5, 6], start: TimeOfDay(16), end: TimeOfDay(17),
                              when: .nthOf(sequence: "school", mod: 2, eq: 1))
        club.bufferMinutes = 0
        let r = SituationResolver(situations: [], book: DayRuleBook(sequences: [seq]), calendar: cal)
        XCTAssertTrue(r.commitments([club], on: day(0)).isEmpty)
        XCTAssertEqual(r.commitments([club], on: day(1)).count, 1)
        // And it survives a save / load.
        let back = try! JSONDecoder().decode(Commitment.self, from: JSONEncoder().encode(club))
        XCTAssertEqual(back.when, club.when)
        let old = try! JSONDecoder().decode(Commitment.self, from: JSONEncoder().encode(Fx.school))
        XCTAssertNil(old.when)
    }

    func testTimelineShowsSituationBusyTime() {
        let sit = Situation(said: "dentist", scope: .on([day(1)]), effects: [.busy(start: TimeOfDay(17), end: TimeOfDay(18), title: "Dentist")])
        let inputs = DayInputs(day: day(1), events: [], commitments: [], routines: [], outcomes: [], health: nil, screen: nil,
                               prefs: Preferences(), situations: [sit])
        let segs = TimelineBuilder.segments(inputs, calendar: cal)
        XCTAssertTrue(segs.contains { $0.label == "Dentist" && $0.minutes == 60 })
    }
}

/// v1.1 A5: the box writes situations, day rules and gaps through the Registry; `admit` still decides.
final class SituationBoxTests: XCTestCase {
    let cal = Fx.cal
    func state() -> DumpState {
        DumpState(items: [], commitments: [Fx.school], exceptions: [], oneOffs: [], markers: [], routines: Routine.defaults,
                  moods: [], screen: [], prefs: Preferences())
    }
    func run(_ s: inout DumpState, _ ops: [DumpOp], writer: Writer = .box) -> DumpReport {
        DumpApplier.apply(DumpResult(ops: ops, reply: ""), to: &s, now: Fx.mon(9), calendar: cal, writer: writer)
    }
    func str(_ v: String) -> JSONValue { .string(v) }

    func testABTimetableFromTheBox() {
        var s = state()
        let id = Ref.activity(Fx.school.id)
        var r = run(&s, [.upsert("day_rule", ["name": str("school"), "kind": str("sequence"), "anchor": str("2026-11-16"),
                                              "rule": str(#"{"all":[{"weekdays":[2,3,4,5,6]},{"not":{"label":"no-school"}}]}"#)])])
        XCTAssertTrue(r.problems.isEmpty, "\(r.problems)")
        XCTAssertEqual(s.dayRules.sequences.count, 1)
        r = run(&s, [.upsert("situation", ["said": str("B days start at 10"),
                                           "scope": str(#"{"nthOf":{"sequence":"school","mod":2,"eq":1}}"#),
                                           "effects": .array([str(#"{"replace":{"commitment":"\#(id)","with":[{"title":"Art","start":"10:00","end":"15:00"}]}}"#)])])])
        XCTAssertTrue(r.problems.isEmpty, "\(r.problems)")
        XCTAssertEqual(s.situations.count, 1)
        XCTAssertTrue(r.changes.contains { $0.hasPrefix("Added: B days start at 10") }, "\(r.changes)")
        XCTAssertTrue(r.changes.contains { $0.contains("School 8:30–3:00 → 10:00–3:00") }, "\(r.changes)")
        // Deleting by ref removes it.
        r = run(&s, [DumpOp("delete", entity: "situation", id: Ref.situation(s.situations[0].id))])
        XCTAssertTrue(s.situations.isEmpty, "\(r.problems)")
    }

    func testSickWeekNeedsAnExpiryAndBehaviourFromTheBoxIsRefused() {
        var s = state()
        let sick = ["said": str("sick till Wednesday"), "scope": str(#"{"dates":{"from":"2026-11-16","until":"2026-11-18"}}"#),
                    "effects": .array([str(#"{"setInput":{"path":"planner.capacity","value":0}}"#), str(#"{"mute":"all"}"#)]),
                    "expires": str("2026-11-18")]
        var r = run(&s, [.upsert("situation", sick)])
        XCTAssertTrue(r.problems.isEmpty, "\(r.problems)")
        XCTAssertEqual(s.situations.count, 1)
        // Open-ended: nothing bounds it, so it is a behaviour change and the box may not make it.
        r = run(&s, [.upsert("situation", ["said": str("always lighter"), "scope": str(#"{"weekdays":[6]}"#),
                                           "effects": .array([str(#"{"setInput":{"path":"planner.capacity","value":0.8}}"#)])])])
        XCTAssertEqual(s.situations.count, 1)
        XCTAssertEqual(r.problems.count, 1, "\(r.problems)")
    }

    func testUnreadableRuleOrEffectIsReportedAndGapsAreKept() {
        var s = state()
        var r = run(&s, [.upsert("situation", ["said": str("x"), "scope": str("nonsense"), "effects": .array([str("{}")])])])
        XCTAssertTrue(s.situations.isEmpty)
        XCTAssertFalse(r.problems.isEmpty)
        r = run(&s, [.upsert("gap", ["said": str("lock my phone at 10"), "wanted": str("lock the phone")])])
        XCTAssertEqual(s.gapNotes.count, 1)
        XCTAssertTrue(r.problems.first?.contains("noted") ?? false)
        let ctx = Prompts.dump()
        XCTAssertTrue(ctx.contains("nthOf") && ctx.contains("situation"))
    }
}

final class SituationObjectTests: XCTestCase {
    func testRuleAndEffectsWrittenAsObjectsAreAccepted() {
        var s = DumpState(items: [], commitments: [Fx.school], exceptions: [], oneOffs: [], markers: [], routines: Routine.defaults,
                          moods: [], screen: [], prefs: Preferences())
        let op = DumpOp.upsert("situation", ["said": .string("sick"),
                                             "scope": .object(["dates": .object(["from": .string("2026-11-17"), "until": .string("2026-11-18")])]),
                                             "effects": .object(["mute": .string("all")]), "expires": .string("2026-11-18")])
        let r = DumpApplier.apply(DumpResult(ops: [op], reply: ""), to: &s, now: Fx.mon(9), calendar: Fx.cal, writer: .box)
        XCTAssertEqual(s.situations.count, 1, "\(r.problems)")
    }
}

final class PlaceStudyTests: XCTestCase {
    let cal = Fx.cal

    func testPlacedStudyIsAFixedBlockAndCountsTowardTheTask() {
        let essay = WorkItem(title: "Essay", kind: .essay, due: Fx.mon(23, plusDays: 6), estimateMinutes: 240)
        let sat = Fx.mon(0, plusDays: 5)
        let place = Situation(said: "essay Saturday 10 to 12", scope: .on([sat]), effects: [.place(item: essay.id, start: TimeOfDay(10), end: TimeOfDay(12))])
        var base = Fx.input(now: Fx.mon(6), items: [essay])
        let without = Planner.plan(base)
        base.situations = [place]
        let plan = Planner.plan(base)
        let blocks = plan.blocks(on: sat, calendar: cal).filter { $0.itemId == essay.id && $0.isStudy }
        XCTAssertTrue(blocks.contains { $0.start == Fx.mon(10, plusDays: 5) && $0.end == Fx.mon(12, plusDays: 5) && $0.hint == "You chose this time" }, "\(blocks.map { ($0.start, $0.end) })")
        let total = { (p: Plan) in p.blocks.filter { $0.itemId == essay.id && $0.isStudy }.reduce(0) { $0 + $1.minutes } }
        XCTAssertLessThanOrEqual(total(plan), total(without) + 15, "the placed 2 h replaces other blocks instead of adding to them")
    }

    func testBoxPlacesStudyAndRefusesNonsense() {
        let essay = WorkItem(title: "Essay", kind: .essay, due: Fx.mon(23, plusDays: 6), estimateMinutes: 240)
        var s = DumpState(items: [essay], commitments: [Fx.school], exceptions: [], oneOffs: [], markers: [], routines: Routine.defaults,
                          moods: [], screen: [], prefs: Preferences())
        func run(_ eff: String) -> DumpReport {
            DumpApplier.apply(DumpResult(ops: [.upsert("situation", ["said": .string("x"), "scope": .string(#"{"on":["2026-11-21"]}"#),
                                                                       "effects": .array([.string(eff)])])], reply: ""),
                              to: &s, now: Fx.mon(6), calendar: cal, writer: .box)
        }
        var r = run(#"{"place":{"task":"\#(Ref.task(essay.id))","start":"10:00","end":"12:00"}}"#)
        XCTAssertTrue(r.problems.isEmpty, "\(r.problems)")
        XCTAssertEqual(s.situations.count, 1)
        r = run(#"{"place":{"task":"\#(Ref.task(essay.id))","start":"08:00","end":"15:00"}}"#)
        XCTAssertFalse(r.problems.isEmpty, "seven hours isn't a block")
        r = run(#"{"place":{"task":"t000000","start":"10:00","end":"11:00"}}"#)
        XCTAssertFalse(r.problems.isEmpty)
    }
}
