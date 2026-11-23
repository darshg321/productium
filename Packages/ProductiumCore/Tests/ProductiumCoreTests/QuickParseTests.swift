import XCTest
@testable import ProductiumCore

/// v1.2 O7: the local fast path is certain or passes. Every phrasing below is handled with no network; every message
/// in `needsSonnet` must pass (a wrong local guess is worse than a slower right answer).
final class QuickParseTests: XCTestCase {
    let cal = Fx.cal
    let now = Fx.mon(18)
    let essay = WorkItem(title: "Gatsby essay", kind: .essay, due: Fx.mon(9, plusDays: 4))
    let reading = WorkItem(title: "Frankenstein reading", kind: .reading, due: Fx.mon(9, plusDays: 3))
    let history = WorkItem(title: "History reading", kind: .reading, due: Fx.mon(9, plusDays: 5))
    let review = WorkItem(title: "DayOneOf review", kind: .other, due: Fx.mon(9, plusDays: 2))

    let timetable = Fx.timetable

    func ctx(running: Entry? = nil) -> QuickContext {
        QuickContext(now: now, calendar: cal, entries: timetable + (running.map { [$0] } ?? []),
                     items: [essay, reading, history, review])
    }

    var shower: Entry { Entry(title: "Shower", start: Fx.mon(17, 50), end: nil, category: "essentials.shower", source: .you) }
    var readingRun: Entry {
        Entry(title: "Frankenstein reading", start: Fx.mon(17, 30), end: nil, category: CategoryTree.studying, taskId: reading.id, source: .you)
    }

    func p(_ s: String, running: Entry? = nil) -> QuickParsed? { QuickParse.parse(s, ctx(running: running)) }

    func testStarts() {
        let plain = ["starting shower", "Starting shower.", "start shower", "started shower", "im starting shower", "i'm starting shower",
                     "starting my shower", "ok starting shower", "now starting shower", "begin shower", "beginning shower",
                     "Starting Shower!", "starting  shower", "doing shower", "starting volleyball practice", "starting gaming",
                     "starting tiktok", "starting dinner", "starting homework", "start walk to school"]
        for s in plain {
            let r = p(s)
            XCTAssertEqual(r?.kind, .start, s)
            XCTAssertEqual(r?.ops.first?.noun, .entry, s)
            XCTAssertNil(r?.ops.first?.fields.start, s)
        }
        XCTAssertEqual(p("starting shower")?.ops[0].fields.category, "essentials.shower")
        XCTAssertEqual(p("starting tiktok")?.ops[0].fields.category, CategoryTree.scrolling)
        XCTAssertEqual(p("starting volleyball practice")?.ops[0].fields.category, CategoryTree.extracurricular)
        XCTAssertEqual(p("starting dinner")?.ops[0].fields.category, CategoryTree.meals)
        XCTAssertEqual(p("starting homework")?.ops[0].fields.category, CategoryTree.studying)
    }

    func testBackdatedStarts() {
        XCTAssertEqual(p("started shower 10 minutes ago")?.ops[0].fields.start, "2026-11-16 17:50")
        XCTAssertEqual(p("started shower 10 min ago")?.ops[0].fields.start, "2026-11-16 17:50")
        XCTAssertEqual(p("started shower like 10 mins ago")?.ops[0].fields.start, "2026-11-16 17:50")
        XCTAssertEqual(p("started gaming an hour ago")?.ops[0].fields.start, "2026-11-16 17:00")
        XCTAssertEqual(p("started gaming half an hour ago")?.ops[0].fields.start, "2026-11-16 17:30")
        XCTAssertEqual(p("started homework 2 hours ago")?.ops[0].fields.start, "2026-11-16 16:00")
    }

    func testTaskStarts() {
        for s in ["starting gatsby essay", "start gatsby essay", "starting the gatsby essay", "starting dayoneof review",
                  "started frankenstein reading 5 min ago", "starting essay"] {
            let r = p(s)
            XCTAssertEqual(r?.ops.first?.noun, .task, s)
            XCTAssertEqual(r?.ops.first?.verb, .start, s)
        }
        XCTAssertEqual(p("starting essay")?.ops[0].ref, Ref.task(essay.id))
    }

    func testStopsAndDone() {
        for s in ["done", "Done.", "stop", "stopped", "finished", "i'm done", "im done", "all done", "done for now", "over", "end",
                  "done with shower", "done shower", "finished shower", "stopping", "done 5 min ago", "done just now", "that's it"] {
            let r = p(s, running: shower)
            XCTAssertEqual(r?.kind, .stop, s)
            XCTAssertEqual(r?.ops.first?.verb, .stop, s)
        }
        XCTAssertEqual(p("done 5 min ago", running: shower)?.ops[0].fields.end, "2026-11-16 17:55")
        // "done X" for the running task's task = task done (that also stops it).
        XCTAssertEqual(p("done frankenstein reading", running: readingRun)?.kind, .taskDone)
        XCTAssertEqual(p("done reading", running: readingRun)?.kind, .taskDone)
        XCTAssertEqual(p("done", running: readingRun)?.kind, .stop, "bare done ends the session, not the task")
        // A task done with nothing running.
        XCTAssertEqual(p("done gatsby essay")?.ops.first?.ref, Ref.task(essay.id))
        XCTAssertEqual(p("finished the gatsby essay")?.kind, .taskDone)
    }

    func testLogs() {
        let cases: [(String, String, String, String)] = [
            ("volleyball 3 to 5", "Volleyball", "2026-11-16 15:00", "2026-11-16 17:00"),
            ("volleyball from 3 to 5", "Volleyball", "2026-11-16 15:00", "2026-11-16 17:00"),
            ("i was at volleyball 3 to 5", "Volleyball", "2026-11-16 15:00", "2026-11-16 17:00"),
            ("3 to 5 volleyball", "Volleyball", "2026-11-16 15:00", "2026-11-16 17:00"),
            ("3 to 5 i was at volleyball", "Volleyball", "2026-11-16 15:00", "2026-11-16 17:00"),
            ("from 3 to 5, volleyball", "Volleyball", "2026-11-16 15:00", "2026-11-16 17:00"),
            ("shower 4:30-4:50", "Shower", "2026-11-16 16:30", "2026-11-16 16:50"),
            ("shower 4:30 – 4:50", "Shower", "2026-11-16 16:30", "2026-11-16 16:50"),
            ("tiktok from 10 till 11:30am", "Tiktok", "2026-11-16 10:00", "2026-11-16 11:30"),
            ("was on tiktok from 10 till like 11:30am", "Tiktok", "2026-11-16 10:00", "2026-11-16 11:30"),
            ("gaming 4pm to 5pm", "Gaming", "2026-11-16 16:00", "2026-11-16 17:00"),
            ("homework 16:00 to 17:15", "Homework", "2026-11-16 16:00", "2026-11-16 17:15"),
            ("dinner 5:30 to 6", "Dinner", "2026-11-16 17:30", "2026-11-16 18:00"),
            ("walk 7 to 7:30am", "Walk", "2026-11-16 07:00", "2026-11-16 07:30"),
        ]
        for (s, title, a, b) in cases {
            let r = p(s)
            XCTAssertEqual(r?.kind, .log, s)
            XCTAssertEqual(r?.ops.first?.fields.title, title, s)
            XCTAssertEqual(r?.ops.first?.fields.start, a, s)
            XCTAssertEqual(r?.ops.first?.fields.end, b, s)
        }
        XCTAssertEqual(p("gatsby essay 3 to 5")?.ops.first?.fields.task, Ref.task(essay.id), "time on a task is the task's")
    }

    func testBackfill() {
        let cases: [(String, String, String)] = [
            ("productium development since 17:15", "Productium development", "2026-11-16 17:15"),
            ("doing productium development since 10 mins ago", "Productium development", "2026-11-16 17:50"),
            ("have been doing productium work since 5:50", "Productium work", "2026-11-16 17:50"),
            ("productium development 5 minutes ago", "Productium development", "2026-11-16 17:55"),
            ("i've been gaming since 4", "Gaming", "2026-11-16 16:00"),
            ("start productium development 5 minutes ago", "Productium development", "2026-11-16 17:55"),
        ]
        for (s, title, at) in cases {
            let r = p(s)
            XCTAssertEqual(r?.kind, .start, s)
            XCTAssertEqual(r?.ops.first?.fields.title, title, s)
            XCTAssertEqual(r?.ops.first?.fields.start, at, s)
        }
        XCTAssertTrue(QuickParse.endsInTimeWord("Productium development since"))
        XCTAssertFalse(QuickParse.endsInTimeWord("Productium development"))
    }

    func testWakeAndGettingReady() {
        let night = Entry(title: "Sleep", start: Fx.mon(0, 30), end: Fx.mon(7, 30), category: CategoryTree.sleep, source: .sensor)
        let ready = Entry(title: "Get ready", start: Fx.mon(7, 30), end: Fx.mon(8, 10), category: CategoryTree.gettingReady, source: .plan)
        let at9 = QuickContext(now: Fx.mon(9), calendar: cal, entries: [night, ready], items: [])
        let woke = QuickParse.parse("woke up at 8:15", at9)
        XCTAssertEqual(woke?.ops.first?.verb, .change)
        XCTAssertEqual(woke?.ops.first?.fields.end, "2026-11-16 08:15")
        XCTAssertEqual(QuickParse.parse("out of bed", at9)?.ops.first?.fields.category, CategoryTree.gettingReady)
        let done = QuickParse.parse("done getting ready", at9)
        XCTAssertEqual(done?.ops.first?.ref, EntryRef.entry(ready.id, occurrence: nil))
        XCTAssertEqual(done?.ops.first?.fields.end, "2026-11-16 09:00")
        let tiles = [QuickStart(title: "Shower", category: "essentials.shower", createdAt: now)]
        let c = QuickContext(now: now, calendar: cal, entries: [], items: [], tiles: tiles)
        XCTAssertEqual(QuickParse.parse("shower", c)?.ops.first?.verb, .start)
        XCTAssertEqual(QuickParse.parse("shower", c)?.ops.first?.fields.title, "Shower")
    }

    func testMoods() {
        XCTAssertEqual(p("mood 4")?.ops.first?.fields.mood, 4)
        XCTAssertEqual(p("mood: 2/5")?.ops.first?.fields.mood, 2)
        XCTAssertEqual(p("feeling 5 out of 5")?.ops.first?.fields.mood, 5)
        XCTAssertEqual(p("😊")?.ops.first?.fields.mood, 5)
        XCTAssertEqual(p("😔")?.ops.first?.fields.mood, 2)
        XCTAssertNil(p("mood 7"))
    }

    func testSchoolAsUsualConfirmsTodaysAssumedSchool() {
        let r = p("school as usual")
        XCTAssertEqual(r?.kind, .confirm)
        XCTAssertEqual(r?.ops.count, 1)
        var s = BoxState(entries: timetable)
        let receipt = BoxApplier.apply(r!.ops, to: &s, now: now, calendar: cal)
        XCTAssertTrue(receipt.problems.isEmpty, "\(receipt.problems)")
        XCTAssertEqual(s.entries[0].marks["2026-11-16"], .confirmed)
    }

    /// Messages that need judgement: none may be taken locally.
    func testNeedsSonnet() {
        let needsSonnet = [
            "starting reading",                                 // two reading tasks
            "starting homework at 7",                           // future
            "starting shower and then homework",                // two things
            "starting homework tomorrow",
            "start studying for the bio test on friday",
            "done", "stop",                                     // nothing running (checked below with no running entry)
            "done with it",
            "done reading",                                     // nothing running, two reading tasks
            "i didn't do valorant today",
            "no school tomorrow",
            "move my reading to tomorrow",
            "my timetable is p1 math 8:26 to 9:38",
            "volleyball 3 to 5 tomorrow",
            "volleyball 8 to 10",                               // 20:00-22:00 hasn't happened; 8-10am is fine… but ambiguous with the evening? (past only)
            "how much math did i do this week",
            "what should i do now?",
            "remind me to call mom at 6",
            "bio quiz thursday",
            "essay due friday, about 3 hours",
            "that was actually 3:30",
            "actually i just finished just now",
            "finished just now",                                // nothing running
            "end of school to now i was gaming",
            "i was gaming from end of school until now",
            "shower every night around 9:30",
            "gym 5 to 7 and then dinner",
            "starting the thing we talked about",
            "starting",
            "start it",
            "mood is kinda bad",
            "feeling tired",
            "school was cancelled",
            "school as usual except math",
            "screen time 4h today",
            "slept 11 to 7",                                    // across midnight: not today's stretch
            "studied 30 minutes",
            "brag sheet today is only 15 mins",
            "can you plan my week",
            "starting homework for 30 min",
        ]
        for s in needsSonnet {
            let r = p(s)
            if s == "volleyball 8 to 10" {
                XCTAssertEqual(r?.ops.first?.fields.start, "2026-11-16 08:00", "only the past reading is possible: 8–10 am")
                continue
            }
            XCTAssertNil(r, "should pass to Sonnet: \(s) → \(String(describing: r))")
        }
        XCTAssertEqual(needsSonnet.count, 40)
    }

    func testAppliesThroughTheBox() {
        var s = BoxState(entries: Fx.timetable, items: [essay])
        let r = BoxApplier.apply(p("starting shower")!.ops, to: &s, now: now, calendar: cal)
        XCTAssertEqual(r.lines.last, "Started Shower at 18:00")
        XCTAssertEqual(TimeLog.running(s.entries)?.category, "essentials.shower")
        let q = QuickContext(now: now.addingTimeInterval(900), calendar: cal, entries: s.entries, items: s.items)
        let stop = BoxApplier.apply(QuickParse.parse("done", q)!.ops, to: &s, now: now.addingTimeInterval(900), calendar: cal)
        XCTAssertEqual(stop.lines, ["Stopped Shower at 18:15 (15m)"])
    }

    func testCategoryRulesLearnAndYourCorrectionsWin() {
        var rules = CategoryRules()
        let tree = CategoryTree()
        XCTAssertEqual(rules.category(for: "Bball", tree: tree), CategoryTree.other)
        rules.learn("Bball", CategoryTree.extracurricular, byYou: false, at: now)
        XCTAssertEqual(rules.category(for: "bball", tree: tree), CategoryTree.extracurricular)
        rules.correct("Shower", from: "essentials.shower", to: CategoryTree.free, at: now)
        XCTAssertEqual(rules.category(for: "Shower", tree: tree), CategoryTree.free, "your correction beats the fallback")
        rules.learn("Shower", "essentials.shower", byYou: false, at: now)
        XCTAssertEqual(rules.category(for: "Shower", tree: tree), CategoryTree.free, "and the box can't undo it")
        XCTAssertEqual(rules.corrections.count, 1)
        // Periods: a class name in the title is a topic; the task's subject is too.
        var t2 = tree
        let math = t2.add("Math", under: CategoryTree.school)!
        XCTAssertEqual(CategoryRules.topics(for: "P1 Math", category: math.id, tree: t2), ["math"])
        XCTAssertEqual(CategoryRules.topics(for: "math homework", category: CategoryTree.studying, tree: t2), ["math"])
        let bio = WorkItem(title: "Bio quiz", kind: .quiz, subject: "Biology", due: now, topics: ["cells"])
        XCTAssertEqual(CategoryRules.topics(for: "Bio quiz", category: CategoryTree.studying, task: bio, tree: t2), ["biology", "cells"])
        XCTAssertEqual(rules.category(for: "Bio quiz", task: bio, tree: t2), CategoryTree.studying)
    }
}
