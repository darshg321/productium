import XCTest
@testable import ProductiumCore

// v1.2 O6 / O8: the box's operations, approval instead of refusal, and Undo.
final class BoxRiskTests: XCTestCase {
    func testConfirmingYourOwnTimeIsNeverHeld() {
        let e = Entry(title: "Reviews", start: Fx.mon(15), end: Fx.mon(16, 5), category: CategoryTree.other, source: .you, createdAt: Fx.mon(16, 5))
        var s = BoxState(entries: [e])
        let r = BoxApplier.apply([BoxOp(.entry, .change, ref: EntryRef.entry(e.id), BoxFields(end: "16:12")),
                                  BoxOp(.entry, .confirm, ref: EntryRef.entry(e.id, occurrence: "2026-11-16"))], to: &s, now: Fx.mon(16, 12), calendar: Fx.cal)
        XCTAssertTrue(r.held.isEmpty, "\(r.held.map(\.why))")
        XCTAssertEqual(s.entries[0].marks["2026-11-16"], .confirmed)
        let gone = BoxApplier.apply([BoxOp(.entry, .skip, ref: EntryRef.entry(e.id))], to: &s, now: Fx.mon(16, 12), calendar: Fx.cal)
        XCTAssertEqual(gone.held.count, 1, "skipping over an hour you logged still asks")
    }
}

final class BoxOpsTests: XCTestCase {
    let cal = Fx.cal
    let now = Fx.mon(18)

    func apply(_ ops: [BoxOp], _ s: inout BoxState, at: Date? = nil, approved: Bool = false) -> BoxReceipt {
        BoxApplier.apply(ops, to: &s, now: at ?? now, calendar: cal, approved: approved)
    }

    func testLogPastTimeIntoANewLeaf() {
        var s = BoxState()
        let r = apply([BoxOp(.entry, .add, BoxFields(title: "Volleyball", start: "15:00", end: "17:00",
                                                     category: "Work › Extracurricular › Volleyball"))], &s)
        XCTAssertEqual(s.categories.pathText(s.entries[0].category), "Work › Extracurricular › Volleyball")
        XCTAssertEqual(s.entries[0].minutes(), 120)
        XCTAssertTrue(r.lines.contains("New category Work › Extracurricular › Volleyball"), r.lines.description)
        _ = apply([BoxOp(.entry, .add, BoxFields(title: "x", start: "10:00", end: "10:30", category: "A › B › C › D"))], &s)
        XCTAssertEqual(s.categories.depth(s.entries.last!.category), 3, "no fourth level")
    }

    func testPastIsEditableAndBigLossesAskFirst() {
        var s = BoxState()
        _ = apply([BoxOp(.entry, .add, BoxFields(title: "Homework", start: "13:00", end: "16:00"))], &s)
        let ref = EntryRef.entry(s.entries[0].id)
        // A small correction just happens.
        _ = apply([BoxOp(.entry, .change, ref: ref, BoxFields(start: "13:30", end: "16:00"))], &s)
        XCTAssertEqual(s.entries[0].start, Fx.mon(13, 30))
        // Removing 2.5 hours you logged waits for Approve.
        let r = apply([BoxOp(.entry, .remove, ref: ref)], &s)
        XCTAssertEqual(r.held.count, 1)
        XCTAssertEqual(s.entries.count, 1)
        _ = apply(r.held.map(\.op), &s, approved: true)
        XCTAssertTrue(s.entries.isEmpty)
    }

    func testBareTimeInAChangeKeepsTheEntrysDay() {
        var s = BoxState()
        _ = apply([BoxOp(.entry, .add, BoxFields(title: "See Mr B", start: "09:38", end: "10:00", day: DayKeys.key(Fx.mon(0, plusDays: 1), cal)))], &s)
        let ref = EntryRef.entry(s.entries[0].id)
        let r = apply([BoxOp(.entry, .change, ref: ref, BoxFields(end: "09:53"))], &s)
        XCTAssertTrue(r.problems.isEmpty, r.problems.description)
        XCTAssertEqual(s.entries[0].end, Fx.mon(9, 53, plusDays: 1))
    }

    func testCalendarChangeBecomesYourOwnEntry() {
        let club = Entry(id: Entry.calendarId("ek1"), title: "CS Club", start: Fx.mon(11, 10, plusDays: 1), end: Fx.mon(12, plusDays: 1),
                         category: CategoryTree.other, source: .calendar)
        var s = BoxState(entries: [club])
        let ref = EntryRef.entry(club.id)
        _ = apply([BoxOp(.entry, .change, ref: ref, BoxFields(start: "2026-11-17 12:00"))], &s)
        XCTAssertEqual(s.entries[0].marks["2026-11-17"], .skipped)
        XCTAssertEqual(s.entries.count, 2)
        XCTAssertEqual(s.entries[1].source, .you)
        XCTAssertEqual(s.entries[1].start, Fx.mon(12, plusDays: 1))
        var t = BoxState(entries: [club])
        let r = apply([BoxOp(.entry, .remove, ref: ref)], &t)
        XCTAssertEqual(t.entries[0].marks["2026-11-17"], .skipped, "removing a calendar event hides it")
        XCTAssertTrue(r.lines[0].contains("still in Calendar"))
    }

    func testOneOccurrenceOfASeries() {
        let school = Entry(title: "School", start: Fx.mon(8, 30), end: Fx.mon(15), category: CategoryTree.school,
                           repeats: .weekly([2, 3, 4, 5, 6]), source: .you)
        var s = BoxState(entries: [school])
        _ = apply([BoxOp(.entry, .change, ref: EntryRef.entry(school.id, occurrence: "2026-11-19"), BoxFields(start: "2026-11-19 10:00"))], &s)
        XCTAssertEqual(s.entries[0].marks["2026-11-19"], .skipped)
        XCTAssertEqual(s.entries[1].start, Fx.mon(10, plusDays: 3))
        XCTAssertEqual(s.entries[1].end, Fx.mon(16, 30, plusDays: 3), "a move keeps the length")
        _ = apply([BoxOp(.entry, .skip, BoxFields(day: "2026-11-20", category: "School"))], &s)
        XCTAssertEqual(s.dayRules.labels[Days.noSchoolLabel], ["2026-11-20"])
        let r = apply([BoxOp(.entry, .remove, ref: EntryRef.entry(school.id))], &s)
        XCTAssertEqual(r.held.first?.why, "Removes “School” every time it repeats")
    }

    func testAlarmsWaitForApproval() {
        var s = BoxState()
        let r = apply([BoxOp(.entry, .add, BoxFields(title: "Bus", start: "07:40", end: "08:00", day: "2026-11-17", alert: "alarm:15"))], &s)
        XCTAssertTrue(s.entries.isEmpty)
        XCTAssertEqual(r.held.count, 1)
        _ = apply(r.held.map(\.op), &s, approved: true)
        XCTAssertEqual(s.entries[0].alert?.approved, true)
    }

    func testUndo() {
        let school = Entry(title: "School", start: Fx.mon(8, 30), end: Fx.mon(15), category: CategoryTree.school,
                           repeats: .weekly([2, 3, 4, 5, 6]), source: .you)
        var s = BoxState(entries: [school], items: [WorkItem(title: "Essay", kind: .essay, due: Fx.mon(20, plusDays: 3))])
        let before = s
        let r = apply([
            BoxOp(.rule, .add, BoxFields(repeats: .weekdays([1, 2, 3, 4, 5]), text: "Mum takes the phone at 10 on school nights",
                                         limits: PlannerLimits(noStudyAfter: TimeOfDay(21, 45)))),
            BoxOp(.entry, .skip, BoxFields(day: "2026-11-20", category: "school")),
            BoxOp(.entry, .add, BoxFields(title: "Trip", start: "2026-11-20 09:00", end: "2026-11-20 17:00", category: "Free Time › Trips")),
            BoxOp(.task, .change, ref: Ref.task(before.items[0].id), BoxFields(minutes: 15)),
            BoxOp(.task, .add, BoxFields(title: "Read", due: "2026-11-19 23:59", minutes: 30)),
        ], &s)
        XCTAssertTrue(r.problems.isEmpty, r.problems.description)
        BoxApplier.undo(r, in: &s)
        XCTAssertEqual(s.rules, before.rules)
        XCTAssertEqual(s.entries, before.entries)
        XCTAssertEqual(s.items, before.items)
        XCTAssertEqual(s.categories, before.categories)
        XCTAssertEqual(s.dayRules, before.dayRules)
    }

    // MARK: Every prompt in the 2026-11-18 backup, as the ops Sonnet should send

    /// Wed 18 Nov 2026 in Toronto, where the backup was made.
    static var tor: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Toronto")!
        return c
    }()
    func at(_ h: Int, _ m: Int = 0, day: Int = 18) -> Date {
        Self.tor.date(from: DateComponents(year: 2026, month: 11, day: day, hour: h, minute: m))!
    }

    func testBackupPromptsAreExpressible() {
        let cal = Self.tor
        var s = BoxState(entries: [Entry(id: Entry.calendarId("cs"), title: "CS Club Meeting", start: at(11, 10, day: 19),
                                         end: at(12, day: 19), category: CategoryTree.other, source: .calendar)])
        func run(_ t: Date, _ ops: [BoxOp], approved: Bool = false) -> BoxReceipt {
            let r = BoxApplier.apply(ops, to: &s, now: t, calendar: cal, approved: approved)
            XCTAssertTrue(r.problems.isEmpty, "\(ops): \(r.problems)")
            XCTAssertTrue(r.held.isEmpty, "\(ops): held \(r.held.map(\.why))")
            return r
        }
        func task(_ title: String) -> String {
            guard let t = s.items.first(where: { $0.title.hasPrefix(title) }) else { XCTFail("no task \(title): \(s.items.map(\.title))"); return "t0000" }
            return Ref.task(t.id)
        }
        func entry(_ title: String) -> String {
            guard let e = s.entries.first(where: { $0.title.hasPrefix(title) }) else { XCTFail("no entry \(title)"); return "e0000" }
            return EntryRef.entry(e.id)
        }

        // "today add task make brag sheet for physics teacher rec, write claim for english practice"
        _ = run(at(13, 40), [BoxOp(.task, .add, BoxFields(title: "Brag sheet for physics teacher rec", due: "23:59", minutes: 45)),
                             BoxOp(.task, .add, BoxFields(title: "English claim", due: "23:59", minutes: 30))])
        // "dinner 7:30": time, not a setting.
        _ = run(at(13, 40), [BoxOp(.entry, .add, BoxFields(title: "Dinner", start: "19:30", end: "20:00", category: "Essentials › Meals",
                                                           repeats: .weekdays(Set(1...7))))])
        // "change english to full practice essay today 1.5h, 1h valorant at night with a friend, 30m frankenstein"
        _ = run(at(13, 56), [BoxOp(.task, .change, ref: task("English claim"), BoxFields(title: "English practice essay", minutes: 90)),
                             BoxOp(.entry, .add, BoxFields(title: "Valorant with friend", start: "21:30", end: "22:30", category: "Free Time › Gaming")),
                             BoxOp(.task, .add, BoxFields(title: "Read Frankenstein", due: "23:59", minutes: 30, kind: "reading", difficulty: 1))])
        // "do dayoneof video reviews today, about 15 mins" (and the rename after)
        _ = run(at(13, 58), [BoxOp(.task, .add, BoxFields(title: "Dayoneof video reviews", due: "23:59", minutes: 15, difficulty: 1))])
        // The timetable, odd and even dates, in one turn: what took v1.1 three turns and failed once.
        let odd = DayRule.all([.weekdays([2, 3, 4, 5, 6]), .dateParity(odd: true)])
        let even = DayRule.all([.weekdays([2, 3, 4, 5, 6]), .dateParity(odd: false)])
        func period(_ t: String, _ a: String, _ b: String, _ r: DayRule, open: Bool = false) -> BoxOp {
            BoxOp(.entry, .add, BoxFields(title: t, start: a, end: b, day: "2026-11-18", category: "School › \(t)", repeats: r, open: open))
        }
        _ = run(at(14, 4), [period("Math", "08:26", "09:38", odd), period("Spare", "09:38", "10:58", odd, open: true),
                            period("Lunch", "10:58", "12:13", odd, open: true), period("English", "12:13", "13:26", odd),
                            period("Data", "13:26", "14:46", odd),
                            period("Spare", "08:26", "09:46", even, open: true), period("Math", "09:46", "10:58", even),
                            period("English", "10:58", "12:11", even), period("Lunch", "12:11", "13:26", even, open: true),
                            period("Data", "13:26", "14:46", even)])
        XCTAssertEqual(s.categories.children(CategoryTree.school).count, 5)
        // "english presentation on 25th: finish frankenstein (pg 30), annotated bibliography, presentation, practice"
        // + "no more than 45m reading a day" + "bibliography can be done without finishing reading": one reading task.
        _ = run(at(14, 19), [BoxOp(.task, .change, ref: task("Read Frankenstein"),
                                   BoxFields(title: "Finish Frankenstein (from pg 30)", due: "2026-11-24 23:59", minutes: 225, maxMinutesPerDay: 45)),
                             BoxOp(.task, .add, BoxFields(title: "Annotated bibliography", due: "2026-11-23 23:59", minutes: 120)),
                             BoxOp(.task, .add, BoxFields(title: "Create English presentation", due: "2026-11-24 23:59", minutes: 120)),
                             BoxOp(.task, .add, BoxFields(title: "Practice English presentation", due: "2026-11-25 08:00", minutes: 60))])
        // "data quiz monday, 6.1-6.3, 2h" + "you already have data period time so that's when it is": due at the class.
        let dataMonday = Days.on(at(0, day: 23), s.entries, now: at(14, 22), calendar: cal).first { $0.title == "Data" }!
        _ = run(at(14, 22), [BoxOp(.task, .add, BoxFields(title: "Data quiz 6.1–6.3", topics: ["6.1", "6.2", "6.3"],
                                                         due: ISO8601DateFormatter().string(from: dataMonday.start), minutes: 120, kind: "quiz"))])
        XCTAssertEqual(s.items.last?.due, at(13, 26, day: 23))
        // "spare periods should be used for easy work": already true (open time takes light work); mark the easy ones.
        _ = run(at(14, 23), [BoxOp(.task, .change, ref: task("Finish Frankenstein"), BoxFields(difficulty: 1))])
        // "no cs club meeting tomorrow": a calendar event, skipped.
        _ = run(at(14, 24), [BoxOp(.entry, .skip, ref: entry("CS Club"))])
        // "need to see mr barnhardt period 2 tomorrow in portable 8" then "only 15 mins"
        _ = run(at(14, 50), [BoxOp(.entry, .add, BoxFields(title: "See Mr Barnhardt, portable 8", start: "09:38", end: "09:53", day: "2026-11-19"))])
        // "back home log my end of school to now as usual walk time"
        _ = run(at(15, 5), [BoxOp(.entry, .add, BoxFields(title: "Walk home", start: "14:46", end: "15:05", category: "travel"))])
        // "starting dayoneof review" … "done dayoneof review" … "actually i just finished just now"
        _ = run(at(15, 7), [BoxOp(.task, .start, ref: task("Dayoneof"))])
        _ = run(at(15, 57), [BoxOp(.task, .done, ref: task("Dayoneof"))])
        let review = s.entries.first { $0.title.hasPrefix("Dayoneof") }!
        _ = run(at(16, 12), [BoxOp(.entry, .change, ref: EntryRef.entry(review.id), BoxFields(end: "16:12"))])
        XCTAssertEqual(s.entries.first { $0.id == review.id }?.end, at(16, 12))
        // "starting brag sheet" at 21:59: Valorant (said ahead) is trimmed to 21:30–21:59.
        _ = run(at(21, 59), [BoxOp(.task, .start, ref: task("Brag"))])
        // "brag sheet can be due tomorrow and move my other tasks to tomorrow"
        _ = run(at(23, 56), [BoxOp(.task, .change, ref: task("Brag"), BoxFields(due: "2026-11-19 23:59")),
                             BoxOp(.task, .change, ref: task("English practice"), BoxFields(notBefore: "2026-11-19")),
                             BoxOp(.entry, .stop)])
        // "didn't do valorant today" / "why can't you edit it": the past is editable.
        _ = run(at(23, 59), [BoxOp(.entry, .skip, ref: entry("Valorant"))])
        let day = TimeLog.past(s.entries, in: Days.dayInterval(at(12), cal), now: at(23, 59), calendar: cal)
        XCTAssertFalse(day.contains { $0.entry?.title.hasPrefix("Valorant") == true })
        XCTAssertTrue(day.contains { $0.entry?.title.hasPrefix("Brag") == true && $0.minutes == 117 })
        // "brag sheet today is only 15 mins", "frankenstein readings are ordered wrong and too many": one task now,
        // with stable numbering; nothing to fix by hand.
        _ = run(at(0, 1, day: 19), [BoxOp(.task, .change, ref: task("Brag"), BoxFields(minutes: 15))])
    }
}
