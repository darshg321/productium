import Foundation

// v1.3 A4: the AI keeps the activity grid tidy (add what you keep typing, merge duplicates, rename vague tiles, hide
// unused ones). Applied at once through `ChangeLog` (Part F) and revertible there. Code checks every change: never a
// pinned tile or one you edited, at most 40 live tiles, nothing hidden that was used in the last 30 days.

public enum GridChange: Codable, Hashable, Sendable {
    case add(title: String, category: CategoryID, symbol: String?)
    /// `from` is hidden and its title starts `into` from then on.
    case merge(from: String, into: String)
    case rename(from: String, to: String)
    case hide(title: String)

    public var target: String {
        switch self {
        case .add(let t, _, _), .merge(let t, _), .rename(let t, _), .hide(let t): return "grid:" + CategoryRules.key(t)
        }
    }

    public var title: String {
        switch self {
        case .add(let t, _, _): return "Added a tile: \(t)"
        case .merge(let a, let b): return "Merged \(a) into \(b)"
        case .rename(let a, let b): return "Renamed \(a) to \(b)"
        case .hide(let t): return "Hid \(t) (unused)"
        }
    }
}

public enum GridTidy {
    public static let maxLive = 40
    public static let hideAfterDays = 30.0
    public static let maxPerRun = 5

    /// Why a change can't be made (nil: it can).
    public static func refusal(_ c: GridChange, grid: QuickStarts, lastUse: [UUID: Date], tree: CategoryTree, now: Date) -> String? {
        func tile(_ t: String) -> QuickStart? { grid.button(for: t) }
        func untouchable(_ b: QuickStart) -> Bool { b.isPinned || b.edited }
        switch c {
        case .add(let t, let cat, _):
            let title = t.trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty, title.count <= 30 else { return "A tile needs a short name" }
            if let b = tile(title) { return b.removed ? "\(b.title) was hidden" : "\(b.title) is already a tile" }
            guard grid.live.count < maxLive else { return "The grid has \(maxLive) tiles" }
            guard tree.node(cat) != nil else { return "No category \(cat)" }
        case .merge(let a, let b):
            guard let from = tile(a), !from.removed, let into = tile(b), !into.removed, from.id != into.id else { return "Merge needs two tiles" }
            guard !untouchable(from) else { return "\(from.title) is yours" }
        case .rename(let a, let b):
            guard let from = tile(a), !from.removed else { return "No tile \(a)" }
            guard !untouchable(from) else { return "\(from.title) is yours" }
            let to = b.trimmingCharacters(in: .whitespaces)
            guard !to.isEmpty, to.count <= 30, tile(to) == nil else { return "\(to) is taken" }
        case .hide(let t):
            guard let b = tile(t), !b.removed else { return "No tile \(t)" }
            guard !untouchable(b) else { return "\(b.title) is yours" }
            guard b.aliases.isEmpty else { return "\(b.title) has tiles merged into it" }
            let last = lastUse[b.id] ?? b.createdAt
            guard now.timeIntervalSince(last) >= hideAfterDays * 86400 else { return "\(b.title) was used in the last 30 days" }
        }
        return nil
    }

    /// Applies a checked change. Returns the tile it created and the text to restore on revert.
    public static func apply(_ c: GridChange, to grid: inout QuickStarts, now: Date) -> (created: UUID?, previous: String?) {
        switch c {
        case .add(let t, let cat, let sym):
            let b = QuickStart(title: t.trimmingCharacters(in: .whitespaces), category: cat, createdAt: now, origin: .ai, symbol: sym)
            grid.buttons.append(b)
            return (b.id, nil)
        case .merge(let a, let b):
            guard let from = grid.button(for: a), let into = grid.button(for: b),
                  let i = grid.buttons.firstIndex(where: { $0.id == into.id }) else { return (nil, nil) }
            grid.buttons[i].aliases += [from.title] + from.aliases
            grid.remove(from.id)
            return (nil, from.title)
        case .rename(let a, let b):
            guard let from = grid.button(for: a), let i = grid.buttons.firstIndex(where: { $0.id == from.id }) else { return (nil, nil) }
            grid.buttons[i].title = b.trimmingCharacters(in: .whitespaces)
            return (nil, from.title)
        case .hide(let t):
            if let b = grid.button(for: t) { grid.remove(b.id) }
            return (nil, nil)
        }
    }

    public static func revert(_ c: GridChange, created: UUID?, previous: String?, in grid: inout QuickStarts) {
        switch c {
        case .add:
            if let id = created { grid.buttons.removeAll { $0.id == id } }
        case .merge(let a, let b):
            if let into = grid.button(for: b), let i = grid.buttons.firstIndex(where: { $0.id == into.id }) {
                let k = CategoryRules.key(previous ?? a)
                grid.buttons[i].aliases.removeAll { CategoryRules.key($0) == k }
            }
            if let from = grid.buttons.first(where: { $0.key == CategoryRules.key(previous ?? a) }) { grid.unhide(from.id) }
        case .rename(let a, let b):
            if let i = grid.buttons.firstIndex(where: { $0.key == CategoryRules.key(b) && !$0.edited }) { grid.buttons[i].title = previous ?? a }
        case .hide(let t):
            if let b = grid.buttons.first(where: { $0.key == CategoryRules.key(t) }) { grid.unhide(b.id) }
        }
    }

    /// For the insight pass: the grid and what you keep typing that has no tile.
    public static func summary(_ grid: QuickStarts, entries: [Entry], now: Date) -> [String] {
        let from = now.addingTimeInterval(-28 * 86400)
        let recent = entries.filter { $0.repeats == nil && $0.source == .you && $0.taskId == nil && $0.start >= from && $0.start < now }
        var counts: [String: (title: String, n: Int)] = [:]
        for e in recent {
            let k = CategoryRules.key(e.title)
            counts[k] = (counts[k]?.title ?? e.title, (counts[k]?.n ?? 0) + 1)
        }
        let last = grid.lastUse(entries)
        let tiles = grid.live.map { b -> String in
            let n = b.keys.reduce(0) { $0 + (counts[$1]?.n ?? 0) }
            let days = last[b.id].map { Int(now.timeIntervalSince($0) / 86400) }
            let mark = b.isPinned || b.edited ? " (theirs)" : ""
            return "\(b.title)\(mark) \(n)×" + (days.map { " last \($0)d ago" } ?? " never used")
        }
        let tileKeys = Set(grid.buttons.flatMap(\.keys))
        let typed = counts.filter { !tileKeys.contains($0.key) && $0.value.n >= 3 }.sorted { $0.value.n > $1.value.n }.prefix(8)
            .map { "\($0.value.title) \($0.value.n)×" }
        var out = ["Activity grid (uses in 28 days): " + tiles.joined(separator: "; ")]
        if !typed.isEmpty { out.append("Typed often with no tile: " + typed.joined(separator: "; ")) }
        return out
    }
}
