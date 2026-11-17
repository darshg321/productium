import XCTest
@testable import ProductiumCore

final class UsageTests: XCTestCase {
    let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Toronto")!
        return c
    }()

    func testLedgerCountsOutputTokensOnly() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var l = UsageLedger()
        l.dailyBudget = 1000
        l.record(UsageRecord(at: now, feature: .box, model: "sonnet", tokens: TokenCount(input: 5000, output: 400, cacheRead: 900)))
        l.record(UsageRecord(at: now, feature: .flashcards, model: "sonnet", tokens: TokenCount(input: 200, output: 150, cacheWrite: 800)))
        l.record(UsageRecord(at: now.addingTimeInterval(-2 * 86400), feature: .box, model: "sonnet", tokens: TokenCount(input: 9000, output: 90)))
        XCTAssertEqual(l.total(on: now, calendar: cal).counted, 550)
        XCTAssertEqual(l.total(lastDays: 7, now: now, calendar: cal).counted, 640)
        XCTAssertEqual(l.byFeature(on: now, calendar: cal).map(\.tokens), [400, 150])
        XCTAssertEqual(l.byFeature(on: now, calendar: cal).first?.feature, .box)
        XCTAssertEqual(l.fractionUsed(now: now, calendar: cal), 0.55, accuracy: 0.001)
        XCTAssertTrue(l.allows(.reads, now: now, calendar: cal), "20k tokens read, but only 550 written")
        l.record(UsageRecord(at: now, feature: .box, model: "sonnet", tokens: TokenCount(input: 60, output: 450)))
        XCTAssertFalse(l.allows(.reads, now: now, calendar: cal), "background AI pauses over budget")
        XCTAssertTrue(l.allows(.box, now: now, calendar: cal), "the box always works")
        XCTAssertEqual(l.daily(lastDays: 3, now: now, calendar: cal).map(\.tokens), [90, 0, 1000])
    }

    func testLedgerKeepsEveryRecord() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var l = UsageLedger()
        l.records = [UsageRecord(at: now.addingTimeInterval(-400 * 86400), feature: .box, model: "sonnet", tokens: TokenCount(input: 1))]
        l.record(UsageRecord(at: now, feature: .box, model: "sonnet", tokens: TokenCount(input: 1)))
        XCTAssertEqual(l.records.count, 2)
    }

    func testLedgerDecodesFromEmptyObject() throws {
        let l = try JSONDecoder().decode(UsageLedger.self, from: Data("{}".utf8))
        XCTAssertEqual(l.dailyBudget, UsageLedger.defaultBudget)
        XCTAssertTrue(l.pauseBackgroundOverBudget)
    }

    func testTokensLabel() {
        XCTAssertEqual(tokensLabel(840), "840")
        XCTAssertEqual(tokensLabel(1234), "1.2k")
        XCTAssertEqual(tokensLabel(25_000), "25k")
        XCTAssertEqual(tokensLabel(1_500_000), "1.5M")
    }

    func testResponseParsesStructuredTextAndUsage() throws {
        let json = """
        {"id":"msg_1","type":"message","role":"assistant","model":"claude-sonnet-5-5","stop_reason":"end_turn",
         "content":[{"type":"text","text":"{\\"actions\\":[],\\"reply\\":\\"ok\\"}"}],
         "usage":{"input_tokens":900,"output_tokens":80,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}
        """
        let r = try JSONDecoder().decode(AIResponse.self, from: Data(json.utf8))
        XCTAssertEqual(try r.structured?.decode(DumpResult.self).reply, "ok")
        XCTAssertEqual(r.tokens.counted, 80)
        let fenced = AIResponse(model: nil, text: "```json\n{\"cards\":[]}\n```", usage: nil)
        XCTAssertNotNil(try fenced.structured?.decode(CardBatch.self))
    }

    func testRequestEncodesMessagesAPIShape() throws {
        let req = AIRequest(system: "s", messages: [AIMessage(role: "user", content: "hi")],
                            schema: Schemas.cards, maxTokens: 300, cacheTTL: 60)
        let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(req)) as! [String: Any]
        XCTAssertEqual(obj["model"] as? String, "sonnet")
        XCTAssertEqual(obj["max_tokens"] as? Int, 300)
        XCTAssertNil(obj["cacheTTL"], "the cache TTL travels as a header, not in the body")
        let fmt = (obj["output_config"] as? [String: Any])?["format"] as? [String: Any]
        XCTAssertEqual(fmt?["type"] as? String, "json_schema")
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            AIRequest(system: "s", messages: []))) as! [String: Any]
        XCTAssertNil(plain["output_config"])
    }

    func testBoxPromptStaysSmall() throws {
        let schema = try JSONEncoder().encode(Schemas.dump)
        let tokens = (Prompts.dump().count + schema.count) / 7 * 2
        XCTAssertLessThan(tokens, 2600, "box system prompt + schema is ~\(tokens) tokens")
    }
}

final class CallLogTests: XCTestCase {
    func testCallKeepsTheWholeExchangeButNotImageBytes() {
        let req = AIRequest(system: "sys", messages: [AIMessage(role: "user", content: "hello", images: [AIImage(mediaType: "image/png", base64: String(repeating: "A", count: 5000))])],
                            schema: Schemas.dump, maxTokens: 900, cacheTTL: 60)
        var c = AICall(request: req, feature: .box, at: Fx.mon(12))
        c.status = 200
        c.response = #"{"content":[{"type":"text","text":"hi"}],"model":"claude-sonnet-5-5"}"#
        XCTAssertEqual(c.messages, [AICall.Message(role: "user", content: "hello", images: 1)])
        XCTAssertTrue(c.schema?.contains("upsert") == true)
        XCTAssertTrue(c.ok)
        XCTAssertTrue(c.prettyResponse.contains("\n"))
        XCTAssertFalse(c.transcript.contains("AAAA"))
        XCTAssertTrue(c.transcript.contains("=== SYSTEM ===\nsys") && c.transcript.contains("(+1 image)"))

        var log = AICallLog()
        var old = c; old.at = Fx.mon(12, plusDays: -60)
        var big = c; big.response = String(repeating: "x", count: 200_000)
        for x in [old, big] + (0..<200).map({ _ in c }) { log.append(x, now: Fx.mon(13)) }
        XCTAssertEqual(log.calls.count, 202)
        XCTAssertEqual(log.calls[1].response.count, 200_000)
    }
}

final class RoutingTests: XCTestCase {
    func testOnlyReflectionRunsOnOpus() {
        for f in AIFeature.allCases where f != .reflection {
            XCTAssertEqual(f.route, AIRoute(model: "sonnet", effort: "low"), "\(f)")
        }
        XCTAssertEqual(AIFeature.reflection.route, AIRoute(model: "opus", effort: "medium"))
        XCTAssertEqual(AIFeature.reflection.title, "Opus · reflection")
    }

    func testEffortIsSentAsOutputConfig() throws {
        let req = AIRequest(model: "opus", system: "s", messages: [AIMessage(role: "user", content: "hi")], schema: nil, maxTokens: 100,
                            effort: AIFeature.reflection.route.effort)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(req)) as! [String: Any]
        XCTAssertEqual((json["output_config"] as? [String: Any])?["effort"] as? String, "medium")
    }
}
