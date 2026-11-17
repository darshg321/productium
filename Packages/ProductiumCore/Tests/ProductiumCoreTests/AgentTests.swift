import XCTest
@testable import ProductiumCore

/// The Inbox as an agent: it sees ids, changes things by id, and never doubles anything up.
final class AgentTests: XCTestCase {
    let cal = Fx.cal

    func state(items: [WorkItem] = [], commitments: [Commitment] = [Fx.school, Fx.soccer]) -> DumpState {
        DumpState(items: items, commitments: commitments, exceptions: [], oneOffs: [], markers: [],
                  routines: Routine.defaults, moods: [], screen: [], prefs: Preferences())
    }

    func act(_ type: String, _ f: (inout DumpAction) -> Void = { _ in }) -> DumpAction {
        var a = DumpAction(type: type); f(&a); return a
    }

    @discardableResult
    func run(_ s: inout DumpState, _ actions: [DumpAction], now: Date? = nil) -> DumpReport {
        DumpApplier.apply(DumpResult(actions: actions, reply: ""), to: &s, now: now ?? Fx.mon(12), calendar: cal)
    }

    let periods = [
        DumpPart(title: "Period 1", start: "8:30", end: "9:20"), DumpPart(title: "Period 2", start: "9:25", end: "10:15"),
        DumpPart(title: "Period 3", start: "10:30", end: "11:20"), DumpPart(title: "Lunch", start: "11:20", end: "12:00"),
        DumpPart(title: "Period 4", start: "12:00", end: "12:50"), DumpPart(title: "Period 5", start: "12:55", end: "15:00"),
    ]

    func testSplitSchoolIntoPeriodsThenAdjustWithoutDuplicates() {
        var s = state()
        let school = Ref.activity(Fx.school.id)
        let r = run(&s, [act("split_activity") { $0.id = school; $0.parts = self.periods }])
        XCTAssertEqual(r.problems, [])
        XCTAssertFalse(s.commitments.contains { $0.id == Fx.school.id }, "the original goes when every day is covered")
        let parts = s.commitments.filter { $0.kind == .school }
        XCTAssertEqual(parts.count, 6)
        XCTAssertTrue(parts.allSatisfy { $0.weekdays == Fx.school.weekdays })

        // Adjust one period by id, as the context shows it.
        let p3 = parts.first { $0.title == "Period 3" }!
        run(&s, [act("update_activity") { $0.id = Ref.activity(p3.id); $0.start = "10:35"; $0.end = "11:25" }])
        XCTAssertEqual(s.commitments.first { $0.id == p3.id }?.start, TimeOfDay(10, 35))

        // The model forgets and adds a period again, or splits again: still six, not twelve.
        run(&s, [act("add_activity") { $0.title = "Period 2"; $0.kind = "school"; $0.weekdays = [2, 3, 4, 5, 6]
            $0.start = "09:30"; $0.end = "10:20" }])
        XCTAssertEqual(s.commitments.filter { $0.kind == .school }.count, 6)
        XCTAssertEqual(s.commitments.first { $0.title == "Period 2" }?.start, TimeOfDay(9, 30))

        // The planner sees one block per period, and the commute still hangs off the first and last.
        let plan = Planner.plan(PlannerInput(now: Fx.mon(6), calendar: cal, items: [], commitments: s.commitments,
                                             routines: s.routines))
        let today = plan.blocks.filter { $0.kind == .commitment && self.cal.isDate($0.start, inSameDayAs: Fx.mon(12)) }
        XCTAssertEqual(today.filter { $0.title.hasPrefix("Period") || $0.title == "Lunch" }.count, 6)
        XCTAssertEqual(plan.blocks.first { $0.title == "Home from school" && self.cal.isDate($0.start, inSameDayAs: Fx.mon(12)) }?.start,
                       Fx.mon(15))
    }

    func testSplittingOneDayKeepsTheOthers() {
        var s = state()
        run(&s, [act("split_activity") { $0.id = Ref.activity(Fx.school.id)
            $0.parts = [DumpPart(title: "Assembly", start: "8:30", end: "9:30", weekdays: [2]),
                        DumpPart(title: "Classes", start: "9:30", end: "15:00", weekdays: [2])] }])
        XCTAssertEqual(s.commitments.first { $0.id == Fx.school.id }?.weekdays, [3, 4, 5, 6])
        XCTAssertEqual(s.commitments.filter { $0.kind == .school }.count, 3)
    }

    func testCancelledDayFollowsTheParts() {
        var s = state()
        s.exceptions = [DayException(day: Fx.mon(0, plusDays: 1), commitmentId: Fx.school.id, cancelled: true)]
        run(&s, [act("split_activity") { $0.id = Ref.activity(Fx.school.id); $0.parts = Array(self.periods.prefix(2)) }])
        XCTAssertEqual(s.exceptions.count, 2)
        XCTAssertTrue(s.exceptions.allSatisfy(\.cancelled))
    }

    func testIdsBeatFuzzyNames() {
        let a = WorkItem(title: "Math homework 1", kind: .assignment, due: Fx.mon(23, plusDays: 1))
        let b = WorkItem(title: "Math homework 10", kind: .assignment, due: Fx.mon(23, plusDays: 2))
        var s = state(items: [a, b])
        run(&s, [act("complete_task") { $0.id = Ref.task(b.id) }, act("update_task") { $0.id = String(Ref.task(a.id).dropFirst()); $0.estimateMinutes = 90 }])
        XCTAssertTrue(s.items[1].isDone)
        XCTAssertFalse(s.items[0].isDone)
        XCTAssertEqual(s.items[0].estimateMinutes, 90, "a ref without its letter still works")
        // In `target` too, and full UUIDs.
        run(&s, [act("reopen_task") { $0.target = Ref.task(b.id) }, act("update_task") { $0.id = a.id.uuidString; $0.notes = "odd ones" }])
        XCTAssertFalse(s.items[1].isDone)
        XCTAssertEqual(s.items[0].notes, "odd ones")
        let r = run(&s, [act("delete_task") { $0.id = "tffffff" }])
        XCTAssertEqual(s.items.count, 2)
        XCTAssertEqual(r.problems.count, 1)
    }

    func testColours() {
        let essay = WorkItem(title: "Gatsby essay", kind: .essay, subject: "English", due: Fx.mon(23, plusDays: 5))
        let math = WorkItem(title: "Calc set", kind: .assignment, subject: "Math", due: Fx.mon(23, plusDays: 3))
        var s = state(items: [essay, math])
        let r = run(&s, [
            act("set_color") { $0.category = "free time"; $0.color = "green" },
            act("set_color") { $0.id = Ref.activity(Fx.soccer.id); $0.color = "Light Blue" },
            act("set_color") { $0.category = "subject:Math"; $0.color = "#FF8800" },
            act("set_color") { $0.id = Ref.task(essay.id); $0.color = "purple" },
            act("set_color") { $0.category = "school"; $0.color = "teal" },
            act("set_color") { $0.category = "sleep"; $0.color = "sparkly" },
            act("update_activity") { $0.target = "school"; $0.color = "default" },
        ])
        XCTAssertEqual(r.problems.count, 1, "an unknown colour is reported")
        XCTAssertEqual(s.prefs.colors, ["free": "green", "subject:math": "#ff8800", "school": "teal"])
        XCTAssertEqual(s.commitments[1].color, "cyan")
        XCTAssertEqual(s.items[0].color, "purple")

        let plan = Planner.plan(PlannerInput(now: Fx.mon(6), calendar: cal, items: s.items, commitments: s.commitments,
                                             preferences: s.prefs, routines: s.routines))
        XCTAssertTrue(plan.blocks.filter { $0.title == "School" }.allSatisfy { $0.color == "teal" }, "kind colour")
        XCTAssertTrue(plan.blocks.filter { $0.title == "Soccer practice" }.allSatisfy { $0.color == "cyan" }, "own colour")
        XCTAssertTrue(plan.blocks.filter { $0.kind == .free }.allSatisfy { $0.color == "green" })
        XCTAssertTrue(plan.blocks.filter { $0.itemId == essay.id }.allSatisfy { $0.color == "purple" })
        XCTAssertTrue(plan.blocks.filter { $0.itemId == math.id }.allSatisfy { $0.color == "#ff8800" }, "subject colour")
        XCTAssertFalse(plan.blocks.filter { $0.itemId == math.id }.isEmpty)
        XCTAssertTrue(plan.blocks.filter { $0.kind == .sleep }.allSatisfy { $0.color == nil })

        XCTAssertEqual(Palette.normalise("Grey"), "gray")
        XCTAssertNil(Palette.normalise("#12345"))
        XCTAssertEqual(Palette.category("Breaks"), "break")
        XCTAssertEqual(Palette.category("tests"), "task:test")
        XCTAssertEqual(Palette.category("wind-down"), "wind_down")
    }

    func testEveryNamedSetting() {
        var s = state()
        let r = run(&s, [
            act("settings") { $0.key = "dinner"; $0.value = "19:15" },
            act("settings") { $0.key = "focus_block_minutes"; $0.value = "50" },
            act("settings") { $0.key = "schoolDays"; $0.value = "2,3,4,5" },
            act("settings") { $0.key = "nudgeLevel"; $0.value = "gentle" },
            act("settings") { $0.key = "sleepNeedMinutes"; $0.value = "7h" },
            act("settings") { $0.key = "freeDayWake"; $0.value = "9:30am" },
            act("settings") { $0.key = "chronotype"; $0.value = "sometimes" },
            act("settings") { $0.key = "warpDrive"; $0.value = "on" },
        ])
        XCTAssertEqual(s.prefs.dinner, TimeOfDay(19, 15))
        XCTAssertEqual(s.prefs.focusBlockMinutes, 50)
        XCTAssertEqual(s.prefs.schoolDays, [2, 3, 4, 5])
        XCTAssertEqual(s.prefs.nudges.level, .gentle)
        XCTAssertEqual(s.prefs.sleepNeedMinutes, 450, "7h asked, the floor holds")
        XCTAssertEqual(s.prefs.freeDayWake, TimeOfDay(9, 30))
        XCTAssertEqual(r.problems.count, 2)
        run(&s, [act("settings") { $0.key = "dinner"; $0.value = "none" }])
        XCTAssertNil(s.prefs.dinner)
    }

    func testEventsDayChangesRoutines() {
        var s = state()
        run(&s, [act("add_event") { $0.title = "Dentist"; $0.date = "2026-11-18"; $0.start = "16:00"; $0.end = "17:00" },
                 act("add_event") { $0.title = "dentist"; $0.date = "2026-11-18"; $0.start = "16:30"; $0.end = "17:30" }])
        XCTAssertEqual(s.oneOffs.count, 1, "the same event twice is a move")
        XCTAssertEqual(s.oneOffs[0].start, Fx.mon(16, 30, plusDays: 2))
        run(&s, [act("update_event") { $0.id = Ref.event(s.oneOffs[0].id); $0.date = "2026-11-19" }])
        XCTAssertEqual(s.oneOffs[0].start, Fx.mon(16, 30, plusDays: 3))
        XCTAssertEqual(s.oneOffs[0].end, Fx.mon(17, 30, plusDays: 3))
        run(&s, [act("delete_event") { $0.target = "dentist" }])
        XCTAssertTrue(s.oneOffs.isEmpty)

        run(&s, [act("change_day") { $0.id = Ref.activity(Fx.soccer.id); $0.date = "2026-11-18"; $0.cancelled = true }])
        XCTAssertEqual(s.exceptions.first?.commitmentId, Fx.soccer.id)
        run(&s, [act("change_day") { $0.id = Ref.dayChange(s.exceptions[0].id); $0.cancelled = false; $0.start = "17:00" }])
        XCTAssertEqual(s.exceptions.count, 1)
        XCTAssertEqual(s.exceptions[0].start, TimeOfDay(17))
        run(&s, [act("delete_day_change") { $0.id = Ref.dayChange(s.exceptions[0].id) }])
        XCTAssertTrue(s.exceptions.isEmpty)

        run(&s, [act("routine") { $0.routine = "get_ready"; $0.enabled = false }])
        XCTAssertEqual(s.routines.first { $0.id == "get_ready" }?.enabled, false)
    }

    func testStepsAndSameTaskTwice() {
        let project = WorkItem(title: "Science fair", kind: .project, due: Fx.mon(23, plusDays: 20))
        var s = state(items: [project])
        run(&s, [act("add_task") { $0.title = "Pick a question"; $0.due = "2026-12-30"; $0.parent = Ref.task(project.id) },
                 act("add_task") { $0.title = "Pick a question"; $0.due = "2026-11-18"; $0.parent = Ref.task(project.id) }])
        let steps = s.items.filter { $0.parentId == project.id }
        XCTAssertEqual(steps.count, 1)
        XCTAssertEqual(steps[0].due, Fx.mon(23, 59, plusDays: 2), "the second is an update, and a step can't be due after its project")
        run(&s, [act("complete_task") { $0.id = Ref.task(steps[0].id) }])
        XCTAssertTrue(s.items.first { $0.id == project.id }!.isDone, "the last step finishes the project")
    }

    func testContextShowsEverythingByReference() {
        var s = state(items: [WorkItem(title: "Bio quiz", kind: .quiz, subject: "Bio", due: Fx.mon(8, plusDays: 2), color: "pink")])
        s.oneOffs = [FixedEvent(id: UUID().uuidString, title: "Dentist", start: Fx.mon(16, plusDays: 1), end: Fx.mon(17, plusDays: 1))]
        s.exceptions = [DayException(day: Fx.mon(0, plusDays: 4), kind: .school, cancelled: true)]
        s.prefs.colors = ["free": "green"]
        let plan = Planner.plan(PlannerInput(now: Fx.mon(12), calendar: cal, items: s.items, commitments: s.commitments,
                                             events: s.oneOffs, preferences: s.prefs, routines: s.routines, exceptions: s.exceptions))
        let ctx = Prompts.dumpContext(DumpContextInput(now: Fx.mon(12), calendar: cal, state: s,
                                                       calendarEvents: [FixedEvent(id: "EK:1", title: "Grandma", start: Fx.mon(18), end: Fx.mon(20))],
                                                       plan: plan, warnings: plan.warnings))
        for needle in [Ref.activity(Fx.school.id), Ref.activity(Fx.soccer.id), Ref.task(s.items[0].id), Ref.event(s.oneOffs[0].id),
                       Ref.dayChange(s.exceptions[0].id), "color pink", "Colours set: free green", "dinner 18:30",
                       "Calendar (read-only): Grandma", "Plan today:", "Plan tomorrow:", "all school cancelled"] {
            XCTAssertTrue(ctx.contains(needle), "context is missing \(needle)\n\(ctx)")
        }
        XCTAssertTrue(Prompts.dump().contains("split_activity"))
        XCTAssertEqual(Ref.event("EK:1"), Ref.event("EK:1"), "stable for non-UUID ids")
    }

    func testLooseNamesForNewActions() {
        let names: [String: DumpActionType] = [
            "split_school": .splitActivity, "divide_activity": .splitActivity, "change_colour": .setColor, "setColor": .setColor,
            "remove_event": .deleteEvent, "move_event": .updateEvent, "clear_day_change": .deleteDayChange,
            "uncomplete_task": .reopenTask, "mark_undone": .reopenTask,
        ]
        for (raw, want) in names { XCTAssertEqual(DumpActionType(loose: raw), want, raw) }
    }
}
