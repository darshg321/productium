import XCTest
@testable import ProductiumCore

// v1.2 O6 / Part F: reading the model's answer, and the time-query engine.
final class BoxTests: XCTestCase {
    let cal = Fx.cal

    func testReadIsLenient() {
        let v: JSONValue = .object([
            "reply": "Done",
            "ops": .array([
                // Fields beside noun / verb instead of under `fields`, and a null.
                .object(["noun": "entry", "verb": "add", "title": "Walk", "start": "15:00", "end": .null]),
                .object(["noun": "spaceship", "verb": "launch"]),
            ]),
            "queries": .array([.object(["id": "q1", "range": .object(["last": "7d"])])]),
        ])
        let r = BoxResult.read(v, timeZone: cal.timeZone)!
        XCTAssertEqual(r.ops.count, 1)
        XCTAssertEqual(r.ops[0].fields.title, "Walk")
        XCTAssertNil(r.ops[0].fields.end)
        XCTAssertEqual(r.unreadable.count, 1, "the bad op is kept for telemetry, the good one still applies")
        XCTAssertEqual(r.queries.first?.id, "q1")
    }

    func testSchemaAndPromptStayInBudget() {
        XCTAssertLessThanOrEqual(BoxPrompt.system().count, 12_010, "no bigger than v1.1's dump prompt")
        guard case .object(let o) = BoxSchema.result, case .object(let p)? = o["properties"] else { return XCTFail() }
        XCTAssertNotNil(p["ops"])
        XCTAssertNotNil(p["queries"])
    }

    func state() -> (entries: [Entry], tree: CategoryTree) {
        var tree = CategoryTree()
        let math = tree.add("Math", under: CategoryTree.school)!.id
        let now = Fx.mon(20)
        var es: [Entry] = []
        // Three days of a 1h math class and a 30m scroll each, logged by you.
        for d in -2...0 {
            es.append(Entry(title: "Math", start: Fx.mon(9, plusDays: d), end: Fx.mon(10, plusDays: d), category: math, filedByYou: true, source: .you))
            es.append(Entry(title: "TikTok", start: Fx.mon(21, plusDays: d - 1), end: Fx.mon(21, 30, plusDays: d - 1),
                            category: CategoryTree.scrolling, filedByYou: true, topics: ["tiktok"], source: .you))
        }
        _ = now
        return (es, tree)
    }

    func testQueryByCategoryPathAndDay() {
        let (es, tree) = state()
        let q = TimeQuery(id: "q1", range: .init(last: "3d"), filter: .init(categories: ["School › Math"]), groupBy: "day")
        let r = TimeQueryEngine.run(q, entries: es, tree: tree, now: Fx.mon(20), calendar: cal)
        XCTAssertEqual(r.total, 180)
        XCTAssertEqual(r.rows.count, 3)
        XCTAssertEqual(r.rows.map(\.value), [60, 60, 60])
        XCTAssertTrue(r.problems.isEmpty, r.problems.description)
        XCTAssertEqual(QueryText.fill("Math: {q1.total}, {q1.avgPerDay}/day", [r]), "Math: 3h, 1h/day")
    }

    func testQueryUnknownNamesAreProblemsNotEmptyCharts() {
        let (es, tree) = state()
        let q = TimeQuery(id: "q1", range: .init(preset: "this week"), filter: .init(categories: ["Chemistry"]), measure: "vibes")
        let r = TimeQueryEngine.run(q, entries: es, tree: tree, now: Fx.mon(20), calendar: cal)
        XCTAssertTrue(r.problems.contains { $0.contains("Chemistry") }, r.problems.description)
        XCTAssertTrue(r.problems.contains { $0.contains("vibes") }, r.problems.description)
    }

    func testQueryCompareAndShare() {
        let (es, tree) = state()
        let q = TimeQuery(id: "q1", range: .init(last: "1d"), filter: .init(topics: ["tiktok"]), compare: "previous")
        let r = TimeQueryEngine.run(q, entries: es, tree: tree, now: Fx.mon(20), calendar: cal)
        // Today has no scroll yet (it was last night); yesterday had 30m.
        XCTAssertEqual(r.previousTotal, 30)
        let share = TimeQueryEngine.run(TimeQuery(id: "q2", range: .init(last: "3d"), groupBy: "group", measure: "share"),
                                        entries: es, tree: tree, now: Fx.mon(20), calendar: cal)
        XCTAssertEqual(share.rows.reduce(0) { $0 + $1.value }, 1, accuracy: 0.001)
    }
}

final class BoxSideOpsTests: XCTestCase {
    func testPromptStaysUnderBudget() {
        XCTAssertLessThan(BoxPrompt.system().count, 6900)
    }

    func testMoodSettingAndScreenTimeApplyOutsideTheBox() throws {
        let cal = Fx.cal
        let ops = [BoxOp(.mood, .add, BoxFields(note: "tired", mood: 2, energy: 3)),
                   BoxOp(.setting, .change, BoxFields(title: "nudgeLevel", text: "gentle")),
                   BoxOp(.entry, .add, BoxFields(title: "Walk", start: "now"))]
        let (box, side) = BoxSideOps.split(ops)
        XCTAssertEqual(box.count, 1); XCTAssertEqual(side.count, 2)
        var s = AppState(); var me = AboutMe.empty
        let r = BoxSideOps.apply(side, to: &s, aboutMe: &me, now: Fx.mon(12), calendar: cal)
        XCTAssertEqual(s.moods.last?.mood, 2)
        XCTAssertEqual(s.prefs.nudges.level, .gentle, "\(r)")
        var sc = BoxScreen(); sc.minutes = 120; sc.apps = [.init(name: "TikTok", minutes: 70), .init(name: "Maps", minutes: 50)]
        let r2 = BoxSideOps.apply([BoxOp(.screen_time, .add, BoxFields(screen: sc))], to: &s, aboutMe: &me, now: Fx.mon(12), calendar: cal)
        XCTAssertEqual(s.screen.count, 1, "\(r2)")
        XCTAssertEqual(s.screen.first?.totalMinutes, 120)
        XCTAssertTrue(BoxSideOps.apply([BoxOp(.mood, .add, BoxFields(mood: 9))], to: &s, aboutMe: &me, now: Fx.mon(12), calendar: cal).problems.count == 1)
    }
}
