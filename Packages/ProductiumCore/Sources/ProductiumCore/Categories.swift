import Foundation

// v1.2 Part C: the category tree every Entry is filed into. Two or three levels; the AI grows it from the seed.
// Ids are opaque and stable (renames and moves keep them), so entries never need re-filing when the tree is tidied.
// Topics (Entry.topics) cut across the tree: "math class" and "studying for the math test" share topic `math`.

public enum CategoryGroup: String, Codable, CaseIterable, Sendable {
    case productive, essential, rest, unproductive
}

public struct CategoryNode: Codable, Hashable, Identifiable, Sendable {
    public var id: CategoryID
    public var name: String
    public var parentId: CategoryID?
    public var symbol: String
    /// A `CategoryPalette` colour name.
    public var colour: String
    public var group: CategoryGroup
    /// Created or named by you: the taxonomy pass never renames, moves or merges it.
    public var yours: Bool

    public init(id: CategoryID, name: String, parentId: CategoryID? = nil, symbol: String, colour: String,
                group: CategoryGroup, yours: Bool = false) {
        self.id = id
        self.name = name
        self.parentId = parentId
        self.symbol = symbol
        self.colour = colour
        self.group = group
        self.yours = yours
    }
}

public struct CategoryTree: Codable, Hashable, Sendable {
    public static let maxDepth = 3

    // Seed ids code refers to. Everything else is created by the AI or you.
    public static let sleep: CategoryID = "sleep"
    public static let school: CategoryID = "school"
    public static let work: CategoryID = "work"
    public static let studying: CategoryID = "work.studying"
    public static let extracurricular: CategoryID = "work.extracurricular"
    public static let essentials: CategoryID = "essentials"
    public static let gettingReady: CategoryID = "essentials.ready"
    public static let meals: CategoryID = "essentials.meals"
    public static let windDown: CategoryID = "essentials.winddown"
    public static let travel: CategoryID = "travel"
    public static let free: CategoryID = "free"
    public static let unproductive: CategoryID = "unproductive"
    public static let scrolling: CategoryID = "unproductive.scrolling"
    public static let other: CategoryID = "other"
    /// Not a node: time nothing explains. Shown in the ring, never counted as free time.
    public static let untracked: CategoryID = "untracked"

    public var nodes: [CategoryNode]

    public init(nodes: [CategoryNode] = CategoryTree.seedNodes) { self.nodes = nodes }

    public static let seedNodes: [CategoryNode] = [
        CategoryNode(id: sleep, name: "Sleep", symbol: "moon.fill", colour: "indigo", group: .essential),
        CategoryNode(id: school, name: "School", symbol: "building.2", colour: "gray", group: .productive),
        CategoryNode(id: work, name: "Work", symbol: "pencil.line", colour: "blue", group: .productive),
        CategoryNode(id: studying, name: "Studying", parentId: work, symbol: "pencil.line", colour: "blue", group: .productive),
        CategoryNode(id: extracurricular, name: "Extracurricular", parentId: work, symbol: "figure.run", colour: "blue", group: .productive),
        CategoryNode(id: essentials, name: "Essentials", symbol: "checklist", colour: "gray", group: .essential),
        CategoryNode(id: "essentials.shower", name: "Shower", parentId: essentials, symbol: "shower", colour: "gray", group: .essential),
        CategoryNode(id: meals, name: "Meals", parentId: essentials, symbol: "fork.knife", colour: "gray", group: .essential),
        CategoryNode(id: gettingReady, name: "Getting Ready", parentId: essentials, symbol: "tshirt", colour: "gray", group: .essential),
        CategoryNode(id: windDown, name: "Wind Down", parentId: essentials, symbol: "moon.haze", colour: "gray", group: .essential),
        CategoryNode(id: travel, name: "Travel", symbol: "figure.walk", colour: "gray", group: .essential),
        CategoryNode(id: free, name: "Free Time", symbol: "sun.max", colour: "yellow", group: .rest),
        CategoryNode(id: unproductive, name: "Unproductive", symbol: "hourglass", colour: "teal", group: .unproductive),
        CategoryNode(id: scrolling, name: "Scrolling", parentId: unproductive, symbol: "hourglass", colour: "teal", group: .unproductive),
        CategoryNode(id: other, name: "Other", symbol: "circle", colour: "gray", group: .rest),
    ]

    public func node(_ id: CategoryID) -> CategoryNode? { nodes.first { $0.id == id } }

    /// Root first: [School, Math].
    public func path(_ id: CategoryID) -> [CategoryNode] {
        var out: [CategoryNode] = []
        var cur = node(id)
        while let n = cur, out.count <= Self.maxDepth {
            out.insert(n, at: 0)
            cur = n.parentId.flatMap(node)
        }
        return out
    }

    /// "School › Math". Untracked and unknown ids get a plain name.
    public func pathText(_ id: CategoryID) -> String {
        if id == Self.untracked { return "Untracked" }
        let p = path(id)
        return p.isEmpty ? id : p.map(\.name).joined(separator: " › ")
    }

    public func root(_ id: CategoryID) -> CategoryID { path(id).first?.id ?? id }

    /// The node itself or anything below it.
    public func isUnder(_ id: CategoryID, _ ancestor: CategoryID) -> Bool { path(id).contains { $0.id == ancestor } }

    public func children(_ id: CategoryID?) -> [CategoryNode] { nodes.filter { $0.parentId == id } }

    /// The group of the node, inherited from the root when unset differently below.
    public func group(_ id: CategoryID) -> CategoryGroup? { node(id)?.group ?? path(id).first?.group }

    public func depth(_ id: CategoryID) -> Int { path(id).count }

    /// Finds a node by name under a parent (case and spacing insensitive), the way the box names categories.
    public func find(_ name: String, under parent: CategoryID? = nil) -> CategoryNode? {
        let k = name.plainKey
        return nodes.first { $0.name.plainKey == k && (parent == nil || $0.parentId == parent) }
    }

    /// Adds a child (or returns the existing one with that name). Nil if the depth limit would be passed.
    @discardableResult
    public mutating func add(_ name: String, under parent: CategoryID?, yours: Bool = false) -> CategoryNode? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        if let hit = nodes.first(where: { $0.name.plainKey == name.plainKey && $0.parentId == parent }) { return hit }
        if let parent, node(parent) == nil || depth(parent) >= Self.maxDepth { return nil }
        let p = parent.flatMap(node)
        var id = (parent.map { $0 + "." } ?? "") + name.plainKey
        var n = 2
        while node(id) != nil { id = (parent.map { $0 + "." } ?? "") + name.plainKey + "\(n)"; n += 1 }
        let new = CategoryNode(id: id, name: name, parentId: parent, symbol: p?.symbol ?? "circle",
                               colour: p?.colour ?? "gray", group: p?.group ?? .rest, yours: yours)
        nodes.append(new)
        return new
    }

    /// The v1.1 eight-way category, for code that hasn't moved to the tree yet (the ring colours, `DayTotals`).
    public func legacy(_ id: CategoryID) -> TimeCategory {
        if id == Self.untracked { return .free }
        if isUnder(id, Self.sleep) { return .sleep }
        if isUnder(id, Self.school) { return .school }
        if isUnder(id, Self.extracurricular) { return .activities }
        if isUnder(id, Self.work) { return .study }
        if isUnder(id, Self.travel) { return .commute }
        if isUnder(id, Self.essentials) { return .routine }
        if isUnder(id, Self.unproductive) { return .screen }
        return .free
    }
}
