import Foundation

// v1.2 C5–C6: the background pass that keeps the category tree tidy. One Sonnet call, at most every 4 hours (v1.5), when
// 3+ things you logged went into Other or new / thin leaves since the last run, or weekly. It merges, renames, moves and creates nodes, at
// most 8 ops a run, and remaps entries so no time is lost. It never touches nodes you named (`yours`), entries you
// filed, seed nodes code relies on, or anything a correction of yours points at. Every run can be reverted.

public struct TaxonomyOp: Codable, Hashable, Sendable {
    /// merge | rename | move | create | file (v1.5: entries titled `name` go `into` a category, and future ones too)
    public var op: String
    public var id: CategoryID?
    public var into: CategoryID?
    public var name: String?
    public var under: CategoryID?
    public var reason: String?

    public init(op: String, id: CategoryID? = nil, into: CategoryID? = nil, name: String? = nil, under: CategoryID? = nil, reason: String? = nil) {
        self.op = op
        self.id = id
        self.into = into
        self.name = name
        self.under = under
        self.reason = reason
    }
}

public struct TaxonomyRun: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var at: Date
    public var lines: [String]
    public var treeBefore: CategoryTree
    /// Entry id → its category before the run (only entries the run moved).
    public var remapped: [UUID: CategoryID]
    public var reverted: Bool

    public init(id: UUID = UUID(), at: Date, lines: [String], treeBefore: CategoryTree, remapped: [UUID: CategoryID]) {
        self.id = id
        self.at = at
        self.lines = lines
        self.treeBefore = treeBefore
        self.remapped = remapped
        self.reverted = false
    }
}

public struct TaxonomyLog: Codable, Hashable, Sendable {
    public var runs: [TaxonomyRun] = []
    public var lastRun: Date?
    public init() {}
}

public enum TaxonomyPass {
    public static let maxOps = 8
    static let seedIds = Set(CategoryTree.seedNodes.map(\.id))

    public static let minHours = 4.0

    /// Due: at most every `minHours`; weekly at least; sooner when 3+ entries you logged went into Other, leaves made
    /// since the last run, or leaves with under 3 entries.
    public static func due(tree: CategoryTree, entries: [Entry], log: TaxonomyLog, now: Date) -> Bool {
        if let l = log.lastRun, now.timeIntervalSince(l) < minHours * 3600 { return false }
        let since = log.lastRun ?? now.addingTimeInterval(-14 * 86400)
        // New or thin as of the last run: what had under 3 entries before it.
        let counts = Dictionary(grouping: entries.filter { $0.source != .plan && $0.createdAt <= since }, by: \.category).mapValues(\.count)
        let thin = Set(tree.nodes.filter { !seedIds.contains($0.id) && (counts[$0.id] ?? 0) < 3 }.map(\.id))
        let recent = entries.filter { $0.createdAt > since && $0.source == .you && (thin.contains($0.category) || $0.category == CategoryTree.other) }
        if recent.count >= 3 { return true }
        return log.lastRun.map { now.timeIntervalSince($0) > 7 * 86400 } ?? false
    }

    public static func system() -> String {
        """
        You keep a high-school student's time categories tidy. The app files every stretch of their day into a tree \
        (at most 3 levels). New leaves get made as things are logged, so duplicates and odd names creep in.

        Return ops (at most 8; none is a fine answer when it's already tidy):
        - merge {id, into}: the same activity twice ("Bball", "Basketball practice", "Hoops" → one). Entries move to `into`.
        - rename {id, name}: a clearer name ("Vball" → "Volleyball").
        - move {id, under}: a leaf in the wrong branch (Gaming under Work → Free Time).
        - create {name, under}: a parent that groups 3+ existing leaves (then move them).
        - file {name, into}: a title sitting in Other (or clearly misfiled) belongs in an existing node; its time moves.
        Each with a short reason. Never touch nodes marked [yours] or [fixed], and keep the student's corrections true: a \
        title they moved somewhere stays there. Prefer fewer, clearer leaves; don't invent detail.
        Split only where the student would compare: study time per subject (Studying › Math, › English) matters; ways \
        of getting somewhere don't (walking, the bus, a ride are all Travel), nor do kinds of meal or getting ready.
        """
    }

    public static let schema: JSONValue = {
        let s = Schemas.str
        return Schemas.obj(["ops": Schemas.arr(Schemas.obj(["op": Schemas.strEnum(["merge", "rename", "move", "create", "file"]), "id": s,
                                                            "into": s, "name": s, "under": s, "reason": s], required: ["op", "reason"]))],
                           required: ["ops"])
    }()

    public struct Output: Codable, Hashable, Sendable { public var ops: [TaxonomyOp] }

    /// The tree with minutes (28 days) and example titles per node, recent new leaves, and the last 30 corrections.
    public static func request(tree: CategoryTree, entries: [Entry], rules: CategoryRules, now: Date, calendar cal: Calendar) -> String {
        let since = now.addingTimeInterval(-28 * 86400)
        let mine = entries.filter { $0.source != .plan && $0.repeats == nil && $0.start >= since }
        var minutes: [CategoryID: Int] = [:], titles: [CategoryID: [String: Int]] = [:]
        for e in mine {
            minutes[e.category, default: 0] += e.minutes(now: now)
            titles[e.category, default: [:]][e.title, default: 0] += 1
        }
        var l = ["Tree (id name · minutes in 28 days · example titles):"]
        func walk(_ parent: CategoryID?, _ depth: Int) {
            for n in tree.children(parent).sorted(by: { $0.name < $1.name }) {
                var line = String(repeating: "  ", count: depth) + "\(n.id) \(n.name)"
                if n.yours { line += " [yours]" } else if seedIds.contains(n.id) { line += " [fixed]" }
                line += " · \(minutesLabel(minutes[n.id] ?? 0))"
                let ex = (titles[n.id] ?? [:]).sorted { $0.value > $1.value }.prefix(3).map { "\"\($0.key)\"" }
                if !ex.isEmpty { line += " · " + ex.joined(separator: ", ") }
                l.append(line)
                walk(n.id, depth + 1)
            }
        }
        walk(nil, 0)
        let fresh = Set(mine.filter { $0.createdAt > now.addingTimeInterval(-7 * 86400) }.map(\.category))
            .filter { !seedIds.contains($0) }.map { tree.pathText($0) }.sorted()
        if !fresh.isEmpty { l.append("Used for the first time this week: " + fresh.joined(separator: "; ")) }
        let other = Dictionary(grouping: mine.filter { $0.category == CategoryTree.other }, by: \.title).mapValues(\.count)
            .sorted { $0.value > $1.value }.prefix(15).map { "\"\($0.key)\" ×\($0.value)" }
        if !other.isEmpty { l.append("In Other (file them if they fit somewhere): " + other.joined(separator: ", ")) }
        if !rules.corrections.isEmpty {
            l.append("The student's corrections (keep them true): " + rules.corrections.suffix(30).map {
                "\"\($0.title)\" → \(tree.pathText($0.to))"
            }.joined(separator: "; "))
        }
        return l.joined(separator: "\n")
    }

    /// Applies what passes the rules (≤8, nothing of yours, no seed node moved or merged away, no correction undone,
    /// depth ≤3, no time lost). Returns the run (nil if nothing applied) and why the rest were refused.
    public static func apply(_ ops: [TaxonomyOp], tree: inout CategoryTree, entries: inout [Entry], rules: inout CategoryRules,
                             now: Date) -> (run: TaxonomyRun?, refused: [String]) {
        let before = tree
        var remapped: [UUID: CategoryID] = [:]
        var lines: [String] = [], refused: [String] = []
        let corrected = Set(rules.learned.values.filter(\.byYou).map(\.category))
        func protectedNode(_ id: CategoryID) -> String? {
            guard let n = tree.node(id) else { return "no node \(id)" }
            if n.yours { return "\(n.name) is yours" }
            if seedIds.contains(id) { return "\(n.name) is fixed" }
            if corrected.contains(id) { return "a correction of yours points at \(n.name)" }
            return nil
        }
        for op in ops.prefix(maxOps) {
            switch op.op {
            case "merge":
                guard let from = op.id, let into = op.into, tree.node(into) != nil, from != into else { refused.append("merge: bad ids"); continue }
                if let why = protectedNode(from) { refused.append("merge: \(why)"); continue }
                if tree.isUnder(into, from) { refused.append("merge: into its own child"); continue }
                if entries.contains(where: { $0.filedByYou && tree.isUnder($0.category, from) }) {
                    refused.append("merge: you filed time under \(tree.node(from)!.name)"); continue
                }
                let name = tree.node(from)!.name
                for c in tree.children(from) { if let i = tree.nodes.firstIndex(where: { $0.id == c.id }) { tree.nodes[i].parentId = into } }
                for i in entries.indices where entries[i].category == from {
                    if remapped[entries[i].id] == nil { remapped[entries[i].id] = from }
                    entries[i].category = into
                }
                rules.remap(from, to: into)
                tree.nodes.removeAll { $0.id == from }
                lines.append("Merged \(name) into \(tree.pathText(into))")
            case "rename":
                guard let id = op.id, let name = op.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { refused.append("rename: bad"); continue }
                if let n = tree.node(id), n.yours { refused.append("rename: \(n.name) is yours"); continue }
                if seedIds.contains(id) { refused.append("rename: fixed"); continue }
                guard let i = tree.nodes.firstIndex(where: { $0.id == id }) else { refused.append("rename: no node"); continue }
                let old = tree.nodes[i].name
                tree.nodes[i].name = name
                lines.append("Renamed \(old) to \(name)")
            case "move":
                guard let id = op.id, let under = op.under, tree.node(under) != nil else { refused.append("move: bad ids"); continue }
                if let why = protectedNode(id) { refused.append("move: \(why)"); continue }
                if tree.isUnder(under, id) { refused.append("move: under itself"); continue }
                let height = 1 + (tree.nodes.contains { $0.parentId == id } ? 1 : 0)
                guard tree.depth(under) + height <= CategoryTree.maxDepth else { refused.append("move: too deep"); continue }
                guard let i = tree.nodes.firstIndex(where: { $0.id == id }) else { continue }
                tree.nodes[i].parentId = under
                if let p = tree.node(under) { tree.nodes[i].group = p.group }
                lines.append("Moved \(tree.nodes[i].name) under \(tree.pathText(under))")
            case "create":
                guard let name = op.name, let made = tree.add(name, under: op.under) else { refused.append("create: bad"); continue }
                lines.append("Made \(tree.pathText(made.id))")
            case "file":
                guard let title = op.name, let into = op.into, tree.node(into) != nil else { refused.append("file: bad"); continue }
                let key = CategoryRules.key(title)
                if rules.learned[key]?.byYou == true { refused.append("file: you filed \(title)"); continue }
                var moved = 0
                for i in entries.indices where CategoryRules.key(entries[i].title) == key && !entries[i].filedByYou
                    && entries[i].source != .plan && entries[i].category != into {
                    if remapped[entries[i].id] == nil { remapped[entries[i].id] = entries[i].category }
                    entries[i].category = into
                    moved += 1
                }
                rules.learn(title, into, byYou: false, at: now)
                lines.append("Filed \(title) under \(tree.pathText(into))" + (moved > 0 ? " (\(moved))" : ""))
            default:
                refused.append("unknown op \(op.op)")
            }
        }
        if ops.count > maxOps { refused.append("\(ops.count - maxOps) over the limit of \(maxOps)") }
        guard !lines.isEmpty else { tree = before; return (nil, refused) }
        return (TaxonomyRun(at: now, lines: lines, treeBefore: before, remapped: remapped), refused)
    }

    /// Puts the tree and the moved entries back (entries you've moved since keep your choice).
    public static func revert(_ run: TaxonomyRun, tree: inout CategoryTree, entries: inout [Entry]) {
        tree = run.treeBefore
        for i in entries.indices {
            guard let old = run.remapped[entries[i].id], !entries[i].filedByYou else { continue }
            entries[i].category = old
        }
    }
}
