import Foundation

// MARK: - Wire format shared with claude-server (POST /v1/complete)

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

/// Which model to use. Haiku is fast and cheap: parsing, short generation, nudges.
/// Sonnet is for reasoning: decomposing goals, weekly reviews, advice.
public enum AITier: String, Codable, Sendable {
    case fast = "haiku"
    case reason = "sonnet"
}

public struct AIImage: Codable, Hashable, Sendable {
    public var mediaType: String      // image/jpeg, image/png
    public var base64: String
    public init(mediaType: String, base64: String) { self.mediaType = mediaType; self.base64 = base64 }
}

/// A chat message. With images it's sent as content blocks (image… then text),
/// the shape claude-server and the Anthropic API take.
public struct AIMessage: Codable, Hashable, Sendable {
    public var role: String
    public var content: String
    public var images: [AIImage]

    public init(role: String, content: String, images: [AIImage] = []) {
        self.role = role
        self.content = content
        self.images = images
    }

    enum CodingKeys: String, CodingKey { case role, content }
    struct Block: Codable {
        struct Source: Codable { var type = "base64"; var media_type: String; var data: String }
        var type: String
        var text: String?
        var source: Source?
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decode(String.self, forKey: .role)
        if let s = try? c.decode(String.self, forKey: .content) {
            content = s
            images = []
        } else {
            let blocks = try c.decode([Block].self, forKey: .content)
            content = blocks.compactMap(\.text).joined(separator: "\n")
            images = blocks.compactMap { $0.source.map { AIImage(mediaType: $0.media_type, base64: $0.data) } }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(role, forKey: .role)
        if images.isEmpty {
            try c.encode(content, forKey: .content)
        } else {
            let blocks = images.map { Block(type: "image", text: nil, source: .init(media_type: $0.mediaType, data: $0.base64)) }
                + [Block(type: "text", text: content.isEmpty ? "(see image)" : content, source: nil)]
            try c.encode(blocks, forKey: .content)
        }
    }
}

public struct AIRequest: Codable, Sendable {
    public var model: String
    public var system: String
    public var messages: [AIMessage]
    public var json_schema: JSONValue?
    public var effort: String?
    public var cache_ttl_s: Int?

    public init(tier: AITier, system: String, messages: [AIMessage], schema: JSONValue? = nil,
                effort: String? = nil, cacheTTL: Int? = nil) {
        self.model = tier.rawValue
        self.system = system
        self.messages = messages
        self.json_schema = schema
        self.effort = effort
        self.cache_ttl_s = cacheTTL
    }
}

public struct AIResponse: Codable, Sendable {
    public var id: String?
    public var model: String?
    public var text: String
    public var structured: JSONValue?
    public var duration_ms: Int?
    public var cached: Bool?
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
}

public struct ReadBatch: Codable, Hashable, Sendable {
    public struct Piece: Codable, Hashable, Sendable {
        public var title: String
        public var body: String
        public var subject: String?
        public var question: String?
    }
    public var pieces: [Piece]
}

// MARK: - Schemas (subset of JSON Schema, passed to `claude --json-schema`)

public enum Schemas {
    static func obj(_ props: [String: JSONValue], required: [String]) -> JSONValue {
        .object(["type": .string("object"), "properties": .object(props),
                 "required": .array(required.map { .string($0) }), "additionalProperties": .bool(false)])
    }
    static let str: JSONValue = .object(["type": .string("string")])
    static let int: JSONValue = .object(["type": .string("integer")])
    static func arr(_ of: JSONValue) -> JSONValue { .object(["type": .string("array"), "items": of]) }
    static func strEnum(_ v: [String]) -> JSONValue { .object(["type": .string("string"), "enum": .array(v.map { .string($0) })]) }

    public static let quickAdd: JSONValue = obj([
        "items": arr(obj(["title": str, "kind": strEnum(TaskKind.allCases.map(\.rawValue)), "subject": str, "due": str,
                          "estimateMinutes": int, "importance": int, "difficulty": int, "topics": arr(str)],
                         required: ["title", "kind", "due"])),
        "commitments": arr(obj(["title": str, "kind": strEnum(CommitmentKind.allCases.map(\.rawValue)),
                                "weekdays": arr(int), "start": str, "end": str],
                               required: ["title", "kind", "weekdays", "start", "end"])),
        "markers": arr(obj(["phrase": str, "activity": str, "category": strEnum(TimeCategory.allCases.map(\.rawValue)),
                            "phase": strEnum(["start", "end", "point"]), "minutesAgo": int],
                           required: ["phrase", "activity", "category", "phase"])),
        "completedTitles": arr(str),
        "mood": int,
        "reply": str,
    ], required: ["items", "commitments", "markers", "completedTitles", "reply"])

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
    static let persona = """
    You are the planning assistant inside Productium, a calm planning app for high-school students. \
    Be warm, brief and concrete. Talk like a supportive older student, not a parent or a productivity guru. \
    Never shame. Never encourage giving up sleep for studying for tests. Sleep is when learning is stored. \
    Don't give medical or mental-health diagnoses. If someone seems in distress, gently suggest talking to a \
    trusted adult or a helpline. Keep any free-text reply under 40 words unless asked for more.
    """

    public static func quickAdd(now: Date, timeZone: TimeZone, commitments: [Commitment], openItems: [WorkItem]) -> String {
        let f = ISO8601DateFormatter(); f.timeZone = timeZone
        f.formatOptions = [.withInternetDateTime]
        let weekday = DateFormatter(); weekday.timeZone = timeZone; weekday.dateFormat = "EEEE"
        let comm = commitments.prefix(15).map { "\($0.title) (\($0.kind.rawValue))" }.joined(separator: ", ")
        let items = openItems.prefix(20).map { "\($0.title)" }.joined(separator: "; ")
        return persona + """

        Turn the student's short message into structured data. Now: \(f.string(from: now)) (\(weekday.string(from: now))), \
        time zone \(timeZone.identifier).
        - items: new assignments/tests/deadlines. Resolve relative dates ("friday", "next week") to an ISO date-time \
          in the local zone. If no time is given use 08:00 for tests/quizzes (in class) and 23:59 for anything submitted. \
          Estimate minutes realistically for a high schooler if not given. importance 1-5 (finals, applications = 5). \
          difficulty 1-3. topics = what to study, if mentioned.
        - commitments: recurring weekly activities ("soccer mon wed 4-6"). weekdays use 1=Sunday..7=Saturday, 24h HH:mm.
        - markers: check-ins about what they're doing right now ("left home", "at practice", "finished math"). \
          activity is a short lowercase key; use to_school / from_school / school / study for those.
        - completedTitles: titles of existing open items they say are done. Open items: \(items.isEmpty ? "none" : items)
        - mood: 1-5 only if they express how they feel.
        - reply: one short friendly confirmation of what you understood.
        Known commitments: \(comm.isEmpty ? "none" : comm).
        """
    }

    public static func decomposition(item: WorkItem, now: Date, timeZone: TimeZone) -> String {
        let f = ISO8601DateFormatter(); f.timeZone = timeZone
        return persona + """

        Break this long-term task into 3-8 concrete steps with their own due dates, between \(f.string(from: now)) \
        and the final deadline \(f.string(from: item.due)). Rules, from the research on long projects:
        - The first step must be tiny and start within 2 days (lowers the barrier to starting).
        - Spread steps out evenly. Regular brief sessions beat binges.
        - Finish the main draft at least 20% of the time before the deadline, leaving room for feedback and \
          revision (people underestimate how long things take).
        - For essays/applications include: brainstorm, outline, rough draft, get feedback from someone, revise, final proofread/submit.
        - estimateMinutes per step realistic for a high schooler. kind: use "essay"/"application"/"project"/"reading"/"chore".
        Give a one-sentence rationale.
        """
    }

    public static func weeklyReview() -> String {
        persona + """

        Write the student's weekly review from the data summary. The planner already handles scheduling. You \
        suggest at most 3 small, specific adjustments that research supports (sleep regularity, spacing, \
        retrieval practice, shorter blocks if they abandon long ones, fewer planned minutes if follow-through is low, \
        phone out of the room). Start with what went well (self-efficacy). If follow-through was low, be self-compassionate: \
        self-forgiveness reduces future procrastination. "changes" are optional numeric tweaks to their settings and must be \
        modest (±10 minutes). Never reduce sleep. Headline under 10 words.
        """
    }

    public static func coach() -> String {
        persona + """

        Answer the student's question about their schedule, studying, or habits. Use the context below. Prefer one \
        concrete next action. If they ask whether to stay up late to study for a test, explain that sleep helps the \
        test more. For deadline-driven writing, a short extension of the evening may be okay once, not repeatedly.
        """
    }

    public static func flashcards(subject: String?, topics: [String], count: Int) -> String {
        persona + """

        Make \(count) flashcards for a high-school student on: \(topics.joined(separator: "; ")) \
        \(subject.map { "(\($0))" } ?? ""). Front: a question that needs recall, not recognition (no yes/no, no multiple choice). \
        Back: a short, exact answer (≤ 25 words). Mix definitions, "why" questions and one or two application problems.
        """
    }

    public static func reads(interests: [String], subjects: [String], count: Int) -> String {
        persona + """

        Write \(count) short reads (120-220 words each) a curious high-schooler can finish in about two minutes \
        instead of scrolling. Half connect to their subjects (\(subjects.joined(separator: ", "))), half to their interests \
        (\(interests.isEmpty ? "science, history, how things work" : interests.joined(separator: ", "))). Accurate, vivid, one \
        surprising fact each, no fluff. End each with one "why/how" question to think about (question field).
        """
    }

    /// Compact context, so prompts stay cheap and on-topic.
    public static func context(now: Date, items: [WorkItem], plan: Plan, summary: PeriodSummary?, moods: [MoodEntry],
                               taper: ScreenTaper, learned: LearnedModel, calendar cal: Calendar) -> String {
        let df = DateFormatter(); df.calendar = cal; df.timeZone = cal.timeZone; df.dateFormat = "EEE MMM d HH:mm"
        var lines = ["Now: \(df.string(from: now))"]
        let open = items.filter { !$0.isDone }.sorted { $0.due < $1.due }.prefix(15)
        lines.append("Open work:")
        for i in open {
            lines.append("- \(i.title) [\(i.kind.rawValue), importance \(i.importance)] due \(df.string(from: i.due)), \(i.completedMinutes)/\(i.estimateMinutes) min done")
        }
        let todays = plan.blocks.filter { cal.isDate($0.start, inSameDayAs: now) && $0.kind != .sleep }
        lines.append("Today's plan: " + todays.map { "\(df.string(from: $0.start).suffix(5)) \($0.title)" }.joined(separator: ", "))
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
