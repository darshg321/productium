import Foundation
import FoundationNetworking
import ProductiumCore

// v1.2 cases from real prompts (V12Cases.swift): `--v12-reference` checks the cases with reference answers, no
// network; `--v12-nothing` checks that doing nothing fails every case; `--v12` asks the model through the box.
// `--v12 <case id part>` runs only matching cases; `-v` prints every transcript.
if let mode = CommandLine.arguments.dropFirst().first, mode.hasPrefix("--v12q") {
    let rest = CommandLine.arguments.dropFirst(2)
    exit(await V12Queries.run(reference: mode == "--v12q-reference", nothing: mode == "--v12q-nothing",
                              only: rest.first { !$0.hasPrefix("-") }, verbose: rest.contains("-v")) ? 0 : 1)
}

if let mode = CommandLine.arguments.dropFirst().first, mode.hasPrefix("--v12"), !mode.hasPrefix("--v12q") {
    let rest = CommandLine.arguments.dropFirst(2)
    exit(await V12.run(reference: mode == "--v12-reference", nothing: mode == "--v12-nothing",
                       only: rest.first { !$0.hasPrefix("-") }, verbose: rest.contains("-v")) ? 0 : 1)
}

let base = URL(string: ProcessInfo.processInfo.environment["CS_URL"]!)!
let key = ProcessInfo.processInfo.environment["CS_KEY"]!
var cal = Calendar(identifier: .gregorian)
cal.timeZone = TimeZone(identifier: "America/Vancouver")!
let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 19, minute: 10))!

var tree = CategoryTree()
var timetable: [Entry] = []
Timetable.write(Commitment(title: "School", kind: .school, weekdays: [2, 3, 4, 5, 6], start: TimeOfDay(8, 30), end: TimeOfDay(15, 0)),
                into: &timetable, tree: &tree, anchor: now, calendar: cal)
Timetable.write(Commitment(title: "Soccer practice", kind: .extracurricular, weekdays: [2, 4], start: TimeOfDay(16), end: TimeOfDay(17, 30)),
                into: &timetable, tree: &tree, anchor: now, calendar: cal)
var s = DumpState(items: [
    WorkItem(title: "Calc problem set 5", kind: .assignment, subject: "Math", due: now.addingTimeInterval(2 * 86400)),
    WorkItem(title: "Bio quiz on cells", kind: .quiz, subject: "Biology", due: now.addingTimeInterval(3 * 86400), topics: ["mitosis"]),
    WorkItem(title: "Gatsby essay", kind: .essay, subject: "English", due: now.addingTimeInterval(8 * 86400)),
], moods: [], screen: [],
   prefs: Preferences())

func send(_ req: AIRequest) async throws -> AIResponse {
    var r = URLRequest(url: base.appendingPathComponent("v1/messages"))
    r.httpMethod = "POST"
    r.setValue(key, forHTTPHeaderField: "x-api-key")
    r.setValue("application/json", forHTTPHeaderField: "Content-Type")
    r.timeoutInterval = 300
    r.httpBody = try JSONEncoder().encode(req)
    let (d, resp) = try await URLSession.shared.data(for: r)
    guard (resp as! HTTPURLResponse).statusCode == 200 else { fatalError(String(data: d, encoding: .utf8)!) }
    return try JSONDecoder().decode(AIResponse.self, from: d)
}

if CommandLine.arguments.dropFirst().first == "--insight" {
    // v1.1 D6: the insight pass (one Sonnet call at low effort) on a fixture week: a task put off often, repeated late
    // starts, three weak days. Prints the note, what the model asked for, and what the code applied or refused.
    var essay = s.items[2]
    essay.deferralLog = (0..<4).map { DeferralEvent(at: now.addingTimeInterval(-Double($0) * 86400), kind: .snoozed, reason: $0 == 0 ? "too tired after soccer" : nil) }
    s.items[2] = essay
    let days = (1...14).map { i in DayRecord(day: cal.date(byAdding: .day, value: -i, to: cal.startOfDay(for: now))!, isSchoolDay: ![1, 7].contains(cal.component(.weekday, from: cal.date(byAdding: .day, value: -i, to: now)!)),
                                              planned: 90, done: i % 3 == 0 ? 80 : 20) }
    let plan = Planner.plan(PlannerInput(now: now, calendar: cal, items: s.items,
                                         preferences: s.prefs, entries: timetable, categories: tree))
    let input = InsightInput(now: now, calendar: cal, trigger: .deferrals, deferrals: InsightPass.deferrals(items: s.items, since: now.addingTimeInterval(-14 * 86400)),
                             days: days, policy: s.policy, items: s.items, plan: plan, dayRules: s.dayRules)
    let req = AIRequest(model: AIFeature.review.route.model, system: InsightPass.system(), messages: [AIMessage(role: "user", content: InsightPass.request(input))],
                        schema: InsightPass.schema, maxTokens: 1500, effort: AIFeature.review.route.effort)
    let res = try await send(req)
    print("tokens out \(res.tokens.output), in \(res.tokens.input)+\(res.tokens.cacheRead)c, system chars \(InsightPass.system().count)")
    guard let out = res.decoded(InsightPass.Output.self, schema: InsightPass.schema, accept: { !$0.headline.isEmpty }) else { print("UNREADABLE:", res.text); exit(1) }
    print("NOTE:", out.headline, "|", out.wins, "|", out.suggestions)
    let run = InsightRun(at: now, note: out.headline, model: "sonnet")
    let drafts = InsightPass.drafts(out, runId: run.id, items: s.items, now: now, model: "sonnet", calendar: cal)
    var log = ChangeLog()
    let problems = log.apply(run, drafts, to: &s, now: now)
    print("asked for \(out.changes.count) changes, model said:", out.changes.map { "\($0.type): \($0.reason)" })
    print("APPLIED:", log.applied.map(\.title))
    print("REFUSED:", problems)
    exit(0)
}

if CommandLine.arguments.dropFirst().first == "--taxonomy" {
    // v1.2 C7: two weeks of messy filings (duplicates, odd names, a leaf in the wrong branch, one of the student's own
    // nodes and a correction). Sonnet tidies; the code applies what passes. The tree must not grow and no time is lost.
    var t = CategoryTree()
    var es: [Entry] = []
    func leaf(_ name: String, _ parent: CategoryID, yours: Bool = false) -> CategoryID { t.add(name, under: parent, yours: yours)!.id }
    let bball = leaf("Bball", CategoryTree.extracurricular), basket = leaf("Basketball practice", CategoryTree.extracurricular)
    let hoops = leaf("Hoops", CategoryTree.free), vball = leaf("Vball", CategoryTree.extracurricular)
    let gaming = leaf("Gaming", CategoryTree.work), games = leaf("Video games", CategoryTree.free)
    let app = leaf("Making App", CategoryTree.free, yours: true), hw = leaf("HW", CategoryTree.studying)
    let homework = leaf("Homework", CategoryTree.studying), insta = leaf("Instagram", CategoryTree.unproductive)
    let plan: [(CategoryID, String, Int)] = [(bball, "bball", 90), (basket, "Basketball practice", 90), (hoops, "hoops w friends", 60),
        (vball, "vball", 75), (gaming, "valorant", 60), (games, "minecraft", 45), (app, "Productium", 120), (hw, "hw", 50),
        (homework, "math homework", 45), (insta, "insta", 30)]
    for d in 0..<14 {
        for (k, (c, title, m)) in plan.enumerated() where (d + k) % 3 == 0 {
            let st = now.addingTimeInterval(Double(-d * 86400 - 6 * 3600 + k * 600))
            es.append(Entry(title: title, start: st, end: st.addingTimeInterval(Double(m) * 60), category: c, source: .you,
                            createdAt: st.addingTimeInterval(Double(m) * 60)))
        }
    }
    var rules = CategoryRules()
    rules.correct("hoops w friends", from: basket, to: hoops, at: now)
    let before = t.nodes.count, minutesBefore = es.reduce(0) { $0 + $1.minutes() }
    let req = AIRequest(model: AIFeature.taxonomy.route.model, system: TaxonomyPass.system(),
                        messages: [AIMessage(role: "user", content: TaxonomyPass.request(tree: t, entries: es, rules: rules, now: now, calendar: cal))],
                        schema: TaxonomyPass.schema, maxTokens: 1200, effort: AIFeature.taxonomy.route.effort)
    let res = try await send(req)
    guard let out = res.decoded(TaxonomyPass.Output.self, schema: TaxonomyPass.schema) else { print("UNREADABLE:", res.text); exit(1) }
    let (run, refused) = TaxonomyPass.apply(out.ops, tree: &t, entries: &es, rules: &rules, now: now)
    print("tokens out \(res.tokens.output); asked \(out.ops.count) ops")
    for o in out.ops { print("  \(o.op) \(o.id ?? "") \(o.into ?? o.under ?? "") \(o.name ?? "") — \(o.reason ?? "")") }
    print("APPLIED:", run?.lines ?? [])
    print("REFUSED:", refused)
    let minutesAfter = es.reduce(0) { $0 + $1.minutes() }
    let lost = es.contains { t.node($0.category) == nil }
    print("nodes \(before) → \(t.nodes.count); minutes \(minutesBefore) → \(minutesAfter); orphaned entries: \(lost)")
    print("hoops still where you put it: \(t.node(hoops) != nil); your Making App untouched: \(t.node(app)?.name == "Making App" && t.node(app)?.parentId == CategoryTree.free)")
    let ok = t.nodes.count <= before && minutesAfter == minutesBefore && !lost && t.node(hoops) != nil && t.node(app)?.parentId == CategoryTree.free
    print(ok ? "PASS" : "FAIL")
    exit(ok ? 0 : 1)
}

print("usage: run.sh --v12 [case-id-part] [-v] | --v12-reference | --v12-nothing | --v12q | --v12q-reference | --v12q-nothing | --insight | --taxonomy")
exit(2)
