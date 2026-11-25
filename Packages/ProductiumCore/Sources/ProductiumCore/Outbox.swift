import Foundation

// v1.2 A9: a reply typed into a notification (or a Shortcut, Siri, the box) is saved here before anything else
// happens, so it's never lost when Tailscale is off or iOS suspends the app. The local fast path (`QuickParse`) runs
// first and needs no network; only what it can't take goes to Sonnet. Unsent items are retried on launch and in
// background refresh, and removed only once applied.

public struct OutboxItem: Codable, Hashable, Identifiable, Sendable {
    public enum Source: String, Codable, Sendable { case notification, app, shortcut, siri, share }
    public var id: UUID
    public var text: String
    public var at: Date
    public var source: Source
    /// What the notification was asking about ("What are you up to?" at 15:40), so the answer keeps its meaning later.
    public var context: String?
    public var attempts: Int
    public var lastError: String?
    public var lastTriedAt: Date?

    public init(id: UUID = UUID(), text: String, at: Date, source: Source, context: String? = nil) {
        self.id = id
        self.text = text
        self.at = at
        self.source = source
        self.context = context
        self.attempts = 0
    }

    /// The text the box gets: a late answer says when it was written and what it answered.
    public func boxText(now: Date, calendar cal: Calendar) -> String {
        var parts: [String] = []
        if let c = context { parts.append("(Answering: \(c))") }
        if now.timeIntervalSince(at) > 10 * 60 {
            parts.append("(Written at \(DateFormatter.local("EEE HH:mm", cal).string(from: at)), sent now)")
        }
        parts.append(text)
        return parts.joined(separator: " ")
    }
}

public struct Outbox: Codable, Hashable, Sendable {
    public var items: [OutboxItem] = []
    public init() {}

    /// Keeps a week of unsent replies; older ones were surely dealt with some other way.
    static let keepFor: TimeInterval = 7 * 86400

    @discardableResult
    public mutating func add(_ text: String, source: OutboxItem.Source, context: String? = nil, at: Date) -> UUID? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        // The same reply twice within a minute (a double tap) is one reply.
        if let dup = items.first(where: { $0.text == t && abs($0.at.timeIntervalSince(at)) < 60 }) { return dup.id }
        let item = OutboxItem(text: t, at: at, source: source, context: context)
        items.append(item)
        return item.id
    }

    public mutating func sent(_ id: UUID) { items.removeAll { $0.id == id } }

    public mutating func failed(_ id: UUID, error: String, at: Date) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].attempts += 1
        items[i].lastError = error
        items[i].lastTriedAt = at
    }

    /// v1.6 G10: older than this, a reply isn't sent by itself (it may be about a day that's gone): the box asks.
    public static let staleAfter: TimeInterval = 6 * 3600

    public func stale(now: Date) -> [OutboxItem] { items.filter { now.timeIntervalSince($0.at) > Self.staleAfter }.sorted { $0.at < $1.at } }

    /// What to try now, oldest first: a back-off of 1, 2, 4 … minutes (at most an hour) after each failure.
    public func due(now: Date) -> [OutboxItem] {
        items.filter { i in
            guard now.timeIntervalSince(i.at) <= Self.staleAfter else { return false }
            guard let last = i.lastTriedAt else { return true }
            let wait = min(3600, 60 * pow(2, Double(max(0, i.attempts - 1))))
            return now.timeIntervalSince(last) >= wait
        }.sorted { $0.at < $1.at }
    }

    public mutating func prune(now: Date) { items.removeAll { now.timeIntervalSince($0.at) > Self.keepFor } }
}
