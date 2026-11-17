import Foundation

// MARK: - Token accounting
//
// Every reply from claude-server carries a `usage` block. The app keeps a small local ledger
// of them and counts output tokens only, so the student can see at a glance how much the AI
// is costing today, and so background AI (flashcards, reads, project breakdowns) can stand down once the
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

    /// What the meter and the budget count: the tokens the model wrote, including its hidden
    /// thinking. Prompt and cache tokens are kept on the record but never counted.
    public var counted: Int { output }

    public static func + (a: TokenCount, b: TokenCount) -> TokenCount {
        TokenCount(input: a.input + b.input, output: a.output + b.output,
                   cacheRead: a.cacheRead + b.cacheRead, cacheWrite: a.cacheWrite + b.cacheWrite)
    }
}

/// What a request was for, so the meter can say where tokens went.
public enum AIFeature: String, Codable, CaseIterable, Sendable {
    case box, flashcards, reads, breakdown, review, reflection

    public var title: String {
        switch self {
        case .box: return "Inbox"
        case .flashcards: return "Flashcards"
        case .reads: return "Short reads"
        case .breakdown: return "Project steps"
        case .review: return "Weekly note"
        case .reflection: return "Opus · reflection"
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
    /// The full call in `AICallLog`, while it's still kept there.
    public var callId: UUID?

    public init(at: Date, feature: AIFeature, model: String, tokens: TokenCount, callId: UUID? = nil) {
        self.at = at
        self.feature = feature
        self.model = model
        self.tokens = tokens
        self.callId = callId
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
    /// Output tokens a day. A typical Inbox message is a few hundred.
    public static let defaultBudget = 10_000

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

    /// Every record is kept (the export holds all of them).
    public mutating func record(_ r: UsageRecord) {
        records.append(r)
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
            return DailyTokens(day: d, tokens: total(on: d, calendar: calendar).counted)
        }
    }

    public func byFeature(on day: Date, calendar: Calendar) -> [FeatureTokens] {
        let todays = records(on: day, calendar: calendar)
        return AIFeature.allCases.compactMap { f in
            let rs = todays.filter { $0.feature == f }
            return rs.isEmpty ? nil : FeatureTokens(feature: f, tokens: rs.reduce(0) { $0 + $1.tokens.counted }, requests: rs.count)
        }
        .sorted { $0.tokens > $1.tokens }
    }

    /// Fraction of today's budget used (can exceed 1).
    public func fractionUsed(now: Date, calendar: Calendar) -> Double {
        guard dailyBudget > 0 else { return 0 }
        return Double(total(on: now, calendar: calendar).counted) / Double(dailyBudget)
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

// MARK: - Every call, in full
//
// The ledger above keeps numbers. This keeps the words: the exact request the app sent (system
// prompt, messages, schema) and the exact body that came back, so a strange reply can be read
// rather than guessed at. Images are kept as a note of their size, not their bytes.

public struct AICall: Codable, Hashable, Identifiable, Sendable {
    public struct Message: Codable, Hashable, Sendable {
        public var role: String
        public var content: String
        public var images: Int
        public init(role: String, content: String, images: Int = 0) { self.role = role; self.content = content; self.images = images }
    }

    public var id: UUID
    public var at: Date
    public var feature: AIFeature
    /// What was asked for, and what answered (the reply's `model`).
    public var requestedModel: String
    public var model: String?
    public var system: String
    public var messages: [Message]
    /// The JSON schema, pretty-printed, when the request asked for structured output.
    public var schema: String?
    public var maxTokens: Int
    public var cacheTTL: Int?
    /// `output_config.effort`, when the request set one.
    public var effort: String?
    public var status: Int?
    public var durationMs: Int
    /// The response body exactly as received (trimmed only if enormous).
    public var response: String
    public var tokens: TokenCount?
    public var error: String?
    /// 2 when this was the automatic second try after an unusable reply.
    public var attempt: Int

    public init(id: UUID = UUID(), at: Date, feature: AIFeature, requestedModel: String, model: String? = nil, system: String,
                messages: [Message], schema: String? = nil, maxTokens: Int, cacheTTL: Int? = nil, status: Int? = nil,
                durationMs: Int = 0, response: String = "", tokens: TokenCount? = nil, error: String? = nil, attempt: Int = 1) {
        self.id = id
        self.at = at
        self.feature = feature
        self.requestedModel = requestedModel
        self.model = model
        self.system = system
        self.messages = messages
        self.schema = schema
        self.maxTokens = maxTokens
        self.cacheTTL = cacheTTL
        self.status = status
        self.durationMs = durationMs
        self.response = response
        self.tokens = tokens
        self.error = error
        self.attempt = attempt
    }

    public init(request r: AIRequest, feature: AIFeature, at: Date, attempt: Int = 1) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let schema = r.answerSchema.flatMap { try? enc.encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
        self.init(at: at, feature: feature, requestedModel: r.model, system: r.system,
                  messages: r.messages.map { Message(role: $0.role, content: $0.content, images: $0.images.count) },
                  schema: schema, maxTokens: r.max_tokens, cacheTTL: r.cacheTTL, attempt: attempt)
        self.effort = r.output_config?.effort
    }

    public var ok: Bool { error == nil && status == 200 }

    /// The reply pretty-printed when it's JSON, as-is otherwise.
    public var prettyResponse: String {
        guard let data = response.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data),
              let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let s = String(data: out, encoding: .utf8) else { return response }
        return s
    }

    /// The whole exchange as one text file, for Share / Copy.
    public var transcript: String {
        var out = ["\(feature.title) · \(ISO8601DateFormatter().string(from: at)) · \(model ?? requestedModel) · attempt \(attempt)",
                   "HTTP \(status.map(String.init) ?? "-") · \(durationMs) ms · max_tokens \(maxTokens)"
                   + (tokens.map { " · in \($0.input) out \($0.output) cache r/w \($0.cacheRead)/\($0.cacheWrite)" } ?? "")]
        if let e = error { out.append("ERROR: \(e)") }
        out.append("\n=== SYSTEM ===\n\(system)")
        for m in messages {
            out.append("\n=== \(m.role.uppercased()) ===\(m.images > 0 ? " (+\(m.images) image\(m.images == 1 ? "" : "s"))" : "")\n\(m.content)")
        }
        if let s = schema { out.append("\n=== SCHEMA ===\n\(s)") }
        out.append("\n=== RESPONSE ===\n\(prettyResponse)")
        return out.joined(separator: "\n")
    }
}

/// Every call, newest last. Kept in its own file so the main state stays small, and nothing is
/// dropped: the export is also the debugging dump.
public struct AICallLog: Codable, Hashable, Sendable {
    public var calls: [AICall] = []

    public init(calls: [AICall] = []) { self.calls = calls }

    public mutating func append(_ c: AICall, now: Date = Date()) {
        calls.append(c)
    }
}
