import Foundation

// MARK: - Token accounting
//
// Every reply from claude-server carries a `usage` block. The app keeps a small local
// ledger of them so the student can see, at a glance, how much the AI is costing today,
// and so background AI (flashcards, reads, project breakdowns) can stand down once the
// daily budget is spent. The box always works: it's the one thing that must never stop.

public struct TokenCount: Codable, Hashable, Sendable {
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite: Int

    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    /// Everything the server processed for this request (what its usage log counts).
    public var total: Int { input + output + cacheRead + cacheWrite }
    /// All prompt-side tokens, cached or not.
    public var prompt: Int { input + cacheRead + cacheWrite }

    public static func + (a: TokenCount, b: TokenCount) -> TokenCount {
        TokenCount(input: a.input + b.input, output: a.output + b.output,
                   cacheRead: a.cacheRead + b.cacheRead, cacheWrite: a.cacheWrite + b.cacheWrite)
    }
}

/// What a request was for, so the meter can say where tokens went.
public enum AIFeature: String, Codable, CaseIterable, Sendable {
    case box, flashcards, reads, breakdown, review

    public var title: String {
        switch self {
        case .box: return "Inbox"
        case .flashcards: return "Flashcards"
        case .reads: return "Short reads"
        case .breakdown: return "Project steps"
        case .review: return "Weekly note"
        }
    }

    /// Background features stand down when the day's budget is spent. The box doesn't.
    public var isBackground: Bool { self != .box }
}

public struct UsageRecord: Codable, Hashable, Sendable {
    public var at: Date
    public var feature: AIFeature
    public var model: String
    public var tokens: TokenCount

    public init(at: Date, feature: AIFeature, model: String, tokens: TokenCount) {
        self.at = at
        self.feature = feature
        self.model = model
        self.tokens = tokens
    }
}

public struct DailyTokens: Hashable, Sendable {
    public var day: Date
    public var tokens: Int
}

public struct FeatureTokens: Hashable, Sendable {
    public var feature: AIFeature
    public var tokens: Int
    public var requests: Int
}

public struct UsageLedger: Codable, Hashable, Sendable {
    public static let defaultBudget = 25_000

    public var records: [UsageRecord] = []
    /// Daily token budget the meter fills against.
    public var dailyBudget: Int = UsageLedger.defaultBudget
    /// When on, background AI pauses for the rest of the day once the budget is spent.
    public var pauseBackgroundOverBudget = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        records = (try? c.decodeIfPresent([UsageRecord].self, forKey: .records)) ?? []
        dailyBudget = (try? c.decodeIfPresent(Int.self, forKey: .dailyBudget)) ?? UsageLedger.defaultBudget
        pauseBackgroundOverBudget = (try? c.decodeIfPresent(Bool.self, forKey: .pauseBackgroundOverBudget)) ?? true
    }

    public mutating func record(_ r: UsageRecord) {
        records.append(r)
        prune(now: r.at)
    }

    /// Keep 31 days: enough for "last 30 days", small enough not to matter.
    public mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-31 * 86400)
        records.removeAll { $0.at < cutoff }
    }

    public func records(on day: Date, calendar: Calendar) -> [UsageRecord] {
        records.filter { calendar.isDate($0.at, inSameDayAs: day) }
    }

    public func total(on day: Date, calendar: Calendar) -> TokenCount {
        records(on: day, calendar: calendar).reduce(TokenCount()) { $0 + $1.tokens }
    }

    public func total(lastDays n: Int, now: Date, calendar: Calendar) -> TokenCount {
        let start = calendar.date(byAdding: .day, value: -(n - 1), to: calendar.startOfDay(for: now)) ?? now
        return records.filter { $0.at >= start }.reduce(TokenCount()) { $0 + $1.tokens }
    }

    /// Per-day totals for the last `n` days, oldest first (today last).
    public func daily(lastDays n: Int, now: Date, calendar: Calendar) -> [DailyTokens] {
        let today = calendar.startOfDay(for: now)
        return (0..<n).reversed().compactMap { i in
            guard let d = calendar.date(byAdding: .day, value: -i, to: today) else { return nil }
            return DailyTokens(day: d, tokens: total(on: d, calendar: calendar).total)
        }
    }

    public func byFeature(on day: Date, calendar: Calendar) -> [FeatureTokens] {
        let todays = records(on: day, calendar: calendar)
        return AIFeature.allCases.compactMap { f in
            let rs = todays.filter { $0.feature == f }
            return rs.isEmpty ? nil : FeatureTokens(feature: f, tokens: rs.reduce(0) { $0 + $1.tokens.total }, requests: rs.count)
        }
        .sorted { $0.tokens > $1.tokens }
    }

    /// Fraction of today's budget used (can exceed 1).
    public func fractionUsed(now: Date, calendar: Calendar) -> Double {
        guard dailyBudget > 0 else { return 0 }
        return Double(total(on: now, calendar: calendar).total) / Double(dailyBudget)
    }

    public func allows(_ feature: AIFeature, now: Date, calendar: Calendar) -> Bool {
        !(feature.isBackground && pauseBackgroundOverBudget && fractionUsed(now: now, calendar: calendar) >= 1)
    }
}

/// "840", "12.4k", "1.2M": short enough for a toolbar.
public func tokensLabel(_ n: Int) -> String {
    switch n {
    case ..<1000: return "\(n)"
    case ..<10_000: return String(format: "%.1fk", Double(n) / 1000)
    case ..<1_000_000: return "\(Int((Double(n) / 1000).rounded()))k"
    default: return String(format: "%.1fM", Double(n) / 1_000_000)
    }
}
