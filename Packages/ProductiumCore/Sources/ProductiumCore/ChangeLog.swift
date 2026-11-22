import Foundation

// v1.1 D.2: the insight pass changes how Productium behaves at once, with no approval step and no announcement.
// Safety is in code, here: Registry ranges and maximum steps, one change per target per 7 days, never sleep
// need / floor / trade-offs, never anything the student wrote, pins, and no retry for 30 days after a revert.
// Everything it did is listed in Settings → What Productium Thinks → Changes, each with Revert.

public enum InsightChange: Codable, Hashable, Sendable {
    case knob(key: String, to: Double)
    case starterStep(parent: UUID, title: String, minutes: Int, due: Date)
    case intention(IntentionNudge)
    case beliefGroup(BeliefGroup, evidence: [String])
    case aboutMe(section: AboutMeSection, text: String)
    /// Celebrations turned down because they made no difference (F6). Revert restores `from`.
    case celebrations(to: CelebrationLevel, from: CelebrationLevel)
    /// v1.3 A4: the activity grid tidied (own cap of `GridTidy.maxPerRun`, not counted in the 3).
    case grid(GridChange)

    var isAboutMe: Bool { if case .aboutMe = self { return true }; return false }
    var isBeliefGroup: Bool { if case .beliefGroup = self { return true }; return false }
    var isGrid: Bool { if case .grid = self { return true }; return false }

    /// What a pin or the once-a-week limit applies to.
    public var target: String {
        switch self {
        case .knob(let k, _): return k
        case .starterStep(let p, _, _, _): return "step:\(p.uuidString)"
        case .intention(let i): return "intention:\(i.itemId?.uuidString ?? i.text)"
        case .beliefGroup: return "group"
        case .aboutMe(_, let t): return "about:\(t.prefix(40))"
        case .celebrations: return "celebrations"
        case .grid(let g): return g.target
        }
    }
}

public enum ChangeStatus: String, Codable, Sendable {
    case applied, reverted
    /// Only from v1.0 exports: a suggestion the student rejected before changes were applied directly.
    case declined
}

public struct LoggedChange: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var runId: UUID
    public var change: InsightChange
    public var from: String
    public var to: String
    public var reason: String
    public var evidence: [String]
    public var model: String
    public var at: Date
    public var status: ChangeStatus
    public var revertedAt: Date?
    /// The step a starter-step change created (removed again on revert).
    public var created: UUID?
    /// The knob's value before (restored on revert).
    public var previous: Double?
    /// The task's first step before (restored on revert).
    public var previousText: String?

    public init(id: UUID = UUID(), runId: UUID, change: InsightChange, from: String = "", to: String = "", reason: String,
                evidence: [String] = [], model: String, at: Date, status: ChangeStatus = .applied) {
        self.id = id
        self.runId = runId
        self.change = change
        self.from = from
        self.to = to
        self.reason = reason
        self.evidence = evidence
        self.model = model
        self.at = at
        self.status = status
    }

    public var title: String {
        switch change {
        case .knob(let k, _): return "\(Registry.knob(k)?.note.capitalizedFirst ?? k): \(from) → \(to)"
        case .starterStep(_, let t, _, _): return "Named a first step: \(t)"
        case .intention(let i): return "Reminds you: \(i.text)"
        case .beliefGroup(let g, _): return "Started noticing: \(g.title)"
        case .aboutMe(let s, let t): return "About You (\(s.rawValue)): \(t)"
        case .celebrations(let to, _): return "Celebrations: \(to.title)"
        case .grid(let g): return g.title
        }
    }

    /// The day a change was reverted or declined: the 30-day no-retry clock starts there.
    var settledAt: Date { revertedAt ?? at }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

public struct InsightRun: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var at: Date
    public var note: String
    public var model: String
    public init(id: UUID = UUID(), at: Date, note: String, model: String) {
        self.id = id
        self.at = at
        self.note = note
        self.model = model
    }
}

public struct ChangeLog: Codable, Hashable, Sendable {
    public var changes: [LoggedChange]
    public var runs: [InsightRun]
    @SortedSet public var pinned: Set<String>

    public static let maxPerRun = 3
    public static let maxAboutMePerRun = 3
    public static let sameTargetDays = 7.0
    public static let noRetryDays = 30.0

    public init(changes: [LoggedChange] = [], runs: [InsightRun] = [], pinned: Set<String> = []) {
        self.changes = changes
        self.runs = runs
        self.pinned = pinned
    }

    /// Newest first: what the Changes list shows.
    public var history: [LoggedChange] { changes.sorted { $0.settledAt > $1.settledAt } }
    public var applied: [LoggedChange] { changes.filter { $0.status == .applied } }

    /// For the box and the weekly note: what Productium changed lately (so neither contradicts it).
    public func changeSummary(now: Date, limit: Int = 4) -> String? {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        f.locale = Locale(identifier: "en_US_POSIX")
        let recent = applied.sorted { $0.at > $1.at }.prefix(limit).map { "\($0.title) (\(f.string(from: $0.at)))" }
        return recent.isEmpty ? nil : "Changes Productium made lately: " + recent.joined(separator: "; ")
    }

    /// Fed back to the insight pass: what the student undid, so it isn't tried again.
    public var feedback: [String] {
        changes.filter { $0.status != .applied }.sorted { $0.settledAt < $1.settledAt }.suffix(10).map {
            "\($0.status == .declined ? "Turned down" : "Reverted"): \($0.title) (\($0.reason))"
        }
    }

    /// Checks every draft against the rules and applies the ones that pass, at once. Returns why the rest didn't.
    @discardableResult
    public mutating func apply(_ run: InsightRun, _ drafts: [LoggedChange], to s: inout DumpState, now: Date) -> [String] {
        var problems: [String] = []
        var done: [LoggedChange] = []
        for var p in drafts {
            p.runId = run.id
            p.status = .applied
            p.at = now
            if let why = refusal(&p, done: done, state: s, now: now) { problems.append(why); continue }
            if let why = perform(&p, in: &s, now: now) { problems.append(why); continue }
            done.append(p)
        }
        runs.append(run)
        runs = Array(runs.suffix(52))
        changes += done
        return problems
    }

    /// Why a draft can't be applied (nil: it can). Also fills in from / to and bounds knob values.
    func refusal(_ p: inout LoggedChange, done: [LoggedChange], state s: DumpState, now: Date) -> String? {
        if case .aboutMe(let section, let text) = p.change {
            guard section == .inferred || section == .patterns, !text.isEmpty else { return "About-me line refused: \(text.prefix(40))" }
            guard done.filter(\.change.isAboutMe).count < Self.maxAboutMePerRun else { return "More than 3 about-me lines" }
            guard !s.aboutMe[section].contains(where: { $0.text.plainKey == text.plainKey }) else { return "Already in About You: \(text.prefix(40))" }
            return nil
        }
        if p.change.isGrid {
            guard done.filter(\.change.isGrid).count < GridTidy.maxPerRun else { return "More than \(GridTidy.maxPerRun) grid changes" }
        } else {
            guard done.filter({ !$0.change.isAboutMe && !$0.change.isGrid }).count < Self.maxPerRun else { return "More than \(Self.maxPerRun) in one run: \(p.title)" }
        }
        let t = p.change.target
        if pinned.contains(t) { return "\(t) is pinned" }
        if done.contains(where: { $0.change.target == t }) { return "\(t) twice in one run" }
        if changes.contains(where: { $0.change.target == t && $0.status == .applied
            && now.timeIntervalSince($0.at) < Self.sameTargetDays * 86400 }) {
            return "\(t) changed in the last 7 days"
        }
        if changes.contains(where: { $0.change.target == t && $0.status != .applied
            && now.timeIntervalSince($0.settledAt) < Self.noRetryDays * 86400 }) {
            return "\(t) was undone less than 30 days ago"
        }
        switch p.change {
        case .knob(let key, let target):
            guard let spec = Registry.knob(key), spec.tier == .behaviour, !spec.reflectionForbidden,
                  let cur = Knobs.value(spec.key, in: s.policy) else { return "\(key) isn't a behaviour setting" }
            let v = Knobs.bounded(spec, from: cur, to: target)
            guard v != cur else { return "\(key) is already \(Knobs.format(cur))" }
            p.change = .knob(key: spec.key, to: v)
            p.from = Knobs.format(cur)
            p.to = Knobs.format(v)
        case .starterStep(let parent, let title, let minutes, _):
            guard let task = s.items.first(where: { $0.id == parent && $0.isOpen }), !title.isEmpty else { return "No open task for a first step" }
            guard (5...20).contains(minutes) else { return "A first step is 5-20 minutes" }
            p.from = task.title
            p.to = title
        case .intention(let i):
            guard !i.text.trimmingCharacters(in: .whitespaces).isEmpty, i.trigger == .arriveHome || i.time != nil else {
                return "A reminder needs text and a time"
            }
            guard s.policy.intentions.filter({ $0.byStudent != true }).count < 3 else { return "Three reminders already" }
        case .beliefGroup(let g, let ev):
            guard ev.count >= 3 else { return "A new group needs 3 pieces of evidence" }
            if done.contains(where: \.change.isBeliefGroup) || changes.contains(where: {
                $0.change.isBeliefGroup && $0.status == .applied && now.timeIntervalSince($0.at) < 7 * 86400 }) {
                return "One new group a week"
            }
            guard !s.beliefs.groups.contains(where: { $0.id == g.id }) else { return "\(g.title) already exists" }
        case .celebrations(let to, let from):
            guard to == .subtle, from == .full, s.rewardSettings.level == .full else { return "Celebrations are already turned down" }
            p.from = from.title
            p.to = to.title
        case .grid(let g):
            if let why = GridTidy.refusal(g, grid: s.quickStarts, lastUse: s.quickStartUse, tree: s.categories, now: now) { return why }
        case .aboutMe: break
        }
        return nil
    }

    func perform(_ p: inout LoggedChange, in s: inout DumpState, now: Date) -> String? {
        switch p.change {
        case .knob(let key, let to):
            p.previous = Knobs.value(key, in: s.policy)
            guard case .changed = Knobs.set(key, String(to), by: .reflection, in: &s) else { return "\(key) couldn't be set" }
        case .starterStep(let parent, let title, _, _):
            // v1.2 H4: the first step is named on the task itself (reminders say it), not added as another task.
            guard let i = s.items.firstIndex(where: { $0.id == parent }) else { return "No task" }
            p.previousText = s.items[i].firstStep
            s.items[i].firstStep = title
        case .intention(let intent):
            s.policy.intentions.append(intent)
        case .beliefGroup(let g, let ev):
            var g = g
            g.createdBy = "reflection"
            g.createdAt = now
            g.note = ev.joined(separator: "; ")
            s.beliefs.groups.append(g)
        case .celebrations(let to, _):
            s.rewardSettings.level = to
        case .grid(let g):
            let r = GridTidy.apply(g, to: &s.quickStarts, now: now)
            p.created = r.created
            p.previousText = r.previous
        case .aboutMe(let section, let text):
            guard case .success = s.aboutMe.apply(AboutMeFact(section: section.rawValue, text: text), by: .reflection, now: now) else {
                return "About-me line refused: \(text.prefix(40))"
            }
        }
        return nil
    }

    public mutating func revert(_ id: UUID, in s: inout DumpState, now: Date) -> Bool {
        guard let i = changes.firstIndex(where: { $0.id == id && $0.status == .applied }) else { return false }
        let p = changes[i]
        switch p.change {
        case .knob(let key, _):
            guard let prev = p.previous else { return false }
            Knobs.write(key, prev, in: &s.policy)
        case .starterStep(let parent, let title, _, _):
            if let i = s.items.firstIndex(where: { $0.id == parent }), s.items[i].firstStep == title { s.items[i].firstStep = p.previousText }
        case .intention(let intent):
            s.policy.intentions.removeAll { $0.id == intent.id }
        case .beliefGroup(let g, _):
            s.beliefs.groups.removeAll { $0.id == g.id }
            s.beliefs.items.removeAll { $0.group == g.id }
        case .celebrations(_, let from):
            s.rewardSettings.level = from
        case .grid(let g):
            GridTidy.revert(g, created: p.created, previous: p.previousText, in: &s.quickStarts)
        case .aboutMe(let section, let text):
            s.aboutMe[section].removeAll { $0.text.plainKey == text.plainKey && !$0.byStudent }
        }
        changes[i].status = .reverted
        changes[i].revertedAt = now
        return true
    }

    /// "Never change this": undoes the change if it's still applied and pins what it changed.
    public mutating func neverChange(_ id: UUID, in s: inout DumpState, now: Date) {
        guard let p = changes.first(where: { $0.id == id }) else { return }
        _ = revert(id, in: &s, now: now)
        pinned.insert(p.change.target)
    }

    public mutating func unpin(_ target: String) { pinned.remove(target) }

    enum CodingKeys: String, CodingKey { case changes, runs, pinned }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        changes = (try? c.decode([LoggedChange].self, forKey: .changes)) ?? []
        runs = (try? c.decode([InsightRun].self, forKey: .runs)) ?? []
        _pinned = (try? c.decode(SortedSet<String>.self, forKey: .pinned)) ?? SortedSet(wrappedValue: [])
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(changes, forKey: .changes)
        try c.encode(runs, forKey: .runs)
        try c.encode(_pinned, forKey: .pinned)
    }
}
