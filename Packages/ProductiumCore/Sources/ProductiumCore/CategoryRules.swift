import Foundation

// v1.2 C2: filing entries that don't come through the box (start buttons, the local fast path, notification answers,
// Shortcuts, sensors). Learned title → category rules first (your corrections beat the box's filings), then the
// task's own category, then the tree's own names and a few fallbacks. Topics come from the timetable's classes, the
// task's subject and topics, and title words that name a class.

public struct CategoryRule: Codable, Hashable, Sendable {
    public var category: CategoryID
    /// You set it (a correction in the entry sheet): it always wins, and the taxonomy pass never undoes it.
    public var byYou: Bool
    public var count: Int
    public var at: Date

    public init(category: CategoryID, byYou: Bool, count: Int = 1, at: Date) {
        self.category = category
        self.byYou = byYou
        self.count = count
        self.at = at
    }
}

/// One correction (for the taxonomy pass's examples, C6).
public struct CategoryCorrection: Codable, Hashable, Sendable {
    public var title: String
    public var from: CategoryID
    public var to: CategoryID
    public var at: Date
    public init(title: String, from: CategoryID, to: CategoryID, at: Date) {
        self.title = title
        self.from = from
        self.to = to
        self.at = at
    }
}

public struct CategoryRules: Codable, Hashable, Sendable {
    /// Keyed by `CategoryRules.key(title)`.
    public var learned: [String: CategoryRule] = [:]
    /// The last 30 corrections, newest last.
    public var corrections: [CategoryCorrection] = []

    public init() {}

    /// "Shower!", "shower " and "Shower · 2 of 3" share a key; numbering and punctuation don't matter.
    public static func key(_ title: String) -> String {
        var t = title.lowercased()
        if let r = t.range(of: #"\s*·\s*\d+\s+of\s+\d+$"#, options: .regularExpression) { t.removeSubrange(r) }
        return t.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
    }

    /// The box filed `title` under `category` (or you did, with `byYou`). A box filing never overrides yours.
    public mutating func learn(_ title: String, _ category: CategoryID, byYou: Bool, at: Date) {
        let k = Self.key(title)
        guard !k.isEmpty, category != CategoryTree.untracked else { return }
        if var r = learned[k] {
            if r.byYou && !byYou { return }
            if r.category == category { r.count += 1 } else { r = CategoryRule(category: category, byYou: byYou, at: at) }
            r.byYou = r.byYou || byYou
            r.at = at
            learned[k] = r
        } else {
            learned[k] = CategoryRule(category: category, byYou: byYou, at: at)
        }
    }

    /// You moved an entry: the rule becomes yours, and the correction is kept for the taxonomy pass.
    public mutating func correct(_ title: String, from: CategoryID, to: CategoryID, at: Date) {
        learn(title, to, byYou: true, at: at)
        corrections.append(CategoryCorrection(title: title, from: from, to: to, at: at))
        if corrections.count > 30 { corrections.removeFirst(corrections.count - 30) }
    }

    /// Drops rules whose category no longer exists (after a merge the taxonomy pass remaps them first).
    public mutating func remap(_ from: CategoryID, to: CategoryID) {
        for (k, r) in learned where r.category == from { learned[k]?.category = to }
    }

    static let fallbacks: [(words: [String], category: CategoryID)] = [
        (["sleep", "nap", "bed"], CategoryTree.sleep),
        (["shower", "bath"], "essentials.shower"),
        (["dinner", "lunch", "breakfast", "eating", "eat", "snack", "meal"], CategoryTree.meals),
        (["getting ready", "get ready", "ready", "dressed", "brush teeth"], CategoryTree.gettingReady),
        (["wind down", "winding down"], CategoryTree.windDown),
        (["walk to school", "bus", "drive", "driving", "commute", "travel", "train", "biking", "bike home", "walk home"], CategoryTree.travel),
        (["homework", "studying", "study", "revision", "review", "essay", "assignment", "reading", "practice test", "problem set"], CategoryTree.studying),
        (["practice", "training", "game", "club", "rehearsal", "lesson", "volleyball", "basketball", "soccer", "football",
          "swim", "swimming", "gym", "tennis", "track", "piano", "guitar", "band", "orchestra", "dance", "debate"], CategoryTree.extracurricular),
        (["scrolling", "tiktok", "instagram", "youtube", "reels", "shorts", "twitter", "reddit", "snapchat", "x app"], CategoryTree.scrolling),
        (["gaming", "valorant", "minecraft", "fortnite", "roblox", "video games", "netflix", "tv", "movie", "friends", "hanging out",
          "chilling", "relaxing", "music"], CategoryTree.free),
    ]

    /// Where `title` goes when the box didn't say: a correction of yours, the task's category, a learned rule, a node
    /// with that name, a scrolling app, a fallback word, else Other.
    public func category(for title: String, task: WorkItem? = nil, tree: CategoryTree,
                         scrollingApps: [String: Bool] = [:]) -> CategoryID {
        let k = Self.key(title)
        let rule = learned[k].flatMap { tree.node($0.category) != nil ? $0 : nil }
        if let r = rule, r.byYou { return r.category }
        if let t = task { return t.category ?? studyCategory(for: t, tree: tree) }
        if let r = rule { return r.category }
        // A node named exactly that ("Shower", "Volleyball", "Math" under School is a class, so not for free time).
        if let n = tree.nodes.filter({ $0.name.lowercased() == k && !tree.isUnder($0.id, CategoryTree.school) })
            .max(by: { tree.depth($0.id) < tree.depth($1.id) }) { return n.id }
        if ScrollingApps.isScrolling(title, scrollingApps) {
            return CategoryTree.scrolling
        }
        let padded = " \(k) "
        for f in Self.fallbacks where f.words.contains(where: { padded.contains(" \($0) ") }) {
            if tree.node(f.category) != nil { return f.category }
        }
        // A leaf whose name appears in the title ("volleyball practice" → Extracurricular › Volleyball).
        if let n = tree.nodes.filter({ tree.depth($0.id) >= 2 && !tree.isUnder($0.id, CategoryTree.school)
            && padded.contains(" \(Self.key($0.name)) ") }).max(by: { $0.name.count < $1.name.count }) { return n.id }
        return CategoryTree.other
    }

    /// A task's time, filed under Work › Studying › its subject when there is one (created as needed by the caller).
    public func studyCategory(for t: WorkItem, tree: CategoryTree) -> CategoryID {
        if let s = t.subject, let n = tree.find(s, under: CategoryTree.studying) { return n.id }
        return CategoryTree.studying
    }

    /// Topics cut across the tree: a class's name, the task's subject and topics, and title words that name a class.
    public static func topics(for title: String, category: CategoryID, task: WorkItem? = nil, tree: CategoryTree) -> [String] {
        var out: [String] = []
        func add(_ t: String) {
            let k = t.lowercased().trimmingCharacters(in: .whitespaces)
            if !k.isEmpty && !out.contains(k) { out.append(k) }
        }
        if tree.isUnder(category, CategoryTree.school), let n = tree.node(category), n.id != CategoryTree.school,
           !Timetable.isOpen(n.name) { add(n.name) }
        if let t = task {
            if let s = t.subject { add(s) }
            t.topics.forEach(add)
        }
        let words = Set(key(title).split(separator: " ").map(String.init))
        for cls in tree.children(CategoryTree.school) where !Timetable.isOpen(cls.name) && words.contains(key(cls.name)) { add(cls.name) }
        return out
    }
}
