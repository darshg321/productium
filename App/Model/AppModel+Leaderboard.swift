import Foundation
import ProductiumCore

// Leaderboard: day scores shared with friends through the Cloudflare Worker (`scripts/leaderboard`).

enum LeaderboardClient {
    /// The server new groups use: Info.plist `ProductiumLeaderboardURL` (CI's LEADERBOARD_URL variable).
    static var defaultServer: String? {
        guard let s = Bundle.main.object(forInfoDictionaryKey: "ProductiumLeaderboardURL") as? String, s.hasPrefix("https://") else { return nil }
        return s.hasSuffix("/") ? String(s.dropLast()) : s
    }

    enum Failure: Error { case status(Int), url }

    private static func request(_ g: BoardGroup, member: Bool, method: String, body: Data? = nil) async throws -> Data {
        let path = "/v1/g/\(g.id)" + (member ? "/m/\(g.memberId)" : "")
        guard let url = URL(string: g.server + path) else { throw Failure.url }
        var r = URLRequest(url: url, timeoutInterval: 15)
        r.httpMethod = method
        if member { r.setValue("Bearer \(g.memberKey)", forHTTPHeaderField: "Authorization") }
        if let body { r.httpBody = body; r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw Failure.status(code) }
        return data
    }

    static func board(_ g: BoardGroup) async throws -> Board {
        try JSONDecoder().decode(Board.self, from: try await request(g, member: false, method: "GET"))
    }

    static func post(_ p: BoardPost, to g: BoardGroup) async throws {
        _ = try await request(g, member: true, method: "PUT", body: try JSONEncoder().encode(p))
    }

    static func leave(_ g: BoardGroup) async throws {
        _ = try await request(g, member: true, method: "DELETE")
    }
}

extension AppModel {
    var myBoardPost: BoardPost {
        Leaderboard.post(name: state.leaderboard.displayName, today: Date(), calendar: cal) { dayScore($0) }
    }

    /// A new group on the default server; you're its first member.
    func createLeaderboard(named name: String) async -> BoardGroup? {
        guard let server = LeaderboardClient.defaultServer else {
            toast = "No leaderboard server in this build. Run scripts/leaderboard/deploy.sh, then rebuild."
            return nil
        }
        let g = BoardGroup(id: Leaderboard.randomId(), name: String(name.prefix(40)), server: server,
                           memberId: Leaderboard.randomId(), memberKey: Leaderboard.randomId(), joinedAt: Date())
        return await add(g) ? g : nil
    }

    /// productium://join?s=…&g=…&n=… (from a link or pasted).
    @discardableResult
    func joinLeaderboard(_ link: String) async -> Bool {
        guard let i = Leaderboard.readInvite(link) else { toast = "That isn't a Productium invite link."; return false }
        guard !state.leaderboard.displayName.isEmpty else { pendingInvite = link; return false }
        pendingInvite = nil
        if state.leaderboard.groups.contains(where: { $0.id == i.group }) { toast = "You're already in \(i.name)."; return true }
        let g = BoardGroup(id: i.group, name: i.name, server: i.server, memberId: Leaderboard.randomId(),
                           memberKey: Leaderboard.randomId(), joinedAt: Date())
        return await add(g)
    }

    private func add(_ g: BoardGroup) async -> Bool {
        do {
            try await LeaderboardClient.post(myBoardPost, to: g)
            state.leaderboard.groups.append(g)
            state.leaderboard.lastPost[g.id] = myBoardPost
            state.leaderboard.lastPostAt[g.id] = Date()
            log(.lifecycle, "leaderboard_joined", ["group": g.name])
            await refreshLeaderboards(force: true)
            save()
            return true
        } catch {
            log(.lifecycle, "leaderboard_join_failed", level: .warn, ["error": "\(error)"])
            toast = "Couldn't reach the leaderboard. Try again in a minute."
            return false
        }
    }

    func leaveLeaderboard(_ id: String) async {
        guard let g = state.leaderboard.groups.first(where: { $0.id == id }) else { return }
        try? await LeaderboardClient.leave(g)
        state.leaderboard.groups.removeAll { $0.id == id }
        state.leaderboard.boards[id] = nil
        state.leaderboard.lastPost[id] = nil
        state.leaderboard.lastPostAt[id] = nil
        save()
    }

    /// Sends your days when they changed (at most every 15 min) and fetches each board. Launch, refresh, Review.
    func refreshLeaderboards(force: Bool = false) async {
        guard !state.leaderboard.groups.isEmpty, !state.leaderboard.displayName.isEmpty else { return }
        let post = myBoardPost
        for g in state.leaderboard.groups {
            let due = force || Date().timeIntervalSince(state.leaderboard.lastPostAt[g.id] ?? .distantPast) > 15 * 60
            if due, state.leaderboard.lastPost[g.id] != post {
                do {
                    try await LeaderboardClient.post(post, to: g)
                    state.leaderboard.lastPost[g.id] = post
                    state.leaderboard.lastPostAt[g.id] = Date()
                } catch {
                    log(.lifecycle, "leaderboard_post_failed", level: .warn, ["group": g.name, "error": "\(error)"])
                }
            }
            let fetched = (try? await LeaderboardClient.board(g)) ?? state.leaderboard.boards[g.id] ?? Board(members: [])
            state.leaderboard.boards[g.id] = Leaderboard.withYou(fetched, you: g.memberId, post: post)
        }
        save()
    }
}
