import XCTest
@testable import ProductiumCore

final class PlannerTests: XCTestCase {
    let cal = Fx.cal

    func testNoStudyDuringSchoolActivitiesOrSleep() {
        let essay = WorkItem(title: "History essay", kind: .essay, due: Fx.mon(23, 59, plusDays: 6), estimateMinutes: 240, importance: 4)
        let test = WorkItem(title: "Chem test", kind: .test, due: Fx.mon(9, 0, plusDays: 4), estimateMinutes: 150, importance: 4)
        let plan = Planner.plan(Fx.input(now: Fx.mon(7, 0), items: [essay, test]))
        let fixed = plan.blocks.filter { [.commitment, .sleep, .routine, .meal].contains($0.kind) }
        for b in plan.blocks where b.isStudy && !b.borrowsSleep {
            for f in fixed {
                XCTAssertFalse(b.start < f.end && f.start < b.end, "\(b.title) \(b.start) overlaps \(f.title) \(f.start)")
            }
        }
        XCTAssertTrue(plan.shortfalls.isEmpty, "\(plan.shortfalls)")
    }

    func testAllWorkScheduledBeforeDueWithPlanningFallacyBuffer() {
        let essay = WorkItem(title: "Essay", kind: .essay, due: Fx.mon(23, 59, plusDays: 6), estimateMinutes: 200, importance: 4)
        let plan = Planner.plan(Fx.input(now: Fx.mon(7, 0), items: [essay]))
        let corrected = Int((200 * LearnedModel.priorRatio).rounded())
        XCTAssertGreaterThanOrEqual(plan.minutes(for: essay.id), corrected)
        // > 240 min of work: target finish is 2 days early.
        let last = plan.study(for: essay.id).map(\.end).max()!
        XCTAssertLessThanOrEqual(last, cal.date(byAdding: .day, value: -2, to: essay.due)!)
    }

    func testTestPrepIsSpacedAcrossDaysNotCrammed() {
        let test = WorkItem(title: "Bio test", kind: .test, due: Fx.mon(9, 0, plusDays: 7), estimateMinutes: 180, importance: 4)
        let plan = Planner.plan(Fx.input(now: Fx.mon(7, 0), items: [test]))
        let days = Set(plan.study(for: test.id).map { cal.startOfDay(for: $0.start) })
        XCTAssertGreaterThanOrEqual(days.count, 3, "spaced over ≥3 days")
        // Something happens the day before the test.
        let dayBefore = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: test.due))!
        XCTAssertTrue(days.contains(dayBefore))
        XCTAssertTrue(plan.study(for: test.id).allSatisfy { $0.kind == .review && !$0.borrowsSleep })
    }

    func testLongTermWorkIsPacedNotBinged() {
        let app = WorkItem(title: "College essay", kind: .application, due: Fx.mon(23, 59, plusDays: 13), estimateMinutes: 480, importance: 5)
        let plan = Planner.plan(Fx.input(now: Fx.mon(7, 0), items: [app]))
        let perDay = Dictionary(grouping: plan.study(for: app.id), by: { cal.startOfDay(for: $0.start) })
        XCTAssertGreaterThanOrEqual(perDay.count, 5)
        XCTAssertLessThanOrEqual(perDay.values.map { $0.reduce(0) { $0 + $1.minutes } }.max()!, 130)
    }

    func testFreeTimeFloorIsKeptOnNormalDays() {
        let hw = (0..<4).map { i in WorkItem(title: "HW \(i)", kind: .assignment, due: Fx.mon(23, 59, plusDays: 3), estimateMinutes: 60) }
        let plan = Planner.plan(Fx.input(now: Fx.mon(7, 0), items: hw))
        let monday = plan.blocks(on: Fx.mon(12), calendar: cal)
        let free = monday.filter { $0.kind == .free || $0.kind == .gap }.reduce(0) { $0 + $1.minutes }
        XCTAssertGreaterThanOrEqual(free, Preferences().minFreeMinutesSchoolDay)
    }

    func testSleepNeverBorrowedForTests() {
        // Way more test prep than fits tonight.
        let test = WorkItem(title: "Physics final", kind: .test, due: Fx.mon(9, 0, plusDays: 1), estimateMinutes: 600, importance: 5)
        let plan = Planner.plan(Fx.input(now: Fx.mon(15, 30), items: [test]))
        XCTAssertEqual(plan.sleepTradeoffMinutes, 0)
        XCTAssertTrue(plan.study(for: test.id).allSatisfy { !$0.borrowsSleep })
        XCTAssertGreaterThan(plan.shortfalls[test.id] ?? 0, 0)
        XCTAssertTrue(plan.warnings.contains { $0.itemId == test.id })
    }

    func testSleepBorrowedOnlyForCriticalProductionAndCapped() {
        let essay = WorkItem(title: "Scholarship essay", kind: .application, due: Fx.mon(8, 0, plusDays: 1), estimateMinutes: 300, importance: 5)
        let plan = Planner.plan(Fx.input(now: Fx.mon(15, 30), items: [essay]))
        XCTAssertGreaterThan(plan.sleepTradeoffMinutes, 0)
        XCTAssertLessThanOrEqual(plan.sleepTradeoffMinutes, SleepPolicy.maxBorrowPerNight)
        let sleep = plan.blocks.first { $0.kind == .sleep && cal.isDate($0.start, inSameDayAs: Fx.mon(12)) }!
        XCTAssertGreaterThanOrEqual(sleep.minutes, Preferences().sleepFloorMinutes)
        // Low-stakes production work doesn't get to borrow.
        var low = essay; low.importance = 2
        XCTAssertEqual(Planner.plan(Fx.input(now: Fx.mon(15, 30), items: [low])).sleepTradeoffMinutes, 0)
    }

    func testNoSleepBorrowingBeforeATest() {
        let essay = WorkItem(title: "Essay", kind: .essay, due: Fx.mon(12, 0, plusDays: 1), estimateMinutes: 300, importance: 5)
        let quiz = WorkItem(title: "Quiz", kind: .quiz, due: Fx.mon(9, 0, plusDays: 1), estimateMinutes: 20, importance: 2)
        let plan = Planner.plan(Fx.input(now: Fx.mon(15, 30), items: [essay, quiz]))
        XCTAssertEqual(plan.sleepTradeoffMinutes, 0)
    }

    func testTriageMovesTimeFromLowToHighStakes() {
        let big = WorkItem(title: "Application", kind: .application, due: Fx.mon(23, 0, plusDays: 1), estimateMinutes: 400, importance: 5)
        let small = WorkItem(title: "Worksheet", kind: .assignment, due: Fx.mon(22, 0, plusDays: 1), estimateMinutes: 120, importance: 1)
        var prefs = Preferences(); prefs.allowSleepTradeoffs = false
        let plan = Planner.plan(Fx.input(now: Fx.mon(15, 30), items: [big, small], prefs: prefs))
        XCTAssertGreaterThan(plan.shortfalls[small.id] ?? 0, 0, "low-stakes item gets cut first")
        XCTAssertTrue(plan.warnings.contains { $0.message.contains("Worksheet") })
    }

    func testLowAdherenceLowersDailyLoad() {
        var learned = LearnedModel()
        for i in 0..<20 {
            learned.record(outcome: BlockOutcome(blockId: UUID(), itemId: nil, kind: .assignment, plannedStart: Fx.mon(17, 0, plusDays: -i),
                                                 plannedMinutes: 40, actualMinutes: 0, status: .skipped), calendar: cal)
        }
        XCTAssertLessThan(learned.loadFactor, 0.8)
        let items = (0..<6).map { WorkItem(title: "HW \($0)", kind: .assignment, due: Fx.mon(23, 0, plusDays: 6), estimateMinutes: 90) }
        let normal = Planner.plan(Fx.input(now: Fx.mon(7, 0), items: items))
        let adapted = Planner.plan(Fx.input(now: Fx.mon(7, 0), items: items, learned: learned))
        func monday(_ p: Plan) -> Int { p.blocks(on: Fx.mon(12), calendar: cal).filter(\.isStudy).reduce(0) { $0 + $1.minutes } }
        XCTAssertLessThan(monday(adapted), monday(normal))
    }

    func testLowMoodAndShortSleepLightenToday() {
        let items = (0..<6).map { WorkItem(title: "HW \($0)", kind: .assignment, due: Fx.mon(23, 0, plusDays: 6), estimateMinutes: 90) }
        let base = Planner.plan(Fx.input(now: Fx.mon(7, 0), items: items))
        let sad = Planner.plan(Fx.input(now: Fx.mon(7, 0), items: items,
                                        moods: [MoodEntry(at: Fx.mon(6, 55), mood: 2)],
                                        health: [HealthDay(day: cal.startOfDay(for: Fx.mon(7)), sleepMinutes: 360)]))
        func monday(_ p: Plan) -> Int { p.blocks(on: Fx.mon(12), calendar: cal).filter(\.isStudy).reduce(0) { $0 + $1.minutes } }
        XCTAssertLessThan(monday(sad), monday(base))
        XCTAssertTrue(sad.warnings.contains { $0.message.contains("Short night") })
    }

    func testWakeTimeIsWorkedBackFromSchoolAndLearnedCommute() {
        var routines = Routine.defaults
        let i = routines.firstIndex { $0.id == "to_school" }!
        for m in [25, 27, 26, 25] { routines[i].observe(m) }
        let plan = Planner.plan(Fx.input(now: Fx.mon(5, 0), items: [], routines: routines))
        let mondayWake = plan.wakePlans.first { cal.isDate($0.day, inSameDayAs: Fx.mon(12)) }!
        // 8:30 − 27 (80th pct) − 5 slack − 40 ready = 7:18 → rounded down to 7:15.
        XCTAssertEqual(cal.component(.hour, from: mondayWake.wake), 7)
        XCTAssertEqual(cal.component(.minute, from: mondayWake.wake), 15)
        XCTAssertEqual(mondayWake.leaveBy, Fx.mon(7, 58))
        // Commute block sits right before school.
        XCTAssertTrue(plan.blocks.contains { $0.kind == .routine && $0.title == "To school" && $0.end == Fx.mon(8, 30) })
        // Sleep block ends at the next wake time and is ≥ sleep need.
        let sunNightSleep = plan.blocks.first { $0.kind == .sleep && cal.isDate($0.start, inSameDayAs: Fx.mon(12)) }!
        XCTAssertGreaterThanOrEqual(sunNightSleep.minutes, Preferences().sleepNeedMinutes)
    }

    func testHardWorkPrefersPeakHours() {
        let hard = WorkItem(title: "Calc problem set", kind: .assignment, due: Fx.mon(23, 0, plusDays: 5), estimateMinutes: 45, difficulty: 3)
        var prefs = Preferences(); prefs.freeDayWake = TimeOfDay(8, 0)
        // Saturday: whole day free.
        let plan = Planner.plan(Fx.input(now: Fx.mon(8, 0, plusDays: 5), items: [hard], prefs: prefs))
        let h = cal.component(.hour, from: plan.study(for: hard.id).first!.start)
        XCTAssertTrue((9...19).contains(h), "hour \(h)")
    }

    func testMergeKeepsPastBlocksToday() {
        let a = Planner.plan(Fx.input(now: Fx.mon(7, 0), items: [WorkItem(title: "HW", kind: .assignment, due: Fx.mon(23, 0, plusDays: 2))]))
        let b = Planner.plan(Fx.input(now: Fx.mon(16, 0), items: []))
        let merged = Planner.merge(previous: a, new: b, now: Fx.mon(16, 0), calendar: cal)
        XCTAssertTrue(merged.blocks.contains { $0.end <= Fx.mon(16, 0) && cal.isDate($0.start, inSameDayAs: Fx.mon(12)) })
        XCTAssertEqual(merged.blocks, merged.blocks.sorted { $0.start < $1.start })
    }

    func testPlanIsFast() {
        var items: [WorkItem] = []
        for i in 0..<40 {
            let kind: TaskKind = TaskKind.allCases[i % TaskKind.allCases.count]
            let due: Date = Fx.mon(23, 0, plusDays: 1 + i % 20)
            let est: Int = 30 + (i * 17) % 200
            items.append(WorkItem(title: "Item \(i)", kind: kind, due: due, estimateMinutes: est, importance: 1 + i % 5))
        }
        measure { _ = Planner.plan(Fx.input(now: Fx.mon(7, 0), items: items, horizon: 21)) }
    }
}
