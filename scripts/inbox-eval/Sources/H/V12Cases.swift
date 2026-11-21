import Foundation
import ProductiumCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// v1.2 O9: box eval cases taken from real prompts (the 2026-11-18 backup). Only the ones that are tricky: they
// failed or were awkward in v1.1, or need the model to reason with the timetable, a task's daily cap, assumed time
// or the past. Each case is a world (`World.base`), what you said (exact words, typos kept), a check on the state
// after, and a reference answer: the ops a correct model could send. `--v12-reference` runs the references
// through the checks with no network, which proves every check is achievable and right. `--v12` sends the turns to
// Sonnet once the v1.2 box schema is wired (handoff step 11: fill in `V12.ask`).

struct V12Case {
    let id: String
    /// What makes it hard.
    let why: String
    let now: Date
    var setup: (inout BoxState) -> Void = { _ in }
    let turns: [String]
    /// One op list per turn.
    let reference: [[BoxOp]]
    let check: (BoxState) -> [String]
    /// H2: the track record in the context.
    var trackRecord: [String] = []
    /// Checks on the last reply and every op sent (side ops like mood aren't in `BoxState`).
    var replyCheck: (String, [BoxOp]) -> [String] = { _, _ in [] }
    /// The reply a correct answer could give, for `--v12-reference`.
    var referenceReply = ""
    /// A reference that depends on the state (refs made in an earlier turn).
    var referenceFor: ((Int, BoxState) -> [BoxOp])?
}

enum World {
    static let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Toronto")!
        return c
    }()
    /// November 2026. The 18th (Wed) is an even date, the 19th (Thu) odd, the 20th (Fri) even, the 23rd (Mon) odd.
    static func at(_ day: Int, _ h: Int, _ m: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 11, day: day, hour: h, minute: m))!
    }
    static func key(_ day: Int) -> String { String(format: "2026-11-%02d", day) }

    static let schoolDays = DayRule.weekdays([2, 3, 4, 5, 6])
    /// The Settings line the app sends (v1.1's defaults for this student).
    static let settings = "school days Mon–Fri, sleep need 8h, sleep floor 7h, wake 6:45 on school days, notifications standard"
    static let odd = DayRule.all([schoolDays, .dateParity(odd: true)])
    static let even = DayRule.all([schoolDays, .dateParity(odd: false)])

    static let frankenstein = UUID(uuidString: "F1000000-0000-0000-0000-000000000001")!
    static let essay = UUID(uuidString: "E2000000-0000-0000-0000-000000000002")!
    static let brag = UUID(uuidString: "B3000000-0000-0000-0000-000000000003")!
    static let dayoneof = UUID(uuidString: "D4000000-0000-0000-0000-000000000004")!
    static let quiz = UUID(uuidString: "A5000000-0000-0000-0000-000000000005")!
    static let bibliography = UUID(uuidString: "C6000000-0000-0000-0000-000000000006")!

    /// "P2 Spare": the period number stays in the title, because "period 2" means P2 (even on swapped days).
    static func period(_ title: String, _ s: (Int, Int), _ e: (Int, Int), _ rule: DayRule, open: Bool, _ tree: inout CategoryTree) -> Entry {
        let subject = String(title.split(separator: " ").last!)
        let cat = tree.add(subject, under: CategoryTree.school)!.id
        return Entry(title: title, start: at(18, s.0, s.1), end: at(18, e.0, e.1), category: cat, topics: [subject.lowercased()],
                     repeats: Repeat(rule), open: open, source: .you, createdAt: at(18, 14, 7))
    }

    static func timetable(openSpares: Bool = true, _ tree: inout CategoryTree) -> [Entry] {
        [period("P1 Math", (8, 26), (9, 38), odd, open: false, &tree), period("P2 Spare", (9, 38), (10, 58), odd, open: openSpares, &tree),
         period("P3 Lunch", (10, 58), (12, 13), odd, open: openSpares, &tree), period("P4 English", (12, 13), (13, 26), odd, open: false, &tree),
         period("P5 Data", (13, 26), (14, 46), odd, open: false, &tree),
         period("P2 Spare", (8, 26), (9, 46), even, open: openSpares, &tree), period("P1 Math", (9, 46), (10, 58), even, open: false, &tree),
         period("P4 English", (10, 58), (12, 11), even, open: false, &tree), period("P3 Lunch", (12, 11), (13, 26), even, open: openSpares, &tree),
         period("P5 Data", (13, 26), (14, 46), even, open: false, &tree)]
    }

    static func task(_ id: UUID, _ title: String, _ kind: TaskKind, due: Date, minutes: Int, difficulty: Int = 2,
                     maxPerDay: Int? = nil) -> WorkItem {
        var t = WorkItem(id: id, title: title, kind: kind, due: due, estimateMinutes: minutes, difficulty: difficulty,
                         source: .ai, createdAt: at(18, 13, 40))
        t.category = CategoryTree.studying
        t.maxMinutesPerDay = maxPerDay
        return t
    }

    /// The app as it stood on the afternoon of Wed 18 Nov, in v1.2 terms.
    static func base(timetable withTimetable: Bool = true, openSpares: Bool = true) -> BoxState {
        var tree = CategoryTree()
        var entries = withTimetable ? timetable(openSpares: openSpares, &tree) : []
        entries.append(Entry(id: Entry.calendarId("cs-club"), title: "CS Club Meeting", start: at(19, 11, 10), end: at(19, 12),
                             category: CategoryTree.other, source: .calendar, createdAt: at(18, 8)))
        entries.append(Entry(title: "Dinner", start: at(18, 19, 30), end: at(18, 20), category: CategoryTree.meals,
                             repeats: Repeat(.weekdays(Set(1...7))), source: .you, createdAt: at(18, 13, 40)))
        entries.append(Entry(title: "Valorant with friend", start: at(18, 21, 30), end: at(18, 22, 30), category: CategoryTree.free,
                             source: .you, createdAt: at(18, 13, 56)))
        let items = [
            task(brag, "Make brag sheet for physics teacher rec", .application, due: at(18, 23, 59), minutes: 15),
            task(essay, "Write practice essay for English", .essay, due: at(18, 23, 59), minutes: 90, difficulty: 3),
            task(dayoneof, "Dayoneof video reviews", .other, due: at(18, 23, 59), minutes: 15, difficulty: 1),
            task(frankenstein, "Finish reading Frankenstein (from pg 30)", .reading, due: at(24, 23, 59), minutes: 225,
                 difficulty: 1, maxPerDay: 45),
            task(bibliography, "Annotated bibliography with research", .assignment, due: at(23, 23, 59), minutes: 120),
            task(quiz, "Data quiz: lessons 6.1-6.3", .quiz, due: at(23, 13, 26), minutes: 120),
        ]
        return BoxState(entries: entries, items: items, categories: tree, sleepFloorMinutes: 420)
    }

    static func ref(_ id: UUID) -> String { Ref.task(id) }
    static func ref(entry title: String, in s: BoxState, occurrence: Int? = nil) -> String {
        let e = s.entries.first { $0.title.hasPrefix(title) }!
        return EntryRef.entry(e.id, occurrence: occurrence.map(key))
    }

    static func plan(_ s: BoxState, now: Date) -> Plan {
        Planner.plan(PlannerInput(now: now, calendar: cal, items: s.items, routines: [], horizonDays: 8, entries: s.entries,
                                  rules: s.rules, categories: s.categories))
    }

    static func on(_ day: Int, _ s: BoxState, now: Date) -> [DayEntry] {
        Days.on(at(day, 12), s.entries, now: now, book: s.dayRules, calendar: cal).filter { cal.isDate($0.start, inSameDayAs: at(day, 12)) }
    }

    static func hm(_ d: Date) -> String { DateFormatter.local("H:mm", cal).string(from: d) }
}

/// Small helpers so checks read like the expectation.
struct Expect {
    var fails: [String] = []
    mutating func that(_ ok: Bool, _ what: @autoclosure () -> String) { if !ok { fails.append(what()) } }
}

enum V12 {
    typealias W = World

    static var cases: [V12Case] { real + V12More.everyday + V12More.exceptions }

    static let real: [V12Case] = [
        V12Case(id: "timetable-odd-even",
                why: "v1.1 needed 3 turns and failed once; the even-date swap has to become its own repeating entries, keeping P-numbers",
                now: W.at(18, 14, 4), setup: { $0 = W.base(timetable: false) },
                turns: ["i have school starts math p1 from 8:26-9:38, spare period until 10:58, lunch until 12:13, english until 1:26, data until 2:46, when school ends. every odd date is like this, every even date p1 and p2 swap around and p3 and p4 swap around"],
                reference: [{
                    func p(_ t: String, _ a: String, _ b: String, _ r: DayRule, _ open: Bool = false) -> BoxOp {
                        BoxOp(.entry, .add, BoxFields(title: t, start: a, end: b, day: "2026-11-18",
                                                      category: "School › \(t.split(separator: " ").last!)", repeats: r, open: open))
                    }
                    return [p("P1 Math", "08:26", "09:38", W.odd), p("P2 Spare", "09:38", "10:58", W.odd, true), p("P3 Lunch", "10:58", "12:13", W.odd, true),
                            p("P4 English", "12:13", "13:26", W.odd), p("P5 Data", "13:26", "14:46", W.odd),
                            p("P2 Spare", "08:26", "09:46", W.even, true), p("P1 Math", "09:46", "10:58", W.even), p("P4 English", "10:58", "12:11", W.even),
                            p("P3 Lunch", "12:11", "13:26", W.even, true), p("P5 Data", "13:26", "14:46", W.even)]
                }()],
                check: { s in
                    var e = Expect()
                    let now = W.at(18, 14, 5)
                    func school(_ d: Int) -> [DayEntry] { W.on(d, s, now: now).filter { s.categories.isUnder($0.category, CategoryTree.school) } }
                    let thu = school(19), fri = school(20)
                    e.that(thu.first?.title.lowercased().contains("math") == true && thu.first.map { W.hm($0.start) } == "8:26",
                           "Thu 19 (odd) starts with Math at 8:26: \(thu.map { "\($0.title) \(W.hm($0.start))" })")
                    e.that(fri.first.map { W.hm($0.start) } == "8:26" && fri.first?.title.lowercased().contains("spare") == true,
                           "Fri 20 (even) starts with the spare at 8:26: \(fri.map { "\($0.title) \(W.hm($0.start))" })")
                    // When periods swap, each keeps its own length (the student's answer, 2026-11-20).
                    func at(_ word: String, _ a: String, _ b: String) {
                        e.that(fri.contains { $0.title.lowercased().contains(word) && W.hm($0.start) == a && W.hm($0.end) == b },
                               "Fri 20 \(word) \(a)–\(b)")
                    }
                    at("spare", "8:26", "9:46")
                    at("math", "9:46", "10:58")
                    at("english", "10:58", "12:11")
                    at("lunch", "12:11", "13:26")
                    for (d, list) in [(19, thu), (20, fri), (23, school(23))] {
                        let covered = TimeLog.resolve(list, in: DateInterval(start: W.at(d, 8, 26), end: W.at(d, 14, 46)))
                        e.that(!covered.contains { $0.entry == nil }, "Nov \(d): school covers 8:26–14:46 without gaps")
                        e.that(list.last.map { W.hm($0.end) } == "14:46", "Nov \(d): school ends 14:46")
                    }
                    e.that(school(21).isEmpty && school(22).isEmpty, "no school on the weekend")
                    e.that(fri.first?.title.contains("2") == true, "the period number is kept (P2 Spare first on even dates): \(fri.first?.title ?? "-")")
                    return e.fails
                }),

        V12Case(id: "reading-cap-not-split",
                why: "v1.1 split the reading into 5 tasks with invented due dates; it should be one task with a daily cap",
                now: W.at(18, 14, 19),
                setup: { s in
                    s = W.base()
                    let i = s.items.firstIndex { $0.id == W.frankenstein }!
                    s.items[i].maxMinutesPerDay = nil
                    s.items[i].estimateMinutes = 240
                    s.items[i].due = W.at(21, 23, 59)
                },
                turns: ["too much reading today, bibliography can be done without finishing reading, so donf add more than 45m reading a day"],
                reference: [[BoxOp(.task, .change, ref: W.ref(W.frankenstein), BoxFields(maxMinutesPerDay: 45))]],
                check: { s in
                    var e = Expect()
                    let readings = s.items.filter { $0.title.lowercased().contains("frankenstein") && $0.isOpen }
                    e.that(readings.count == 1, "one Frankenstein task, not split: \(readings.map(\.title))")
                    e.that(readings.first?.maxMinutesPerDay == 45, "daily cap 45: \(String(describing: readings.first?.maxMinutesPerDay))")
                    e.that(s.items.first { $0.id == W.bibliography }?.notBefore == nil, "the bibliography isn't made to wait for the reading")
                    let plan = W.plan(s, now: W.at(18, 14, 20))
                    let perDay = Dictionary(grouping: plan.blocks.filter { $0.itemId == readings.first?.id && $0.isStudy },
                                            by: { DayKeys.key($0.start, W.cal) }).mapValues { $0.reduce(0) { $0 + $1.minutes } }
                    e.that(perDay.values.allSatisfy { $0 <= 45 }, "≤45 min of reading on any day: \(perDay)")
                    return e.fails
                }),

        V12Case(id: "push-capped-reading-to-tomorrow",
                why: "a capped task moved a day: must set not-before, not change the due date, the cap or the total",
                now: W.at(18, 16), setup: { $0 = W.base() },
                turns: ["push frankenstein to tomorrow"],
                reference: [[BoxOp(.task, .change, ref: W.ref(W.frankenstein), BoxFields(notBefore: "2026-11-19"))]],
                check: { s in
                    var e = Expect()
                    guard let f = s.items.first(where: { $0.id == W.frankenstein }) else { return ["the task is gone"] }
                    e.that(f.notBefore.map { W.cal.isDate($0, inSameDayAs: W.at(19, 12)) && W.cal.component(.hour, from: $0) < 9 } == true,
                           "not before Thu 19 (early): \(String(describing: f.notBefore))")
                    e.that(f.due == W.at(24, 23, 59), "due unchanged (24th): \(f.due)")
                    e.that(f.maxMinutesPerDay == 45 && f.estimateMinutes == 225, "cap and total unchanged")
                    e.that(s.items.filter { $0.title.lowercased().contains("frankenstein") }.count == 1, "no new reading tasks")
                    let plan = W.plan(s, now: W.at(18, 16, 1))
                    let blocks = plan.blocks.filter { $0.itemId == W.frankenstein && $0.isStudy }
                    e.that(!blocks.contains { W.cal.isDate($0.start, inSameDayAs: W.at(18, 12)) }, "no reading left today")
                    e.that(blocks.contains { W.cal.isDate($0.start, inSameDayAs: W.at(19, 12)) }, "reading tomorrow")
                    return e.fails
                }),

        V12Case(id: "quiz-due-at-its-class",
                why: "the due time comes from the timetable (Monday 23rd is an odd date: Data 13:26), said in a follow-up",
                now: W.at(18, 14, 21),
                setup: { s in s = W.base(); s.items.removeAll { $0.id == W.quiz } },
                turns: ["data quiz monday, need to do 6.1-6.3 lessons, about 2h total studying",
                        "use my schedule for when i give assignments, you already have data period time so thats when it is, which also gives me time durinf spare period and lunch if i need it"],
                reference: [[BoxOp(.task, .add, BoxFields(title: "Data quiz: lessons 6.1-6.3", topics: ["6.1", "6.2", "6.3"],
                                                          due: "2026-11-23 08:00", minutes: 120, kind: "quiz"))],
                            [BoxOp(.task, .change, ref: nil, BoxFields(due: "2026-11-23 13:26"))]],
                check: { s in
                    var e = Expect()
                    let q = s.items.filter { $0.title.lowercased().contains("quiz") && $0.isOpen }
                    e.that(q.count == 1, "one quiz task: \(q.map(\.title))")
                    e.that(q.first?.due == W.at(23, 13, 26), "due at Monday's Data period, 13:26: \(String(describing: q.first?.due))")
                    e.that((110...130).contains(q.first?.estimateMinutes ?? 0), "about 2h")
                    e.that(s.entries.filter { $0.title.lowercased().contains("spare") }.allSatisfy(\.open), "spares stay open time")
                    return e.fails
                }),

        V12Case(id: "spares-for-easy-work",
                why: "a standing preference: spares become open time and the easy tasks become light, not a per-task flag",
                now: W.at(18, 14, 23), setup: { $0 = W.base(openSpares: false) },
                turns: ["spare periods should be used for easy work, such as dayoneof review or reading etc"],
                reference: [[BoxOp(.entry, .change, ref: nil, BoxFields(open: true))]],   // filled per spare at run time
                check: { s in
                    var e = Expect()
                    let spares = s.entries.filter { $0.title.lowercased().contains("spare") }
                    e.that(!spares.isEmpty && spares.allSatisfy(\.open), "both spare series are open time")
                    e.that(s.items.filter { [W.dayoneof, W.frankenstein].contains($0.id) }.allSatisfy(\.isLight), "dayoneof and reading are light work")
                    e.that(s.items.first { $0.id == W.essay }?.isLight == false, "the essay isn't made light")
                    e.that(s.entries.filter { s.categories.isUnder($0.category, CategoryTree.school) }.count == 10, "the timetable is otherwise untouched")
                    return e.fails
                }),

        V12Case(id: "skip-calendar-event",
                why: "v1.1 refused (calendar is read-only); skipping one occurrence is allowed",
                now: W.at(18, 14, 24), setup: { $0 = W.base() },
                turns: ["no cs club meeting tomorrow"],
                reference: [[BoxOp(.entry, .skip, ref: EntryRef.entry(Entry.calendarId("cs-club")))]],
                check: { s in
                    var e = Expect()
                    let club = s.entries.first { $0.id == Entry.calendarId("cs-club") }
                    e.that(club?.marks[W.key(19)] == .skipped, "CS Club skipped on the 19th")
                    e.that(!W.on(19, s, now: W.at(18, 15)).contains { $0.title.contains("CS Club") }, "not on Thursday's day")
                    e.that(s.entries.filter { $0.marks.values.contains(.skipped) }.count == 1, "nothing else skipped")
                    return e.fails
                }),

        V12Case(id: "period-2-odd-date",
                why: "'period 2 tomorrow' has to be read off Thursday's (odd) timetable, then shortened",
                now: W.at(18, 14, 50), setup: { $0 = W.base() },
                turns: ["need to see mr barnhardt period 2 tomorrow in portable 8", "only 15 mins"],
                reference: [[BoxOp(.entry, .add, BoxFields(title: "See Mr Barnhardt, portable 8", start: "09:38", end: "10:58", day: "2026-11-19"))],
                            [BoxOp(.entry, .change, ref: nil, BoxFields(start: "09:38", end: "09:53", day: "2026-11-19"))]],
                check: { s in
                    var e = Expect()
                    let m = s.entries.filter { $0.title.lowercased().contains("barnhardt") }
                    e.that(m.count == 1, "one meeting: \(m.count)")
                    e.that(m.first.map { $0.start == W.at(19, 9, 38) && $0.minutes() == 15 } == true,
                           "Thu 19 9:38–9:53: \(m.map { "\($0.start) \($0.minutes())m" })")
                    e.that(s.entries.filter { $0.title.lowercased().contains("spare") && $0.repeats != nil }.count == 2, "the spare series is intact")
                    return e.fails
                }),

        V12Case(id: "period-2-even-date",
                why: "'period 2' means P2 itself (the spare); on even dates P1 and P2 swap, so it's 8:26, not 9:38",
                now: W.at(18, 14, 50), setup: { $0 = W.base() },
                turns: ["need to see mr barnhardt period 2 on friday in portable 8, only takes 15 mins"],
                reference: [[BoxOp(.entry, .add, BoxFields(title: "See Mr Barnhardt, portable 8", start: "08:26", end: "08:41", day: "2026-11-20"))]],
                check: { s in
                    var e = Expect()
                    let m = s.entries.filter { $0.title.lowercased().contains("barnhardt") }
                    e.that(m.count == 1 && W.cal.isDate(m[0].start, inSameDayAs: W.at(20, 12)), "one meeting on Fri 20")
                    e.that(m.allSatisfy { $0.start == W.at(20, 8, 26) && $0.minutes() == 15 },
                           "P2 (the spare) on an even date: 8:26–8:41: \(m.map { "\(W.hm($0.start)) \($0.minutes())m" })")
                    return e.fails
                }),

        V12Case(id: "log-walk-home",
                why: "'end of school to now' needs today's last period's end (even date: Data ends 14:46)",
                now: W.at(18, 15, 5), setup: { $0 = W.base() },
                turns: ["back home log my end of scholl to now as usual walk time"],
                reference: [[BoxOp(.entry, .add, BoxFields(title: "Walk home from school", start: "14:46", end: "15:05", category: "travel"))]],
                check: { s in
                    var e = Expect()
                    let w = s.entries.filter { s.categories.isUnder($0.category, CategoryTree.travel) }
                    e.that(w.count == 1, "one travel entry: \(w.map(\.title))")
                    e.that(w.first.map { abs($0.start.timeIntervalSince(W.at(18, 14, 46))) <= 120 && abs(($0.end ?? .distantPast).timeIntervalSince(W.at(18, 15, 5))) <= 120 } == true,
                           "14:46–15:05: \(w.map { "\(W.hm($0.start))–\($0.end.map(W.hm) ?? "running")" })")
                    return e.fails
                }),

        V12Case(id: "start-then-done",
                why: "v1.1 logged a start marker and never ended it; done has to stop the task's running entry",
                now: W.at(18, 15, 7), setup: { $0 = W.base() },
                turns: ["starting dayoneof review", "done dayoneof review"],
                reference: [[BoxOp(.task, .start, ref: W.ref(W.dayoneof))], [BoxOp(.task, .done, ref: W.ref(W.dayoneof))]],
                check: { s in
                    var e = Expect()
                    let es = s.entries.filter { $0.taskId == W.dayoneof }
                    e.that(es.count == 1, "one entry for the task: \(es.count)")
                    e.that(es.first?.end != nil, "it's stopped")
                    e.that(s.items.first { $0.id == W.dayoneof }?.isDone == true, "the task is done")
                    return e.fails
                }),

        V12Case(id: "finished-just-now",
                why: "the past entry's end has to move to now; v1.1 said there was nothing to change",
                now: W.at(18, 16, 12),
                setup: { s in
                    s = W.base()
                    s.entries.append(Entry(title: "Dayoneof video reviews", start: W.at(18, 15, 7), end: W.at(18, 15, 57),
                                           category: CategoryTree.studying, taskId: W.dayoneof, source: .you, createdAt: W.at(18, 15, 7)))
                    let i = s.items.firstIndex { $0.id == W.dayoneof }!
                    s.items[i].isDone = true
                    s.items[i].doneAt = W.at(18, 15, 57)
                },
                turns: ["actually i just finished the dayoneof work just now"],
                reference: [[BoxOp(.entry, .change, ref: nil, BoxFields(end: "16:12"))]],
                check: { s in
                    var e = Expect()
                    let es = s.entries.filter { $0.taskId == W.dayoneof || $0.title.lowercased().contains("dayoneof") }
                    e.that(es.count == 1, "still one entry: \(es.count)")
                    e.that(es.first.flatMap(\.end).map { abs($0.timeIntervalSince(W.at(18, 16, 12))) <= 60 } == true,
                           "ends 16:12: \(es.map { $0.end.map(W.hm) ?? "running" })")
                    e.that(es.first?.start == W.at(18, 15, 7), "start unchanged")
                    return e.fails
                }),

        V12Case(id: "didnt-do-assumed-plan",
                why: "Valorant was said ahead, so it's assumed; 'didn't do it' must remove it from the past, not the brag sheet",
                now: W.at(18, 23, 59),
                setup: { s in
                    s = W.base()
                    let i = s.entries.firstIndex { $0.title.hasPrefix("Valorant") }!
                    s.entries[i].end = W.at(18, 21, 59)
                    s.entries.append(Entry(title: "Make brag sheet for physics teacher rec", start: W.at(18, 21, 59), end: W.at(18, 23, 56),
                                           category: CategoryTree.studying, taskId: W.brag, source: .you, createdAt: W.at(18, 21, 59)))
                },
                turns: ["didn’t do valorant today"],
                reference: [[BoxOp(.entry, .skip, ref: nil)]],
                check: { s in
                    var e = Expect()
                    let day = TimeLog.past(s.entries, in: Days.dayInterval(W.at(18, 12), W.cal), now: W.at(18, 23, 59), calendar: W.cal)
                    e.that(!day.contains { $0.entry?.title.lowercased().contains("valorant") == true }, "no Valorant in today's log")
                    e.that(day.contains { $0.entry?.taskId == W.brag && $0.minutes == 117 }, "the brag sheet 21:59–23:56 is untouched")
                    return e.fails
                }),

        V12Case(id: "move-tonights-tasks",
                why: "'my other tasks' = only the ones due tonight; due dates move (not-before alone would be after the due)",
                now: W.at(18, 23, 56),
                setup: { s in
                    s = W.base()
                    s.entries.append(Entry(title: "Make brag sheet for physics teacher rec", start: W.at(18, 21, 59), end: nil,
                                           category: CategoryTree.studying, taskId: W.brag, source: .you, createdAt: W.at(18, 21, 59)))
                },
                turns: ["brag sheet can be due tomorrow and move my other tasks to tomorrow"],
                reference: [[BoxOp(.task, .change, ref: W.ref(W.brag), BoxFields(due: "2026-11-19 23:59")),
                             BoxOp(.task, .change, ref: W.ref(W.essay), BoxFields(due: "2026-11-19 23:59")),
                             BoxOp(.task, .change, ref: W.ref(W.dayoneof), BoxFields(due: "2026-11-19 23:59"))]],
                check: { s in
                    var e = Expect()
                    func t(_ id: UUID) -> WorkItem? { s.items.first { $0.id == id } }
                    for id in [W.brag, W.essay, W.dayoneof] {
                        e.that(t(id).map { W.cal.isDate($0.due, inSameDayAs: W.at(19, 12)) && $0.isOpen } == true,
                               "\(t(id)?.title ?? "?") due tomorrow and still open: \(String(describing: t(id)?.due))")
                    }
                    e.that(t(W.frankenstein)?.due == W.at(24, 23, 59) && t(W.quiz)?.due == W.at(23, 13, 26) && t(W.bibliography)?.due == W.at(23, 23, 59),
                           "tasks due later are untouched")
                    return e.fails
                }),

        V12Case(id: "presentation-breakdown",
                why: "one deadline into ordered steps, reusing the existing reading task instead of adding another",
                now: W.at(18, 14, 18), setup: { s in s = W.base(); s.items.removeAll { $0.id == W.bibliography } },
                turns: ["english presentation on 25th, need to finish reading frankenstejn (currently on pg30), create annotated bibliography eith research, create predentstion, practice it"],
                reference: [[BoxOp(.task, .add, BoxFields(title: "Annotated bibliography with research", due: "2026-11-22 23:59", minutes: 120)),
                             BoxOp(.task, .add, BoxFields(title: "Create English presentation", due: "2026-11-23 23:59", minutes: 120)),
                             BoxOp(.task, .add, BoxFields(title: "Practice English presentation", due: "2026-11-24 23:59", minutes: 60))]],
                check: { s in
                    var e = Expect()
                    e.that(s.items.filter { $0.title.lowercased().contains("frankenstein") }.count == 1, "the reading task is reused, not duplicated")
                    func find(_ w: String) -> WorkItem? { s.items.first { $0.title.lowercased().contains(w) && $0.id != W.frankenstein } }
                    let bib = find("bibliograph"), make = s.items.first { $0.title.lowercased().contains("presentation") && !$0.title.lowercased().contains("practi") }
                    let practice = s.items.first { $0.title.lowercased().contains("practi") && $0.title.lowercased().contains("present") }
                    e.that(bib != nil && make != nil && practice != nil, "bibliography, presentation and practice tasks: \(s.items.map(\.title))")
                    let end = W.at(25, 23, 59)
                    e.that([bib, make, practice].compactMap { $0 }.allSatisfy { $0.due <= end }, "all due by the 25th")
                    if let make, let practice { e.that(practice.due >= make.due, "practice comes after making it") }
                    return e.fails
                }),
    ]

    /// Reference answers that need refs only known once the world exists.
    static func referenceOps(_ c: V12Case, turn: Int, _ s: BoxState) -> [BoxOp] {
        if let f = c.referenceFor { return f(turn, s) }
        var ops = c.reference[turn]
        switch c.id {
        case "quiz-due-at-its-class" where turn == 1:
            ops[0].ref = Ref.task(s.items.first { $0.title.contains("quiz") }!.id)
        case "spares-for-easy-work":
            ops = s.entries.filter { $0.title.lowercased().contains("spare") }.map { BoxOp(.entry, .change, ref: EntryRef.entry($0.id), BoxFields(open: true)) }
        case "period-2-odd-date" where turn == 1, "finished-just-now", "didnt-do-assumed-plan":
            let title = c.id == "didnt-do-assumed-plan" ? "Valorant" : c.id == "finished-just-now" ? "Dayoneof" : "See Mr"
            ops[0].ref = EntryRef.entry(s.entries.first { $0.title.hasPrefix(title) }!.id)
        default: break
        }
        return ops
    }

    /// Sends a request to the claude-server (CS_URL, CS_KEY), like the v1.1 harness.
    static func send(_ req: AIRequest) async throws -> AIResponse {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["CS_URL"].flatMap(URL.init(string:)), let key = env["CS_KEY"] else {
            throw NSError(domain: "eval", code: 1, userInfo: [NSLocalizedDescriptionKey: "set CS_URL and CS_KEY (run.sh does)"])
        }
        var r = URLRequest(url: base.appendingPathComponent("v1/messages"))
        r.httpMethod = "POST"
        r.setValue(key, forHTTPHeaderField: "x-api-key")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.timeoutInterval = 300
        r.httpBody = try JSONEncoder().encode(req)
        let (d, resp) = try await URLSession.shared.data(for: r)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw NSError(domain: "eval", code: status, userInfo: [NSLocalizedDescriptionKey: String(data: d, encoding: .utf8) ?? "HTTP \(status)"])
        }
        return try JSONDecoder().decode(AIResponse.self, from: d)
    }

    /// Runs every case (or the ones whose id contains `only`): with reference answers, with no ops, or on the model.
    static func run(reference: Bool, nothing: Bool = false, only: String? = nil, verbose: Bool = false) async -> Bool {
        var passed = 0, total = 0, tokensOut = 0
        for c in cases where only.map({ c.id.contains($0) }) ?? true {
            total += 1
            var s = BoxState()
            c.setup(&s)
            var convo = Conversation(startedAt: c.now)
            var problems: [String] = [], transcript: [String] = []
            var allOps: [BoxOp] = [], lastReply = reference ? c.referenceReply : ""
            for (i, text) in c.turns.enumerated() {
                let at = c.now.addingTimeInterval(Double(i) * 20)
                let ops: [BoxOp]
                var result: BoxResult?, response: AIResponse?, context = "", content: JSONValue = .null
                if nothing {
                    ops = []
                } else if reference {
                    ops = referenceOps(c, turn: i, s)
                } else {
                    let planned = PlanEntries.from(World.plan(s, now: at), items: s.items, now: at)
                    var input = BoxContextInput(now: at, calendar: World.cal, state: s, planned: planned, settings: World.settings)
                    input.trackRecord = c.trackRecord
                    context = BoxContext.make(input)
                    if ProcessInfo.processInfo.environment["V12_CTX"] != nil { print("----- context, turn \(i + 1)\n" + context) }
                    let (req, userContent) = BoxTurn.request(convo, context: context, text: text)
                    content = userContent
                    do {
                        let res = try await send(req)
                        guard let r = BoxResult.read(res, timeZone: World.cal.timeZone) else {
                            problems.append("turn \(i + 1): unreadable answer: \(res.text.prefix(300))")
                            break
                        }
                        tokensOut += res.tokens.output
                        result = r
                        response = res
                    } catch {
                        problems.append("turn \(i + 1): \(error.localizedDescription.prefix(300))")
                        break
                    }
                    ops = result!.ops
                    if !result!.unreadable.isEmpty { problems.append("turn \(i + 1): unreadable ops \(result!.unreadable)") }
                }
                allOps += ops
                s.planned = PlanEntries.from(World.plan(s, now: at), items: s.items, now: at)
                let r = BoxApplier.apply(BoxSideOps.split(ops).box, to: &s, now: at, calendar: World.cal)
                if let result { lastReply = result.reply }
                if let result, let response {
                    // What was really applied, so the next turn starts with it.
                    BoxTurn.record(&convo, at: at, text: text, content: content, response: response, result: result, receipt: r,
                                   context: context)
                    transcript.append("   turn \(i + 1) “\(text.prefix(60))”\n     ops: \((try? String(data: JSONEncoder().encode(ops), encoding: .utf8)!) ?? "")\n     reply: \(result.reply)\(result.gap.map { "\n     gap: " + $0 } ?? "")\n     applied: \(r.lines.joined(separator: " | "))")
                }
                problems += r.problems.map { "turn \(i + 1): \($0)" }
                if !r.held.isEmpty { problems.append("turn \(i + 1) held: \(r.held.map(\.why))") }
            }
            let fails = problems + c.check(s) + c.replyCheck(lastReply, allOps)
            print(fails.isEmpty ? "PASS" : "FAIL", c.id, fails.isEmpty ? "" : "\n   " + fails.joined(separator: "\n   "))
            if !fails.isEmpty || verbose { transcript.forEach { print($0) } }
            if fails.isEmpty { passed += 1 }
        }
        print("\(passed)/\(total) passed" + (tokensOut > 0 ? ", \(tokensOut) output tokens" : ""))
        return nothing ? passed == 0 : passed == total
    }
}
