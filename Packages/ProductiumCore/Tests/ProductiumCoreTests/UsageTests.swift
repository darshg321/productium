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
        l.record(UsageRecord(at: now, feature: .taxonomy, model: "sonnet", tokens: TokenCount(input: 200, output: 150, cacheWrite: 800)))
        l.record(UsageRecord(at: now.addingTimeInterval(-2 * 86400), feature: .box, model: "sonnet", tokens: TokenCount(input: 9000, output: 90)))
        XCTAssertEqual(l.total(on: now, calendar: cal).counted, 550)
        XCTAssertEqual(l.total(lastDays: 7, now: now, calendar: cal).counted, 640)
        XCTAssertEqual(l.byFeature(on: now, calendar: cal).map(\.tokens), [400, 150])
        XCTAssertEqual(l.byFeature(on: now, calendar: cal).first?.feature, .box)
        XCTAssertEqual(l.fractionUsed(now: now, calendar: cal), 0.55, accuracy: 0.001)
        XCTAssertTrue(l.allows(.taxonomy, now: now, calendar: cal), "20k tokens read, but only 550 written")
        l.record(UsageRecord(at: now, feature: .box, model: "sonnet", tokens: TokenCount(input: 60, output: 450)))
        XCTAssertFalse(l.allows(.taxonomy, now: now, calendar: cal), "background AI pauses over budget")
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


    func testRequestEncodesMessagesAPIShape() throws {
        let req = AIRequest(system: "s", messages: [AIMessage(role: "user", content: "hi")],
                            schema: Schemas.decomposition, maxTokens: 300, cacheTTL: 60)
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

}

final class CallLogTests: XCTestCase {

}

final class RoutingTests: XCTestCase {
    func testEverythingRunsOnSonnetAndOldReflectionRecordsStillLoad() throws {
        for f in AIFeature.allCases { XCTAssertEqual(f.route, AIRoute(model: "sonnet", effort: "low"), "\(f)") }
        let old = #"{"at":"2026-11-10T12:00:00Z","feature":"reflection","model":"opus","tokens":{"input":1,"output":2,"cacheRead":0,"cacheWrite":0}}"#
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let r = try dec.decode(UsageRecord.self, from: Data(old.utf8))
        XCTAssertEqual(r.feature, .review, "v1.0's reflection is part of the weekly note now")
    }

    func testEffortIsSentAsOutputConfig() throws {
        let req = AIRequest(model: "opus", system: "s", messages: [AIMessage(role: "user", content: "hi")], schema: nil, maxTokens: 100,
                            effort: AIFeature.review.route.effort)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(req)) as! [String: Any]
        XCTAssertEqual((json["output_config"] as? [String: Any])?["effort"] as? String, "low")
    }

    func testRetiredFeaturesInOldRecordsStillDecode() throws {
        let old = #"{"at": 0, "feature": "flashcards", "model": "sonnet", "tokens": {"input": 1, "output": 2, "cacheRead": 0, "cacheWrite": 0}}"#
        let r = try JSONDecoder().decode(UsageRecord.self, from: Data(old.utf8))
        XCTAssertEqual(r.feature, .review, "counted with the background budget's history")
        let reads = try JSONDecoder().decode(UsageRecord.self, from: Data(old.replacingOccurrences(of: "flashcards", with: "reads").utf8))
        XCTAssertEqual(reads.feature, .review)
    }
}
