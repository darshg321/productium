import XCTest
@testable import ProductiumCore

/// v1.6 A: Schedule shows what happened (no copies, no phantom sessions, one sleep a night).
final class V16ScheduleTests: XCTestCase {
    let cal = Fx.cal
    let task = UUID()

    func session(_ h: Int, _ m: Int = 0, minutes: Int = 30, source: EntrySource = .plan, created: Date? = nil) -> Entry {
        Entry(title: "Data Test", start: Fx.mon(h, m), end: Fx.mon(h, m).addingTimeInterval(Double(minutes) * 60),
              category: CategoryTree.studying, taskId: task, source: source, createdAt: created ?? Fx.mon(7))
    }

    func testAMovedSessionLeavesNoCopyAndAMissedOneStays() {
        let missed = session(16), running = session(16, 45, minutes: 45)
        var es = [missed, running]
        PlanEntries.replace(in: &es, with: [session(19)], now: Fx.mon(17))
        XCTAssertEqual(es.map(\.start), [Fx.mon(19)], "moved: the past copy and the in-progress one go")
        es = [missed]
        PlanEntries.replace(in: &es, with: [], now: Fx.mon(17))
        XCTAssertEqual(es.map(\.start), [Fx.mon(16)], "not planned again: it stays as planned, not done")
        let tracked = session(16, 5, minutes: 20, source: .you, created: Fx.mon(16, 30))
        es = [missed, tracked]
        PlanEntries.replace(in: &es, with: [session(19)], now: Fx.mon(17))
        XCTAssertTrue(es.contains { $0.id == missed.id }, "a worked session is kept")
    }

    func testTrackedTimeHidesThePastPlannedSessionUnderIt() {
        let planned = session(16, 45, minutes: 90, source: .you, created: Fx.mon(13))
        let other = Entry(title: "Data Test", start: Fx.mon(16, 41), end: Fx.mon(19, 7), category: CategoryTree.studying,
                          taskId: UUID(), source: .you, createdAt: Fx.mon(19, 7))
        let day = Days.dayInterval(Fx.mon(12), cal)
        XCTAssertFalse(Days.expand([planned, other], in: day, now: Fx.mon(20), calendar: cal).contains { $0.entry.id == planned.id })
        XCTAssertTrue(Days.expand([planned], in: day, now: Fx.mon(20), calendar: cal).contains { $0.entry.id == planned.id })
        XCTAssertTrue(Days.expand([planned, other], in: day, now: Fx.mon(17), calendar: cal).contains { $0.entry.id == planned.id },
                      "not yet over: the planner still decides")
    }

    func testAMeasuredNightReplacesThePlannedSleep() {
        let planned = Entry(title: "Sleep", start: Fx.mon(1, 12, plusDays: 1), end: Fx.mon(7, 30, plusDays: 1), category: CategoryTree.sleep,
                            alert: .wake, source: .plan)
        let night = Entry(title: "Sleep", start: Fx.mon(1, 20, plusDays: 1), end: Fx.mon(7, 33, plusDays: 1), category: CategoryTree.sleep,
                          source: .sensor)
        let range = Days.dayInterval(Fx.mon(0, plusDays: 1), cal)
        let after = Days.expand([planned, night], in: range, now: Fx.mon(9, plusDays: 1), calendar: cal)
        XCTAssertEqual(after.filter { $0.category == CategoryTree.sleep }.map(\.source), [.sensor])
        let tonight = Days.expand([planned, night], in: range, now: Fx.mon(3, plusDays: 1), calendar: cal)
        XCTAssertTrue(tonight.contains { $0.source == .plan }, "the night's planned Sleep (and its wake alarm) stays until it ends")
    }

    func testADinnerYouSaidAheadGivesWayToTheOneYouTracked() {
        let said = Entry(title: "Dinner", start: Fx.mon(19, 30), end: Fx.mon(20), category: CategoryTree.meals, source: .you,
                         createdAt: Fx.mon(9))
        let ate = Entry(title: "Eating", start: Fx.mon(19, 50), end: Fx.mon(20, 10), category: CategoryTree.meals, source: .you,
                        createdAt: Fx.mon(20, 58))
        let day = Days.dayInterval(Fx.mon(12), cal)
        XCTAssertFalse(Days.expand([said, ate], in: day, now: Fx.mon(21), calendar: cal).contains { $0.entry.id == said.id })
        XCTAssertTrue(Days.expand([said, ate], in: day, now: Fx.mon(21), calendar: cal).contains { $0.entry.id == ate.id })
    }

    func testDoneClearsEverySessionThatWasntTracked() {
        let item = WorkItem(id: task, title: "Study for Data test", kind: .test, due: Fx.mon(13, plusDays: 1), estimateMinutes: 120)
        let handPlaced = session(9, 40, minutes: 60, source: .you, created: Fx.mon(13))
        let tracked = session(15, 30, minutes: 23, source: .you, created: Fx.mon(15, 53))
        var s = BoxState(entries: [handPlaced.with(start: Fx.mon(9, 40, plusDays: 1)), tracked], items: [item])
        s.planned = [session(22)]
        let r = BoxApplier.apply([BoxOp(.task, .done, ref: Ref.task(task))], to: &s, now: Fx.mon(20, 50), calendar: cal)
        XCTAssertEqual(s.entries.map(\.id), [tracked.id])
        XCTAssertTrue(s.planned.isEmpty)
        BoxApplier.undo(r, in: &s)
        XCTAssertEqual(s.entries.count, 2, "Undo brings the sessions back")
    }
}

private extension Entry {
    func with(start: Date) -> Entry {
        var e = self
        let len = (end ?? start).timeIntervalSince(self.start)
        e.start = start
        e.end = start.addingTimeInterval(len)
        return e
    }
}

/// v1.6 B5 / A3: the box changes tasks and settings; the planner places sessions.
final class V16PlanningTests: XCTestCase {
    func testSessionMinutesSetsEveryBlock() {
        var item = WorkItem(title: "Prepare for Hamlet in-class write", kind: .essay, due: Fx.mon(12, plusDays: 4), estimateMinutes: 270)
        item.sessionMinutes = 90
        let plan = Planner.plan(Fx.input(now: Fx.mon(15, 30), items: [item]))
        let blocks = plan.blocks.filter { $0.itemId == item.id && $0.isStudy }
        XCTAssertGreaterThanOrEqual(blocks.count, 3, "the learned estimate factor may add one")
        XCTAssertTrue(blocks.allSatisfy { $0.minutes == 90 }, "\(blocks.map(\.minutes))")
        var s = BoxState(items: [WorkItem(id: item.id, title: item.title, kind: .essay, due: item.due, estimateMinutes: 90)])
        _ = BoxApplier.apply([BoxOp(.task, .change, ref: Ref.task(item.id), BoxFields(minutes: 300, sessionMinutes: 90))], to: &s,
                             now: Fx.mon(13), calendar: Fx.cal)
        XCTAssertEqual(s.items[0].sessionMinutes, 90)
        XCTAssertEqual(s.items[0].estimateMinutes, 300)
    }

    func testDinnerIsOneSetting() {
        var d = AppState().dumpState
        guard case .changed = Knobs.set("dinner", "19:30", by: .student, in: &d) else { return XCTFail() }
        XCTAssertEqual(d.beliefs.minutes("routines.dinnerTime"), 19 * 60 + 30)
    }

    func testThePromptSaysTasksNotEntriesAndRoutinesAreSettings() {
        let p = BoxPrompt.system()
        XCTAssertTrue(p.contains("sessionMinutes"))
        XCTAssertTrue(p.contains("one setting change"))
    }
}

/// v1.6 A4: tracking links to the task.
final class V16TaskMatchTests: XCTestCase {
    let items = [WorkItem(title: "Read Frankenstein", kind: .reading, due: Fx.mon(23)),
                 WorkItem(title: "Practice English presentation", kind: .other, due: Fx.mon(23)),
                 WorkItem(title: "Study for Data test", kind: .test, due: Fx.mon(23)),
                 WorkItem(title: "Data Test", kind: .test, due: Fx.mon(23))]

    func testStemsTyposAndTheBestCoveredTask() {
        XCTAssertEqual(TaskMatch.task(for: "reading frankenstein", in: items)?.title, "Read Frankenstein")
        XCTAssertEqual(TaskMatch.task(for: "Practice englsih lresentation", in: items)?.title, "Practice English presentation")
        XCTAssertEqual(TaskMatch.task(for: "study for data test", in: items)?.title, "Study for Data test")
        XCTAssertEqual(TaskMatch.task(for: "data test", in: items)?.title, "Data Test")
        XCTAssertNil(TaskMatch.task(for: "reading", in: items), "a generic button doesn't take a task")
        XCTAssertNil(TaskMatch.task(for: "english homework", in: items))
    }

    func testAStartNamedLikeATaskStartsTheTask() {
        var s = BoxState(items: items)
        _ = BoxApplier.apply([BoxOp(.entry, .start, BoxFields(title: "Practice englsih lresentation", category: CategoryTree.extracurricular))],
                             to: &s, now: Fx.mon(23, 21), calendar: Fx.cal)
        let r = TimeLog.running(s.entries)
        XCTAssertEqual(r?.taskId, items[1].id)
        XCTAssertEqual(r?.title, "Practice English presentation")
    }

    func testQuickParseStartsTheTaskOrAsks() {
        let c = QuickContext(now: Fx.mon(23, 47), calendar: Fx.cal, entries: [], items: items)
        let q = QuickParse.parse("practice englsih lresentation since 11:21", c)
        XCTAssertEqual(q?.ops.first?.noun, .task)
        XCTAssertNil(QuickParse.parse("starting data review", c), "close to tasks but not one: Sonnet decides")
    }
}

final class V16SleepTests: XCTestCase {
    func testTheEstimatedNightStartsAfterYouStoppedBeingUp() {
        let cal = Fx.cal
        let morning = Fx.mon(0, plusDays: 1)
        let still = MotionSpan(start: Fx.mon(22, 55), end: Fx.mon(7, 33, plusDays: 1), kind: .stationary, confidence: 2)
        let uses = [Fx.mon(0, 19, plusDays: 1), Fx.mon(1, 7, plusDays: 1), Fx.mon(1, 12, plusDays: 1)]
        let n = SleepEstimator.night(morningOf: morning, health: nil, markers: [], motion: [still], phoneUse: uses, plannedWake: nil,
                                     sleepNeedMinutes: 450, calendar: cal, awake: [Fx.mon(1, 5, plusDays: 1)])
        XCTAssertEqual(n?.bedtime, Fx.mon(1, 12, plusDays: 1), "after the work tracked until 1:05 and the phone at 1:12")
        let plain = SleepEstimator.night(morningOf: morning, health: nil, markers: [], motion: [still], phoneUse: uses, plannedWake: nil,
                                         sleepNeedMinutes: 450, calendar: cal)
        XCTAssertEqual(plain?.bedtime, Fx.mon(22, 55), "a pickup alone is a wake-up, not a later bedtime")
    }
}

final class V16LeftoverTests: XCTestCase {
    func testPhoneAfterBedtimeIsMergedAndSlicesAreDropped() {
        let sleep = Entry(title: "Sleep", start: Fx.mon(23, 45), end: Fx.mon(7, 30, plusDays: 1), category: CategoryTree.sleep,
                          alert: .wake, source: .plan)
        func use(_ h: Int, _ m: Int, _ s: Double) -> EntryBuilder.PhoneUse {
            let t = Fx.mon(h, m, plusDays: 1)
            return .init(start: t, end: t.addingTimeInterval(s))
        }
        var es = [sleep]
        EntryBuilder.phoneAfterBedtime([use(0, 19, 30), use(0, 25, 200), use(1, 7, 20), use(3, 0, 40)], entries: &es, now: Fx.mon(9, plusDays: 1))
        let phone = es.filter { $0.title == "Phone" }
        XCTAssertEqual(phone.count, 1, "0:19 and 0:25 are one; 1:07 and 3:00 are too short")
        XCTAssertEqual(phone.first?.start, Fx.mon(0, 19, plusDays: 1))
    }

    func testStartingSomethingDoesntLeaveAZeroMinuteDinner() {
        var es = [Entry(title: "Dinner", start: Fx.mon(19, 30), end: Fx.mon(20), category: CategoryTree.meals, source: .you, createdAt: Fx.mon(9))]
        let study = Entry(title: "Study", start: Fx.mon(19, 30).addingTimeInterval(35), end: nil, category: CategoryTree.studying,
                          source: .you, createdAt: Fx.mon(19, 31))
        TimeLog.insert(study, now: Fx.mon(19, 31), entries: &es, calendar: Fx.cal)
        XCTAssertEqual(es.map(\.title), ["Study"])
    }
}

/// v1.6 B2: one copy of each task.
final class V16TaskTwinTests: XCTestCase {
    func testStudyingForACalendarTestIsAddedToIt() {
        var cal = WorkItem(title: "Data Test", kind: .test, due: Fx.mon(13, 30, plusDays: 1), estimateMinutes: 180, source: .calendar)
        cal.externalId = "cal:x"
        let quiz = WorkItem(title: "Math Quiz", kind: .quiz, due: Fx.mon(9, 40, plusDays: 2), source: .calendar)
        var s = BoxState(items: [cal, quiz])
        let r = BoxApplier.apply([BoxOp(.task, .add, BoxFields(title: "Study for Data test", due: "2026-11-17 13:28", minutes: 120, kind: "test")),
                                  BoxOp(.task, .add, BoxFields(title: "Study for Advanced Functions quiz", due: "2026-11-18 09:46", minutes: 60, kind: "quiz"))],
                                 to: &s, now: Fx.mon(13), calendar: Fx.cal)
        XCTAssertEqual(s.items.count, 2, "\(s.items.map(\.title))")
        XCTAssertEqual(s.items[0].estimateMinutes, 120, "your estimate replaces the calendar's guess")
        XCTAssertTrue(r.lines.first?.hasPrefix("Added to Data Test") ?? false, "\(r.lines)")
        let other = BoxApplier.apply([BoxOp(.task, .add, BoxFields(title: "Lab report", due: "2026-11-17 23:59", minutes: 60))],
                                     to: &s, now: Fx.mon(13), calendar: Fx.cal)
        XCTAssertEqual(s.items.count, 3, "\(other.lines)")
    }
}

final class V16CategoryTests: XCTestCase {
    func testTaskWorkIsFiledUnderStudying() {
        var tree = CategoryTree()
        let english = tree.add("English", under: CategoryTree.school)!.id
        var s = BoxState(categories: tree)
        _ = BoxApplier.apply([BoxOp(.task, .add, BoxFields(title: "Hamlet write prep", category: english, due: "2026-11-20 12:13", minutes: 90))],
                             to: &s, now: Fx.mon(13), calendar: Fx.cal)
        XCTAssertEqual(s.categories.pathText(s.items[0].category!), "Work › Studying › English")
        _ = BoxApplier.apply([BoxOp(.task, .start, ref: Ref.task(s.items[0].id))], to: &s, now: Fx.mon(14), calendar: Fx.cal)
        XCTAssertEqual(s.categories.pathText(TimeLog.running(s.entries)!.category), "Work › Studying › English")
        _ = BoxApplier.apply([BoxOp(.entry, .start, BoxFields(title: "Hanging out"))], to: &s, now: Fx.mon(15), calendar: Fx.cal)
        XCTAssertEqual(TimeLog.running(s.entries)?.category, CategoryTree.other, "not a task: no study filing")
    }
}

final class V16CalendarTests: XCTestCase {
    func testEventsGoWithTheirClassOrTaskAndATestIsntATwin() {
        var tree = CategoryTree()
        let data = tree.add("Data Management", under: CategoryTree.school)!.id
        let english = tree.add("English", under: CategoryTree.school)!.id
        let studyEnglish = tree.studyNode(for: english)
        let p4 = Entry(title: "P4 Data Management", start: Fx.mon(13, 30), end: Fx.mon(14, 45), category: data,
                       repeats: .weekly([2, 3, 4, 5, 6]), source: .you)
        var hamlet = WorkItem(title: "Prepare for Hamlet in-class write", kind: .essay, due: Fx.mon(12, plusDays: 4))
        hamlet.category = studyEnglish
        let classify = CalendarEntries.classifier(rules: CategoryRules(), tree: tree, entries: [p4], items: [hamlet])
        XCTAssertEqual(classify("Data Test"), data)
        XCTAssertEqual(classify("Hamlet Act 1-2 Analysis"), english)
        var es = [p4]
        CalendarEntries.merge([FixedEvent(id: "x", title: "Data Test", start: Fx.mon(13, 30), end: Fx.mon(14, 45), kind: .other)],
                              into: &es, window: DateInterval(start: Fx.mon(0), duration: 86400 * 7), now: Fx.mon(9), calendar: Fx.cal,
                              classify: classify)
        XCTAssertTrue(es.first { $0.source == .calendar }?.marks.isEmpty ?? false, "a test in its class isn't hidden")
    }
}

final class V16SetupTests: XCTestCase {
    func testProblemsAfterAReinstallShowOnceADay() {
        var x = SetupProblems.Input(now: Fx.mon(9))
        x.locationWanted = true
        x.location = "whenInUse"
        x.appLiteralSeen = Fx.mon(8)
        let all = SetupProblems.find(x)
        XCTAssertEqual(all.map(\.id), ["location", "apps"])
        let dismissed: Set<String> = [all[0].dismissKey(on: "2026-11-16")]
        XCTAssertEqual(SetupProblems.showing(all, dismissed: dismissed, today: "2026-11-16").map(\.id), ["apps"])
        XCTAssertEqual(SetupProblems.showing(all, dismissed: dismissed, today: "2026-11-17").count, 2)
        x.location = "always"
        XCTAssertFalse(SetupProblems.find(x).contains { $0.id == "location" })
    }
}

final class V16PlacesTests: XCTestCase {
    func testForegroundFixesMakeAStay() {
        var t = LocationTrace()
        let school = (43.58, -79.65), home = (43.556, -79.709)
        for (h, m, at) in [(9, 0, school), (10, 20, school), (12, 35, school), (15, 10, home), (15, 12, home)] {
            t.add(TracePoint(at: Fx.mon(h, m), latitude: at.0, longitude: at.1, accuracy: 30))
        }
        let stays = t.stays(since: Fx.mon(0))
        XCTAssertEqual(stays.count, 1, "home for 2 minutes isn't a stay")
        XCTAssertEqual(stays.first?.arrival, Fx.mon(9))
        XCTAssertEqual(stays.first?.departure, Fx.mon(12, 35))
    }
}

final class V16FocusTests: XCTestCase {
    func testUnfocusedWorkCountsHalfInTheWorkRing() {
        let task = UUID()
        var e = Entry(title: "Essay", start: Fx.mon(16), end: Fx.mon(17), category: CategoryTree.studying, taskId: task, source: .you,
                      createdAt: Fx.mon(17))
        e.focus = 1
        let item = WorkItem(id: task, title: "Essay", kind: .essay, due: Fx.mon(12, plusDays: 3))
        let acct = Accountability.day(Fx.mon(12), asked: [task: 60], entries: [e], items: [item], now: Fx.mon(18), calendar: Fx.cal)
        XCTAssertEqual(acct.did, 30)
        let slices = TimeLog.past([e], in: Days.dayInterval(Fx.mon(12), Fx.cal), now: Fx.mon(18), calendar: Fx.cal)
        XCTAssertEqual(slices.first { $0.entry != nil }?.minutes, 60, "tracked time is unchanged")
    }
}

final class V16NudgeCapTests: XCTestCase {
    func testSleepOutranksLeavingAndTheLiveActivityTakesStarts() {
        let cal = Fx.cal
        func n(_ id: String, _ k: NudgeKind, _ h: Int) -> PlannedNudge { PlannedNudge(id: id, kind: k, at: Fx.mon(h), title: id, body: "") }
        let xs = [n("wind", .windDown, 22), n("bed", .bedtime, 23), n("sleep", .sleepConfirm, 10), n("leave10", .leaveSoon, 8),
                  n("go", .leaveNow, 9), n("s1", .start, 16), n("s2", .start, 18)]
        let (kept, _) = NudgePlanner.capped(xs, cap: 4, calendar: cal)
        XCTAssertEqual(Set(kept.map(\.id)), ["wind", "bed", "sleep", "go"])
        let (la, _) = NudgePlanner.capped(xs, cap: 5, liveActivity: true, calendar: cal)
        XCTAssertFalse(la.contains { $0.kind == .start })
    }
}

final class V16PauseTests: XCTestCase {
    func testPauseResumeKeepsTheTimeLeftAndStopEndsAtThePause() {
        let task = UUID()
        var es = [Entry(title: "Essay", start: Fx.mon(16), end: nil, category: CategoryTree.studying, taskId: task, source: .you,
                        createdAt: Fx.mon(16))]
        let p = PausedSession.pause(entries: &es, plannedEnd: Fx.mon(16, 40), now: Fx.mon(16, 25), calendar: Fx.cal)!
        XCTAssertNil(TimeLog.running(es))
        XCTAssertEqual(es[0].end, Fx.mon(16, 25), "the time ends at the pause")
        XCTAssertEqual(p.left, 15 * 60)
        let r = p.resume(now: Fx.mon(17))
        XCTAssertEqual(r.op.noun, .task)
        XCTAssertEqual(r.ends, Fx.mon(17, 15), "the countdown carries on")
        let item = WorkItem(id: task, title: "Essay", kind: .essay, due: Fx.mon(12, plusDays: 3))
        let card = NowActivity.make(NowInput(now: Fx.mon(16, 40), calendar: Fx.cal, entries: es, plan: .empty, items: [item],
                                             tree: CategoryTree(), paused: p))!.card
        XCTAssertEqual(card.title, "Paused: Essay")
        XCTAssertEqual(card.buttons.map(\.action), ["resume", "stop"])
    }
}

final class V16QuickParseTests: XCTestCase {
    func testForThePastNMinutes() {
        let items = [WorkItem(title: "Read Frankenstein", kind: .reading, due: Fx.mon(23))]
        let c = QuickContext(now: Fx.mon(20), calendar: Fx.cal, entries: [], items: items)
        let q = QuickParse.parse("frankenstein reading for past 8 mins", c)
        XCTAssertEqual(q?.ops.first?.noun, .task)
        XCTAssertEqual(q?.ops.first?.fields.start, QuickParse.stamp(Fx.mon(19, 52), Fx.cal))
        let h = QuickParse.parse("been doing homework for 20 min", c)
        XCTAssertEqual(h?.ops.first?.fields.title, "Homework")
        XCTAssertEqual(h?.ops.first?.fields.start, QuickParse.stamp(Fx.mon(19, 40), Fx.cal))
    }
}

final class V16OutboxTests: XCTestCase {
    func testAnOldReplyIsntSentByItself() {
        var box = Outbox()
        box.add("delet last annotated bibliography session", source: .app, at: Fx.mon(17, 47))
        XCTAssertEqual(box.due(now: Fx.mon(18)).count, 1)
        XCTAssertTrue(box.due(now: Fx.mon(12, plusDays: 2)).isEmpty)
        XCTAssertEqual(box.stale(now: Fx.mon(12, plusDays: 2)).count, 1)
    }
}

final class V16BackupSizeTests: XCTestCase {
    func testArchivedScreenshotsAreKeptOnceAndExportsCarryAWeekOfTelemetry() {
        var c = Conversation(startedAt: Fx.mon(9))
        let img: JSONValue = .array([.object(["type": .string("image"), "source": .object(["data": .string(String(repeating: "A", count: 1000))])]),
                                     .object(["type": .string("text"), "text": .string("hi")])])
        c.add(ConversationTurn(at: Fx.mon(9), text: "hi", userContent: img, reply: "ok"))
        var a = ConversationArchive()
        a.archive(c, now: Fx.mon(10))
        let data = try! JSONEncoder().encode(a)
        XCTAssertFalse(String(data: data, encoding: .utf8)!.contains("AAAA"))
        var s = AppState()
        s.telemetry.record(.log, "old", at: Fx.mon(9, plusDays: -10))
        s.telemetry.record(.log, "new", at: Fx.mon(9))
        XCTAssertEqual(s.forExport(now: Fx.mon(10)).telemetry.events.map(\.name), ["new"])
    }
}
