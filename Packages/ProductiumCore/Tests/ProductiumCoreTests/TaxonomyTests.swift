import XCTest
@testable import ProductiumCore

/// v1.2 C5–C6: duplicate leaves merge with their time; your nodes, filings and corrections are never undone; revert.
final class TaxonomyTests: XCTestCase {
    func fixture() -> (CategoryTree, [Entry], CategoryRules) {
        var tree = CategoryTree()
        let bball = tree.add("Bball", under: CategoryTree.extracurricular)!
        let basketball = tree.add("Basketball practice", under: CategoryTree.extracurricular)!
        let hoops = tree.add("Hoops", under: CategoryTree.free)!
        let mine = tree.add("Making App", under: CategoryTree.free, yours: true)!
        let gaming = tree.add("Gaming", under: CategoryTree.work)!
        var es: [Entry] = []
        for (i, c) in [bball.id, basketball.id, hoops.id, basketball.id, mine.id, gaming.id].enumerated() {
            es.append(Entry(title: tree.node(c)!.name, start: Fx.mon(16, plusDays: -i), end: Fx.mon(17, plusDays: -i), category: c,
                            source: .you, createdAt: Fx.mon(17, plusDays: -i)))
        }
        return (tree, es, CategoryRules())
    }

    func testDuplicatesMergeWithTheirTimeYoursUntouchedAndRevertRestores() {
        var (tree, es, rules) = fixture()
        let total = es.reduce(0) { $0 + $1.minutes() }
        let ops = [
            TaxonomyOp(op: "merge", id: "work.extracurricular.bball", into: "work.extracurricular.basketballpractice", reason: "same"),
            TaxonomyOp(op: "merge", id: "free.hoops", into: "work.extracurricular.basketballpractice", reason: "same"),
            TaxonomyOp(op: "rename", id: "work.extracurricular.basketballpractice", name: "Basketball", reason: "clearer"),
            TaxonomyOp(op: "move", id: "work.gaming", under: CategoryTree.free, reason: "not work"),
            TaxonomyOp(op: "merge", id: "free.makingapp", into: CategoryTree.free, reason: "x"),
            TaxonomyOp(op: "merge", id: CategoryTree.scrolling, into: CategoryTree.free, reason: "x"),
        ]
        let before = tree
        let (run, refused) = TaxonomyPass.apply(ops, tree: &tree, entries: &es, rules: &rules, now: Fx.mon(20))
        XCTAssertEqual(run?.lines.count, 4)
        XCTAssertEqual(refused.count, 2, "\(refused)")
        XCTAssertTrue(refused.contains("merge: Making App is yours"))
        XCTAssertTrue(refused.contains("merge: Scrolling is fixed"))
        XCTAssertEqual(tree.pathText("work.extracurricular.basketballpractice"), "Work › Extracurricular › Basketball")
        XCTAssertEqual(es.filter { $0.category == "work.extracurricular.basketballpractice" }.count, 4)
        XCTAssertEqual(es.reduce(0) { $0 + $1.minutes() }, total, "no time lost")
        XCTAssertEqual(tree.pathText("work.gaming"), "Free Time › Gaming")
        XCTAssertTrue(tree.nodes.count < before.nodes.count)
        TaxonomyPass.revert(run!, tree: &tree, entries: &es)
        XCTAssertEqual(tree, before)
        XCTAssertEqual(es.filter { $0.category == "work.extracurricular.bball" }.count, 1)
    }

    func testFiledByYouAndCorrectionsAreNeverUndone() {
        var (tree, es, rules) = fixture()
        es[0].filedByYou = true
        rules.correct("Hoops", from: CategoryTree.free, to: "free.hoops", at: Fx.mon(9))
        let (run, refused) = TaxonomyPass.apply([
            TaxonomyOp(op: "merge", id: "work.extracurricular.bball", into: "work.extracurricular.basketballpractice", reason: "same"),
            TaxonomyOp(op: "merge", id: "free.hoops", into: "work.extracurricular.basketballpractice", reason: "same"),
        ], tree: &tree, entries: &es, rules: &rules, now: Fx.mon(20))
        XCTAssertNil(run)
        XCTAssertEqual(refused, ["merge: you filed time under Bball", "merge: a correction of yours points at Hoops"])
    }

    func testDueAtMostDailyAndWhenThinLeavesFill() {
        var (tree, es, _) = fixture()
        var log = TaxonomyLog()
        XCTAssertFalse(TaxonomyPass.due(tree: tree, entries: es, log: log, now: Fx.mon(20)))
        let leaf = tree.add("Chess", under: CategoryTree.free)!
        for i in 0..<10 {
            es.append(Entry(title: "Chess \(i)", start: Fx.mon(10), end: Fx.mon(10, 10), category: leaf.id,
                            source: .you, createdAt: Fx.mon(10)))
        }
        XCTAssertTrue(TaxonomyPass.due(tree: tree, entries: es, log: log, now: Fx.mon(20)))
        log.lastRun = Fx.mon(12)
        XCTAssertFalse(TaxonomyPass.due(tree: tree, entries: es, log: log, now: Fx.mon(20)), "not twice a day")
        let text = TaxonomyPass.request(tree: tree, entries: es, rules: CategoryRules(), now: Fx.mon(20), calendar: Fx.cal)
        XCTAssertTrue(text.contains("free.makingapp Making App [yours]"))
        XCTAssertTrue(text.contains("unproductive.scrolling Scrolling [fixed]"))
    }
}
