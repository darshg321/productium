import Foundation

public struct Flashcard: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var itemId: UUID?
    public var subject: String?
    public var front: String
    public var back: String
    public var box: Int
    public var due: Date
    public var createdAt: Date
    public var reviews: Int
    public var lapses: Int

    public init(id: UUID = UUID(), itemId: UUID? = nil, subject: String? = nil, front: String, back: String,
                box: Int = 1, due: Date = Date(), createdAt: Date = Date(), reviews: Int = 0, lapses: Int = 0) {
        self.id = id
        self.itemId = itemId
        self.subject = subject
        self.front = front
        self.back = back
        self.box = box
        self.due = due
        self.createdAt = createdAt
        self.reviews = reviews
        self.lapses = lapses
    }
}

public enum Leitner {
    public static let intervals = [0, 1, 2, 4, 8, 16]

    public static func review(_ card: Flashcard, correct: Bool, now: Date, testDate: Date? = nil) -> Flashcard {
        var c = card
        c.reviews += 1
        if correct { c.box = min(5, c.box + 1) } else { c.box = 1; c.lapses += 1 }
        var next = now.addingTimeInterval(Double(intervals[c.box]) * 86400)
        if c.box == 1 { next = now.addingTimeInterval(10 * 60) }
        if let t = testDate, next > t { next = max(now, t.addingTimeInterval(-86400)) }
        c.due = next
        return c
    }

    public static func dueCards(_ cards: [Flashcard], now: Date) -> [Flashcard] {
        cards.filter { $0.due <= now }.sorted { ($0.box, $0.due) < ($1.box, $1.due) }
    }
}

public struct ReadPiece: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var body: String
    public var subject: String?
    public var question: String?
    public var minutes: Int
    public var source: String
    public var createdAt: Date
    public var readAt: Date?

    public init(id: UUID = UUID(), title: String, body: String, subject: String? = nil, question: String? = nil,
                minutes: Int? = nil, source: String, createdAt: Date = Date(), readAt: Date? = nil) {
        self.id = id
        self.title = title
        self.body = body
        self.subject = subject
        self.question = question
        self.minutes = minutes ?? max(1, body.split(separator: " ").count / 200)
        self.source = source
        self.createdAt = createdAt
        self.readAt = readAt
    }
}

public enum GapActivity: Hashable, Sendable {
    case flashcards(count: Int)
    case read(ReadPiece)
    case nextStep(itemId: UUID, prompt: String)
    case breathe
    case walk

    public var title: String {
        switch self {
        case .flashcards(let n): return "Review \(n) card\(n == 1 ? "" : "s")"
        case .read(let p): return p.title
        case .nextStep: return "Prep your next block"
        case .breathe: return "One minute to reset"
        case .walk: return "Quick walk"
        }
    }
}

public enum GapPlanner {
    public static func options(minutes: Int, cards: [Flashcard], reads: [ReadPiece], items: [WorkItem],
                               mood: Int?, now: Date) -> [GapActivity] {
        var out: [GapActivity] = []
        if let mood, mood <= 2 { out.append(.breathe) }
        let due = Leitner.dueCards(cards, now: now)
        if !due.isEmpty { out.append(.flashcards(count: min(due.count, max(3, minutes * 2)))) }
        if let r = reads.filter({ $0.readAt == nil && $0.minutes <= max(2, minutes) })
            .sorted(by: { $0.createdAt < $1.createdAt }).first {
            out.append(.read(r))
        }
        if let essay = items.filter({ !$0.isDone && ($0.kind == .essay || $0.kind == .application || $0.kind == .project) })
            .min(by: { $0.due < $1.due }) {
            out.append(.nextStep(itemId: essay.id, prompt: "Write 3 bullet points for what the next part of “\(essay.title)” should say. That's the whole task. Next session starts warm."))
        }
        if minutes >= 10 { out.append(.walk) }
        if out.isEmpty { out.append(.breathe) }
        return Array(out.prefix(3))
    }

    public static let breathingSteps = ["Inhale through your nose", "Short second inhale on top", "Long, slow exhale through your mouth"]
}
