import Foundation

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

    public var counted: Int { output }

    public static func + (a: TokenCount, b: TokenCount) -> TokenCount {
        TokenCount(input: a.input + b.input, output: a.output + b.output,
                   cacheRead: a.cacheRead + b.cacheRead, cacheWrite: a.cacheWrite + b.cacheWrite)
    }
}

public enum AIFeature: String, Codable, CaseIterable, Sendable {
    case box, breakdown, review
    /// v1.2 C5: the category tree's daily tidy.
    case taxonomy

    public var title: String {
        switch self {
        case .box: return "Inbox"
        case .breakdown: return "Project steps"
        case .review: return "Weekly note"
        case .taxonomy: return "Category tidy-up"
        }
    }

    public var isBackground: Bool { self != .box }

    /// Every feature runs on Sonnet at low effort (v1.1: the Opus reflection became part of the weekly note).
    public var route: AIRoute { AIRoute(model: AIModel.sonnet, effort: "low") }

    /// v1.0 logged the reflection as its own feature; it's the weekly note's insight pass now.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        // v1.2 K2: flashcards and short reads are gone; their old records stay in the background budget's history.
        switch raw {
        case "reflection", "flashcards", "reads": self = .review
        default: self = AIFeature(rawValue: raw) ?? .box
        }
    }
}

public struct AIRoute: Hashable, Sendable {
    public var model: String
    public var effort: String
    public init(model: String, effort: String) {
        self.model = model
        self.effort = effort
    }

    public var title: String { "\(model.capitalized) · \(effort) effort" }
}

public struct UsageRecord: Codable, Hashable, Sendable {
    public var at: Date
    public var feature: AIFeature
    public var model: String
    public var tokens: TokenCount
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
    public static let defaultBudget = 10_000

    public var records: [UsageRecord] = []
    public var dailyBudget: Int = UsageLedger.defaultBudget
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

    public func fractionUsed(now: Date, calendar: Calendar) -> Double {
        guard dailyBudget > 0 else { return 0 }
        return Double(total(on: now, calendar: calendar).counted) / Double(dailyBudget)
    }

    public func allows(_ feature: AIFeature, now: Date, calendar: Calendar) -> Bool {
        !(feature.isBackground && pauseBackgroundOverBudget && fractionUsed(now: now, calendar: calendar) >= 1)
    }
}

public func tokensLabel(_ n: Int) -> String {
    switch n {
    case ..<1000: return "\(n)"
    case ..<10_000: return String(format: "%.1fk", Double(n) / 1000)
    case ..<1_000_000: return "\(Int((Double(n) / 1000).rounded()))k"
    default: return String(format: "%.1fM", Double(n) / 1_000_000)
    }
}

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
    public var requestedModel: String
    public var model: String?
    public var system: String
    public var messages: [Message]
    public var schema: String?
    public var maxTokens: Int
    public var cacheTTL: Int?
    public var effort: String?
    public var status: Int?
    public var durationMs: Int
    public var response: String
    public var tokens: TokenCount?
    public var error: String?
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

    public var prettyResponse: String {
        guard let data = response.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data),
              let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let s = String(data: out, encoding: .utf8) else { return response }
        return s
    }

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

public struct AICallLog: Codable, Hashable, Sendable {
    public var calls: [AICall] = []

    public init(calls: [AICall] = []) { self.calls = calls }

    public mutating func append(_ c: AICall, now: Date = Date()) {
        calls.append(c)
    }
}
