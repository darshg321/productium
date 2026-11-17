import XCTest
@testable import ProductiumCore

final class RepairTests: XCTestCase {
    func response(_ text: String, stop: String? = nil) -> AIResponse { AIResponse(model: "sonnet", text: text, usage: nil, stopReason: stop) }

    func fields(_ op: DumpOp?) -> DumpFields { op.map(DumpFields.read) ?? DumpFields() }

    func dump(_ text: String, file: StaticString = #filePath, line: UInt = #line) throws -> DumpResult {
        try XCTUnwrap(DumpResult.read(response(text)), "not understood: \(text)", file: file, line: line)
    }

    static let real = #"{"ops": [{"op": "upsert", "entity": "task", "fields": {"title": "Macbeth Act 1 reading quiz", "kind": "quiz", "subject": "English", "due": "2026-11-19T08:00", "estimateMinutes": 45, "importance": 3, "difficulty": 2, "topics": ["Macbeth Act 1"]}}, {"op": "upsert", "entity": "task", "fields": {"title": "Soliloquy annotation (submit on Teams)", "kind": "assignment", "subject": "English", "due": "2026-11-23T23:59", "estimateMinutes": 60, "importance": 3, "difficulty": 2}}, {"op": "upsert", "entity": "day_change", "fields": {"date": "2026-11-21", "wake": "10:00"}}, {"op": "upsert", "entity": "mood", "fields": {"mood": 2, "energy": 2, "note": "tired, \"kinda\" stressed"}}], "reply": "Added 2 tasks. I read \"5-630\" as 17:00-18:30, so tell me if that's off."}"#

    func testMessageShapes() throws {
        func message(_ json: String) throws -> AIResponse { try JSONDecoder().decode(AIResponse.self, from: Data(json.utf8)) }
        let text = try message(#"{"id":"msg_1","type":"message","role":"assistant","model":"claude-sonnet-5-5","stop_reason":"end_turn","content":[{"type":"text","text":"{\"ops\":[],\"reply\":\"ok\"}"}],"usage":{"input_tokens":900,"output_tokens":80}}"#)
        XCTAssertEqual(DumpResult.read(text)?.reply, "ok")
        XCTAssertEqual(text.tokens.counted, 80)
        let tool = try message(#"{"content":[{"type":"thinking","thinking":"hmm","signature":"x"},{"type":"tool_use","id":"toolu_1","name":"structured_output","input":{"ops":[{"op":"upsert","entity":"mood","fields":{"mood":4}}],"reply":"Nice."}}],"stop_reason":"tool_use"}"#)
        XCTAssertEqual(fields(DumpResult.read(tool)?.ops.first).mood, 4)
        XCTAssertEqual(tool.text, "")
        XCTAssertEqual(DumpResult.read(try message(#"{"content":"{\"ops\":[],\"reply\":\"s\"}"}"#))?.reply, "s")
        XCTAssertEqual(DumpResult.read(try message(#"{"content":["{\"ops\":[],", "\"reply\":\"parts\"}"]}"#))?.reply, "parts")
        XCTAssertNil(DumpResult.read(try message(#"{"type":"message"}"#)))
        XCTAssertNil(DumpResult.read(try message(#"{"content":null,"usage":"none","model":5}"#)))
        XCTAssertEqual(try message(#"{"content":[{"type":"text","text":"hi"},{"type":"text"},7,null]}"#).text, "hi")
        XCTAssertTrue(try message(#"{"content":[],"stop_reason":"max_tokens"}"#).isTruncated)
    }

    func testCleanReply() throws {
        let r = try dump(Self.real)
        XCTAssertEqual(r.ops.count, 4)
        XCTAssertEqual(fields(r.ops[0]).topics, ["Macbeth Act 1"])
        XCTAssertEqual(fields(r.ops[3]).note, "tired, \"kinda\" stressed")
    }

    func testWrappedFencedProseAndDoubleEncoded() throws {
        XCTAssertEqual(try dump(#"{"structured_output":{"actions":[],"reply":"Hi"}}"#).reply, "Hi")
        XCTAssertEqual(try dump(#"{"input":"{\"actions\":[],\"reply\":\"Hi\"}"}"#).reply, "Hi")
        XCTAssertEqual(try dump("```json\n{\"actions\":[],\"reply\":\"Hi\"}\n```").reply, "Hi")
        XCTAssertEqual(try dump("Sure! Here it is:\n```\n{\"actions\":[],\"reply\":\"Hi\"}\n```\nAnything else?").reply, "Hi")
        XCTAssertEqual(try dump("Here you go: {\"actions\":[],\"reply\":\"Hi\"} hope that helps").reply, "Hi")
        XCTAssertEqual(try dump("I used {curly} braces and [brackets] first. {\"actions\":[],\"reply\":\"Hi\"}").reply, "Hi")
        XCTAssertEqual(try dump(#""{\"actions\":[],\"reply\":\"Hi\"}""#).reply, "Hi", "double-encoded")
        XCTAssertEqual(try dump("\u{FEFF}  {\"actions\":[],\"reply\":\"Hi\"}").reply, "Hi", "byte-order mark")
    }

    func testSloppyJSON() throws {
        let r = try dump("""
        {
          // what changed
          'ops': [
            {op: 'upsert', entity: 'day_change', fields: {date: '2026-11-17', activity: "school", cancelled: True, note: None,},},
          ],
          "reply": 'Got it.',
        }
        """)
        XCTAssertEqual(fields(r.ops.first).cancelled, true)
        XCTAssertNil(fields(r.ops.first).note)
        XCTAssertEqual(r.reply, "Got it.")
        let s = try dump("{“ops”: [] “reply”: “Line one\nline two”}")
        XCTAssertEqual(s.reply, "Line one\nline two")
        let e = try dump(#"{"ops":[],"reply":"café 😀 a\\b \"q\" \/ tab\there",}"#)
        XCTAssertEqual(e.reply, "café 😀 a\\b \"q\" / tab\there")
    }

    func testUnescapedQuotesInsideStrings() throws {
        let r = try dump(#"{"ops": [{"op": "upsert", "entity": "task", "fields": {"title": "Read "The Road", ch 3", "due": "2026-11-22T17:00"}}], "reply": "I read "5-630" as 17:00, so tell me if that's off."}"#)
        XCTAssertEqual(fields(r.ops.first).title, #"Read "The Road", ch 3"#)
        XCTAssertEqual(fields(r.ops.first).due, "2026-11-22T17:00")
        XCTAssertEqual(r.reply, #"I read "5-630" as 17:00, so tell me if that's off."#)
    }

    func testTruncatedAtEveryLength() throws {
        let full = try dump(Self.real)
        let chars = Array(Self.real)
        let firstActionEnd = try XCTUnwrap(Self.real.range(of: #""topics": ["Macbeth Act 1"]}}"#)).upperBound
        let enough = Self.real.distance(from: Self.real.startIndex, to: firstActionEnd)
        for n in 1..<chars.count {
            let cut = String(chars[0..<n])
            let r = DumpResult.read(response(cut, stop: "max_tokens"))
            if n >= enough {
                let got = try XCTUnwrap(r, "nothing read from the first \(n) characters")
                XCTAssertGreaterThanOrEqual(got.ops.count, 1)
                XCTAssertEqual(got.ops, Array(full.ops.prefix(got.ops.count)), "a half-written operation got through at \(n)")
            }
        }
    }

    func testStringifiedActionsArray() throws {
        let r = try dump(#"{"ops":"[{\"op\":\"upsert\",\"entity\":\"task\",\"fields\":{\"title\":\"Essay\",\"estimateMinutes\":\"90\"}}]","reply":"ok"}"#)
        XCTAssertEqual(r.ops.count, 1)
        XCTAssertEqual(fields(r.ops.first).estimateMinutes, 90)
    }

    func testWrongTypesAreConvertedOrDropped() throws {
        let r = try dump(#"{"ops":[{"op":"upsert","entity":"day_change","date":20261117,"target":"school","cancelled":"true","importance":3.0,"weekdays":"2, 4","estimateMinutes":"about an hour","difficulty":"2 hours","minutes":"25 min","mood":[4],"topics":"stoich; gas laws","apps":{"name":"TikTok","minutes":"120"},"title":["Chem","test"],"energy":{"level":3},"start":null}],"reply":7}"#)
        let a = fields(try XCTUnwrap(r.ops.first))
        XCTAssertEqual(a.date, "20261117")
        XCTAssertEqual(a.cancelled, true)
        XCTAssertEqual(a.importance, 3)
        XCTAssertEqual(a.weekdays, [2, 4])
        XCTAssertNil(a.estimateMinutes, "words aren't a number")
        XCTAssertNil(a.difficulty, "hours aren't minutes")
        XCTAssertEqual(a.minutes, 25)
        XCTAssertEqual(a.mood, 4)
        XCTAssertEqual(a.topics, ["stoich", "gas laws"])
        XCTAssertEqual(a.apps?.first?.minutes, 120)
        XCTAssertEqual(a.title, "Chem test")
        XCTAssertNil(a.energy)
        XCTAssertNil(a.start)
        XCTAssertEqual(r.reply, "7")
    }

    func testKeySpellings() throws {
        let r = try dump(#"{"Ops":[{"Op":"upsert","Entity":"task","Fields":{"Title":"Lab","estimate_minutes":40,"Estimate Minutes":99,"DUE":"2026-11-20"}}],"REPLY":"ok"}"#)
        let a = fields(try XCTUnwrap(r.ops.first))
        XCTAssertEqual(a.title, "Lab")
        XCTAssertEqual(a.due, "2026-11-20")
        XCTAssertNotNil(a.estimateMinutes)
        XCTAssertEqual(r.reply, "ok")
    }

    func testOtherShapesOfAnAnswer() throws {
        XCTAssertEqual(try dump(#"{"reply":"Sleep wins."}"#).ops.count, 0)
        XCTAssertEqual(fields(try dump(#"{"ops":{"op":"upsert","entity":"mood","fields":{"mood":2}}}"#).ops.first).mood, 2, "one object for a list")
        XCTAssertEqual(try dump(#"[{"op":"upsert","entity":"mood","mood":2},{"op":"upsert","entity":"routine","id":"get_ready","minutes":25}]"#).ops.count, 2, "the list alone")
        XCTAssertEqual(try dump(#"[{"ops":[{"op":"upsert","entity":"mood","fields":{"mood":2}}],"reply":"ok"}]"#).reply, "ok", "the answer in a list")
        let bare = try dump(#"{"op":"upsert","entity":"task","target":"Math worksheet","done":true,"reply":"Done!"}"#)
        XCTAssertEqual(fields(bare.ops.first).target, "Math worksheet", "one operation on its own, fields beside it")
        XCTAssertEqual(fields(bare.ops.first).done, true)
        XCTAssertEqual(bare.reply, "Done!")
        XCTAssertEqual(try dump(#"{"actions":[{"op":"upsert","entity":"mood","fields":{"mood":5}}],"message":"Glad to hear it."}"#).reply, "Glad to hear it.")
        XCTAssertEqual(try dump("Most teens need 8 to 10 hours. Want me to set a target?").reply,
                       "Most teens need 8 to 10 hours. Want me to set a target?", "prose is a reply")
    }

    func testNothingUsableIsNotUnderstood() {
        for text in ["", "   \n", "{}", "[]", #"{"foo":1}"#, "{", #"{"ops":[],"reply":""}"#, "null", "42", "ok", "…",
                     #"{"ops": [{"o"#, "Here: {\"ops\": [{\"op\": \"ups"] {
            XCTAssertNil(DumpResult.read(response(text)), "should ask again for: \(text)")
        }
    }

    func testOperationNames() throws {
        let r = try dump(#"{"ops":[{"fields":{"title":"no op"}},{"op":"Create","entity":"Task","fields":{"title":"Read ch 3","due":"2026-11-20"}},null,{"op":"fly_to_moon"}],"reply":"ok"}"#)
        XCTAssertEqual(r.ops.map(\.op), ["Create", "fly_to_moon"], "an operation with no name is dropped")
        XCTAssertEqual(r.ops.first?.entity, "task", "names are fixed where they can be")
        var s = DumpState(items: [], commitments: [], exceptions: [], oneOffs: [], markers: [], routines: Routine.defaults,
                          moods: [], screen: [], prefs: Preferences())
        let rep = DumpApplier.apply(r, to: &s, now: Fx.mon(12), calendar: Fx.cal)
        XCTAssertEqual(rep.changes, ["Added Read ch 3"], "the rest are skipped")
        XCTAssertEqual(rep.problems.count, 1)
    }

    func testOtherSchemas() throws {
        let cards = response(#"{"cards":"[{\"front\":\"Q\",\"back\":\"A\"},{\"front\":\"no back\"}]"}"#).decoded(CardBatch.self, schema: Schemas.cards)
        XCTAssertEqual(cards?.cards.count, 2)
        XCTAssertEqual(cards?.usable.count, 1)
        XCTAssertEqual(response(#"[{"front":"Q","back":"A"}]"#).decoded(CardBatch.self, schema: Schemas.cards)?.usable.count, 1, "the list alone")
        let steps = response(#"{"steps":[{"title":"Outline","estimateMinutes":"30","due":"2026-11-18T17:00","kind":"Essay"},{"title":"Draft"}],"rationale":["Small", "steps."]}"#)
            .decoded(Decomposition.self, schema: Schemas.decomposition)
        XCTAssertEqual(steps?.steps.map(\.estimateMinutes), [30, 0])
        XCTAssertEqual(steps?.steps.first?.kind, "essay")
        XCTAssertEqual(steps?.rationale, "Small steps.")
        let review = response(#"{"headline":"Good week","wins":"Slept well","changes":{"focusBlockMinutes":"30","windDownMinutes":"more"}}"#)
            .decoded(WeeklyReview.self, schema: Schemas.weeklyReview)
        XCTAssertEqual(review?.wins, ["Slept well"])
        XCTAssertEqual(review?.suggestions, [])
        XCTAssertNil(response("I can't make cards for that.").decoded(CardBatch.self, schema: Schemas.cards), "no JSON: ask again")
        XCTAssertNil(response(#"{"cards":[]}"#).decoded(CardBatch.self, schema: Schemas.cards) { !$0.usable.isEmpty }, "empty: ask again")
    }

    struct Rng: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    static let schemas: [JSONValue] = [Schemas.dump, Schemas.decomposition, Schemas.weeklyReview, Schemas.cards, Schemas.reads]

    func decodes(_ v: JSONValue, _ schema: JSONValue) -> Bool {
        let fitted = StructuredRepair.coerce(v, to: schema)
        if schema == Schemas.dump {
            guard case .object(let o) = fitted, case .array(let ops)? = o["ops"], case .string? = o["reply"] else { return false }
            return ops.allSatisfy { (try? $0.decode(DumpOp.self)) != nil }
        }
        if schema == Schemas.decomposition { return (try? fitted.decode(Decomposition.self)) != nil }
        if schema == Schemas.weeklyReview { return (try? fitted.decode(WeeklyReview.self)) != nil }
        if schema == Schemas.cards { return (try? fitted.decode(CardBatch.self)) != nil }
        return (try? fitted.decode(ReadBatch.self)) != nil
    }

    func testAnyValueFitsEverySchema() {
        var rng = Rng(state: 42)
        let keys = ["ops", "op", "entity", "fields", "knob", "value", "actions", "reply", "type", "title", "due", "estimateMinutes", "topics", "weekdays", "apps", "name", "minutes",
                    "cancelled", "steps", "rationale", "kind", "cards", "front", "back", "pieces", "body", "question", "headline",
                    "wins", "suggestions", "changes", "focusBlockMinutes", "mood", "Estimate_Minutes", "x", ""]
        func value(_ depth: Int) -> JSONValue {
            switch Int.random(in: 0..<(depth > 4 ? 6 : 9), using: &rng) {
            case 0: return .null
            case 1: return .bool(Bool.random(using: &rng))
            case 2: return .number([0, 1, -3, 2.5, 90, 1e300, -1e300, 1e-9].randomElement(using: &rng)!)
            case 3: return .string(["", "add_task", "90", "true", "2 hours", "2026-11-20", "[1,2]", "{\"reply\":\"x\"}", "a, b", "🙂", "{"].randomElement(using: &rng)!)
            case 4, 5: return .string(String((0..<Int.random(in: 0..<6, using: &rng)).map { _ in "ab{}[]\",:'\\ \n1".randomElement(using: &rng)! }))
            case 6: return .array((0..<Int.random(in: 0..<4, using: &rng)).map { _ in value(depth + 1) })
            default:
                return .object(Dictionary((0..<Int.random(in: 0..<6, using: &rng)).map { _ in (keys.randomElement(using: &rng)!, value(depth + 1)) },
                                          uniquingKeysWith: { a, _ in a }))
            }
        }
        for n in 0..<4000 {
            let v = value(0)
            for schema in Self.schemas {
                XCTAssertTrue(decodes(v, schema), "case \(n) doesn't decode: \(v)")
            }
        }
    }

    func testDamagedRepliesNeverBreakTheReader() {
        var rng = Rng(state: 7)
        let junk = Array("{}[]\",:'\\ \n\t“”`/*#0aé🙂")
        for n in 0..<3000 {
            var chars = Array(Self.real)
            for _ in 0..<Int.random(in: 1...6, using: &rng) {
                guard !chars.isEmpty else { break }
                let at = Int.random(in: 0..<chars.count, using: &rng)
                switch Int.random(in: 0..<5, using: &rng) {
                case 0: chars.remove(at: at)
                case 1: chars.insert(junk.randomElement(using: &rng)!, at: at)
                case 2: chars[at] = junk.randomElement(using: &rng)!
                case 3: chars.removeSubrange(at..<min(chars.count, at + Int.random(in: 1..<40, using: &rng)))
                default: chars = Array(chars[0..<at])
                }
            }
            let text = String(chars)
            let res = response(text)
            for schema in Self.schemas {
                if let v = res.structured { XCTAssertTrue(decodes(v, schema), "case \(n) doesn't decode: \(text)") }
            }
            if let r = DumpResult.read(res) {
                var s = DumpState(items: [], commitments: [Fx.school], exceptions: [], oneOffs: [], markers: [], routines: Routine.defaults,
                                  moods: [], screen: [], prefs: Preferences())
                DumpApplier.apply(r, to: &s, now: Fx.mon(12), calendar: Fx.cal)
            }
        }
    }

    func testHostileInputTerminates() {
        for text in [String(repeating: "[", count: 20_000), String(repeating: "{\"a\":", count: 20_000),
                     String(repeating: "{", count: 5000) + String(repeating: "}", count: 5000),
                     String(repeating: "\"", count: 9999), String(repeating: "{,:]", count: 5000), "{\"a\": \"" + String(repeating: "\\", count: 9999)] {
            _ = DumpResult.read(response(text))
        }
    }
}
