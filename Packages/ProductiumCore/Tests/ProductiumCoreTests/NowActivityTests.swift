import XCTest
@testable import ProductiumCore

/// v1.3 Part B: which state the Now Live Activity shows (running > question > untracked > assumed > up next).
final class NowActivityTests: XCTestCase {
    let cal = Fx.cal

    func input(_ now: Date, entries: [Entry], question: Inference? = nil, items: [WorkItem] = [], plan: Plan = .empty,
               prompts: PromptSettings = PromptSettings()) -> NowInput {
        var q = QuickStarts()
        q.seedTemplates(at: Fx.mon(0, plusDays: -3))
        let tiles = q.ranked(entries: entries, now: now, calendar: cal).top
        return NowInput(now: now, calendar: cal, entries: entries, plan: plan, items: items, tree: CategoryTree(),
                        question: question, tiles: tiles, prompts: prompts)
    }

    func told(_ title: String, _ s: Date, _ e: Date?, _ c: CategoryID = CategoryTree.free) -> Entry {
        Entry(title: title, start: s, end: e, category: c, source: .you, createdAt: e ?? s)
    }

    var question: Inference {
        let w = DateInterval(start: Fx.mon(16), end: Fx.mon(16, 25))
        return Inference(id: "walk@t", kind: .walk, interval: w, evidence: ["motion: walking 25 min"], confidence: 0.6, proposal: [],
                         question: "Were you out for a walk?", answers: ["Yes, a walk", "No"], band: .ask)
    }

    func testRunningWinsAndHasStop() {
        let es = Fx.timetable + [told("Gaming", Fx.mon(16), nil)]
        let s = NowActivity.make(input(Fx.mon(16, 30), entries: es, question: question))!
        XCTAssertEqual(s.card.kind, .running)
        XCTAssertEqual(s.card.title, "Gaming")
        XCTAssertEqual(s.card.since, Fx.mon(16))
        XCTAssertEqual(s.card.buttons.first?.action, "stop")
    }

    func testAQuestionBeatsUntracked() {
        let es = Fx.timetable + [told("Bus home", Fx.mon(15), Fx.mon(15, 30), CategoryTree.travel)]
        let s = NowActivity.make(input(Fx.mon(16, 40), entries: es, question: question))!
        XCTAssertEqual(s.card.kind, .question)
        XCTAssertEqual(s.card.buttons.map(\.action), ["answer:walk@t:Yes, a walk", "answer:walk@t:No"])
    }

    func testUntrackedAsksWithTheTopTiles() {
        // Tuesday: no soccer, so after the bus home nothing covers the afternoon.
        let es = Fx.timetable + [told("Bus home", Fx.mon(15, plusDays: 1), Fx.mon(15, 30, plusDays: 1), CategoryTree.travel)]
        let s = NowActivity.make(input(Fx.mon(16, 10, plusDays: 1), entries: es))!
        XCTAssertEqual(s.card.kind, .untracked)
        XCTAssertEqual(s.card.subtitle, "Untracked since 15:30")
        XCTAssertEqual(s.card.buttons.count, QuickStarts.topSize)
        XCTAssertTrue(s.card.buttons.allSatisfy { $0.action.hasPrefix("start:") })
        XCTAssertTrue(s.card.other)
        let off = NowActivity.make(input(Fx.mon(16, 10, plusDays: 1), entries: es, prompts: PromptSettings([.untracked: .notification])))
        XCTAssertNil(off, "set to a notification, it isn't in the activity")
    }

    func testAssumedSchoolAsksAndThenTurnsUntracked() {
        let s = NowActivity.make(input(Fx.mon(10), entries: Fx.timetable))!
        XCTAssertEqual(s.card.kind, .assumed)
        XCTAssertEqual(s.card.title, "School until 15:00", "v1.6 E4: school is shown, not asked about")
        XCTAssertTrue(s.card.buttons.isEmpty)
        XCTAssertEqual(s.until, Fx.mon(15))
        XCTAssertEqual(s.then?.kind, .untracked)
        XCTAssertEqual(s.then?.since, Fx.mon(15))
        let walk = Entry(title: "Walk the dog", start: Fx.mon(9), end: Fx.mon(11), category: CategoryTree.free,
                         repeats: .weekly([2]), source: .you)
        let asked = NowActivity.make(input(Fx.mon(10), entries: [walk]))!
        XCTAssertEqual(asked.card.title, "Still at Walk the dog until 11:00?")
        XCTAssertTrue(asked.card.buttons[0].action.hasPrefix("yes:e"))
    }

    func testUpNextWhenNothingElse() {
        let item = WorkItem(title: "Math unit test", kind: .test, due: Fx.mon(8, 30, plusDays: 2), estimateMinutes: 120)
        let block = PlannedBlock(kind: .work, start: Fx.mon(19), end: Fx.mon(19, 40), title: "Math unit test", itemId: item.id)
        let plan = Plan(generatedAt: Fx.mon(12), blocks: [block], warnings: [], shortfalls: [:], sleepTradeoffMinutes: 0, loadFactor: 1)
        let es = Fx.timetable + [told("Homework", Fx.mon(17, 30), Fx.mon(18, 30), CategoryTree.studying)]
        let s = NowActivity.make(input(Fx.mon(18, 35), entries: es, items: [item], plan: plan))!
        XCTAssertEqual(s.card.kind, .upNext)
        XCTAssertEqual(s.card.title, "Math unit test · 40m at 19:00")
        XCTAssertEqual(s.card.buttons.first?.action, "task:\(item.id.uuidString)")
        XCTAssertEqual(s.card.buttons.count, 1)
        let other = WorkItem(title: "Write UofTHacks application", kind: .application, due: Fx.mon(23, plusDays: 4))
        var two = plan
        two.blocks.append(PlannedBlock(kind: .work, start: Fx.mon(20), end: Fx.mon(20, 40), title: other.title, itemId: other.id))
        let s2 = NowActivity.make(input(Fx.mon(18, 35), entries: es, items: [item, other], plan: two))!
        XCTAssertEqual(s2.card.buttons.map(\.action), ["task:\(item.id.uuidString)", "task:\(other.id.uuidString)"],
                       "v1.6 C5: start something else from the Live Activity")
        XCTAssertEqual(s2.card.buttons.last?.label, "Write UofTHacks a…")
    }

    func testQuietAtNight() {
        XCTAssertNil(NowActivity.make(input(Fx.mon(23, 30), entries: Fx.timetable)))
    }
}
