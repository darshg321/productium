import Foundation

/// v1.6.1: the app's one server, the Pi behind productium.duckdns.org (`server/` in the repo). Caddy sends `/v1/g/*` and
/// `/v1/backup*` to productium-server and every other `/v1/*` and `/health` to claude-server, which stays on localhost.
public enum ProductiumServer {
    public static let host = "productium.duckdns.org"
    public static let url = "https://\(host)"

    /// The Cloudflare Worker the leaderboard used before 1.6.1; its groups and invites now live on this server.
    public static let movedLeaderboards: Set<String> = ["https://productium-leaderboard.darshg321.workers.dev"]

    /// Where a stored leaderboard address points now.
    public static func current(_ server: String) -> String {
        let s = server.hasSuffix("/") ? String(server.dropLast()) : server
        return movedLeaderboards.contains(s) ? url : s
    }
}
