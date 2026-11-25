import XCTest
@testable import ProductiumCore

// v1.2 O1 / O2: Entries, repeats, marks, detaching one occurrence, refs, alerts and `Days.expand`.
final class EntryTests: XCTestCase {
    let cal = Fx.cal
    var week: DateInterval { DateInterval(start: Fx.mon(0), end: Fx.mon(0, plusDays: 7)) }

    func school(_ rule: DayRule = .weekdays([2, 3, 4, 5, 6]), title: String = "School") -> Entry {
        Entry(title: title, start: Fx.mon(8, 30), end: Fx.mon(15), category: CategoryTree.school,
              repeats: Repeat(rule), source: .you, createdAt: Fx.mon(7))
    }

    func testWeeklyRepeatExpandsOnItsDays() {
        let occ = Days.expand([school()], in: week, now: Fx.mon(7), calendar: cal)
        XCTAssertEqual(occ.map { cal.component(.weekday, from: $0.start) }, [2, 3, 4, 5, 6])
        XCTAssertTrue(occ.allSatisfy { $0.minutes == 390 && $0.busy })
        XCTAssertEqual(occ[2].start, Fx.mon(8, 30, plusDays: 2))
    }

    func testOccurrenceIdsAreStable() {
        let e = school()
        let a = Days.expand([e], in: week, now: Fx.mon(7), calendar: cal).map(\.id)
        let b = Days.on(Fx.mon(0, plusDays: 2), [e], now: Fx.mon(20, plusDays: 1), calendar: cal).map(\.id)
        XCTAssertEqual(b, [a[2]])
        XCTAssertEqual(a[2], "\(e.id.uuidString)@2026-11-18")
    }

    func testRepeatBounds() {
        var e = school()
        e.repeats = Repeat(.weekdays([2, 3, 4, 5, 6]), from: Fx.mon(0, plusDays: 2), until: Fx.mon(0, plusDays: 3))
        XCTAssertEqual(Days.expand([e], in: week, now: Fx.mon(7), calendar: cal).map { $0.occurrence! }, ["2026-11-18", "2026-11-19"])
    }

    func testOddEvenDateTimetable() {
        // The real timetable from the 2026-11-18 backup: P1/P2 and P3/P4 swap on even dates.
        let odd = DayRule.all([.weekdays([2, 3, 4, 5, 6]), .dateParity(odd: true)])
        let even = DayRule.all([.weekdays([2, 3, 4, 5, 6]), .dateParity(odd: false)])
        let math1 = Entry(title: "Math", start: Fx.mon(8, 26), end: Fx.mon(9, 38), category: CategoryTree.school, repeats: Repeat(odd), source: .you)
        let math2 = Entry(title: "Math", start: Fx.mon(9, 46), end: Fx.mon(10, 58), category: CategoryTree.school, repeats: Repeat(even), source: .you)
        let wed = Days.on(Fx.mon(0, plusDays: 2), [math1, math2], now: Fx.mon(7), calendar: cal)   // 18th: even
        let thu = Days.on(Fx.mon(0, plusDays: 3), [math1, math2], now: Fx.mon(7), calendar: cal)   // 19th: odd
        XCTAssertEqual(wed.map(\.start), [Fx.mon(9, 46, plusDays: 2)])
        XCTAssertEqual(thu.map(\.start), [Fx.mon(8, 26, plusDays: 3)])
    }

    func testABRotationShiftsAfterANoSchoolDay() {
        var book = DayRuleBook(sequences: [DaySequence(name: "school",
                                                        rule: .all([.weekdays([2, 3, 4, 5, 6]), .not(.label(Days.noSchoolLabel))]),
                                                        anchor: Fx.mon(0))])
        var entries = [school(.nthOf(sequence: "school", mod: 2, eq: 0), title: "A day"),
                       school(.nthOf(sequence: "school", mod: 2, eq: 1), title: "B day")]
        func titles() -> [String] { Days.expand(entries, in: week, now: Fx.mon(7), book: book, calendar: cal).map(\.title) }
        XCTAssertEqual(titles(), ["A day", "B day", "A day", "B day", "A day"])
        let refs = Days.skip(category: CategoryTree.school, on: Fx.mon(0, plusDays: 2), entries: &entries,
                             tree: CategoryTree(), book: &book, now: Fx.mon(7), calendar: cal)
        XCTAssertEqual(refs.count, 1)
        XCTAssertEqual(titles(), ["A day", "B day", "A day", "B day"], "Thursday is the next A day")
    }

    func testDetachOneOccurrence() {
        var e = school()
        let one = Days.detach(&e, occurrence: "2026-11-19", calendar: cal, now: Fx.mon(7))!
        XCTAssertEqual(e.marks["2026-11-19"], .skipped)
        XCTAssertNil(one.repeats)
        XCTAssertEqual(one.start, Fx.mon(8, 30, plusDays: 3))
        let thu = Days.on(Fx.mon(0, plusDays: 3), [e, one], now: Fx.mon(7), calendar: cal)
        XCTAssertEqual(thu.map(\.entry.id), [one.id], "the series is skipped, the copy stands in")
        XCTAssertNil(Days.detach(&e, occurrence: "2026-11-21", calendar: cal, now: Fx.mon(7)), "no school Saturday")
    }

    func testOvernightRepeatAcrossDST() {
        let start = cal.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 22, minute: 30))!
        let end = cal.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 7))!
        let e = Entry(title: "Sleep", start: start, end: end, category: CategoryTree.sleep, repeats: .weekly(Set(1...7)), source: .plan)
        let range = DateInterval(start: cal.date(from: DateComponents(year: 2026, month: 10, day: 31))!,
                                 end: cal.date(from: DateComponents(year: 2026, month: 11, day: 2))!)
        let occ = Days.expand([e], in: range, now: start, calendar: cal)
        XCTAssertEqual(occ.first?.occurrence, "2026-10-30", "last night's sleep overlaps this morning")
        XCTAssertTrue(occ.allSatisfy { cal.component(.hour, from: $0.end) == 7 })
        XCTAssertTrue(occ.contains { $0.minutes == 570 }, "the night the clocks go back is an hour longer")
    }

    func testAssumedAndPlannedSessions() {
        let now = Fx.mon(23)
        func occ(_ e: Entry) -> DayEntry { Days.expand([e], in: Days.dayInterval(Fx.mon(0), cal), now: now, calendar: cal)[0] }
        let saidAhead = Entry(title: "Valorant", start: Fx.mon(21, 30), end: Fx.mon(22, 30), category: CategoryTree.free,
                              source: .you, createdAt: Fx.mon(14))
        let saidAfter = Entry(title: "Walk home", start: Fx.mon(14, 46), end: Fx.mon(15, 5), category: CategoryTree.travel,
                              source: .you, createdAt: Fx.mon(15, 5))
        let plannedDinner = Entry(title: "Dinner", start: Fx.mon(19, 30), end: Fx.mon(20), category: CategoryTree.meals, source: .plan)
        let plannedStudy = Entry(title: "Essay", start: Fx.mon(17), end: Fx.mon(18), category: CategoryTree.studying,
                                 taskId: UUID(), source: .plan)
        let pinned = Entry(title: "Reading", start: Fx.mon(16), end: Fx.mon(16, 45), category: CategoryTree.studying,
                           taskId: UUID(), source: .you, createdAt: Fx.mon(9))
        XCTAssertTrue(occ(saidAhead).assumed)
        XCTAssertFalse(occ(saidAfter).assumed)
        XCTAssertTrue(occ(plannedDinner).assumed, "planned routines count unless you say no")
        XCTAssertTrue(occ(plannedStudy).isPlannedSession && !occ(plannedStudy).assumed, "study needs tracking")
        XCTAssertTrue(occ(pinned).isPlannedSession)
        var yes = saidAhead
        yes.marks["2026-11-16"] = .confirmed
        XCTAssertFalse(occ(yes).assumed)
        XCTAssertGreaterThan(occ(saidAfter).rank, occ(saidAhead).rank)
    }

    func testRefsParseAndResolve() {
        let e = school()
        let short = EntryRef.entry(e.id)
        XCTAssertEqual(short.count, 7)
        XCTAssertEqual(EntryRef.parse(short + "@2026-11-20")?.occurrence, "2026-11-20")
        XCTAssertNil(EntryRef.parse("t1234@2026-11-20"), "only entries have occurrences")
        XCTAssertNil(EntryRef.parse("x1234"))
        let other = Entry(title: "x", start: Fx.mon(9), end: Fx.mon(10), category: CategoryTree.other, source: .you)
        let hit = EntryRef.resolve(short + "@2026-11-20", in: [other, e])
        XCTAssertEqual(hit?.index, 1)
        XCTAssertEqual(hit?.occurrence, "2026-11-20")
    }

    func testStateRoundTripAndCleanBreak() throws {
        var e = school()
        e.alert = .notify(before: 10)
        e.marks["2026-11-17"] = .skipped
        let enc = ExportBundle.encoder(), dec = ExportBundle.decoder()
        var s = AppState()
        s.entries = [e]
        s.rules = [Rule(text: "Exam week: 45 minute blocks", limits: PlannerLimits(maxBlockMinutes: 45), createdAt: Fx.mon(7))]
        s.telemetry.record(.box, "turn", at: Fx.mon(7), ["ops": "entry.add"])
        let back = try dec.decode(AppState.self, from: enc.encode(s))
        XCTAssertEqual(back.entries, [e])
        XCTAssertEqual(back.rules, s.rules)
        XCTAssertEqual(back.telemetry, s.telemetry)
        XCTAssertThrowsError(try dec.decode(AppState.self, from: Data(#"{"onboarded":true,"items":[]}"#.utf8)), "v1.1 state isn't read")
    }

    func testCategoryTree() {
        var t = CategoryTree()
        XCTAssertEqual(t.pathText(CategoryTree.studying), "Work › Studying")
        let math = t.add("Math", under: CategoryTree.studying)!
        XCTAssertEqual(t.depth(math.id), 3)
        XCTAssertNil(t.add("Algebra", under: math.id), "no fourth level")
        XCTAssertEqual(t.add("math", under: CategoryTree.studying)?.id, math.id, "same name, same node")
        XCTAssertEqual(t.group(math.id), .productive)
        XCTAssertEqual(t.legacy(math.id), .study)
        XCTAssertEqual(t.pathText(CategoryTree.untracked), "Untracked")
    }

    func testAlertsBecomeAlarmsOnlyWhenApproved() {
        var sleep = Entry(title: "Sleep", start: Fx.mon(22, 30), end: Fx.mon(7, plusDays: 1), category: CategoryTree.sleep,
                          repeats: .weekly(Set(1...7)), alert: .wake, source: .plan)
        let dentist = Entry(title: "Dentist", start: Fx.mon(10, plusDays: 1), end: Fx.mon(11, plusDays: 1),
                            category: CategoryTree.other, alert: Alert(.alarm, minutesBefore: 30), source: .you)
        let quiz = Entry(title: "Quiz review", start: Fx.mon(11, 30, plusDays: 1), end: Fx.mon(11, 55, plusDays: 1),
                         category: CategoryTree.studying, alert: .notify(before: 5), source: .plan)
        let range = DateInterval(start: Fx.mon(12), end: Fx.mon(12, plusDays: 1))
        func occ() -> [DayEntry] { Days.expand([sleep, dentist, quiz], in: range, now: Fx.mon(12), calendar: cal) }
        XCTAssertEqual(EntryAlerts.due(occ(), now: Fx.mon(12)).map(\.title), ["Good morning", "Dentist in 30m", "Quiz review in 5m"])
        XCTAssertEqual(EntryAlerts.alarms(occ(), now: Fx.mon(12), allowed: true).map(\.title), ["Good morning"])
        XCTAssertTrue(EntryAlerts.alarms(occ(), now: Fx.mon(12), allowed: false).isEmpty)
        sleep.marks["2026-11-16"] = .skipped
        XCTAssertTrue(EntryAlerts.alarms(occ(), now: Fx.mon(12), allowed: true).isEmpty)
    }
}

final class EntryBuilderTests: XCTestCase {
    func testPhoneAfterBedtimeCutsAssumedSleep() {
        let cal = Fx.cal
        let sleep = Entry(title: "Sleep", start: Fx.mon(23), end: Fx.mon(7, plusDays: 1), category: CategoryTree.sleep,
                          alert: .wake, source: .plan)
        var entries = [sleep]
        let uses = [EntryBuilder.PhoneUse(start: Fx.mon(23, 10), end: Fx.mon(0, 40, plusDays: 1)),
                    EntryBuilder.PhoneUse(start: Fx.mon(5, 0, plusDays: 1), end: Fx.mon(5, 10, plusDays: 1))]
        let ids = EntryBuilder.phoneAfterBedtime(uses, entries: &entries, now: Fx.mon(8, plusDays: 1))
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(entries.first { $0.id == sleep.id }?.start, Fx.mon(0, 40, plusDays: 1), "sleep starts after the late pickup, not the 5am wake")
        let range = DateInterval(start: Fx.mon(22), end: Fx.mon(8, plusDays: 1))
        let slices = TimeLog.past(entries, in: range, now: Fx.mon(8, plusDays: 1), calendar: cal)
        let totals = TimeLog.totals(slices)
        XCTAssertEqual(totals[CategoryTree.scrolling], 90 + 10, "the phone use shows as scrolling")
        XCTAssertEqual(totals[CategoryTree.sleep], 370)
        // Rebuilding is idempotent.
        EntryBuilder.phoneAfterBedtime(uses, entries: &entries, now: Fx.mon(8, plusDays: 1))
        XCTAssertEqual(entries.filter { $0.source == .sensor }.count, 2)
    }
}
