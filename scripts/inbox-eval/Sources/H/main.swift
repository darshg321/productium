import Foundation
import FoundationNetworking
import ProductiumCore

let base = URL(string: ProcessInfo.processInfo.environment["CS_URL"]!)!
let key = ProcessInfo.processInfo.environment["CS_KEY"]!
var cal = Calendar(identifier: .gregorian)
cal.timeZone = TimeZone(identifier: "America/Vancouver")!
let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 19, minute: 10))!

let school = Commitment(title: "School", kind: .school, weekdays: [2, 3, 4, 5, 6], start: TimeOfDay(8, 30), end: TimeOfDay(15, 0))
let soccer = Commitment(title: "Soccer practice", kind: .extracurricular, weekdays: [2, 4], start: TimeOfDay(16), end: TimeOfDay(17, 30))
var s = DumpState(items: [
    WorkItem(title: "Calc problem set 5", kind: .assignment, subject: "Math", due: now.addingTimeInterval(2 * 86400)),
    WorkItem(title: "Bio quiz on cells", kind: .quiz, subject: "Biology", due: now.addingTimeInterval(3 * 86400), topics: ["mitosis"]),
    WorkItem(title: "Gatsby essay", kind: .essay, subject: "English", due: now.addingTimeInterval(8 * 86400)),
], commitments: [school, soccer], exceptions: [], oneOffs: [], markers: [], routines: Routine.defaults, moods: [], screen: [],
   prefs: Preferences())
var convo = Conversation(startedAt: now)

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
    let lateStarts = (0..<3).map { DayException(day: cal.date(byAdding: .day, value: -7 * ($0 + 1) - 0, to: cal.startOfDay(for: now))!, commitmentId: school.id, start: TimeOfDay(10)) }
    s.exceptions = lateStarts
    let days = (1...14).map { i in DayRecord(day: cal.date(byAdding: .day, value: -i, to: cal.startOfDay(for: now))!, isSchoolDay: ![1, 7].contains(cal.component(.weekday, from: cal.date(byAdding: .day, value: -i, to: now)!)),
                                              planned: 90, done: i % 3 == 0 ? 80 : 20) }
    let plan = Planner.plan(PlannerInput(now: now, calendar: cal, items: s.items, commitments: s.commitments, events: s.oneOffs,
                                         preferences: s.prefs, routines: s.routines, exceptions: s.exceptions))
    let input = InsightInput(now: now, calendar: cal, trigger: .deferrals, deferrals: InsightPass.deferrals(items: s.items, since: now.addingTimeInterval(-14 * 86400)),
                             days: days, policy: s.policy, items: s.items, plan: plan, commitments: s.commitments,
                             situations: s.situations, dayRules: s.dayRules, exceptions: s.exceptions)
    let req = AIRequest(model: AIFeature.review.route.model, system: InsightPass.system(), messages: [AIMessage(role: "user", content: InsightPass.request(input))],
                        schema: InsightPass.schema, maxTokens: 1500, effort: AIFeature.review.route.effort)
    let res = try await send(req)
    print("tokens out \(res.tokens.output), in \(res.tokens.input)+\(res.tokens.cacheRead)c, system chars \(InsightPass.system().count)")
    guard let out = res.decoded(InsightPass.Output.self, schema: InsightPass.schema, accept: { !$0.headline.isEmpty }) else { print("UNREADABLE:", res.text); exit(1) }
    print("NOTE:", out.headline, "|", out.wins, "|", out.suggestions)
    let run = InsightRun(at: now, note: out.headline, model: "sonnet")
    let drafts = InsightPass.drafts(out, runId: run.id, items: s.items, now: now, model: "sonnet", calendar: cal, commitments: s.commitments)
    var log = ChangeLog()
    let base = PlannerInput(now: now, calendar: cal, items: s.items, commitments: s.commitments, events: s.oneOffs, preferences: s.prefs, routines: s.routines, exceptions: s.exceptions)
    let problems = log.apply(run, drafts, to: &s, now: now, admitSituation: { sit in
        if case .failure(let why) = SituationRules.admit(sit, into: base, writer: .reflection) { return why.reason }
        return nil
    })
    print("asked for \(out.changes.count) changes, model said:", out.changes.map { "\($0.type): \($0.reason)" })
    print("APPLIED:", log.applied.map(\.title))
    print("REFUSED:", problems)
    exit(0)
}

let turns = CommandLine.arguments.dropFirst()
var outTotal = 0
for (n, text) in turns.enumerated() {
    let plan = Planner.plan(PlannerInput(now: now, calendar: cal, items: s.items, commitments: s.commitments, events: s.oneOffs,
                                         preferences: s.prefs, routines: s.routines, exceptions: s.exceptions))
    let ctx = Prompts.dumpContext(DumpContextInput(now: now, calendar: cal, state: s, plan: plan, warnings: plan.warnings))
    if ProcessInfo.processInfo.environment["CTX_LINES"] != nil {
        for line in ctx.split(separator: "\n") { print("CTX", line.count, line.prefix(60)) }
    }
    let pics: [AIImage] = (n == 0 ? ProcessInfo.processInfo.environment["IMG"] : nil)
        .flatMap { FileManager.default.contents(atPath: $0) }.map { [AIImage(mediaType: "image/png", base64: $0.base64EncodedString())] } ?? []
    let content = ConversationPolicy.userContent(for: convo, text: text, images: pics, fullContext: ctx)
    let req = convo.request(system: Prompts.dump(), tool: ConversationPolicy.tool(schema: Schemas.dump),
                            userContent: content, maxTokens: 3000)
    let res = try await send(req)
    outTotal += res.tokens.output
    guard let r = DumpResult.read(res) else { print("UNREADABLE:", res.text); exit(1) }
    let rep = DumpApplier.apply(r, to: &s, now: now, calendar: cal)
    convo.add(ConversationTurn(at: now, text: text, userContent: content, assistantContent: res.rawContent, reply: r.reply,
                               applied: AppliedReport(changes: rep.changes, problems: rep.problems), tokens: res.tokens, context: ctx))
    print("\n===== TURN \(n + 1): \(text)")
    print("tokens out \(res.tokens.output), in \(res.tokens.input)+\(res.tokens.cacheRead)c, truncated \(res.isTruncated)")
    print("ops:", r.ops.map { o in [o.op, o.entity, o.id, o.knob, o.value].compactMap { $0 }.joined(separator: " ")
        + (o.fields.map { " " + ($0.keys.sorted().joined(separator: ",")) } ?? "") })
    print("reply:", r.reply)
    print("changes:", rep.changes)
    print("problems:", rep.problems)
    let wd = ["", "Su", "M", "Tu", "W", "Th", "F", "Sa"]
    for c in s.commitments.sorted(by: { ($0.start, $0.title) < ($1.start, $1.title) }) {
        print("  ", c.title, c.kind.rawValue, c.weekdays.sorted().map { wd[$0] }.joined(), c.start.label, "-", c.end.label, "buf", c.bufferMinutes, c.color ?? "")
    }
    print("  colors:", s.prefs.colors, "items:", s.items.map { "\($0.title)=\($0.color ?? "-")" })
}
print("\nTOTAL OUTPUT TOKENS", outTotal)
