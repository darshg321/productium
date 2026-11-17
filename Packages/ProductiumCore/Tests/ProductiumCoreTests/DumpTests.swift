import XCTest
@testable import ProductiumCore

final class DumpTests: XCTestCase {
    let cal = Fx.cal

    func state(items: [WorkItem] = []) -> DumpState {
        DumpState(items: items, commitments: [Fx.school, Fx.soccer], exceptions: [], oneOffs: [], markers: [],
                  routines: Routine.defaults, moods: [], screen: [], prefs: Preferences())
    }

    @discardableResult
    func run(_ s: inout DumpState, _ ops: [DumpOp], now: Date) -> DumpReport {
        DumpApplier.apply(DumpResult(ops: ops, reply: ""), to: &s, now: now, calendar: cal)
    }

    func testDidntGoToSchoolRemovesSchoolEverywhere() {
        var s = state()
        run(&s, [.upsert("day_change", ["activity": "school", "date": "2026-11-16", "cancelled": true])], now: Fx.mon(11))
        XCTAssertEqual(s.exceptions.count, 1)
        XCTAssertEqual(s.exceptions[0].kind, .school)
        // Planner: no school block or commute today, but tomorrow still has school.
        let input = PlannerInput(now: Fx.mon(11), calendar: cal, items: [], commitments: s.commitments,
                                 routines: s.routines, exceptions: s.exceptions)
        let plan = Planner.plan(input)
        XCTAssertFalse(plan.blocks.contains { $0.title == "School" && cal.isDate($0.start, inSameDayAs: Fx.mon(12)) })
        XCTAssertFalse(plan.blocks.contains { $0.title == "Home from school" && cal.isDate($0.start, inSameDayAs: Fx.mon(12)) })
        XCTAssertTrue(plan.blocks.contains { $0.title == "School" && cal.isDate($0.start, inSameDayAs: Fx.mon(12, plusDays: 1)) })
        // Timeline: the day isn't assumed to be school, and the wake-up is a free-day one.
        let segs = TimelineBuilder.segments(DayInputs(day: Fx.mon(12), events: [], commitments: s.commitments, routines: s.routines,
                                                      outcomes: [], health: nil, screen: nil, prefs: s.prefs, exceptions: s.exceptions),
                                            calendar: cal)
        XCTAssertFalse(segs.contains { $0.category == .school })
        XCTAssertEqual(segs.first { $0.category == .sleep }?.end, Fx.mon(8, 30))
    }

    func testChangedStartTimeAndWakeOverride() {
        var s = state()
        run(&s, [
            .upsert("day_change", ["activity": "school", "date": "2026-11-17", "start": "10:00"]),
            .upsert("day_change", ["date": "2026-11-21", "wake": "10:30"]),
        ], now: Fx.mon(20))
        let tue = WakePlanner.plan(for: Fx.mon(0, plusDays: 1), commitments: s.commitments, events: [], routines: s.routines,
                                   prefs: s.prefs, calendar: cal, exceptions: s.exceptions)
        XCTAssertEqual(tue.firstCommitment, Fx.mon(10, 0, plusDays: 1))
        let sat = WakePlanner.plan(for: Fx.mon(0, plusDays: 5), commitments: s.commitments, events: [], routines: s.routines,
                                   prefs: s.prefs, calendar: cal, exceptions: s.exceptions)
        XCTAssertEqual(sat.wake, Fx.mon(10, 30, plusDays: 5))
    }

    func testTaskCrudWithFuzzyNames() {
        let essay = WorkItem(title: "English essay on Gatsby", kind: .essay, due: Fx.mon(23, 59, plusDays: 5))
        var s = state(items: [essay])
        let log = run(&s, [
            .upsert("task", ["title": "Bio quiz", "kind": "quiz", "due": "2026-11-19T08:00"]),
            .upsert("task", ["target": "gatsby essay", "due": "2026-11-24T23:59", "doneMinutes": 30]),
            .upsert("task", ["target": "bio quiz", "done": true]),
            DumpOp("delete", entity: "task", fields: ["target": "nonexistent thing"]),
        ], now: Fx.mon(18))
        XCTAssertEqual(s.items.count, 2)
        XCTAssertEqual(s.items[0].due, Fx.mon(23, 59, plusDays: 8))
        XCTAssertEqual(s.items[0].completedMinutes, 30)
        XCTAssertTrue(s.items[1].isDone)
        XCTAssertEqual(log.changes.count, 3)
        XCTAssertEqual(log.problems.count, 1, "the missing task is reported, not silently dropped")
    }

    /// B9: progress is absolute, so re-stating a total doesn't add it again.
    func testRestatedProgressIsNotDoubleCounted() {
        let apps = WorkItem(title: "University applications", kind: .application, due: Fx.mon(23, plusDays: 40))
        var s = state(items: [apps])
        let ref = Ref.task(apps.id)
        run(&s, [.upsert("task", id: ref, ["doneMinutes": 200])], now: Fx.mon(18))
        run(&s, [.upsert("task", id: ref, ["doneMinutes": 200])], now: Fx.mon(19))
        XCTAssertEqual(s.items[0].completedMinutes, 200)
    }

    func testLogsRoutinesScreenTimeSettings() {
        var s = state()
        run(&s, [
            .upsert("marker", ["activity": "sleep", "phase": "end", "at": "2026-11-16T09:00"]),
            .upsert("marker", ["activity": "future", "at": "2026-11-16T23:00"]),
            .upsert("routine", id: "to_school", ["minutes": 25]),
            .upsert("screen_time", ["date": "2026-11-15", "screenMinutes": 300,
                                    "apps": [["name": "TikTok", "minutes": 120, "distracting": true],
                                             ["name": "Notes", "minutes": 30, "distracting": false]]]),
            .set("sleepNeedMinutes", "300"),
            .upsert("mood", ["mood": 2, "note": "tired"]),
        ], now: Fx.mon(12))
        XCTAssertEqual(s.markers[0].at, Fx.mon(9))
        XCTAssertEqual(s.markers[1].at, Fx.mon(12), "future log clamps to now")
        XCTAssertEqual(s.routines.first { $0.id == "to_school" }?.minutes, 25)
        XCTAssertEqual(s.screen.first?.distractingMinutes, 120)
        XCTAssertEqual(s.prefs.sleepNeedMinutes, 450, "sleep floor holds")
        let segs = TimelineBuilder.segments(DayInputs(day: Fx.mon(12), events: s.markers, commitments: [], routines: [], outcomes: [],
                                                      health: nil, screen: nil, prefs: s.prefs), calendar: cal, now: Fx.mon(12))
        XCTAssertEqual(segs.first?.category, .sleep)
        XCTAssertEqual(segs.first?.end, Fx.mon(9))
        XCTAssertEqual(s.moods.first?.mood, 2)
    }

    func testActivitiesAndMessageEncoding() throws {
        var s = state()
        run(&s, [
            .upsert("activity", ["title": "Debate", "weekdays": [3], "start": "15:30", "end": "17:00"]),
            .upsert("activity", ["target": "soccer", "start": "16:30"]),
            .upsert("event", ["title": "Dentist", "date": "2026-11-18", "start": "16:00", "end": "17:00"]),
        ], now: Fx.mon(12))
        XCTAssertEqual(s.commitments.count, 3)
        XCTAssertEqual(s.commitments.first { $0.title == "Soccer practice" }?.start, TimeOfDay(16, 30))
        XCTAssertEqual(s.oneOffs.first?.start, Fx.mon(16, plusDays: 2))
        // Images go out as content blocks; text-only stays a string.
        let withImage = String(data: try JSONEncoder().encode(AIMessage(role: "user", content: "hi", images: [AIImage(mediaType: "image/png", base64: "AA==")])), encoding: .utf8)!
        XCTAssertTrue(withImage.contains("\"type\":\"image\"") && withImage.contains("media_type"))
        let back = try JSONDecoder().decode(AIMessage.self, from: Data(withImage.utf8))
        XCTAssertEqual(back.images.count, 1)
        XCTAssertEqual(back.content, "hi")
    }
}
