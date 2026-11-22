import Foundation

// Leaderboard: friends compare day scores through a Cloudflare Worker (`scripts/leaderboard`). Only each day's score
// parts and a display name leave the phone, never entries, tasks or places. A group is a random id; whoever has the
// invite link is in it. Each member writes only their own row (a random key, set on the first write).

/// One day as the board sees it.
public struct BoardDay: Codable, Hashable, Sendable {
    /// "yyyy-MM-dd"
    public var d: String
    public var score: Int
    /// Share of waking time tracked, 0–100.
    public var tracked: Int
    /// Minutes worked on tasks.
    public var work: Int
    public var met: Int
    public var missed: Int
    /// Minutes scrolling.
    public var scroll: Int

    public init(d: String, score: Int, tracked: Int, work: Int, met: Int, missed: Int, scroll: Int) {
        self.d = d; self.score = score; self.tracked = tracked; self.work = work; self.met = met; self.missed = missed; self.scroll = scroll
    }

    public init(day: String, _ s: DayScore) {
        self.init(d: day, score: s.score,
                  tracked: s.wakingMinutes == 0 ? 0 : Int((100 * Double(s.wakingMinutes - s.untrackedMinutes) / Double(s.wakingMinutes)).rounded()),
                  work: s.workMinutes, met: s.deadlinesMet, missed: s.deadlinesDue - s.deadlinesMet, scroll: s.scrollingMinutes)
    }
}

/// What a phone sends: its last days and its own usual score (so "vs usual" is fair across different timetables).
public struct BoardPost: Codable, Hashable, Sendable {
    public var name: String
    public var usual: Int?
    public var days: [BoardDay]
    public init(name: String, usual: Int?, days: [BoardDay]) { self.name = name; self.usual = usual; self.days = days }
}

public struct BoardMember: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var usual: Int?
    public var days: [BoardDay]
    /// When they last posted (ms since 1970, the Worker's clock).
    public var at: Double?
    public init(id: String, name: String, usual: Int?, days: [BoardDay], at: Double? = nil) {
        self.id = id; self.name = name; self.usual = usual; self.days = days; self.at = at
    }
}

public struct Board: Codable, Hashable, Sendable {
    public var members: [BoardMember]
    public init(members: [BoardMember]) { self.members = members }
}

/// A group you're in, with your own member id and write key for it.
public struct BoardGroup: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// The Worker's base URL ("https://productium-leaderboard.you.workers.dev").
    public var server: String
    public var memberId: String
    public var memberKey: String
    public var joinedAt: Date
    public init(id: String, name: String, server: String, memberId: String, memberKey: String, joinedAt: Date) {
        self.id = id; self.name = name; self.server = server; self.memberId = memberId; self.memberKey = memberKey; self.joinedAt = joinedAt
    }
}

public struct LeaderboardState: Codable, Hashable, Sendable {
    /// The name friends see.
    public var displayName = ""
    public var groups: [BoardGroup] = []
    /// The last board fetched per group (shown offline).
    public var boards: [String: Board] = [:]
    /// What was last sent per group, so an unchanged day isn't sent again (the free Worker allows 1,000 writes a day).
    public var lastPost: [String: BoardPost] = [:]
    public var lastPostAt: [String: Date] = [:]
    public init() {}
}

public enum Leaderboard {
    public enum Metric: String, CaseIterable, Codable, Sendable {
        case score, vsUsual, work, tracked, scrolling
        public var title: String {
            switch self {
            case .score: return "Score"
            case .vsUsual: return "vs Usual"
            case .work: return "Work"
            case .tracked: return "Tracked"
            case .scrolling: return "Least Scrolling"
            }
        }
    }

    public struct Row: Hashable, Identifiable, Sendable {
        public var id: String
        public var name: String
        public var rank: Int
        public var value: Double
        public var label: String
        public var isYou: Bool
        /// Days with data in the window.
        public var days: Int
    }

    /// The window: the last `days` days up to and including today.
    public static func window(today: Date, days: Int, calendar cal: Calendar) -> Set<String> {
        Set((0..<days).compactMap { cal.date(byAdding: .day, value: -$0, to: cal.startOfDay(for: today)) }.map { DayKeys.key($0, cal) })
    }

    /// Ranked rows for a metric over the window. Members with no day in it come last, unranked.
    public static func rows(_ board: Board, metric: Metric, you: String?, today: Date, days: Int = 7, calendar cal: Calendar) -> [Row] {
        let keys = window(today: today, days: days, calendar: cal)
        var rows: [Row] = board.members.map { m in
            let ds = m.days.filter { keys.contains($0.d) }
            func mean(_ f: (BoardDay) -> Int) -> Double { ds.isEmpty ? 0 : Double(ds.map(f).reduce(0, +)) / Double(ds.count) }
            let value: Double, label: String
            switch metric {
            case .score: value = mean(\.score); label = "\(Int(value.rounded()))"
            case .vsUsual:
                value = m.usual.map { mean(\.score) - Double($0) } ?? 0
                label = m.usual == nil ? "new" : (value >= 0 ? "+" : "−") + "\(Int(abs(value).rounded()))"
            case .work: value = Double(ds.map(\.work).reduce(0, +)); label = minutesLabel(Int(value))
            case .tracked: value = mean(\.tracked); label = "\(Int(value.rounded()))%"
            case .scrolling: value = -mean(\.scroll); label = "\(minutesLabel(Int(-value))) a day"
            }
            return Row(id: m.id, name: m.name, rank: 0, value: value, label: ds.isEmpty ? "–" : label, isYou: m.id == you, days: ds.count)
        }
        rows.sort { a, b in
            if (a.days == 0) != (b.days == 0) { return a.days > 0 }
            if a.value != b.value { return a.value > b.value }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        // Ties share a rank (1, 2, 2, 4).
        for i in rows.indices where rows[i].days > 0 {
            rows[i].rank = i > 0 && rows[i - 1].days > 0 && rows[i - 1].value == rows[i].value ? rows[i - 1].rank : i + 1
        }
        return rows
    }

    /// Your own row is always your current numbers (the Worker's list can lag a write by up to a minute, and a post
    /// can fail offline).
    public static func withYou(_ board: Board, you: String, post: BoardPost?) -> Board {
        guard let post else { return board }
        var b = board
        let at = b.members.first { $0.id == you }?.at
        b.members.removeAll { $0.id == you }
        b.members.append(BoardMember(id: you, name: post.name, usual: post.usual, days: post.days, at: at))
        return b
    }

    // MARK: Ids, keys and invites

    /// 128 random bits, URL-safe (the Worker accepts [A-Za-z0-9_-]{8,64}).
    public static func randomId() -> String {
        var g = SystemRandomNumberGenerator()
        let bytes = (0..<16).map { _ in UInt8.random(in: 0...255, using: &g) }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    public static func isValidId(_ s: String) -> Bool {
        (8...64).contains(s.count) && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// productium://join?s=<server>&g=<group>&n=<name> (productium-dev:// from a dev build).
    public static func invite(_ g: BoardGroup, scheme: String = "productium") -> URL? {
        var c = URLComponents()
        c.scheme = scheme
        c.host = "join"
        c.queryItems = [URLQueryItem(name: "s", value: g.server), URLQueryItem(name: "g", value: g.id), URLQueryItem(name: "n", value: g.name)]
        return c.url
    }

    public static func readInvite(_ s: String) -> (server: String, group: String, name: String)? {
        guard let c = URLComponents(string: s.trimmingCharacters(in: .whitespacesAndNewlines)), c.scheme == "productium" || c.scheme == "productium-dev", c.host == "join",
              let server = c.queryItems?.first(where: { $0.name == "s" })?.value, server.hasPrefix("https://"),
              let group = c.queryItems?.first(where: { $0.name == "g" })?.value, isValidId(group) else { return nil }
        let name = c.queryItems?.first(where: { $0.name == "n" })?.value ?? "Friends"
        return (server, group, String(name.prefix(40)))
    }

    // MARK: What to send

    /// Your last `days` days and your usual (the median score of the 4 weeks before them, when there are 7+ such days).
    public static func post(name: String, today: Date, days: Int = 7, calendar cal: Calendar, score: (Date) -> DayScore?) -> BoardPost {
        let start = cal.startOfDay(for: today)
        let recent: [BoardDay] = (0..<days).reversed().compactMap { i in
            guard let d = cal.date(byAdding: .day, value: -i, to: start), let s = score(d), s.wakingMinutes > 0 else { return nil }
            return BoardDay(day: DayKeys.key(d, cal), s)
        }
        let before = (days..<(days + 28)).compactMap { i -> Int? in
            guard let d = cal.date(byAdding: .day, value: -i, to: start), let s = score(d), s.wakingMinutes > 0 else { return nil }
            return s.score
        }.sorted()
        return BoardPost(name: String(name.prefix(40)), usual: before.count >= 7 ? before[before.count / 2] : nil, days: recent)
    }
}
