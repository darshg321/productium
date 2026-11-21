import XCTest
@testable import ProductiumCore

/// v1.2 A9: a reply is saved before it's sent, retried with back-off, and removed only once applied.
final class OutboxTests: XCTestCase {
    let t0 = Fx.mon(15, 40)

    func testSavedBeforeSendRetriedAndRemovedOnceApplied() throws {
        var box = Outbox()
        let id = try XCTUnwrap(box.add("gym with sam", source: .notification, context: "What are you up to? (15:40)", at: t0))
        XCTAssertEqual(box.due(now: t0).map(\.id), [id], "due at once")
        // Survives a relaunch: it's in the state that's saved before any network call.
        let data = try JSONEncoder().encode(box)
        box = try JSONDecoder().decode(Outbox.self, from: data)
        box.failed(id, error: "offline", at: t0)
        XCTAssertTrue(box.due(now: t0.addingTimeInterval(30)).isEmpty, "waits a minute")
        XCTAssertEqual(box.due(now: t0.addingTimeInterval(61)).count, 1)
        box.failed(id, error: "offline", at: t0.addingTimeInterval(61))
        XCTAssertTrue(box.due(now: t0.addingTimeInterval(61 + 100)).isEmpty, "then two")
        XCTAssertEqual(box.due(now: t0.addingTimeInterval(61 + 121)).first?.attempts, 2)
        box.sent(id)
        XCTAssertTrue(box.items.isEmpty)
    }

    func testDoubleTapIsOneReplyAndEmptyIsNothing() {
        var box = Outbox()
        let a = box.add("done", source: .notification, at: t0)
        let b = box.add(" done ", source: .notification, at: t0.addingTimeInterval(5))
        XCTAssertEqual(a, b)
        XCTAssertNil(box.add("   ", source: .app, at: t0))
        XCTAssertEqual(box.items.count, 1)
    }

    func testALateAnswerKeepsWhenAndWhatItAnswered() {
        let item = OutboxItem(text: "gym", at: t0, source: .notification, context: "What are you up to? (15:40)")
        XCTAssertEqual(item.boxText(now: t0.addingTimeInterval(60), calendar: Fx.cal), "(Answering: What are you up to? (15:40)) gym")
        XCTAssertEqual(item.boxText(now: t0.addingTimeInterval(3600), calendar: Fx.cal),
                       "(Answering: What are you up to? (15:40)) (Written at Mon 15:40, sent now) gym")
    }

    func testOldOnesArePruned() {
        var box = Outbox()
        box.add("x", source: .app, at: t0)
        box.prune(now: t0.addingTimeInterval(8 * 86400))
        XCTAssertTrue(box.items.isEmpty)
    }
}
