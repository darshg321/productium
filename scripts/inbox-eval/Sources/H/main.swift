import Foundation
import FoundationNetworking
import ProductiumCore

// Multi-turn Inbox run against a real claude-server, the way AppModel.dump does it: the same prompt,
// context, schema, history (with what was applied) and applier, on a sample student. Each argument
// is one message. Uses real subscription tokens (Sonnet), so check Settings → AI Usage first.
//
//   CS_URL=http://localhost:8799 CS_KEY=cs_... swift run H \
//     "split school into periods: P1 8:30-9:20, P2 9:25-10:15, P3 10:30-11:20, lunch 11:20-12:05, P4 12:05-12:55, P5 1:00-3:00" \
//     "period 3 is actually 10:35-11:25, make lunch green and the rest of school teal" \
//     "split school into periods again, same times"
//
// Then read the printed activities: no duplicates, each change where it was asked for.
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
var chat: [AIMessage] = []

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

let turns = CommandLine.arguments.dropFirst()
var outTotal = 0
for (n, text) in turns.enumerated() {
    let plan = Planner.plan(PlannerInput(now: now, calendar: cal, items: s.items, commitments: s.commitments, events: s.oneOffs,
                                         preferences: s.prefs, routines: s.routines, exceptions: s.exceptions))
    let ctx = Prompts.dumpContext(DumpContextInput(now: now, calendar: cal, state: s, plan: plan, warnings: plan.warnings))
    let msg = "Context (the app right now):\n\(ctx)\n\nStudent:\n\(text)"
    let req = AIRequest(system: Prompts.dump(), messages: Array(chat.suffix(6)) + [AIMessage(role: "user", content: msg)],
                        schema: Schemas.dump, maxTokens: 1800)
    let res = try await send(req)
    outTotal += res.tokens.output
    guard let r = DumpResult.read(res) else { print("UNREADABLE:", res.text); exit(1) }
    let rep = DumpApplier.apply(r, to: &s, now: now, calendar: cal)
    var memory = r.reply
    if !rep.changes.isEmpty { memory += "\n[Applied: \(rep.changes.joined(separator: "; "))]" }
    if !rep.problems.isEmpty { memory += "\n[Not applied: \(rep.problems.joined(separator: "; "))]" }
    chat += [AIMessage(role: "user", content: text), AIMessage(role: "assistant", content: memory)]
    print("\n===== TURN \(n + 1): \(text)")
    print("tokens out \(res.tokens.output), in \(res.tokens.input)+\(res.tokens.cacheRead)c, truncated \(res.isTruncated)")
    print("actions:", r.actions.map { a in [a.type, a.id, a.target, a.title, a.start, a.end, a.color, a.category, a.key, a.value,
                                          a.parts.map { "\($0.count) parts" }].compactMap { $0 }.joined(separator: " ") })
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
