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
], oneOffs: [], markers: [], routines: Routine.defaults, moods: [], screen: [],
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
    let plan = Planner.plan(PlannerInput(now: now, calendar: cal, items: s.items, events: s.oneOffs,
                                         preferences: s.prefs, routines: s.routines, entries: timetable, categories: tree))
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

print("usage: run.sh --v12 [case-id-part] [-v] | --v12-reference | --v12-nothing | --v12q | --v12q-reference | --v12q-nothing | --insight")
exit(2)
