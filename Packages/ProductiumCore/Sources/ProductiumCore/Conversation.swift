import Foundation

// MARK: - The Inbox box is one ongoing AI session
//
// Every prompt continues the same conversation until the student clears it. The whole active
// conversation is sent every time, byte-for-byte as it went the first time, and only the new user
// turn is appended (claude-server's rule 3). The server then continues the same live session and
// reads the prompt cache instead of rebuilding it.
//
// The box answers through one forced client tool (`apply`), not `output_config.format`: claude-server
// parks a live session after a tool call, but never after a json_schema answer. Each later user turn
// starts with the tool's result, which is what the app applied for the previous answer, so the model
// learns what really happened without anyone editing history.
//
// App context: the full context goes in the first user turn only. Later turns carry a delta
// ("since your last message: …") so the history stays stable and the cache stays valid.

/// What the app did with one answer: the receipt's lines.
public struct AppliedReport: Codable, Hashable, Sendable {
    public var changes: [String]
    public var problems: [String]
    public init(changes: [String] = [], problems: [String] = []) { self.changes = changes; self.problems = problems }

    /// The tool result sent back at the start of the next turn.
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
    /// Exactly what the student typed.
    public var text: String
    /// Exactly the images that were sent with it.
    public var images: [AIImage]
    /// The user message's `content` as sent, kept so history replays byte-for-byte.
    public var userContent: JSONValue
    /// The assistant message's `content` exactly as it came back. Nil when the request failed
    /// (a failed turn stays in the thread but isn't part of the history that's sent).
    public var assistantContent: JSONValue?
    /// The reply shown to the student.
    public var reply: String
    public var applied: AppliedReport
    public var callId: UUID?
    public var tokens: TokenCount?
    public var failed: Bool
    /// Why it failed, in full (for Details).
    public var detail: String?
    /// The full context this turn's message was built against (the baseline for the next delta).
    public var context: String

    public init(id: UUID = UUID(), at: Date, text: String, images: [AIImage] = [], userContent: JSONValue,
                assistantContent: JSONValue? = nil, reply: String = "", applied: AppliedReport = AppliedReport(),
                callId: UUID? = nil, tokens: TokenCount? = nil, failed: Bool = false, detail: String? = nil,
                context: String = "") {
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

    /// True when this turn is part of the history that's sent.
    public var isInHistory: Bool { !failed && assistantContent != nil }

    /// The id of the `apply` call in the answer, which the next turn's tool result points at.
    public var toolUseId: String? {
        guard case .array(let blocks)? = assistantContent else { return nil }
        for b in blocks {
            if case .object(let o) = b, o["type"] == .string("tool_use"), case .string(let id)? = o["id"] { return id }
        }
        return nil
    }
}

public struct ConversationTokenStats: Codable, Hashable, Sendable {
    /// The latest request's usage: what the next prompt carries is input + cacheRead + cacheWrite.
    public var last: TokenCount?
    /// Everything the model wrote in this conversation.
    public var outputTotal: Int
    public var cacheReadTotal: Int
    public var requests: Int

    public init(last: TokenCount? = nil, outputTotal: Int = 0, cacheReadTotal: Int = 0, requests: Int = 0) {
        self.last = last
        self.outputTotal = outputTotal
        self.cacheReadTotal = cacheReadTotal
        self.requests = requests
    }

    /// The conversation's size: what the next prompt will carry.
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
    /// Set when it's archived: a one-line title.
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

    /// Adds a finished turn (answered or failed) and counts its tokens.
    public mutating func add(_ turn: ConversationTurn) {
        turns.append(turn)
        if let t = turn.tokens { tokenStats.add(t) }
        if !turn.failed { lastRequestAt = turn.at }
    }

    /// The request for a new prompt: the whole history unchanged, then the new user turn.
    public func request(system: String, tool: AITool, userContent: JSONValue, maxTokens: Int,
                        model: String = AIModel.sonnet, effort: String? = nil) -> AIRequest {
        AIRequest(model: model, system: system, messages: messages + [AIMessage(role: "user", raw: userContent)],
                  tool: tool, maxTokens: maxTokens, effort: effort)
    }

    /// The turns that are sent as history, oldest first.
    public var history: [ConversationTurn] { turns.filter(\.isInHistory) }

    /// The messages that go before a new user turn, exactly as they went the first time.
    public var messages: [AIMessage] {
        history.flatMap { t -> [AIMessage] in
            [AIMessage(role: "user", raw: t.userContent), AIMessage(role: "assistant", raw: t.assistantContent ?? .array([]))]
        }
    }

    /// When the prompt cache behind this conversation has expired (see `ConversationPolicy.cacheTTL`).
    public func cacheExpired(now: Date) -> Bool {
        guard let last = lastRequestAt, !history.isEmpty else { return false }
        return now.timeIntervalSince(last) >= ConversationPolicy.cacheTTL
    }

    /// A one-line title: the first prompt, shortened.
    public var suggestedTitle: String {
        let first = turns.first { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?.text
            ?? (turns.first.map { _ in "Screenshots" } ?? "Empty")
        let line = first.split(whereSeparator: \.isNewline).first.map(String.init) ?? first
        return line.count > 60 ? String(line.prefix(57)).trimmingCharacters(in: .whitespaces) + "…" : line
    }
}

/// Cleared conversations, newest last.
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

    /// Takes one back out (to resume it).
    public mutating func remove(_ id: UUID) -> Conversation? {
        guard let i = conversations.firstIndex(where: { $0.id == id }) else { return nil }
        return conversations.remove(at: i)
    }

    /// Newest first, optionally only those whose prompts or replies contain `query`.
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

public enum ConversationPolicy {
    /// The box's one tool. Forced, so every answer is a tool call claude-server can park a session on.
    public static let toolName = "apply"

    /// How long the conversation stays cached. Requests carry the 1-hour prompt-cache marker, but
    /// claude-server keeps a live session waiting for a tool result for 15 minutes
    /// (`CLAUDE_SERVER_SESSION_TOOL_TTL`, default 900 s). After that the history is replayed as a
    /// transcript, which re-reads every token, so 15 minutes is when the Clear button turns red.
    public static let cacheTTL: TimeInterval = 15 * 60

    /// The block marker that asks for the 1-hour prompt cache. It's in the first user turn, so it
    /// is in every request of the conversation and the session signature never changes.
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

    /// The content of the next user turn, and the full context it was built against.
    ///
    /// First turn: [full context (cache marker), images…, the student's words].
    /// Later turns: [tool result for the last answer (what was applied, plus the images), the
    /// context delta, images…, the student's words]. Images are in both places because the live
    /// session only reads the tool result's images and a replayed one only reads the top-level ones.
    public static func userContent(for c: Conversation, text: String, images: [AIImage],
                                   fullContext: String) -> JSONValue {
        let student = textBlock(studentText(text, images: images))
        let pics = images.map(image)
        guard let last = c.history.last else {
            return .array([textBlock("Context (the app right now):\n\(fullContext)", cache: true)] + pics + [student])
        }
        var blocks: [JSONValue] = []
        if let toolId = last.toolUseId {
            blocks.append(.object(["type": .string("tool_result"), "tool_use_id": .string(toolId),
                                   "content": .array([textBlock(last.applied.toolResultText)] + pics)]))
        } else {
            blocks.append(textBlock("[Your last answer: \(last.applied.toolResultText)]"))
        }
        blocks.append(textBlock(delta(from: last.context, to: fullContext)))
        return .array(blocks + pics + [student])
    }

    /// What changed in the app's context since the last turn, line by line. When that's longer
    /// than the context itself, the whole context is sent again instead.
    public static func delta(from old: String, to new: String) -> String {
        let a = old.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let b = new.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var remaining = Dictionary(a.map { ($0, 1) }, uniquingKeysWith: +)
        var added: [String] = []
        for line in b {
            if let n = remaining[line], n > 0 { remaining[line] = n - 1 } else { added.append(line) }
        }
        var stillThere = Dictionary(b.map { ($0, 1) }, uniquingKeysWith: +)
        var removed: [String] = []
        for line in a {
            if let n = stillThere[line], n > 0 { stillThere[line] = n - 1 } else { removed.append(line) }
        }
        let full = "Context (the app right now, replaces the earlier context):\n\(new)"
        if added.isEmpty && removed.isEmpty { return "Context: unchanged since your last message." }
        let body = (["Since your last message, the context changed:"]
            + removed.filter { !$0.isEmpty }.map { "- " + $0 }
            + added.filter { !$0.isEmpty }.map { "+ " + $0 }).joined(separator: "\n")
        return body.count >= full.count ? full : body
    }
}
