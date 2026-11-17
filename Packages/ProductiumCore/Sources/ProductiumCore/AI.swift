import Foundation

// MARK: - Wire format shared with claude-server (POST /v1/messages)

/// Minimal JSON value so schemas and structured output pass through untyped.
public indirect enum JSONValue: Codable, Hashable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }

    /// Re-decode into a typed value.
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(self))
    }
}

/// The one model every request uses. Only output tokens are counted, and every call this app makes
/// is structured extraction or short writing. Measured through claude-server on the app's own
/// prompts (16 Inbox messages, a project breakdown, flashcards, reads, the weekly note), Sonnet 5.5
/// at the server's default low effort wrote about 8.1k output tokens where Haiku 5.5 wrote 14.4k:
/// Haiku's thinking can't be turned off and it thinks more than Sonnet does. Both got every case
/// right, so a second model would only add cost. Haiku 4.5 isn't used.
public enum AIModel {
    public static let sonnet = "sonnet"
}

public struct AIImage: Codable, Hashable, Sendable {
    public var mediaType: String      // image/jpeg, image/png
    public var base64: String
    public init(mediaType: String, base64: String) { self.mediaType = mediaType; self.base64 = base64 }
}

/// A chat message. With images it's sent as content blocks (image… then text), the shape
/// claude-server and the Anthropic API take. With `raw` set, that exact `content` is sent instead:
/// a conversation's history goes back byte-for-byte as it went the first time.
public struct AIMessage: Codable, Hashable, Sendable {
    public var role: String
    public var content: String
    public var images: [AIImage]
    public var raw: JSONValue?

    public init(role: String, content: String, images: [AIImage] = []) {
        self.role = role
        self.content = content
        self.images = images
        self.raw = nil
    }

    /// A message whose `content` is sent exactly as given.
    public init(role: String, raw: JSONValue) {
        self.role = role
        self.raw = raw
        self.content = AIMessage.text(of: raw)
        self.images = AIMessage.images(in: raw)
    }

    enum CodingKeys: String, CodingKey { case role, content }
    struct Block: Codable {
        struct Source: Codable { var type = "base64"; var media_type: String; var data: String }
        var type: String
        var text: String?
        var source: Source?
    }

    /// The readable text of a content value (text blocks, tool inputs and tool results).
    static func text(of v: JSONValue) -> String {
        switch v {
        case .string(let s): return s
        case .array(let blocks): return blocks.map(text(of:)).filter { !$0.isEmpty }.joined(separator: "\n")
        case .object(let o):
            switch o["type"] {
            case .string("text")?: if case .string(let t)? = o["text"] { return t }
            case .string("tool_use")?:
                let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                let input = o["input"].flatMap { try? enc.encode($0) }.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                return "[tool call] " + input
            case .string("tool_result")?: return "[tool result] " + (o["content"].map(text(of:)) ?? "")
            default: break
            }
            return ""
        default: return ""
        }
    }

    static func images(in v: JSONValue) -> [AIImage] {
        guard case .array(let blocks) = v else { return [] }
        return blocks.compactMap { b in
            guard case .object(let o) = b, o["type"] == .string("image"), case .object(let src)? = o["source"],
                  case .string(let mt)? = src["media_type"], case .string(let data)? = src["data"] else { return nil }
            return AIImage(mediaType: mt, base64: data)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decode(String.self, forKey: .role)
        if let s = try? c.decode(String.self, forKey: .content) {
            content = s
            images = []
            raw = nil
        } else {
            let v = try c.decode(JSONValue.self, forKey: .content)
            raw = v
            content = AIMessage.text(of: v)
            images = AIMessage.images(in: v)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(role, forKey: .role)
        if let raw {
            try c.encode(raw, forKey: .content)
        } else if images.isEmpty {
            try c.encode(content, forKey: .content)
        } else {
            let blocks = images.map { Block(type: "image", text: nil, source: .init(media_type: $0.mediaType, data: $0.base64)) }
                + [Block(type: "text", text: content.isEmpty ? "(see image)" : content, source: nil)]
            try c.encode(blocks, forKey: .content)
        }
    }
}

/// A client tool. The box uses one, forced, so claude-server can keep the session alive.
public struct AITool: Codable, Hashable, Sendable {
    public var name: String
    public var description: String
    public var input_schema: JSONValue
    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.input_schema = inputSchema
    }
}

/// A request to claude-server's Anthropic-compatible `POST /v1/messages`. Structured output goes
/// through `output_config.format`, which the server runs as one forced tool call (one API turn), or
/// through a forced client tool (`tools` + `tool_choice`), which also keeps a live session.
public struct AIRequest: Encodable, Sendable {
    public struct Format: Encodable, Sendable { var type = "json_schema"; var schema: JSONValue }
    public struct OutputConfig: Encodable, Sendable {
        var format: Format?
        var effort: String?
    }
    public struct ToolChoice: Encodable, Sendable { var type = "tool"; var name: String }

    public var model: String
    public var max_tokens: Int
    public var system: String
    public var messages: [AIMessage]
    public var output_config: OutputConfig?
    public var tools: [AITool]?
    public var tool_choice: ToolChoice?
    /// Not sent in the body: identical requests within this many seconds are answered from the server's
    /// memory without using any tokens (sent as the `x-cache-ttl` header).
    public var cacheTTL: Int?

    enum CodingKeys: String, CodingKey { case model, max_tokens, system, messages, output_config, tools, tool_choice }

    public init(model: String = AIModel.sonnet, system: String, messages: [AIMessage], schema: JSONValue? = nil,
                maxTokens: Int = 600, cacheTTL: Int? = nil, effort: String? = nil) {
        self.model = model
        self.max_tokens = maxTokens
        self.system = system
        self.messages = messages
        self.output_config = (schema != nil || effort != nil)
            ? OutputConfig(format: schema.map { Format(schema: $0) }, effort: effort) : nil
        self.cacheTTL = cacheTTL
    }

    /// A request answered by calling `tool` (forced).
    public init(model: String = AIModel.sonnet, system: String, messages: [AIMessage], tool: AITool,
                maxTokens: Int, effort: String? = nil) {
        self.init(model: model, system: system, messages: messages, schema: nil, maxTokens: maxTokens, effort: effort)
        self.tools = [tool]
        self.tool_choice = ToolChoice(name: tool.name)
    }

    /// The schema the answer has to fit: the output format's, or the forced tool's.
    public var answerSchema: JSONValue? {
        output_config?.format?.schema ?? tool_choice.flatMap { c in tools?.first { $0.name == c.name }?.input_schema }
    }
}

// MARK: - Structured outputs

public struct ParsedItem: Codable, Hashable, Sendable {
    public var title: String
    public var kind: String
    public var subject: String?
    public var due: String           // ISO 8601 date or date-time, local
    public var estimateMinutes: Int?
    public var importance: Int?
    public var difficulty: Int?
    public var topics: [String]?

    public init(title: String, kind: String, subject: String? = nil, due: String, estimateMinutes: Int? = nil,
                importance: Int? = nil, difficulty: Int? = nil, topics: [String]? = nil) {
        self.title = title
        self.kind = kind
        self.subject = subject
        self.due = due
        self.estimateMinutes = estimateMinutes
        self.importance = importance
        self.difficulty = difficulty
        self.topics = topics
    }
}

public struct ParsedCommitment: Codable, Hashable, Sendable {
    public var title: String
    public var kind: String
    public var weekdays: [Int]       // 1 = Sunday … 7 = Saturday
    public var start: String         // "HH:mm"
    public var end: String
}

public struct ParsedMarker: Codable, Hashable, Sendable {
    public var phrase: String
    public var activity: String
    public var category: String
    public var phase: String
    public var minutesAgo: Int?
}

public struct QuickAddResult: Codable, Hashable, Sendable {
    public var items: [ParsedItem]
    public var commitments: [ParsedCommitment]
    public var markers: [ParsedMarker]
    public var completedTitles: [String]
    public var mood: Int?
    public var reply: String
}

public struct DecomposedStep: Codable, Hashable, Sendable {
    public var title: String
    public var estimateMinutes: Int
    public var due: String
    public var kind: String
}

public struct Decomposition: Codable, Hashable, Sendable {
    public var steps: [DecomposedStep]
    public var rationale: String
}

public struct PreferenceChanges: Codable, Hashable, Sendable {
    public var focusBlockMinutes: Int?
    public var maxStudyMinutesSchoolDay: Int?
    public var maxStudyMinutesFreeDay: Int?
    public var minFreeMinutesSchoolDay: Int?
    public var windDownMinutes: Int?

    public init(focusBlockMinutes: Int? = nil, maxStudyMinutesSchoolDay: Int? = nil, maxStudyMinutesFreeDay: Int? = nil,
                minFreeMinutesSchoolDay: Int? = nil, windDownMinutes: Int? = nil) {
        self.focusBlockMinutes = focusBlockMinutes
        self.maxStudyMinutesSchoolDay = maxStudyMinutesSchoolDay
        self.maxStudyMinutesFreeDay = maxStudyMinutesFreeDay
        self.minFreeMinutesSchoolDay = minFreeMinutesSchoolDay
        self.windDownMinutes = windDownMinutes
    }
}

public struct WeeklyReview: Codable, Hashable, Sendable {
    public var headline: String
    public var wins: [String]
    public var suggestions: [String]
    public var changes: PreferenceChanges?
}

public struct CardBatch: Codable, Hashable, Sendable {
    public struct Card: Codable, Hashable, Sendable { public var front: String; public var back: String }
    public var cards: [Card]
    /// Cards with both sides written.
    public var usable: [Card] { cards.filter { !$0.front.isEmpty && !$0.back.isEmpty } }
}

public struct ReadBatch: Codable, Hashable, Sendable {
    public struct Piece: Codable, Hashable, Sendable {
        public var title: String
        public var body: String
        public var subject: String?
        public var question: String?
    }
    public var pieces: [Piece]
    /// Reads with a title and a body.
    public var usable: [Piece] { pieces.filter { !$0.title.isEmpty && !$0.body.isEmpty } }
}

// MARK: - Schemas (subset of JSON Schema, sent as `output_config.format`)

public enum Schemas {
    static func obj(_ props: [String: JSONValue], required: [String]) -> JSONValue {
        .object(["type": .string("object"), "properties": .object(props),
                 "required": .array(required.map { .string($0) }), "additionalProperties": .bool(false)])
    }
    static let str: JSONValue = .object(["type": .string("string")])
    static let int: JSONValue = .object(["type": .string("integer")])
    static func arr(_ of: JSONValue) -> JSONValue { .object(["type": .string("array"), "items": of]) }
    static func strEnum(_ v: [String]) -> JSONValue { .object(["type": .string("string"), "enum": .array(v.map { .string($0) })]) }

    public static let decomposition: JSONValue = obj([
        "steps": arr(obj(["title": str, "estimateMinutes": int, "due": str, "kind": strEnum(TaskKind.allCases.map(\.rawValue))],
                         required: ["title", "estimateMinutes", "due", "kind"])),
        "rationale": str,
    ], required: ["steps", "rationale"])

    public static let weeklyReview: JSONValue = obj([
        "headline": str, "wins": arr(str), "suggestions": arr(str),
        "changes": obj(["focusBlockMinutes": int, "maxStudyMinutesSchoolDay": int, "maxStudyMinutesFreeDay": int,
                        "minFreeMinutesSchoolDay": int, "windDownMinutes": int], required: []),
    ], required: ["headline", "wins", "suggestions"])

    public static let cards: JSONValue = obj(["cards": arr(obj(["front": str, "back": str], required: ["front", "back"]))],
                                             required: ["cards"])

    public static let reads: JSONValue = obj(["pieces": arr(obj(["title": str, "body": str, "subject": str, "question": str],
                                                                required: ["title", "body", "question"]))],
                                             required: ["pieces"])
}

// MARK: - Prompts

public enum Prompts {
    // System prompts are constants: the server's prompt cache and live sessions key on a
    // byte-identical system prompt, so anything that varies (dates, topics, names) goes in
    // the user message. They're also short: a shorter prompt is less to read and keeps the
    // answer focused.

    static let persona = """
    You are the assistant in Productium, a calm planner for high-school students. Warm, brief, concrete, never \
    shaming. Sleep is never traded for test prep. No diagnoses; if someone seems in distress, suggest a trusted \
    adult or a helpline.
    """

    static func iso(_ d: Date, _ tz: TimeZone) -> String {
        let f = ISO8601DateFormatter(); f.timeZone = tz; f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    public static func decomposition() -> String {
        persona + """

        Split a long task into 3-8 steps, each with its own due date between now and the deadline. First step tiny, \
        due within 2 days. Spread steps evenly. Main draft done with 20%+ of the time left for feedback and revision. \
        Essays/applications: brainstorm, outline, draft, feedback, revise, proofread/submit. Realistic minutes. \
        kind: essay|application|project|reading|chore. due: local ISO date-time. rationale: one sentence.
        """
    }

    public static func decompositionRequest(item: WorkItem, now: Date, timeZone: TimeZone, aboutMe: AboutMe = .empty) -> String {
        "Now \(iso(now, timeZone)). Task: \(item.title) (\(item.kind.rawValue)), due \(iso(item.due, timeZone)), " +
            "about \(item.estimateMinutes) min total." + (item.notes.map { " Notes: \($0.prefix(300))" } ?? "")
            + (aboutMe.isEmpty ? "" : "\n" + aboutMe.promptText)
    }

    public static func weeklyReview() -> String {
        persona + """

        Write the student's weekly review from the data. Headline under 10 words. wins: 1-2 short sentences on what \
        went well. suggestions: at most 2 small, specific, research-backed tweaks (sleep regularity, spacing, \
        self-testing, shorter blocks, planning less if follow-through is low, phone out of the room). Be \
        self-compassionate about misses. changes: optional ±10 min tweaks to their settings; never reduce sleep.
        """
    }

    public static func flashcards() -> String {
        persona + """

        Make flashcards for a high-school student. Front: a recall question (not yes/no or multiple choice). \
        Back: exact answer, 25 words max. Mix definitions, "why" questions and an application problem.
        """
    }

    public static func flashcardsRequest(subject: String?, topics: [String], count: Int) -> String {
        "\(count) cards on: \(topics.joined(separator: "; "))" + (subject.map { " (\($0))" } ?? "")
    }

    public static func reads() -> String {
        persona + """

        Write short reads (120-180 words) a curious high-schooler finishes in two minutes instead of scrolling. \
        Accurate, vivid, one surprising fact each, no fluff. question: one "why/how" question to think about.
        """
    }

    public static func readsRequest(interests: [String], subjects: [String], count: Int) -> String {
        "\(count) reads. Half on their subjects (\(subjects.isEmpty ? "any" : subjects.joined(separator: ", "))), half on " +
            "their interests (\(interests.isEmpty ? "science, history, how things work" : interests.joined(separator: ", ")))."
    }

    /// Compact context, so prompts stay cheap and on-topic.
    public static func context(now: Date, items: [WorkItem], plan: Plan, summary: PeriodSummary?, moods: [MoodEntry],
                               taper: ScreenTaper, learned: LearnedModel, calendar cal: Calendar,
                               aboutMe: AboutMe = .empty) -> String {
        let df = DateFormatter(); df.calendar = cal; df.timeZone = cal.timeZone; df.dateFormat = "EEE MMM d HH:mm"
        var lines = ["Now: \(df.string(from: now))"]
        if !aboutMe.isEmpty { lines.append(aboutMe.promptText) }
        // The weekly note is about how the week went, so only the next few deadlines matter.
        let open = items.filter { !$0.isDone && $0.parentId == nil }.sorted { $0.due < $1.due }.prefix(8)
        if !open.isEmpty {
            lines.append("Coming up: " + open.map { "\($0.title) (\(df.string(from: $0.due)), \($0.completedMinutes)/\($0.estimateMinutes)m)" }
                .joined(separator: "; "))
        }
        if !plan.warnings.isEmpty { lines.append("Planner warnings: " + plan.warnings.map(\.message).joined(separator: " | ")) }
        if let s = summary {
            let mins = s.averageMinutes.filter { $0.value > 0 }.map { "\($0.key.rawValue) \($0.value)m" }.sorted().joined(separator: ", ")
            lines.append("Last \(s.days) days, average per day: \(mins)")
            if let f = s.followThrough { lines.append("Follow-through on planned study: \(Int(f * 100))%") }
            if let sl = s.averageSleep { lines.append("Average sleep: \(minutesLabel(sl))") }
            if let m = s.averageMood { lines.append(String(format: "Average mood: %.1f/5", m)) }
            if !s.bestHours.isEmpty { lines.append("Most reliable hours: \(s.bestHours.map { "\($0):00" }.joined(separator: ", "))") }
            if !s.patterns.isEmpty { lines.append("Patterns: " + s.patterns.joined(separator: " ")) }
        }
        if let t = taper.targetMinutes { lines.append("Screen-time daily limit: \(minutesLabel(t)) (baseline \(minutesLabel(taper.baselineMinutes ?? t)))") }
        lines.append(String(format: "Adherence (EWMA): %.0f%%, focus block: %d min", learned.adherence * 100, Int(learned.focusMinutes)))
        if let m = moods.last { lines.append("Latest mood: \(m.mood)/5\(m.note.map { " – \($0)" } ?? "")") }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Turning AI output into model objects, with guard rails

public enum AIMapper {
    public static func parseDate(_ s: String, timeZone: TimeZone) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = timeZone
            f.dateFormat = fmt
            if let d = f.date(from: s) {
                return fmt == "yyyy-MM-dd" ? d.addingTimeInterval(23 * 3600 + 59 * 60) : d
            }
        }
        return nil
    }

    public static func item(_ p: ParsedItem, timeZone: TimeZone, source: ItemSource = .ai, parentId: UUID? = nil) -> WorkItem? {
        guard let due = parseDate(p.due, timeZone: timeZone), !p.title.isEmpty else { return nil }
        let kind = TaskKind(rawValue: p.kind) ?? .other
        return WorkItem(title: String(p.title.prefix(120)), kind: kind, subject: p.subject, due: due,
                        estimateMinutes: p.estimateMinutes.map { max(5, min(3000, $0)) },
                        importance: p.importance ?? 3, difficulty: p.difficulty ?? 2, parentId: parentId,
                        topics: p.topics ?? [], source: source)
    }

    public static func commitment(_ p: ParsedCommitment) -> Commitment? {
        func tod(_ s: String) -> TimeOfDay? {
            let parts = s.split(separator: ":").compactMap { Int($0) }
            guard parts.count >= 1, (0...23).contains(parts[0]) else { return nil }
            return TimeOfDay(parts[0], parts.count > 1 ? parts[1] : 0)
        }
        guard let s = tod(p.start), let e = tod(p.end), e > s else { return nil }
        let days = Set(p.weekdays.filter { (1...7).contains($0) })
        guard !days.isEmpty else { return nil }
        return Commitment(title: p.title, kind: CommitmentKind(rawValue: p.kind) ?? .extracurricular, weekdays: days, start: s, end: e)
    }

    public static func marker(_ p: ParsedMarker, now: Date) -> TimelineEvent {
        TimelineEvent(at: now.addingTimeInterval(-Double(max(0, min(600, p.minutesAgo ?? 0))) * 60), phrase: p.phrase,
                      activity: p.activity.lowercased(), category: TimeCategory(rawValue: p.category) ?? .free,
                      phase: MarkerPhase(rawValue: p.phase) ?? .point, source: .voice)
    }

    /// AI-suggested setting changes are clamped to safe, modest ranges, and they can
    /// never touch sleep need, the sleep floor, or the sleep trade-off switch.
    public static func apply(_ c: PreferenceChanges, to p: Preferences) -> Preferences {
        var out = p
        func nudge(_ cur: Int, _ new: Int?, _ lo: Int, _ hi: Int) -> Int {
            guard let new else { return cur }
            return max(lo, min(hi, max(cur - 10, min(cur + 10, new))))
        }
        out.focusBlockMinutes = nudge(p.focusBlockMinutes, c.focusBlockMinutes, 20, 60)
        out.maxStudyMinutesSchoolDay = nudge(p.maxStudyMinutesSchoolDay, c.maxStudyMinutesSchoolDay, 45, 300)
        out.maxStudyMinutesFreeDay = nudge(p.maxStudyMinutesFreeDay, c.maxStudyMinutesFreeDay, 45, 420)
        out.minFreeMinutesSchoolDay = nudge(p.minFreeMinutesSchoolDay, c.minFreeMinutesSchoolDay, 30, 240)
        out.windDownMinutes = nudge(p.windDownMinutes, c.windDownMinutes, 15, 60)
        return out
    }
}
