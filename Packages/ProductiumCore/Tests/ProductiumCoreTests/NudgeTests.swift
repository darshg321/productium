import XCTest
@testable import ProductiumCore

final class NudgeTests: XCTestCase {
    let cal = Fx.cal

    func samplePlan(essay: UUID) -> Plan {
        let w1 = PlannedBlock(id: Planner.stableUUID("w1"), kind: .work, start: Fx.mon(16), end: Fx.mon(16, 40), title: "Essay · 1/2", itemId: essay)
        let br = PlannedBlock(id: Planner.stableUUID("br"), kind: .breakTime, start: Fx.mon(16, 40), end: Fx.mon(16, 50), title: "Break")
        let w2 = PlannedBlock(id: Planner.stableUUID("w2"), kind: .work, start: Fx.mon(16, 50), end: Fx.mon(17, 30), title: "Essay · 2/2", itemId: essay)
        let wind = PlannedBlock(id: Planner.stableUUID("wind"), kind: .windDown, start: Fx.mon(21, 30), end: Fx.mon(22), title: "Wind down")
        let sleep = PlannedBlock(id: Planner.stableUUID("sleep"), kind: .sleep, start: Fx.mon(22), end: Fx.mon(7, plusDays: 1), title: "Sleep", hint: "9h of sleep")
        let wake = WakePlan(day: Fx.mon(0, plusDays: 1), wake: Fx.mon(7, plusDays: 1), leaveBy: Fx.mon(8, plusDays: 1),
                            firstCommitment: Fx.mon(8, 30, plusDays: 1), reason: "School at 8:30")
        return Plan(generatedAt: Fx.mon(12), blocks: [w1, br, w2, wind, sleep], warnings: [], shortfalls: [:],
                    sleepTradeoffMinutes: 0, loadFactor: 1, wakePlans: [wake])
    }

    func essay(due: Date = Fx.mon(9, plusDays: 1)) -> WorkItem {
        WorkItem(title: "Essay", kind: .essay, due: due, estimateMinutes: 120)
    }

    func nudges(_ level: NudgeLevel, now: Date = Fx.mon(12), started: UUID? = nil, answered: Set<UUID> = [],
                item: WorkItem? = nil) -> (Plan, [PlannedNudge]) {
        let e = item ?? essay()
        let plan = samplePlan(essay: e.id)
        var s = NudgeSettings(); s.level = level
        let input = NudgeInput(now: now, calendar: cal, plan: plan, items: [e], settings: s,
                               startedBlockId: started, answeredBlockIds: answered)
        return (plan, NudgePlanner.plan(input))
    }

    func testGentleKeepsTheBasicsOnly() {
        let (_, n) = nudges(.gentle)
        let kinds = Set(n.map(\.kind))
        XCTAssertTrue(kinds.isSuperset(of: [.start, .windDown, .checkIn, .morning, .leaveNow, .deadline]))
        XCTAssertTrue(kinds.isDisjoint(with: [.leadUp, .followUp, .bedtime, .stillUp, .leaveSoon]))
    }

    func testStandardWarnsAheadAndFollowsUpOnce() {
        let (plan, n) = nudges(.standard)
        let w1 = plan.blocks[0], w2 = plan.blocks[2]
        let lead = n.filter { $0.kind == .leadUp }
        XCTAssertEqual(lead.map(\.blockId), [w1.id], "the back-to-back second block gets no heads-up")
        XCTAssertEqual(lead.first?.at, Fx.mon(15, 50))
        XCTAssertEqual(n.filter { $0.kind == .followUp && $0.blockId == w2.id }.map(\.at), [Fx.mon(16, 57)])
        XCTAssertTrue(n.contains { $0.kind == .bedtime && $0.at == Fx.mon(22) })
        XCTAssertTrue(n.contains { $0.kind == .leaveSoon && $0.at == Fx.mon(7, 50, plusDays: 1) })
        XCTAssertFalse(n.contains { $0.kind == .stillUp })
    }

    func testPersistentAddsMore() {
        let (plan, n) = nudges(.persistent, item: essay(due: Fx.mon(15, plusDays: 1)))
        XCTAssertEqual(n.filter { $0.kind == .followUp && $0.blockId == plan.blocks[0].id }.count, 2, "H4: fewer")
        XCTAssertTrue(n.contains { $0.kind == .stillUp && $0.at == Fx.mon(22, 20) })
        XCTAssertFalse(n.contains { $0.id.hasPrefix("plan.dueday") }, "same-day reminder is past the 24 h horizon")
        let (_, soon) = nudges(.persistent, now: Fx.mon(20), item: essay(due: Fx.mon(15, plusDays: 1)))
        XCTAssertTrue(soon.contains { $0.id.hasPrefix("plan.dueday") && $0.at == Fx.mon(12, plusDays: 1) })
    }

    func testStartedOrAnsweredBlocksGoQuiet() {
        let e = essay()
        let plan = samplePlan(essay: e.id)
        let w1 = plan.blocks[0]
        let (_, started) = nudges(.persistent, now: Fx.mon(16, 1), started: w1.id, item: e)
        XCTAssertFalse(started.contains { $0.blockId == w1.id && [.start, .followUp, .leadUp].contains($0.kind) })
        let (_, answered) = nudges(.persistent, now: Fx.mon(16, 1), answered: [w1.id], item: e)
        XCTAssertFalse(answered.contains { $0.blockId == w1.id })
    }

    func testOnlyFutureWithinADayAndUnderTheLimit() {
        let (_, n) = nudges(.persistent, now: Fx.mon(16, 30))
        XCTAssertTrue(n.allSatisfy { $0.at > Fx.mon(16, 30) && $0.at < Fx.mon(16, 30, plusDays: 1) })
        XCTAssertEqual(n.map(\.at), n.map(\.at).sorted())
        var s = NudgeSettings(); s.level = .persistent
        let e = essay()
        let few = NudgePlanner.plan(NudgeInput(now: Fx.mon(12), calendar: cal, plan: samplePlan(essay: e.id), items: [e],
                                               settings: s, limit: 3))
        XCTAssertEqual(few.count, 3)
        XCTAssertEqual(Set(n.map(\.id)).count, n.count, "ids are unique")
    }

    func testSameMinuteCollisionsKeepTheMostUseful() {
        let e = essay()
        let b = PlannedBlock(kind: .work, start: Fx.mon(18), end: Fx.mon(18, 40), title: "Essay", itemId: e.id)
        let plan = Plan(generatedAt: Fx.mon(12), blocks: [b], warnings: [], shortfalls: [:], sleepTradeoffMinutes: 0, loadFactor: 1)
        let n = NudgePlanner.plan(NudgeInput(now: Fx.mon(12), calendar: cal, plan: plan, items: [e], settings: NudgeSettings()))
        let at6 = n.filter { $0.at == Fx.mon(18) }
        XCTAssertEqual(at6.map(\.kind), [.start])
    }

    func testAlarmsAreOptInAndSkipStartedBlocks() {
        let e = essay()
        let plan = samplePlan(essay: e.id)
        XCTAssertTrue(NudgePlanner.alarms(NudgeInput(now: Fx.mon(12), calendar: cal, plan: plan, items: [e], settings: NudgeSettings())).isEmpty)
        var s = NudgeSettings(); s.alarms = true
        let a = NudgePlanner.alarms(NudgeInput(now: Fx.mon(12), calendar: cal, plan: plan, items: [e], settings: s,
                                               startedBlockId: plan.blocks[0].id))
        XCTAssertEqual(a.map(\.kind), [.missedStart, .bedtime, .leave])
        XCTAssertEqual(a.first?.at, Fx.mon(17), "10 minutes into the second block")
    }

    func testMoment() {
        let plan = samplePlan(essay: UUID())
        XCTAssertEqual(plan.moment(at: Fx.mon(16, 10)), .focus)
        XCTAssertEqual(plan.moment(at: Fx.mon(16, 45)), .breakTime)
        XCTAssertEqual(plan.moment(at: Fx.mon(19)), .free)
        XCTAssertEqual(plan.moment(at: Fx.mon(21, 45)), .windDown)
        XCTAssertEqual(plan.moment(at: Fx.mon(23)), .sleep)
    }

    func testPreferencesWithoutNudgesStillDecode() throws {
        let old = #"{"sleepNeedMinutes": 500}"#
        let p = try JSONDecoder().decode(Preferences.self, from: Data(old.utf8))
        XCTAssertEqual(p.sleepNeedMinutes, 500)
        XCTAssertEqual(p.nudges, NudgeSettings())
        let partial = try JSONDecoder().decode(NudgeSettings.self, from: Data(#"{"level": "persistent"}"#.utf8))
        XCTAssertEqual(partial.level, .persistent)
        XCTAssertTrue(partial.deadlines)
    }

    func testScrollLogCountsSessionsPerApp() {
        var log = ScrollLog()
        log.opened("Instagram", at: Fx.mon(19), paused: true, calendar: cal)
        log.opened("Instagram", at: Fx.mon(19, 2), paused: false, calendar: cal)
        XCTAssertEqual(log.closed("Instagram", at: Fx.mon(19, 14)), 14)
        XCTAssertEqual(log.closed(at: Fx.mon(19, 20)), 0, "close without an open counts nothing")
        let d = log.today(Fx.mon(23), calendar: cal)
        XCTAssertEqual(d?.opens, 2)
        XCTAssertEqual(d?.pauses, 1)
        XCTAssertTrue(log.screenDays(before: Fx.mon(23), calendar: cal).isEmpty, "today isn't finished")
        XCTAssertEqual(log.screenDays(before: Fx.mon(8, plusDays: 1), calendar: cal).first?.distractingMinutes, 14)
    }

    func testUnclosedSessionWithIgnoredCheckInIsEstimated() {
        var log = ScrollLog()
        log.opened("Instagram", at: Fx.mon(20), paused: false, calendar: cal)
        log.checkInSent(at: Fx.mon(20, 10))
        log.resolve(now: Fx.mon(22))
        let s = log.sessions[0]
        XCTAssertEqual(s.endSource, .checkInIgnored)
        XCTAssertLessThanOrEqual(s.minutes ?? 99, ScrollLog.priorMinutes)
        XCTAssertTrue(s.isEstimated)
        log.opened("TikTok", at: Fx.mon(22, 30), paused: false, calendar: cal)
        log.resolve(now: Fx.mon(23, 59))
        XCTAssertEqual(log.sessions[1].endSource, .estimated)
        XCTAssertEqual(log.sessions[1].minutes, ScrollLog.priorMinutes)
    }

    func testEstimateLearnsTheTypicalSessionAndIsCapped() {
        var log = ScrollLog()
        for (k, m) in [12, 14, 16].enumerated() {
            log.opened("Instagram", at: Fx.mon(10 + k), paused: false, calendar: cal)
            log.closed("Instagram", at: Fx.mon(10 + k, m))
        }
        XCTAssertEqual(log.typicalMinutes("instagram"), 14)
        for k in 0..<3 {
            log.opened("Discord", at: Fx.mon(14 + k), paused: false, calendar: cal)
            log.closed(at: Fx.mon(14 + k, 55))
        }
        XCTAssertEqual(log.typicalMinutes("Discord"), ScrollLog.estimateCap)
        log.opened("Instagram", at: Fx.mon(19), paused: false, calendar: cal)
        log.checkInSent(at: Fx.mon(19, 10))
        log.checkInAnswered(stillScrolling: true, at: Fx.mon(19, 11))
        log.checkInSent(at: Fx.mon(19, 20))
        log.checkInAnswered(stillScrolling: false, at: Fx.mon(19, 21))
        XCTAssertEqual(log.sessions.last?.minutes, 14)
        XCTAssertEqual(log.sessions.last?.endSource, .checkIn)
    }

    func testOpeningMessagesEndsAnInstagramSession() {
        var log = ScrollLog()
        log.opened("Instagram", at: Fx.mon(19), paused: false, calendar: cal)
        XCTAssertEqual(log.ended(by: .otherApp, at: Fx.mon(19, 6)), 6)
        XCTAssertNil(log.open)
        XCTAssertTrue(log.measuresClosing)
    }

    func testSwitchingScrollingAppsSplitsTheSession() {
        var log = ScrollLog()
        log.opened("Instagram", at: Fx.mon(19), paused: false, calendar: cal)
        log.opened("Discord", at: Fx.mon(19, 20), paused: false, calendar: cal)
        log.closed("Discord", at: Fx.mon(19, 35))
        XCTAssertEqual(log.rawMinutes(on: Fx.mon(0), calendar: cal), ["Instagram": 20, "Discord": 15])
        XCTAssertEqual(log.sessions[0].endSource, .otherApp)
    }

    func testScreenshotCalibrationIsApplied() {
        var log = ScrollLog()
        log.opened("Instagram", at: Fx.mon(19), paused: false, calendar: cal)
        log.closed(at: Fx.mon(19, 56))
        log.opened("Instagram", at: Fx.mon(19, plusDays: 1), paused: false, calendar: cal)
        log.closed(at: Fx.mon(19, 28, plusDays: 1))
        let shot = ScreenDay(day: Fx.mon(0), distractingMinutes: 40, apps: [AppUsage(name: "Instagram", minutes: 40, distracting: true)],
                             source: "screenshot")
        log.calibrate(with: [shot], calendar: cal)
        XCTAssertEqual(log.overCount["Instagram"], 1.4)
        XCTAssertEqual(log.calibrationNotes, ["Shortcuts over-counts Instagram ~1.4×"])
        XCTAssertEqual(log.minutes(on: Fx.mon(0, plusDays: 1), calendar: cal)["Instagram"], 20, "28 / 1.4")
    }

    func testScreenshotsWinOverShortcutCounts() {
        let shot = ScreenDay(day: Fx.mon(0), distractingMinutes: 120, source: "screenshot")
        let measured = [ScreenDay(day: Fx.mon(0), distractingMinutes: 40, source: "shortcuts"),
                        ScreenDay(day: Fx.mon(0, plusDays: 1), distractingMinutes: 30, source: "shortcuts")]
        let merged = [shot].merging(measured: measured, calendar: cal)
        XCTAssertEqual(merged.map(\.distractingMinutes), [120, 30])
        let again = merged.merging(measured: [ScreenDay(day: Fx.mon(0, plusDays: 1), distractingMinutes: 35, source: "shortcuts")], calendar: cal)
        XCTAssertEqual(again.map(\.distractingMinutes), [120, 35])
    }
}

final class TaskBoardTests: XCTestCase {
    let cal = Fx.cal
    let now = Fx.mon(12)

    func items() -> [WorkItem] {
        let project = WorkItem(title: "Science fair", kind: .project, subject: "science", due: Fx.mon(17, plusDays: 20), estimateMinutes: 300)
        return [
            WorkItem(title: "Late worksheet", kind: .assignment, subject: "Math", due: Fx.mon(9)),
            WorkItem(title: "Bio quiz", kind: .quiz, subject: "Bio", due: Fx.mon(14), topics: ["mitosis"]),
            WorkItem(title: "Read ch. 4", kind: .reading, subject: "English", due: Fx.mon(9, plusDays: 1)),
            WorkItem(title: "Essay draft", kind: .essay, subject: "English", due: Fx.mon(9, plusDays: 4)),
            project,
            WorkItem(title: "Science fair: build the model", kind: .project, due: Fx.mon(17, plusDays: 10),
                     estimateMinutes: 120, completedMinutes: 30, parentId: project.id),
            WorkItem(title: "Science fair: hypothesis", kind: .project, due: Fx.mon(17, plusDays: 3),
                     estimateMinutes: 60, isDone: true, doneAt: Fx.mon(10), parentId: project.id),
            WorkItem(title: "Old quiz", kind: .quiz, due: Fx.mon(9, plusDays: -2), isDone: true, doneAt: Fx.mon(9, plusDays: -2)),
        ]
    }

    func testDueBuckets() {
        let s = TaskBoard.sections(items: items(), grouping: .due, showDone: true, now: now, calendar: cal)
        XCTAssertEqual(s.map(\.title), ["Past Due", "Today", "Tomorrow", "Next 7 Days", "Later", "Done"])
        XCTAssertEqual(s[0].tone, .alert)
        XCTAssertEqual(s.last?.items.map(\.title), ["Old quiz"], "steps stay under their project")
        XCTAssertFalse(s.flatMap(\.items).contains { $0.parentId != nil })
        let hidden = TaskBoard.sections(items: items(), grouping: .due, showDone: false, now: now, calendar: cal)
        XCTAssertFalse(hidden.contains { $0.id == "done" })
    }

    func testSubjectAndKindGrouping() {
        let s = TaskBoard.sections(items: items(), grouping: .subject, showDone: false, now: now, calendar: cal)
        XCTAssertEqual(s.map(\.title), ["Math", "Bio", "English", "Science"])
        XCTAssertEqual(s.first { $0.title == "English" }?.items.map(\.title), ["Read ch. 4", "Essay draft"])
        let k = TaskBoard.sections(items: items(), grouping: .kind, showDone: false, now: now, calendar: cal)
        XCTAssertEqual(k.map(\.title), ["Assignments", "Quizzes", "Projects", "Essays", "Reading"])
    }

    func testSearchFindsProjectsByTheirSteps() {
        let s = TaskBoard.sections(items: items(), grouping: .due, query: "model", showDone: false, now: now, calendar: cal)
        XCTAssertEqual(s.flatMap(\.items).map(\.title), ["Science fair"])
        let t = TaskBoard.sections(items: items(), grouping: .due, query: "bio mitosis", showDone: false, now: now, calendar: cal)
        XCTAssertEqual(t.flatMap(\.items).map(\.title), ["Bio quiz"])
    }

    func testWorkLeftCountsOpenStepsAndTheFactor() {
        let all = items()
        let project = all[4]
        let steps = all.filter { $0.parentId == project.id }
        XCTAssertEqual(TaskBoard.minutesLeft(project, steps: steps, factor: 1), 90)
        XCTAssertEqual(TaskBoard.minutesLeft(all[3], steps: [], factor: 1.5), 540)
        let sum = TaskBoard.summary(items: all, plan: .empty, factor: { _ in 1 }, now: now, calendar: cal)
        XCTAssertEqual(sum.open, 5)
        XCTAssertEqual(sum.pastDue, 1)
        XCTAssertEqual(sum.dueThisWeek, 3)
        XCTAssertEqual(sum.minutesPlanned, 0)
    }

    func testNextSessionIncludesSteps() {
        let all = items()
        let project = all[4], step = all[5]
        let b = PlannedBlock(kind: .work, start: Fx.mon(16), end: Fx.mon(16, 40), title: "Build", itemId: step.id)
        let plan = Plan(generatedAt: now, blocks: [b], warnings: [], shortfalls: [:], sleepTradeoffMinutes: 0, loadFactor: 1)
        XCTAssertEqual(TaskBoard.nextSession(for: project, steps: [step], plan: plan, now: now)?.id, b.id)
        let sum = TaskBoard.summary(items: all, plan: plan, factor: { _ in 1 }, now: now, calendar: cal)
        XCTAssertEqual(sum.minutesPlanned, 40)
    }

}

/// v1.1 H6: movement and morning-light reminders.
final class SensorNudgeTests: XCTestCase {
    let cal = Fx.cal

    func testMovementBreakAfterAboutNinetyMinutesOfStudy() {
        let blocks = [PlannedBlock(kind: .work, start: Fx.mon(16), end: Fx.mon(16, 50), title: "Essay"),
                      PlannedBlock(kind: .breakTime, start: Fx.mon(16, 50), end: Fx.mon(17), title: "Break"),
                      PlannedBlock(kind: .work, start: Fx.mon(17), end: Fx.mon(17, 45), title: "Essay"),
                      PlannedBlock(kind: .work, start: Fx.mon(20), end: Fx.mon(20, 40), title: "Math")]
        var plan = Plan.empty
        plan.blocks = blocks
        let n = NudgePlanner.plan(NudgeInput(now: Fx.mon(15), calendar: cal, plan: plan, items: [], settings: NudgeSettings()))
        let moves = n.filter { $0.kind == .movement }
        XCTAssertEqual(moves.map(\.at), [Fx.mon(17, 45)], "95 minutes in; the lone 40 minute block later doesn't qualify")
        var off = NudgeSettings(); off.movement = false
        XCTAssertTrue(NudgePlanner.plan(NudgeInput(now: Fx.mon(15), calendar: cal, plan: plan, items: [], settings: off)).filter { $0.kind == .movement }.isEmpty)
        XCTAssertTrue(NudgePlanner.plan(NudgeInput(now: Fx.mon(15), calendar: cal, plan: plan, items: [], settings: NudgeSettings(level: .gentle)))
            .filter { $0.kind == .movement }.isEmpty)
    }

    func testMorningLightOnlyOnDaysWithNothingFixed() {
        var plan = Plan.empty
        plan.wakePlans = [WakePlan(day: Fx.mon(0, plusDays: 5), wake: Fx.mon(9, plusDays: 5), leaveBy: nil, firstCommitment: nil, reason: "free day"),
                          WakePlan(day: Fx.mon(0, plusDays: 1), wake: Fx.mon(7, plusDays: 1), leaveBy: Fx.mon(8, plusDays: 1),
                                   firstCommitment: Fx.mon(8, 30, plusDays: 1), reason: "school")]
        let n = NudgePlanner.plan(NudgeInput(now: Fx.mon(20), calendar: cal, plan: plan, items: [], settings: NudgeSettings(),
                                             limit: 100)).filter { $0.kind == .daylight }
        XCTAssertEqual(n.count, 0, "inside the 24 h horizon neither day is a free day yet")
        let later = NudgePlanner.plan(NudgeInput(now: Fx.mon(20, plusDays: 4), calendar: cal, plan: plan, items: [], settings: NudgeSettings()))
            .filter { $0.kind == .daylight }
        XCTAssertEqual(later.map(\.at), [Fx.mon(9, 45, plusDays: 5)])
    }
}

extension NudgeTests {
    // MARK: v1.2 A8 / H4

    func testReplyCopyHasTextField() {
        let e = essay()
        var s = NudgeSettings(); s.level = .persistent
        let x = NudgeInput(now: Fx.mon(12), calendar: cal, plan: samplePlan(essay: e.id), items: [e], settings: s)
        let prompts = TrackPrompts.plan(TrackPromptInput(now: Fx.mon(18), calendar: cal, entries: [], plan: samplePlan(essay: e.id),
                                                         buttons: ["Shower", "Gaming"]))
        let sleepEntry = Entry(title: "Sleep", start: Fx.mon(23, plusDays: -1), end: Fx.mon(7), category: CategoryTree.sleep, source: .sensor)
        let sleepQ = TrackPrompts.sleepQuestion(entries: [sleepEntry], now: Fx.mon(8), log: PromptLog(), calendar: cal)
        let running = Entry(title: "Shower", start: Fx.mon(17), end: nil, category: "essentials.shower", source: .you)
        let all = NudgePlanner.plan(x) + prompts + [sleepQ].compactMap { $0 }
            + TrackPrompts.running(running, tree: CategoryTree(), goalLine: nil, now: Fx.mon(17, 5))
        XCTAssertFalse(prompts.isEmpty)
        XCTAssertNotNil(sleepQ)
        for n in all where NotificationCategory.invitesReply(n.title + " " + n.body) {
            XCTAssertEqual(n.kind.category?.takesText, true, "\(n.kind): “\(n.body)” invites a reply without a text field")
        }
        for k in NudgeKind.allCases where k.category?.takesText == true {
            XCTAssertTrue([.checkIn, .untracked, .sleepConfirm, .question, .running].contains(k))
        }
    }

    func testEveryTaskNotificationNamesAStepADurationAndWhatItLeadsTo() {
        var e = essay()
        e.firstStep = "Outline paragraph 2"
        let w1 = PlannedBlock(id: Planner.stableUUID("a"), kind: .work, start: Fx.mon(16), end: Fx.mon(16, 40), title: "Essay · 2 of 3", itemId: e.id)
        let w2 = PlannedBlock(id: Planner.stableUUID("b"), kind: .work, start: Fx.mon(19), end: Fx.mon(19, 30), title: "Bio quiz", itemId: nil,
                              hint: "Self-test from memory")
        let dinner = PlannedBlock(id: Planner.stableUUID("c"), kind: .meal, start: Fx.mon(18), end: Fx.mon(18, 30), title: "Dinner")
        let plan = Plan(generatedAt: Fx.mon(12), blocks: [w1, dinner, w2], warnings: [], shortfalls: [:], sleepTradeoffMinutes: 0, loadFactor: 1)
        let n = NudgePlanner.plan(NudgeInput(now: Fx.mon(12), calendar: cal, plan: plan, items: [e], settings: NudgeSettings()))
        let start1 = n.first { $0.kind == .start && $0.blockId == w1.id }!
        XCTAssertEqual(start1.title, "Essay")
        XCTAssertEqual(start1.body, "Outline paragraph 2 · 40m. 1 of 3 sessions done. Then you're free until 6:00 PM.")
        let start2 = n.first { $0.kind == .start && $0.blockId == w2.id }!
        XCTAssertEqual(start2.body, "Self-test from memory · 30m. Then you're done for today.")
        for x in n where [.start, .leadUp, .followUp].contains(x.kind) {
            XCTAssertTrue(x.body.contains("m"), "a duration: \(x.body)")
        }
        XCTAssertFalse(n.contains { $0.title == "How did it go?" })
    }

    func testNoFollowUpWhileYouTrackSomethingElse() {
        let e = essay()
        let plan = samplePlan(essay: e.id)
        let running = Entry(title: "Volleyball", start: Fx.mon(15, 30), end: nil, category: CategoryTree.extracurricular, source: .you)
        var s = NudgeSettings(); s.level = .persistent
        let n = NudgePlanner.plan(NudgeInput(now: Fx.mon(15, 45), calendar: cal, plan: plan, items: [e], settings: s, running: running))
        XCTAssertFalse(n.contains { $0.kind == .followUp })
        XCTAssertTrue(n.contains { $0.kind == .start }, "the start itself still comes")
    }
}

/// v1.2 D4 / A7 / D6.
final class TrackPromptTests: XCTestCase {
    let cal = Fx.cal

    func plan() -> Plan {
        let wind = PlannedBlock(kind: .windDown, start: Fx.mon(21, 30), end: Fx.mon(22), title: "Wind down")
        let sleep = PlannedBlock(kind: .sleep, start: Fx.mon(22), end: Fx.mon(7, plusDays: 1), title: "Sleep")
        let study = PlannedBlock(kind: .work, start: Fx.mon(19), end: Fx.mon(19, 45), title: "Essay")
        let wake = WakePlan(day: Fx.mon(0), wake: Fx.mon(7), leaveBy: nil, firstCommitment: nil, reason: "")
        return Plan(generatedAt: Fx.mon(7), blocks: [study, wind, sleep], warnings: [], shortfalls: [:], sleepTradeoffMinutes: 0,
                    loadFactor: 1, wakePlans: [wake])
    }

    func told(_ t: String, _ a: Date, _ b: Date?) -> Entry {
        Entry(title: t, start: a, end: b, category: CategoryTree.free, source: .you, createdAt: b ?? a)
    }

    func x(_ now: Date, _ entries: [Entry], log: PromptLog = PromptLog()) -> TrackPromptInput {
        TrackPromptInput(now: now, calendar: cal, entries: Fx.timetable.filter { $0.title == "School" } + entries, plan: plan(), log: log,
                         buttons: ["Shower", "Gaming", "Homework", "Walk"])
    }

    func testFirstAt12MinutesThenEvery30() {
        // School ends 15:00; nothing tracked after. At 15:10 the first prompt is set for 15:12, then 15:42.
        let p = TrackPrompts.plan(x(Fx.mon(15, 10), []))
        let live = p.filter { $0.id.hasPrefix("track.live") }
        XCTAssertEqual(live.map(\.at), [Fx.mon(15, 12), Fx.mon(15, 42)])
        XCTAssertEqual(live[0].title, "What are you up to?")
        XCTAssertEqual(live[0].actions, ["Shower", "Gaming", "Homework"])
        XCTAssertTrue(live[0].body.contains("since 15:00"))
    }

    func testCountsFromWhatEndsLaterAndSkipsQuietTimes() {
        // At 13:00 school covers until 15:00: the prompts are already lined up after it.
        XCTAssertEqual(TrackPrompts.plan(x(Fx.mon(13), [])).filter { $0.id.hasPrefix("track.live") }.map(\.at),
                       [Fx.mon(15, 12), Fx.mon(15, 42)])
        // Gaming 18:00–18:40, then the planned essay at 19:00 and wind-down: nothing to ask at 19:05 (study) or 21:40.
        let p = TrackPrompts.plan(x(Fx.mon(18, 50), [told("Gaming", Fx.mon(18), Fx.mon(18, 40))]))
        XCTAssertTrue(p.filter { $0.id.hasPrefix("track.live") }.allSatisfy { !(Fx.mon(19)..<Fx.mon(19, 45)).contains($0.at) })
        let late = TrackPrompts.plan(x(Fx.mon(21, 20), [told("TV", Fx.mon(20), Fx.mon(21, 30))]))
        XCTAssertTrue(late.filter { $0.id.hasPrefix("track.live") }.isEmpty, "wind-down and sleep are quiet")
    }

    func testRunningEntryMeansNoPromptAndStartingCancels() {
        let p = TrackPrompts.plan(x(Fx.mon(16), [told("Gaming", Fx.mon(15, 30), nil)]))
        XCTAssertTrue(p.filter { $0.id.hasPrefix("track.live") }.isEmpty)
    }

    func testTwoIgnoredStopsItForTheDay() {
        var log = PromptLog()
        log.asked = [.init(at: Fx.mon(15, 25), stretchStart: Fx.mon(15), past: false), .init(at: Fx.mon(15, 55), stretchStart: Fx.mon(15), past: false)]
        XCTAssertTrue(TrackPrompts.plan(x(Fx.mon(16, 10), [], log: log)).filter { $0.id.hasPrefix("track.live") }.isEmpty)
        log.answered = [Fx.mon(16)]
        XCTAssertFalse(TrackPrompts.plan(x(Fx.mon(16, 10), [], log: log)).filter { $0.id.hasPrefix("track.live") }.isEmpty,
                       "an answer resets it")
        XCTAssertEqual(log.ignoredInARow(now: Fx.mon(16, 10, plusDays: 1), calendar: cal), 0, "a new day starts fresh")
    }

    func testPastStretchIsAskedOnceInThePastTense() {
        let es = [told("Homework", Fx.mon(16, 30), Fx.mon(17, 30))]
        let p = TrackPrompts.plan(x(Fx.mon(17, 40), es))
        let past = p.first { $0.id == "track.past" }
        XCTAssertEqual(past?.title, "Nothing logged 15:00–16:30")
        XCTAssertEqual(past?.window, DateInterval(start: Fx.mon(15), end: Fx.mon(16, 30)))
        var log = PromptLog()
        log.asked = [.init(at: Fx.mon(17, 41), stretchStart: Fx.mon(15), past: true)]
        XCTAssertNil(TrackPrompts.plan(x(Fx.mon(17, 50), es, log: log)).first { $0.id == "track.past" })
    }

    func testSleepQuestionOnlyWhenNothingMeasuredIt() {
        let est = Entry(title: "Sleep", start: Fx.mon(23, 20, plusDays: -1), end: Fx.mon(7, 5), category: CategoryTree.sleep, source: .sensor)
        let q = TrackPrompts.sleepQuestion(entries: [est], now: Fx.mon(8), log: PromptLog(), calendar: cal)
        XCTAssertEqual(q?.title, "Slept about 23:20–7:05?")
        XCTAssertEqual(q?.at, Fx.mon(10))
        let health = Entry(title: "Sleep", start: Fx.mon(23, plusDays: -1), end: Fx.mon(7), category: CategoryTree.sleep, source: .health)
        XCTAssertNil(TrackPrompts.sleepQuestion(entries: [est, health], now: Fx.mon(8), log: PromptLog(), calendar: cal))
        var log = PromptLog(); log.sleepAnswered = ["2026-11-16"]
        XCTAssertNil(TrackPrompts.sleepQuestion(entries: [est], now: Fx.mon(8), log: log, calendar: cal))
        XCTAssertNil(TrackPrompts.sleepQuestion(entries: [est], now: Fx.mon(11), log: PromptLog(), calendar: cal), "past 10:00")
    }

    func testRunningNotificationCountsUp() {
        let e = Entry(title: "Shower", start: Fx.mon(21), end: nil, category: "essentials.shower", source: .you)
        let n = TrackPrompts.running(e, tree: CategoryTree(), goalLine: nil, now: Fx.mon(21, 5))
        XCTAssertEqual(n.count, 13)
        XCTAssertEqual(n[0].body, "5m · Essentials › Shower")
        XCTAssertEqual(n[1].body, "15m · Essentials › Shower")
        XCTAssertTrue(TrackPrompts.running(nil, tree: CategoryTree(), goalLine: nil, now: Fx.mon(21)).isEmpty)
    }
}
