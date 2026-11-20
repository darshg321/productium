import Foundation

public struct AppliedReport: Codable, Hashable, Sendable {
    public var changes: [String]
    public var problems: [String]
    public init(changes: [String] = [], problems: [String] = []) { self.changes = changes; self.problems = problems }

    public var toolResultText: String {
        var out: [String] = []
        out.append(changes.isEmpty ? "Applied: nothing" : "Applied: " + changes.joined(separator: "; "))
        if !problems.isEmpty { out.append("Not applied: " + problems.joined(separator: "; ")) }
        return out.joined(separator: "\n")
    }
}

public struct ConversationTurn: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var at: Date
    public var text: String
    public var images: [AIImage]
    public var userContent: JSONValue
    public var assistantContent: JSONValue?
    public var reply: String
    public var applied: AppliedReport
    public var callId: UUID?
    public var tokens: TokenCount?
    public var failed: Bool
    public var detail: String?
    public var context: String
    /// The box's queries for this turn (Part F): charts re-run them live against the log.
    public var queries: [TimeQuery]?

    public init(id: UUID = UUID(), at: Date, text: String, images: [AIImage] = [], userContent: JSONValue,
                assistantContent: JSONValue? = nil, reply: String = "", applied: AppliedReport = AppliedReport(),
                callId: UUID? = nil, tokens: TokenCount? = nil, failed: Bool = false, detail: String? = nil,
                context: String = "", queries: [TimeQuery]? = nil) {
        self.queries = queries.flatMap { $0.isEmpty ? nil : $0 }
        self.id = id
        self.at = at
        self.text = text
        self.images = images
        self.userContent = userContent
        self.assistantContent = assistantContent
        self.reply = reply
        self.applied = applied
        self.callId = callId
        self.tokens = tokens
        self.failed = failed
        self.detail = detail
        self.context = context
    }

    public var isInHistory: Bool { !failed && assistantContent != nil }

    public var toolUseId: String? {
        guard case .array(let blocks)? = assistantContent else { return nil }
        for b in blocks {
            if case .object(let o) = b, o["type"] == .string("tool_use"), case .string(let id)? = o["id"] { return id }
        }
        return nil
    }
}

public struct ConversationTokenStats: Codable, Hashable, Sendable {
    public var last: TokenCount?
    public var outputTotal: Int
    public var cacheReadTotal: Int
    public var requests: Int

    public init(last: TokenCount? = nil, outputTotal: Int = 0, cacheReadTotal: Int = 0, requests: Int = 0) {
        self.last = last
        self.outputTotal = outputTotal
        self.cacheReadTotal = cacheReadTotal
        self.requests = requests
    }

    public var size: Int { last.map { $0.input + $0.cacheRead + $0.cacheWrite } ?? 0 }

    public mutating func add(_ t: TokenCount) {
        last = t
        outputTotal += t.output
        cacheReadTotal += t.cacheRead
        requests += 1
    }
}

public struct Conversation: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var startedAt: Date
    public var lastRequestAt: Date?
    public var turns: [ConversationTurn]
    public var tokenStats: ConversationTokenStats
    public var title: String?
    public var archivedAt: Date?

    public init(id: UUID = UUID(), startedAt: Date, lastRequestAt: Date? = nil, turns: [ConversationTurn] = [],
                tokenStats: ConversationTokenStats = ConversationTokenStats(), title: String? = nil, archivedAt: Date? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.lastRequestAt = lastRequestAt
        self.turns = turns
        self.tokenStats = tokenStats
        self.title = title
        self.archivedAt = archivedAt
    }

    public var isEmpty: Bool { turns.isEmpty }

    public mutating func add(_ turn: ConversationTurn) {
        turns.append(turn)
        if let t = turn.tokens { tokenStats.add(t) }
        if !turn.failed { lastRequestAt = turn.at }
    }

    public func request(system: String, tool: AITool, userContent: JSONValue, maxTokens: Int,
                        model: String = AIModel.sonnet, effort: String? = nil) -> AIRequest {
        AIRequest(model: model, system: system, messages: messages + [AIMessage(role: "user", raw: userContent)],
                  tool: tool, maxTokens: maxTokens, effort: effort)
    }

    public var history: [ConversationTurn] { turns.filter(\.isInHistory) }

    public var messages: [AIMessage] {
        history.flatMap { t -> [AIMessage] in
            [AIMessage(role: "user", raw: t.userContent), AIMessage(role: "assistant", raw: t.assistantContent ?? .array([]))]
        }
    }

    public func cacheExpired(now: Date) -> Bool {
        guard let last = lastRequestAt, !history.isEmpty else { return false }
        return now.timeIntervalSince(last) >= ConversationPolicy.cacheTTL
    }

    /// "Clear · 14.2k tokens": what the next prompt will carry.
    public var clearTitle: String {
        tokenStats.size > 0 ? "Clear · \(tokensLabel(tokenStats.size)) tokens" : "Clear"
    }

    public var outputLine: String? {
        tokenStats.outputTotal > 0 ? "\(tokensLabel(tokenStats.outputTotal)) tokens out so far" : nil
    }

    /// Shown when the Clear button turns red. Nothing clears by itself.
    public func cacheNote(now: Date) -> String? {
        guard cacheExpired(now: now) else { return nil }
        let size = tokenStats.size > 0 ? "all \(tokensLabel(tokenStats.size)) tokens" : "the whole conversation"
        return "Cache expired. Your next message re-reads \(size). Clear to start fresh, or keep going to keep the context."
    }

    public var suggestedTitle: String {
        let first = turns.first { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?.text
            ?? (turns.first.map { _ in "Screenshots" } ?? "Empty")
        let line = first.split(whereSeparator: \.isNewline).first.map(String.init) ?? first
        return line.count > 60 ? String(line.prefix(57)).trimmingCharacters(in: .whitespaces) + "…" : line
    }
}

public struct ConversationArchive: Codable, Hashable, Sendable {
    public var conversations: [Conversation]
    public init(conversations: [Conversation] = []) { self.conversations = conversations }

    public mutating func archive(_ c: Conversation, now: Date) {
        guard !c.isEmpty else { return }
        var c = c
        c.title = c.title ?? c.suggestedTitle
        c.archivedAt = now
        conversations.removeAll { $0.id == c.id }
        conversations.append(c)
    }

    public mutating func remove(_ id: UUID) -> Conversation? {
        guard let i = conversations.firstIndex(where: { $0.id == id }) else { return nil }
        return conversations.remove(at: i)
    }

    public func search(_ query: String) -> [Conversation] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let all = conversations.sorted { ($0.archivedAt ?? $0.startedAt) > ($1.archivedAt ?? $1.startedAt) }
        guard !q.isEmpty else { return all }
        return all.filter { c in
            (c.title ?? "").lowercased().contains(q)
                || c.turns.contains { $0.text.lowercased().contains(q) || $0.reply.lowercased().contains(q) }
        }
    }
}

// claude-server only keeps a live session (and its prompt cache) when history is resent byte-for-byte
// and the last answer was a tool call: a json_schema answer is never parked, so the box uses a forced tool.
public enum ConversationPolicy {
    public static let toolName = "apply"

    // The server drops a session waiting on a tool result after 15 min (CLAUDE_SERVER_SESSION_TOOL_TTL).
    public static let cacheTTL: TimeInterval = 15 * 60

    public static let cacheControl: JSONValue = .object(["type": .string("ephemeral"), "ttl": .string("1h")])

    public static func tool(schema: JSONValue) -> AITool {
        AITool(name: toolName, description: "Apply your changes to the app and give your reply. Always call this.",
               inputSchema: schema)
    }

    static func textBlock(_ s: String, cache: Bool = false) -> JSONValue {
        var o: [String: JSONValue] = ["type": .string("text"), "text": .string(s)]
        if cache { o["cache_control"] = cacheControl }
        return .object(o)
    }

    static func image(_ i: AIImage) -> JSONValue {
        .object(["type": .string("image"),
                 "source": .object(["type": .string("base64"), "media_type": .string(i.mediaType), "data": .string(i.base64)])])
    }

    static func studentText(_ text: String, images: [AIImage]) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Student:\n" + (t.isEmpty ? (images.isEmpty ? "(empty)" : "(screenshots only)") : t)
    }

    public static func userContent(for c: Conversation, text: String, images: [AIImage],
                                   fullContext: String) -> JSONValue {
        let student = textBlock(studentText(text, images: images))
        let pics = images.map(image)
        guard let last = c.history.last else {
            return .array([textBlock("Context (the app right now):\n\(fullContext)", cache: true)] + pics + [student])
        }
        var blocks: [JSONValue] = []
        if let toolId = last.toolUseId {
            // Images go in the tool result (read by a live session) and top-level (read when history is replayed).
            blocks.append(.object(["type": .string("tool_result"), "tool_use_id": .string(toolId),
                                   "content": .array([textBlock(last.applied.toolResultText)] + pics)]))
        } else {
            blocks.append(textBlock("[Your last answer: \(last.applied.toolResultText)]"))
        }
        blocks.append(textBlock(delta(from: last.context, to: fullContext)))
        return .array(blocks + pics + [student])
    }

    public static func delta(from old: String, to new: String) -> String {
        func lines(_ s: String) -> [String] { s.split(separator: "\n").map(String.init) }
        /// Lines of `xs` not in `ys`, counting repeats.
        func missing(_ xs: [String], from ys: [String]) -> [String] {
            var left = Dictionary(ys.map { ($0, 1) }, uniquingKeysWith: +)
            return xs.filter { x in
                guard let n = left[x], n > 0 else { return true }
                left[x] = n - 1
                return false
            }
        }
        let a = lines(old), b = lines(new)
        let added = missing(b, from: a), removed = missing(a, from: b)
        let full = "Context (the app right now, replaces the earlier context):\n\(new)"
        if added.isEmpty && removed.isEmpty { return "Context: unchanged since your last message." }
        let body = (["Since your last message, the context changed:"]
            + removed.map { "- " + $0 } + added.map { "+ " + $0 }).joined(separator: "\n")
        return body.count >= full.count ? full : body
    }
}
