import XCTest
@testable import ProductiumCore

final class LeaderboardTests: XCTestCase {
    let cal = Fx.cal

    func day(_ back: Int, score: Int, work: Int = 60, scroll: Int = 30, tracked: Int = 80) -> BoardDay {
        BoardDay(d: DayKeys.key(Fx.mon(0, plusDays: -back), cal), score: score, tracked: tracked, work: work, met: 1, missed: 0, scroll: scroll)
    }

    var board: Board {
        Board(members: [
            BoardMember(id: "me", name: "Me", usual: 60, days: [day(0, score: 70), day(1, score: 70)]),
            BoardMember(id: "ana", name: "Ana", usual: 85, days: [day(0, score: 80, work: 200, scroll: 10), day(1, score: 80, work: 100, scroll: 10)]),
            BoardMember(id: "ben", name: "Ben", usual: nil, days: [day(0, score: 70, scroll: 90), day(9, score: 100)]),
            BoardMember(id: "cy", name: "Cy", usual: 50, days: [day(20, score: 99)]),
        ])
    }

    func testRanksByMetricOverTheWindow() {
        let score = Leaderboard.rows(board, metric: .score, you: "me", today: Fx.mon(12), calendar: cal)
        XCTAssertEqual(score.map(\.name), ["Ana", "Ben", "Me", "Cy"])
        XCTAssertEqual(score.map(\.rank), [1, 2, 2, 0], "ties share a rank; no data in the window is unranked")
        XCTAssertEqual(score[1].days, 1, "Ben's day 9 days ago is outside the week")
        XCTAssertTrue(score[2].isYou)
        let vs = Leaderboard.rows(board, metric: .vsUsual, you: "me", today: Fx.mon(12), calendar: cal)
        XCTAssertEqual(vs.first?.name, "Me", "beating your own usual beats a higher score below theirs")
        XCTAssertEqual(vs.first?.label, "+10")
        XCTAssertEqual(vs.first { $0.name == "Ana" }?.label, "−5")
        XCTAssertEqual(Leaderboard.rows(board, metric: .work, you: nil, today: Fx.mon(12), calendar: cal).first?.label, "5h")
        XCTAssertEqual(Leaderboard.rows(board, metric: .scrolling, you: nil, today: Fx.mon(12), calendar: cal).map(\.name).prefix(3),
                       ["Ana", "Me", "Ben"])
    }

    func testYourRowIsWhatYouLastSent() {
        let p = BoardPost(name: "Me 2", usual: 61, days: [day(0, score: 90)])
        let b = Leaderboard.withYou(board, you: "me", post: p)
        XCTAssertEqual(b.members.count, 4)
        XCTAssertEqual(b.members.first { $0.id == "me" }?.name, "Me 2")
        XCTAssertEqual(Leaderboard.withYou(Board(members: []), you: "me", post: p).members.map(\.id), ["me"], "shown before the list catches up")
    }

    func testInviteRoundTripsAndRejectsJunk() {
        let g = BoardGroup(id: Leaderboard.randomId(), name: "Study crew", server: "https://lb.example.workers.dev",
                           memberId: Leaderboard.randomId(), memberKey: Leaderboard.randomId(), joinedAt: Fx.mon(0))
        XCTAssertTrue(Leaderboard.isValidId(g.id), g.id)
        let url = Leaderboard.invite(g)!.absoluteString
        let back = Leaderboard.readInvite(url)
        XCTAssertEqual(back?.group, g.id)
        XCTAssertEqual(back?.name, "Study crew")
        XCTAssertEqual(back?.server, g.server)
        XCTAssertNil(Leaderboard.readInvite("productium://join?s=http://evil&g=\(g.id)"), "https only")
        XCTAssertNil(Leaderboard.readInvite("productium://join?s=https://x.dev&g=a/b"))
        XCTAssertNil(Leaderboard.readInvite("https://example.com"))
    }

    func testPostSendsRecentDaysAndAUsualOnlyWithHistory() {
        let s = DayScore(wakingMinutes: 900, untrackedMinutes: 90, workMinutes: 60, askedMinutes: 60, deadlinesDue: 1, deadlinesMet: 1, scrollingMinutes: 30)
        let p = Leaderboard.post(name: "Me", today: Fx.mon(12), calendar: cal) { d in d < Fx.mon(0, plusDays: -20) ? nil : s }
        XCTAssertEqual(p.days.count, 7)
        XCTAssertEqual(p.days.last?.d, DayKeys.key(Fx.mon(0), cal))
        XCTAssertEqual(p.days.last?.tracked, 90)
        XCTAssertEqual(p.usual, s.score, "14 days of history before the week is enough")
        let fresh = Leaderboard.post(name: "Me", today: Fx.mon(12), calendar: cal) { d in d < Fx.mon(0, plusDays: -8) ? nil : s }
        XCTAssertNil(fresh.usual)
    }
}
