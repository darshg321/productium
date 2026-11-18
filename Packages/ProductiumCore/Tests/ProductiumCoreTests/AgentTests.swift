import XCTest
@testable import ProductiumCore

final class AgentTests: XCTestCase {
    let cal = Fx.cal

    func state(items: [WorkItem] = [], commitments: [Commitment] = [Fx.school, Fx.soccer]) -> DumpState {
        DumpState(items: items, commitments: commitments, exceptions: [], oneOffs: [], markers: [],
                  routines: Routine.defaults, moods: [], screen: [], prefs: Preferences())
    }

    @discardableResult
    func run(_ s: inout DumpState, _ ops: [DumpOp], now: Date? = nil, writer: Writer = .box) -> DumpReport {
        DumpApplier.apply(DumpResult(ops: ops, reply: ""), to: &s, now: now ?? Fx.mon(12), calendar: cal, writer: writer)
    }

    func split(_ id: String, _ parts: [DumpPart]) -> DumpOp {
        DumpOp("split", entity: "activity", id: id,
               fields: ["parts": .array(parts.map { p in
                   var o: [String: JSONValue] = ["title": .string(p.title), "start": .string(p.start), "end": .string(p.end)]
                   if let w = p.weekdays { o["weekdays"] = .array(w.map { .number(Double($0)) }) }
                   return .object(o)
               })])
    }

    let periods = [
        DumpPart(title: "Period 1", start: "8:30", end: "9:20"), DumpPart(title: "Period 2", start: "9:25", end: "10:15"),
        DumpPart(title: "Period 3", start: "10:30", end: "11:20"), DumpPart(title: "Lunch", start: "11:20", end: "12:00"),
        DumpPart(title: "Period 4", start: "12:00", end: "12:50"), DumpPart(title: "Period 5", start: "12:55", end: "15:00"),
    ]

    func testSplitSchoolIntoPeriodsThenAdjustWithoutDuplicates() {
        var s = state()
        let school = Ref.activity(Fx.school.id)
        let r = run(&s, [split(school, periods)])
        XCTAssertEqual(r.problems, [])
        XCTAssertFalse(s.commitments.contains { $0.id == Fx.school.id }, "the original goes when every day is covered")
        let parts = s.commitments.filter { $0.kind == .school }
        XCTAssertEqual(parts.count, 6)
        XCTAssertTrue(parts.allSatisfy { $0.weekdays == Fx.school.weekdays })

        let p3 = parts.first { $0.title == "Period 3" }!
        run(&s, [.upsert("activity", id: Ref.activity(p3.id), ["start": "10:35", "end": "11:25"])])
        XCTAssertEqual(s.commitments.first { $0.id == p3.id }?.start, TimeOfDay(10, 35))

        run(&s, [.upsert("activity", ["title": "Period 2", "kind": "school", "weekdays": [2, 3, 4, 5, 6],
                                      "start": "09:30", "end": "10:20"])])
        XCTAssertEqual(s.commitments.filter { $0.kind == .school }.count, 6)
        XCTAssertEqual(s.commitments.first { $0.title == "Period 2" }?.start, TimeOfDay(9, 30))

        let plan = Planner.plan(PlannerInput(now: Fx.mon(6), calendar: cal, items: [], commitments: s.commitments,
                                             routines: s.routines))
        let today = plan.blocks.filter { $0.kind == .commitment && self.cal.isDate($0.start, inSameDayAs: Fx.mon(12)) }
        XCTAssertEqual(today.filter { $0.title.hasPrefix("Period") || $0.title == "Lunch" }.count, 6)
        XCTAssertEqual(plan.blocks.first { $0.title == "Home from school" && self.cal.isDate($0.start, inSameDayAs: Fx.mon(12)) }?.start,
                       Fx.mon(15))
    }

    func testSplittingOneDayKeepsTheOthers() {
        var s = state()
        run(&s, [split(Ref.activity(Fx.school.id), [DumpPart(title: "Assembly", start: "8:30", end: "9:30", weekdays: [2]),
                                                    DumpPart(title: "Classes", start: "9:30", end: "15:00", weekdays: [2])])])
        XCTAssertEqual(s.commitments.first { $0.id == Fx.school.id }?.weekdays, [3, 4, 5, 6])
        XCTAssertEqual(s.commitments.filter { $0.kind == .school }.count, 3)
    }

    func testCancelledDayFollowsTheParts() {
        var s = state()
        s.exceptions = [DayException(day: Fx.mon(0, plusDays: 1), commitmentId: Fx.school.id, cancelled: true)]
        run(&s, [split(Ref.activity(Fx.school.id), Array(periods.prefix(2)))])
        XCTAssertEqual(s.exceptions.count, 2)
        XCTAssertTrue(s.exceptions.allSatisfy(\.cancelled))
    }

    func testIdsBeatFuzzyNames() {
        let a = WorkItem(title: "Math homework 1", kind: .assignment, due: Fx.mon(23, plusDays: 1))
        let b = WorkItem(title: "Math homework 10", kind: .assignment, due: Fx.mon(23, plusDays: 2))
        var s = state(items: [a, b])
        run(&s, [.upsert("task", id: Ref.task(b.id), ["done": true]),
                 .upsert("task", id: String(Ref.task(a.id).dropFirst()), ["estimateMinutes": 90])])
        XCTAssertTrue(s.items[1].isDone)
        XCTAssertFalse(s.items[0].isDone)
        XCTAssertEqual(s.items[0].estimateMinutes, 90, "a ref without its letter still works")
        run(&s, [.upsert("task", ["target": .string(Ref.task(b.id)), "done": false]),
                 .upsert("task", id: a.id.uuidString, ["notes": "odd ones"])])
        XCTAssertFalse(s.items[1].isDone)
        XCTAssertEqual(s.items[0].notes, "odd ones")
        let r = run(&s, [.delete("task", id: "tffffff")])
        XCTAssertEqual(s.items.count, 2)
        XCTAssertEqual(r.problems.count, 1)
    }

    func testColours() {
        let essay = WorkItem(title: "Gatsby essay", kind: .essay, subject: "English", due: Fx.mon(23, plusDays: 5))
        let math = WorkItem(title: "Calc set", kind: .assignment, subject: "Math", due: Fx.mon(23, plusDays: 3))
        var s = state(items: [essay, math])
        let r = run(&s, [
            .set("color.free time", "green"),
            .upsert("activity", id: Ref.activity(Fx.soccer.id), ["color": "Light Blue"]),
            .set("color.subject:Math", "#FF8800"),
            .upsert("task", id: Ref.task(essay.id), ["color": "purple"]),
            .set("colour.school", "teal"),
            .set("color.sleep", "sparkly"),
            .upsert("activity", ["target": "school", "color": "default"]),
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

    func testEveryNamedKnob() {
        var s = state()
        let r = run(&s, [
            .set("dinnerTime", "19:15"),
            .set("study.focusMinutes", "50"),
            .set("schoolDays", "2,3,4,5"),
            .set("nudgeLevel", "gentle"),
            .set("sleepNeedMinutes", "7h"),
            .set("freeDayWake", "9:30am"),
            .set("sleep.chronotype", "sometimes"),
            .set("warpDrive", "on"),
        ])
        XCTAssertEqual(s.beliefs.minutes("routines.dinnerTime"), 19 * 60 + 15)
        XCTAssertEqual(s.beliefs["routines.dinnerTime"]?.confidence, .stated)
        XCTAssertEqual(s.beliefs.minutes("study.focusMinutes"), 50)
        XCTAssertEqual(s.prefs.schoolDays, [2, 3, 4, 5])
        XCTAssertEqual(s.prefs.nudges.level, .gentle)
        XCTAssertEqual(s.prefs.sleepNeedMinutes, 450, "7h asked, the floor holds")
        XCTAssertEqual(s.prefs.freeDayWake, TimeOfDay(9, 30))
        XCTAssertEqual(r.problems.count, 2)
        run(&s, [.set("routines.dinnerMinutes", "0")])
        XCTAssertEqual(s.beliefs.minutes("routines.dinnerMinutes"), 0, "no dinner block")
    }

    func testBehaviourKnobsAreRefusedFromTheBox() {
        var s = state()
        let r = run(&s, [.set("planner.maxBlockMinutes", "25"), .set("capacityMultiplier", "0.8")])
        XCTAssertEqual(s.policy, BehaviourPolicy())
        XCTAssertEqual(r.changes, [])
        XCTAssertEqual(r.problems.count, 2)
        XCTAssertTrue(r.problems[0].contains("Productium only adjusts it from how your weeks go"), r.problems[0])
        run(&s, [.set("planner.maxBlockMinutes", "25")], writer: .reflection)
        XCTAssertEqual(s.policy.maxBlockMinutes, 45, "55 → 25 asked, at most -10 per change")
        run(&s, [.set("planner.capacityMultiplier", "3")], writer: .reflection)
        XCTAssertEqual(s.policy.capacityMultiplier, 1.1, accuracy: 0.001)
        let forbidden = run(&s, [.set("sleepNeedMinutes", "450")], writer: .reflection)
        XCTAssertEqual(forbidden.problems.count, 1, "reflection never touches sleep need")
        XCTAssertFalse(Prompts.dump().contains("planner.capacityMultiplier"))
        s.policy.maxBlockMinutes = 25
        let essay = WorkItem(title: "Essay", kind: .essay, due: Fx.mon(23, plusDays: 6), estimateMinutes: 240)
        let plan = Planner.plan(PlannerInput(now: Fx.mon(6), calendar: cal, items: [essay], commitments: s.commitments,
                                             routines: s.routines, policy: s.policy))
        XCTAssertTrue(plan.blocks.filter { $0.itemId == essay.id }.allSatisfy { $0.minutes <= 25 },
                      "\(plan.blocks.filter { $0.itemId == essay.id }.map(\.minutes))")
        XCTAssertFalse(plan.blocks.filter { $0.itemId == essay.id }.isEmpty)
    }

    func testEventsDayChangesRoutines() {
        var s = state()
        run(&s, [.upsert("event", ["title": "Dentist", "date": "2026-11-18", "start": "16:00", "end": "17:00"]),
                 .upsert("event", ["title": "dentist", "date": "2026-11-18", "start": "16:30", "end": "17:30"])])
        XCTAssertEqual(s.oneOffs.count, 1, "the same event twice is a move")
        XCTAssertEqual(s.oneOffs[0].start, Fx.mon(16, 30, plusDays: 2))
        run(&s, [.upsert("event", id: Ref.event(s.oneOffs[0].id), ["date": "2026-11-19"])])
        XCTAssertEqual(s.oneOffs[0].start, Fx.mon(16, 30, plusDays: 3))
        XCTAssertEqual(s.oneOffs[0].end, Fx.mon(17, 30, plusDays: 3))
        run(&s, [DumpOp("delete", entity: "event", fields: ["target": "dentist"])])
        XCTAssertTrue(s.oneOffs.isEmpty)

        run(&s, [.upsert("day_change", ["activity": .string(Ref.activity(Fx.soccer.id)), "date": "2026-11-18", "cancelled": true])])
        XCTAssertEqual(s.exceptions.first?.commitmentId, Fx.soccer.id)
        run(&s, [.upsert("day_change", id: Ref.dayChange(s.exceptions[0].id), ["cancelled": false, "start": "17:00"])])
        XCTAssertEqual(s.exceptions.count, 1)
        XCTAssertEqual(s.exceptions[0].start, TimeOfDay(17))
        run(&s, [.delete("day_change", id: Ref.dayChange(s.exceptions[0].id))])
        XCTAssertTrue(s.exceptions.isEmpty)

        run(&s, [.upsert("routine", id: "get_ready", ["enabled": false])])
        XCTAssertEqual(s.routines.first { $0.id == "get_ready" }?.enabled, false)
    }

    func testStepsAndSameTaskTwice() {
        let project = WorkItem(title: "Science fair", kind: .project, due: Fx.mon(23, plusDays: 20))
        var s = state(items: [project])
        let parent = JSONValue.string(Ref.task(project.id))
        run(&s, [.upsert("task", ["title": "Pick a question", "due": "2026-12-30", "parent": parent]),
                 .upsert("task", ["title": "Pick a question", "due": "2026-11-18", "parent": parent])])
        let steps = s.items.filter { $0.parentId == project.id }
        XCTAssertEqual(steps.count, 1)
        XCTAssertEqual(steps[0].due, Fx.mon(23, 59, plusDays: 2), "the second is an update, and a step can't be due after its project")
        run(&s, [.upsert("task", id: Ref.task(steps[0].id), ["done": true])])
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
                       Ref.dayChange(s.exceptions[0].id), "color pink", "Colours set: free green", "routines.dinnerTime 18:30 assumed",
                       "Calendar (read-only): Grandma", "Plan today:", "Plan tomorrow:", "all school cancelled"] {
            XCTAssertTrue(ctx.contains(needle), "context is missing \(needle)\n\(ctx)")
        }
        XCTAssertTrue(Prompts.dump().contains("split (activity)"))
        XCTAssertEqual(Ref.event("EK:1"), Ref.event("EK:1"), "stable for non-UUID ids")
    }

    func testLooseOperationNames() {
        let names: [String: DumpOpKind] = ["create": .upsert, "Update": .upsert, "add": .upsert, "remove": .delete,
                                           "set": .set, "split_activity": .split, "SPLIT": .split]
        for (raw, want) in names { XCTAssertEqual(DumpOpKind(loose: raw), want, raw) }
        XCTAssertNil(DumpOpKind(loose: "fly_to_moon"))
        let essay = WorkItem(title: "Essay", kind: .essay, due: Fx.mon(23, plusDays: 5))
        var s = state(items: [essay])
        run(&s, [DumpOp("upsert", id: Ref.task(essay.id), fields: ["done": true])])
        XCTAssertTrue(s.items[0].isDone)
    }
}
