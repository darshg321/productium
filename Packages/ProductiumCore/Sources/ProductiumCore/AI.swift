import Foundation

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

    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(self))
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(stringLiteral v: String) { self = .string(v) }
    public init(integerLiteral v: Int) { self = .number(Double(v)) }
    public init(floatLiteral v: Double) { self = .number(v) }
    public init(booleanLiteral v: Bool) { self = .bool(v) }
    public init(arrayLiteral v: JSONValue...) { self = .array(v) }
    public init(dictionaryLiteral v: (String, JSONValue)...) { self = .object(Dictionary(v, uniquingKeysWith: { _, b in b })) }

    public static func encoding<T: Encodable>(_ v: T) -> JSONValue? {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        return (try? e.encode(v)).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
    }

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var numberValue: Double? { if case .number(let n) = self { return n }; return nil }
}

public enum AIModel {
    public static let sonnet = "sonnet"
    public static let opus = "opus"
}

public struct AIImage: Codable, Hashable, Sendable {
    public var mediaType: String
    public var base64: String
    public init(mediaType: String, base64: String) { self.mediaType = mediaType; self.base64 = base64 }
}

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
    // Sent as the x-cache-ttl header, not in the body.
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

    public init(model: String = AIModel.sonnet, system: String, messages: [AIMessage], tool: AITool,
                maxTokens: Int, effort: String? = nil) {
        self.init(model: model, system: system, messages: messages, schema: nil, maxTokens: maxTokens, effort: effort)
        self.tools = [tool]
        self.tool_choice = ToolChoice(name: tool.name)
    }

    public var answerSchema: JSONValue? {
        output_config?.format?.schema ?? tool_choice.flatMap { c in tools?.first { $0.name == c.name }?.input_schema }
    }
}

public struct ParsedItem: Codable, Hashable, Sendable {
    public var title: String
    public var kind: String
    public var subject: String?
    public var due: String
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
    public var weekdays: [Int]
    public var start: String
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

public struct WeeklyReview: Codable, Hashable, Sendable {
    public var headline: String
    public var wins: [String]
    public var suggestions: [String]

    public init(headline: String, wins: [String], suggestions: [String]) {
        self.headline = headline
        self.wins = wins
        self.suggestions = suggestions
    }
}

public struct CardBatch: Codable, Hashable, Sendable {
    public struct Card: Codable, Hashable, Sendable { public var front: String; public var back: String }
    public var cards: [Card]
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
    public var usable: [Piece] { pieces.filter { !$0.title.isEmpty && !$0.body.isEmpty } }
}

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

    public static let cards: JSONValue = obj(["cards": arr(obj(["front": str, "back": str], required: ["front", "back"]))],
                                             required: ["cards"])

    public static let reads: JSONValue = obj(["pieces": arr(obj(["title": str, "body": str, "subject": str, "question": str],
                                                                required: ["title", "body", "question"]))],
                                             required: ["pieces"])
}

// System prompts must stay byte-identical across requests (server cache and session key); variable data goes in the user turn.
public enum Prompts {
    static let persona = """
    You are the assistant in Productium, a calm planner for high-school students. Warm, brief, concrete, never \
    shaming. Sleep is never traded for test prep.
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

    public static func flashcards() -> String {
        """
        Make flashcards for a high-school student. Front: a recall question (not yes/no or multiple choice). \
        Back: exact answer, 25 words max. Mix definitions, "why" questions and an application problem.
        """
    }

    public static func flashcardsRequest(subject: String?, topics: [String], count: Int) -> String {
        "\(count) cards on: \(topics.joined(separator: "; "))" + (subject.map { " (\($0))" } ?? "")
    }

    public static func reads() -> String {
        """
        Write short reads (120-180 words) a curious high-schooler finishes in two minutes instead of scrolling. \
        Accurate, vivid, one surprising fact each, no fluff. question: one "why/how" question to think about.
        """
    }

    public static func readsRequest(interests: [String], subjects: [String], count: Int) -> String {
        "\(count) reads. Half on their subjects (\(subjects.isEmpty ? "any" : subjects.joined(separator: ", "))), half on " +
            "their interests (\(interests.isEmpty ? "science, history, how things work" : interests.joined(separator: ", ")))."
    }

    public static func context(now: Date, items: [WorkItem], plan: Plan, summary: PeriodSummary?, moods: [MoodEntry],
                               taper: ScreenTaper, learned: LearnedModel, calendar cal: Calendar,
                               aboutMe: AboutMe = .empty, beliefs: String? = nil, changes: String? = nil) -> String {
        let df = DateFormatter.local("EEE MMM d HH:mm", cal)
        var lines = ["Now: \(df.string(from: now))"]
        if !aboutMe.isEmpty { lines.append(aboutMe.promptText) }
        if let beliefs { lines.append(beliefs) }
        if let changes { lines.append(changes) }
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
}
