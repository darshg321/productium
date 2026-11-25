import Foundation

/// v1.6 A4: which open task a phrase or a button's name means. Words match by stem ("reading" ≈ "read") or within a
/// typo (one edit per 5 letters: "englsih" ≈ "english", "lresentation" ≈ "presentation").
public enum TaskMatch {
    static let filler: Set<String> = ["the", "my", "a", "an", "for", "on", "of", "to", "some", "task", "and"]

    static func words(_ s: String) -> [String] {
        CategoryRules.key(s).split(separator: " ").map(String.init).filter { !filler.contains($0) }
    }

    static func stem(_ w: String) -> String {
        var w = w
        for suffix in ["ing", "ed", "s"] where w.count > suffix.count + 2 && w.hasSuffix(suffix) {
            w = String(w.dropLast(suffix.count))
            break
        }
        if w.count >= 4, let l = w.last, w.dropLast().last == l, !"aeiouls".contains(l) { w = String(w.dropLast()) }
        return w
    }

    static func same(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let sa = stem(a), sb = stem(b)
        if sa == sb { return true }
        if min(sa.count, sb.count) >= 4 && (sa.hasPrefix(sb) || sb.hasPrefix(sa)) && abs(sa.count - sb.count) <= 1 { return true }
        let allowed = min(a.count, b.count) / 5
        return allowed > 0 && distance(a, b) <= allowed
    }

    /// Edits between two words; swapping two neighbours is one edit.
    static func distance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty, !y.isEmpty else { return max(x.count, y.count) }
        var d = Array(repeating: Array(repeating: 0, count: y.count + 1), count: x.count + 1)
        for i in 0...x.count { d[i][0] = i }
        for j in 0...y.count { d[0][j] = j }
        for i in 1...x.count {
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, x[i - 1] == y[j - 2], x[i - 2] == y[j - 1] { d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1) }
            }
        }
        return d[x.count][y.count]
    }

    /// The share of the phrase's words found in the title, and of the title's words found in the phrase.
    static func coverage(_ phrase: [String], _ title: [String]) -> (phrase: Double, title: Double) {
        guard !phrase.isEmpty, !title.isEmpty else { return (0, 0) }
        let p = phrase.filter { w in title.contains { same(w, $0) } }.count
        let t = title.filter { w in phrase.contains { same(w, $0) } }.count
        return (Double(p) / Double(phrase.count), Double(t) / Double(title.count))
    }

    /// The one open task the phrase names: every word of it is in the title and it covers most of the title (2 of 3
    /// words). With several, the best covered wins if it's the only one.
    public static func task(for phrase: String, in items: [WorkItem]) -> WorkItem? {
        let p = words(phrase)
        guard p.contains(where: { $0.count >= 4 }) else { return nil }
        let scored = items.filter(\.isOpen).compactMap { item -> (WorkItem, Double)? in
            let c = coverage(p, words(item.title))
            return c.phrase == 1 && c.title >= 2.0 / 3 ? (item, c.title) : nil
        }
        guard let best = scored.map(\.1).max() else { return nil }
        let top = scored.filter { $0.1 == best }
        return top.count == 1 ? top[0].0 : nil
    }

    /// Open tasks the phrase is close to (half its words or more): more than none but no clear one is a question.
    public static func near(_ phrase: String, in items: [WorkItem]) -> Int {
        let p = words(phrase).filter { $0.count >= 4 }
        guard !p.isEmpty else { return 0 }
        return items.filter(\.isOpen).filter { coverage(p, words($0.title)).phrase >= 0.5 }.count
    }

    /// v1.6 B2: an open task that a new one repeats: due the same day, and half its words (or its subject) match.
    public static func twin(of new: WorkItem, in items: [WorkItem], calendar cal: Calendar) -> Int? {
        let w = words(new.title).filter { $0.count >= 4 && !["study", "studying", "prepare", "review", "practice"].contains($0) }
        let hits = items.indices.filter { i in
            let t = items[i]
            guard t.isOpen, t.id != new.id, cal.isDate(t.due, inSameDayAs: new.due) else { return false }
            let theirs = words(t.title)
            let shared = w.filter { a in theirs.contains { same(a, $0) } }.count
            return !w.isEmpty && Double(shared) / Double(w.count) >= 0.5
                || (t.source == .calendar && t.kind.isMemoryBased && new.kind.isMemoryBased
                    && (abs(t.due.timeIntervalSince(new.due)) <= 90 * 60 || (new.category != nil && new.category == t.category)))
        }
        return hits.count == 1 ? hits[0] : nil
    }
}
