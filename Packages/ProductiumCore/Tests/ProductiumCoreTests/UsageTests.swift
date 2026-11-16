import XCTest
@testable import ProductiumCore

final class UsageTests: XCTestCase {
    let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Toronto")!
        return c
    }()

    func testLedgerTotalsAndBudget() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var l = UsageLedger()
        l.dailyBudget = 1000
        l.record(UsageRecord(at: now, feature: .box, model: "lite", tokens: TokenCount(input: 500, output: 100)))
        l.record(UsageRecord(at: now, feature: .flashcards, model: "lite", tokens: TokenCount(input: 200, output: 150)))
        l.record(UsageRecord(at: now.addingTimeInterval(-2 * 86400), feature: .box, model: "lite", tokens: TokenCount(input: 9000)))
        XCTAssertEqual(l.total(on: now, calendar: cal).total, 950)
        XCTAssertEqual(l.total(lastDays: 7, now: now, calendar: cal).total, 9950)
        XCTAssertEqual(l.byFeature(on: now, calendar: cal).first?.feature, .box)
        XCTAssertTrue(l.allows(.reads, now: now, calendar: cal))
        l.record(UsageRecord(at: now, feature: .box, model: "lite", tokens: TokenCount(input: 60)))
        XCTAssertFalse(l.allows(.reads, now: now, calendar: cal), "background AI pauses over budget")
        XCTAssertTrue(l.allows(.box, now: now, calendar: cal), "the box always works")
        XCTAssertEqual(l.daily(lastDays: 3, now: now, calendar: cal).map(\.tokens), [9000, 0, 1010])
    }

    func testLedgerPrunesOldRecords() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var l = UsageLedger()
        l.records = [UsageRecord(at: now.addingTimeInterval(-40 * 86400), feature: .box, model: "lite", tokens: TokenCount(input: 1))]
        l.record(UsageRecord(at: now, feature: .box, model: "lite", tokens: TokenCount(input: 1)))
        XCTAssertEqual(l.records.count, 1)
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
        {"id":"msg_1","type":"message","role":"assistant","model":"claude-haiku-4-5","stop_reason":"end_turn",
         "content":[{"type":"text","text":"{\\"actions\\":[],\\"reply\\":\\"ok\\"}"}],
         "usage":{"input_tokens":900,"output_tokens":80,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}
        """
        let r = try JSONDecoder().decode(AIResponse.self, from: Data(json.utf8))
        XCTAssertEqual(try r.structured?.decode(DumpResult.self).reply, "ok")
        XCTAssertEqual(r.tokens.total, 980)
        let fenced = AIResponse(model: nil, text: "```json\n{\"cards\":[]}\n```", usage: nil)
        XCTAssertNotNil(try fenced.structured?.decode(CardBatch.self))
    }

    func testRequestEncodesMessagesAPIShape() throws {
        let req = AIRequest(tier: .fast, system: "s", messages: [AIMessage(role: "user", content: "hi")],
                            schema: Schemas.cards, maxTokens: 300, cacheTTL: 60)
        let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(req)) as! [String: Any]
        XCTAssertEqual(obj["model"] as? String, "lite")
        XCTAssertEqual(obj["max_tokens"] as? Int, 300)
        XCTAssertNil(obj["cacheTTL"], "the cache TTL travels as a header, not in the body")
        let fmt = (obj["output_config"] as? [String: Any])?["format"] as? [String: Any]
        XCTAssertEqual(fmt?["type"] as? String, "json_schema")
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            AIRequest(tier: .reason, system: "s", messages: []))) as! [String: Any]
        XCTAssertNil(plain["output_config"])
    }

    /// The box runs on every message, so its fixed cost is watched. ~3.5 characters per token.
    func testBoxPromptStaysSmall() throws {
        let schema = try JSONEncoder().encode(Schemas.dump)
        let tokens = (Prompts.dump().count + schema.count) / 7 * 2
        XCTAssertLessThan(tokens, 1300, "box system prompt + schema is ~\(tokens) tokens")
    }
}
