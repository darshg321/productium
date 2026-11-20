import Foundation
import ProductiumCore

// v1.2 F2: the six questions from plan Part F, asked of the box over a 28-day world. The check is the query the model
// wrote, run through `TimeQueryEngine`: it must give the expected number (the model never writes the numbers itself,
// so the reply must carry a {q1.…} placeholder). `--v12q-reference` and `--v12q-nothing` need no network.

struct V12QueryCase {
    let id: String
    let why: String
    let text: String
    let reference: TimeQuery
    let check: (QueryResult) -> [String]
}

enum V12Queries {
    typealias W = World
    /// Sunday 13 Dec 2026, evening: the 28 days are Mon 16 Nov … Sun 13 Dec.
    /// Weeks start on Monday for this student ("this week" = Mon 7 – Sun 13 Dec).
    static let cal: Calendar = { var c = World.cal; c.firstWeekday = 2; c.minimumDaysInFirstWeek = 4; return c }()
    static let now = W.cal.date(from: DateComponents(year: 2026, month: 12, day: 13, hour: 20))!

    static func day(_ offset: Int, _ h: Int, _ m: Int = 0) -> Date {
        let base = W.cal.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: h, minute: m))!
        return W.cal.date(byAdding: .day, value: offset, to: base)!
    }

    /// Math class and English every weekday (one absence, Wed 25 Nov), Math homework Mon / Wed evenings (the last
    /// Wednesday skipped), scrolling Tue (an hour) and Thu (half an hour) nights.
    static func world() -> BoxState {
        var tree = CategoryTree()
        let math = tree.add("Math", under: CategoryTree.school)!.id
        let english = tree.add("English", under: CategoryTree.school)!.id
        var m = Entry(title: "Math", start: day(0, 9), end: day(0, 10), category: math, topics: ["math"],
                      repeats: .weekly([2, 3, 4, 5, 6]), source: .you)
        m.marks["2026-11-25"] = .skipped
        var es = [m, Entry(title: "English", start: day(0, 10), end: day(0, 11), category: english, topics: ["english"],
                           repeats: .weekly([2, 3, 4, 5, 6]), source: .you)]
        for week in 0..<4 {
            for dow in [0, 2] where !(week == 3 && dow == 2) {
                es.append(Entry(title: "Math homework", start: day(week * 7 + dow, 19), end: day(week * 7 + dow, 19, 45),
                                category: CategoryTree.studying, filedByYou: true, topics: ["math"], source: .you))
            }
            es.append(Entry(title: "TikTok", start: day(week * 7 + 1, 22), end: day(week * 7 + 1, 23),
                            category: CategoryTree.scrolling, filedByYou: true, topics: ["tiktok"], source: .you))
            es.append(Entry(title: "TikTok", start: day(week * 7 + 3, 22), end: day(week * 7 + 3, 22, 30),
                            category: CategoryTree.scrolling, filedByYou: true, topics: ["tiktok"], source: .you))
        }
        return BoxState(entries: es, categories: tree, sleepFloorMinutes: 420)
    }

    static func expect(_ r: QueryResult, total: Double, _ what: String) -> [String] {
        abs(r.total - total) < 0.5 ? [] : ["\(what): total \(r.total), expected \(total)"]
    }

    static let cases: [V12QueryCase] = [
        V12QueryCase(id: "math-class-28d", why: "an exact class: the category, not the topic", text: "how much time did i spend in math class in the past 28 days",
                     reference: TimeQuery(id: "q1", range: .init(last: "28d"), filter: .init(categories: ["School › Math"])),
                     check: { expect($0, total: 19 * 60, "math class") + ($0.problems.isEmpty ? [] : ["problems: \($0.problems)"]) }),
        V12QueryCase(id: "all-math-4w", why: "a topic adds homework to the class", text: "how much time total have i spent on math the last 4 weeks",
                     reference: TimeQuery(id: "q1", range: .init(last: "28d"), filter: .init(topics: ["math"])),
                     check: { expect($0, total: 19 * 60 + 7 * 45, "all math") }),
        V12QueryCase(id: "most-unproductive-hour", why: "group by hour, a heat of one group", text: "when am i most unproductive",
                     reference: TimeQuery(id: "q1", range: .init(last: "28d"), filter: .init(groups: ["unproductive"]), groupBy: "hour", chart: "heatmap"),
                     check: { r in
                         var f = expect(r, total: 4 * 90, "unproductive")
                         if r.rows.max(by: { $0.value < $1.value })?.label.contains("22") != true { f.append("busiest hour should be 22: \(r.rows.map(\.label))") }
                         return f
                     }),
        V12QueryCase(id: "homework-this-week-vs-last", why: "compare to the previous period; 'homework' is not 'math'", text: "have i done less homework this week than last week",
                     reference: TimeQuery(id: "q1", range: .init(preset: "this week"), filter: .init(titles: ["homework"]), compare: "previous"),
                     check: { r in
                         var f = expect(r, total: 45, "this week")
                         if r.previousTotal != 90 { f.append("last week \(r.previousTotal.map { "\($0)" } ?? "none"), expected 90") }
                         return f
                     }),
        V12QueryCase(id: "scrolling-by-weekday", why: "group by weekday", text: "which day of the week do i scroll the most",
                     reference: TimeQuery(id: "q1", range: .init(last: "28d"), filter: .init(categories: ["Scrolling"]), groupBy: "weekday"),
                     check: { r in
                         var f = expect(r, total: 4 * 90, "scrolling")
                         if r.rows.max(by: { $0.value < $1.value })?.value != 240 { f.append("Tuesday should lead with 240: \(r.rows.map { "\($0.label)=\($0.value)" })") }
                         return f
                     }),
        V12QueryCase(id: "scroll-sessions-2w", why: "a count, not minutes", text: "how many times did i scroll tiktok in the last 2 weeks",
                     reference: TimeQuery(id: "q1", range: .init(last: "14d"), filter: .init(topics: ["tiktok"]), measure: "count"),
                     check: { r in expect(r, total: 4, "sessions") + (r.measure == "count" ? [] : ["measure should be count, was \(r.measure)"]) }),
    ]

    static func run(reference: Bool, nothing: Bool = false, only: String? = nil, verbose: Bool = false) async -> Bool {
        var passed = 0, total = 0, tokensOut = 0
        let s = world()
        let planned: [Entry] = []
        for c in cases where only.map({ c.id.contains($0) }) ?? true {
            total += 1
            var queries: [TimeQuery] = [], reply = "", fails: [String] = []
            if nothing {
            } else if reference {
                queries = [c.reference]
                reply = "{q1.total}"
            } else {
                let context = BoxContext.make(BoxContextInput(now: now, calendar: W.cal, state: s, planned: planned, settings: W.settings))
                let (req, _) = BoxTurn.request(Conversation(startedAt: now), context: context, text: c.text)
                do {
                    let res = try await V12.send(req)
                    guard let r = BoxResult.read(res, timeZone: W.cal.timeZone) else {
                        print("FAIL", c.id, "\n   unreadable: \(res.text.prefix(300))"); continue
                    }
                    tokensOut += res.tokens.output
                    queries = r.queries
                    reply = r.reply
                    if verbose { print("   “\(c.text)” → \((try? String(data: JSONEncoder().encode(r.queries), encoding: .utf8)!) ?? "") | \(r.reply)") }
                    if !r.ops.isEmpty { fails.append("changed things: \(r.ops.count) ops") }
                } catch {
                    print("FAIL", c.id, "\n   \(error.localizedDescription.prefix(300))"); continue
                }
            }
            if let q = queries.first {
                let result = TimeQueryEngine.run(q, entries: s.entries, items: s.items, tree: s.categories, now: now,
                                                 book: s.dayRules, calendar: cal)
                fails += c.check(result)
                if !reply.contains("{\(q.id).") { fails.append("the reply should use a {\(q.id).…} placeholder, not write numbers: “\(reply.prefix(120))”") }
            } else {
                fails.append("no query")
            }
            print(fails.isEmpty ? "PASS" : "FAIL", c.id, fails.isEmpty ? "" : "\n   " + fails.joined(separator: "\n   "))
            if fails.isEmpty { passed += 1 }
        }
        print("\(passed)/\(total) passed" + (tokensOut > 0 ? ", \(tokensOut) output tokens" : ""))
        return nothing ? passed == 0 : passed == total
    }
}
