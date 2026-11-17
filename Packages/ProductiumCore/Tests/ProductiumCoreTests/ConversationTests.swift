import XCTest
@testable import ProductiumCore

/// The box is one ongoing session: history goes back byte-for-byte, only the new turn is appended.
final class ConversationTests: XCTestCase {
    let tool = ConversationPolicy.tool(schema: Schemas.dump)

    func encoded(_ m: [AIMessage]) throws -> [Data] {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        return try m.map { try enc.encode($0) }
    }

    /// A claude-server reply: one forced `apply` call, with cache reads after the first turn.
    func reply(_ n: Int) throws -> AIResponse {
        let json = """
        {"id":"msg_\(n)","type":"message","role":"assistant","model":"claude-sonnet-5-5","stop_reason":"tool_use",
         "content":[{"type":"tool_use","id":"toolu_\(n)","name":"apply","input":{"actions":[],"reply":"ok \(n)"}}],
         "usage":{"input_tokens":40,"output_tokens":90,"cache_creation_input_tokens":\(n == 1 ? 3000 : 120),
                  "cache_read_input_tokens":\(n == 1 ? 0 : 3000 + n * 150)}}
        """
        return try JSONDecoder().decode(AIResponse.self, from: Data(json.utf8))
    }

    func testTwentyTurnsReplayExactlyAndReadTheCache() throws {
        var c = Conversation(startedAt: Date(timeIntervalSince1970: 0))
        var ledger = UsageLedger()
        var previous: [Data] = []
        for n in 1...20 {
            let now = Date(timeIntervalSince1970: Double(n) * 60)
            let ctx = "Now: \(n)\nOpen tasks:\n- id t1 \"Essay\" \(n * 10)/120m"
            let image = n == 7 ? [AIImage(mediaType: "image/png", base64: "aGk=")] : []
            let content = ConversationPolicy.userContent(for: c, text: "prompt \(n)", images: image, fullContext: ctx)
            let req = c.request(system: Prompts.dump(), tool: tool, userContent: content, maxTokens: 3000)
            let sent = try encoded(req.messages)
            // Everything sent before is sent again, unchanged, and in the same place.
            XCTAssertEqual(Array(sent.prefix(previous.count)), previous, "turn \(n) rewrote history")
            XCTAssertEqual(sent.count, previous.count + 1)
            XCTAssertEqual(req.tool_choice?.name, "apply")

            let res = try reply(n)
            ledger.record(UsageRecord(at: now, feature: .box, model: "sonnet", tokens: res.tokens))
            let result = try XCTUnwrap(DumpResult.read(res))
            XCTAssertEqual(result.reply, "ok \(n)")
            c.add(ConversationTurn(at: now, text: "prompt \(n)", images: image, userContent: content,
                                   assistantContent: res.rawContent, reply: result.reply,
                                   applied: AppliedReport(changes: ["Changed Essay"]), tokens: res.tokens, context: ctx))
            previous = sent + (try encoded([AIMessage(role: "assistant", raw: res.rawContent!)]))
        }
        XCTAssertEqual(c.history.count, 20)
        let reads = ledger.records.map(\.tokens.cacheRead)
        XCTAssertEqual(reads.first, 0)
        XCTAssertTrue(reads.dropFirst().allSatisfy { $0 > 0 }, "turns 2-20 read the prompt cache")
        XCTAssertEqual(c.tokenStats.requests, 20)
        XCTAssertEqual(c.tokenStats.size, 40 + 120 + 3000 + 20 * 150)
        XCTAssertEqual(c.tokenStats.outputTotal, 20 * 90)
        // The thread shows every prompt verbatim.
        XCTAssertEqual(c.turns.map(\.text), (1...20).map { "prompt \($0)" })
    }

    func testLaterTurnsStartWithTheToolResultAndCarryOnlyADelta() throws {
        var c = Conversation(startedAt: Date())
        let ctx1 = "Now: Mon 08:00\nOpen tasks:\n- id t1 \"Essay\" 0/120m\n- id t2 \"Lab\" 0/60m"
        let first = ConversationPolicy.userContent(for: c, text: "hi", images: [], fullContext: ctx1)
        guard case .array(let b1) = first, case .object(let ctxBlock) = b1[0] else { return XCTFail() }
        XCTAssertNotNil(ctxBlock["cache_control"], "the first turn asks for the 1-hour cache")
        XCTAssertEqual(b1.count, 2)
        c.add(ConversationTurn(at: Date(), text: "hi", userContent: first,
                               assistantContent: try reply(1).rawContent, applied: AppliedReport(changes: ["Done: Lab"]), context: ctx1))
        let ctx2 = "Now: Mon 08:05\nOpen tasks:\n- id t1 \"Essay\" 0/120m"
        let second = ConversationPolicy.userContent(for: c, text: "and the essay?", images: [], fullContext: ctx2)
        guard case .array(let b2) = second, case .object(let result) = b2[0], case .object(let delta) = b2[1],
              case .object(let words) = b2[2] else { return XCTFail() }
        XCTAssertEqual(result["type"], .string("tool_result"))
        XCTAssertEqual(result["tool_use_id"], .string("toolu_1"))
        XCTAssertTrue(AIMessage.text(of: .object(result)).contains("Applied: Done: Lab"))
        let d = AIMessage.text(of: .object(delta))
        XCTAssertTrue(d.contains("- - id t2 \"Lab\""), d)
        XCTAssertTrue(d.contains("+ Now: Mon 08:05"), d)
        XCTAssertFalse(d.contains("Essay"), "unchanged lines aren't repeated")
        XCTAssertEqual(words["text"], .string("Student:\nand the essay?"))
    }

    func testDeltaFallsBackToTheFullContextWhenItWouldBeBigger() {
        let old = (1...5).map { "line \($0)" }.joined(separator: "\n")
        let new = (6...10).map { "other \($0)" }.joined(separator: "\n")
        XCTAssertTrue(ConversationPolicy.delta(from: old, to: new).hasPrefix("Context (the app right now"))
        XCTAssertEqual(ConversationPolicy.delta(from: old, to: old), "Context: unchanged since your last message.")
    }

    func testFailedTurnsStayInTheThreadButNotInHistory() throws {
        var c = Conversation(startedAt: Date())
        let content = ConversationPolicy.userContent(for: c, text: "x", images: [], fullContext: "ctx")
        c.add(ConversationTurn(at: Date(), text: "x", userContent: content, failed: true))
        XCTAssertEqual(c.turns.count, 1)
        XCTAssertTrue(c.messages.isEmpty)
        XCTAssertFalse(c.cacheExpired(now: Date()))
    }

    func testCacheExpiresAfterTheTTLAndArchiveKeepsEverything() throws {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var c = Conversation(startedAt: t0)
        let content = ConversationPolicy.userContent(for: c, text: "Waterloo drafts\nmore", images: [], fullContext: "ctx")
        c.add(ConversationTurn(at: t0, text: "Waterloo drafts\nmore", userContent: content,
                               assistantContent: try reply(1).rawContent, reply: "Noted"))
        XCTAssertFalse(c.cacheExpired(now: t0.addingTimeInterval(ConversationPolicy.cacheTTL - 1)))
        XCTAssertTrue(c.cacheExpired(now: t0.addingTimeInterval(ConversationPolicy.cacheTTL)))
        var a = ConversationArchive()
        a.archive(c, now: t0)
        XCTAssertEqual(a.conversations.first?.title, "Waterloo drafts")
        XCTAssertEqual(a.search("noted").count, 1)
        XCTAssertEqual(a.search("nothing").count, 0)
        XCTAssertEqual(a.remove(c.id)?.turns.count, 1)
        XCTAssertTrue(a.conversations.isEmpty)
    }

    func testRawMessagesRoundTrip() throws {
        let raw: JSONValue = .array([.object(["type": .string("text"), "text": .string("hello")])])
        let m = AIMessage(role: "user", raw: raw)
        let back = try JSONDecoder().decode(AIMessage.self, from: JSONEncoder().encode(m))
        XCTAssertEqual(back.raw, raw)
        XCTAssertEqual(back.content, "hello")
    }
}
