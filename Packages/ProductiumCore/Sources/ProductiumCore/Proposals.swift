import Foundation

public enum ProposalChange: Codable, Hashable, Sendable {
    case knob(key: String, to: Double)
    case starterStep(parent: UUID, title: String, minutes: Int, due: Date)
    case intention(IntentionNudge)
    case beliefGroup(BeliefGroup, evidence: [String])
    case aboutMe(section: AboutMeSection, text: String)

    var isAboutMe: Bool { if case .aboutMe = self { return true }; return false }
    var isBeliefGroup: Bool { if case .beliefGroup = self { return true }; return false }

    public var target: String {
        switch self {
        case .knob(let k, _): return k
        case .starterStep(let p, _, _, _): return "step:\(p.uuidString)"
        case .intention(let i): return "intention:\(i.itemId?.uuidString ?? i.text)"
        case .beliefGroup: return "group"
        case .aboutMe(_, let t): return "about:\(t.prefix(40))"
        }
    }
}

public enum ProposalStatus: String, Codable, Sendable { case pending, approved, rejected, reverted, expired }

public struct BehaviourProposal: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var runId: UUID
    public var change: ProposalChange
    public var from: String
    public var to: String
    public var reason: String
    public var evidence: [String]
    public var model: String
    public var at: Date
    public var status: ProposalStatus
    public var decidedAt: Date?
    public var created: UUID?
    public var previous: Double?

    public init(id: UUID = UUID(), runId: UUID, change: ProposalChange, from: String, to: String, reason: String,
                evidence: [String], model: String, at: Date) {
        self.id = id
        self.runId = runId
        self.change = change
        self.from = from
        self.to = to
        self.reason = reason
        self.evidence = evidence
        self.model = model
        self.at = at
        self.status = .pending
    }

    public var title: String {
        switch change {
        case .knob(let k, _): return "\(Registry.knob(k)?.note.capitalizedFirst ?? k): \(from) → \(to)"
        case .starterStep(_, let t, let m, _): return "Add a \(m)-minute first step: \(t)"
        case .intention(let i): return "Remind you: \(i.text)"
        case .beliefGroup(let g, _): return "Start noticing: \(g.title)"
        case .aboutMe(let s, let t): return "Add to About You (\(s.rawValue)): \(t)"
        }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

public struct ReflectionRun: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var at: Date
    public var note: String
    public var model: String
    public init(id: UUID = UUID(), at: Date, note: String, model: String) { self.id = id; self.at = at; self.note = note; self.model = model }
}

public struct ProposalBook: Codable, Hashable, Sendable {
    public var proposals: [BehaviourProposal]
    public var runs: [ReflectionRun]
    @SortedSet public var pinned: Set<String>
    public var pausedUntil: Date?

    public static let maxPerRun = 3
    public static let sameKnobDays = 7.0
    public static let expiryDays = 7.0
    public static let noRepeatDays = 30.0

    public init(proposals: [BehaviourProposal] = [], runs: [ReflectionRun] = [], pinned: Set<String> = [], pausedUntil: Date? = nil) {
        self.proposals = proposals
        self.runs = runs
        self.pinned = pinned
        self.pausedUntil = pausedUntil
    }

    public var pending: [BehaviourProposal] { proposals.filter { $0.status == .pending } }
    public var history: [BehaviourProposal] {
        proposals.filter { $0.status == .approved || $0.status == .reverted }.sorted { ($0.decidedAt ?? $0.at) > ($1.decidedAt ?? $1.at) }
    }

    public mutating func expire(now: Date) {
        for i in proposals.indices where proposals[i].status == .pending
            && now.timeIntervalSince(proposals[i].at) > Self.expiryDays * 86400 {
            proposals[i].status = .expired
            proposals[i].decidedAt = now
        }
    }

    public var feedback: [String] {
        proposals.filter { $0.status == .rejected || $0.status == .reverted }.suffix(10).map {
            "\($0.status == .rejected ? "Rejected" : "Reverted"): \($0.title) (\($0.reason))"
        }
    }

    @discardableResult
    public mutating func submit(_ run: ReflectionRun, _ drafts: [BehaviourProposal], state s: DumpState, now: Date) -> [String] {
        expire(now: now)
        var problems: [String] = []
        var accepted: [BehaviourProposal] = []
        for var p in drafts {
            if case .aboutMe(let section, let text) = p.change {
                guard section == .inferred || section == .patterns, !text.isEmpty,
                      accepted.filter(\.change.isAboutMe).count < 3 else {
                    problems.append("About-me line refused: \(text.prefix(40))"); continue
                }
                guard !s.aboutMe[section].contains(where: { $0.text.plainKey == text.plainKey }) else { continue }
                p.runId = run.id
                p.status = .pending
                accepted.append(p)
                continue
            }
            guard accepted.filter({ !$0.change.isAboutMe }).count < Self.maxPerRun else { problems.append("More than \(Self.maxPerRun) in one run: \(p.title)"); continue }
            let t = p.change.target
            if pinned.contains(t) { problems.append("\(t) is pinned"); continue }
            if proposals.contains(where: { $0.change.target == t && $0.status == .approved
                && now.timeIntervalSince($0.decidedAt ?? $0.at) < Self.sameKnobDays * 86400 }) {
                problems.append("\(t) changed in the last 7 days"); continue
            }
            if accepted.contains(where: { $0.change.target == t }) || pending.contains(where: { $0.change.target == t }) {
                problems.append("\(t) already has a suggestion waiting"); continue
            }
            if proposals.contains(where: { $0.change == p.change && ($0.status == .rejected || $0.status == .reverted)
                && now.timeIntervalSince($0.decidedAt ?? $0.at) < Self.noRepeatDays * 86400 }) {
                problems.append("Already turned down: \(p.title)"); continue
            }
            switch p.change {
            case .knob(let key, let target):
                guard let spec = Registry.knob(key), spec.tier == .behaviour, !spec.reflectionForbidden,
                      let cur = Knobs.value(spec.key, in: s.policy) else { problems.append("\(key) isn't a behaviour knob"); continue }
                let v = Knobs.bounded(spec, from: cur, to: target)
                guard v != cur else { problems.append("\(key) is already \(Knobs.format(cur))"); continue }
                p.change = .knob(key: spec.key, to: v)
                p.from = Knobs.format(cur)
                p.to = Knobs.format(v)
            case .starterStep(let parent, let title, let minutes, _):
                guard let task = s.items.first(where: { $0.id == parent && !$0.isDone }), !title.isEmpty else {
                    problems.append("No open task for a first step"); continue
                }
                guard minutes >= 5, minutes <= 20 else { problems.append("A first step is 5-20 minutes"); continue }
                p.from = task.title
                p.to = title
            case .intention(let i):
                guard !i.text.trimmingCharacters(in: .whitespaces).isEmpty, i.trigger == .arriveHome || i.time != nil else {
                    problems.append("A reminder needs text and a time"); continue
                }
                guard s.policy.intentions.count < 3 else { problems.append("Three reminders already"); continue }
            case .aboutMe: break
            case .beliefGroup(let g, let ev):
                guard ev.count >= 3 else { problems.append("A new group needs 3 pieces of evidence"); continue }
                if accepted.contains(where: \.change.isBeliefGroup) || proposals.contains(where: {
                    $0.change.isBeliefGroup && $0.status != .rejected && $0.status != .expired && now.timeIntervalSince($0.at) < 7 * 86400 }) {
                    problems.append("One new group a week"); continue
                }
                guard !s.beliefs.groups.contains(where: { $0.id == g.id }) else { problems.append("\(g.title) already exists"); continue }
            }
            p.runId = run.id
            p.status = .pending
            accepted.append(p)
        }
        if !accepted.isEmpty { runs.append(run) }
        proposals += accepted
        return problems
    }

    public mutating func approve(_ id: UUID, in s: inout DumpState, now: Date, calendar cal: Calendar) -> Bool {
        guard let i = proposals.firstIndex(where: { $0.id == id && $0.status == .pending }) else { return false }
        var p = proposals[i]
        switch p.change {
        case .knob(let key, let to):
            p.previous = Knobs.value(key, in: s.policy)
            guard case .changed = Knobs.set(key, String(to), by: .reflection, in: &s) else { return false }
        case .starterStep(let parent, let title, let minutes, let due):
            guard let task = s.items.first(where: { $0.id == parent }) else { return false }
            let step = WorkItem(title: title, kind: .chore, subject: task.subject, due: min(due, task.due), estimateMinutes: minutes,
                                importance: task.importance, difficulty: 1, parentId: parent, source: .ai)
            s.items.append(step)
            p.created = step.id
        case .intention(let intent):
            s.policy.intentions.append(intent)
        case .beliefGroup(let g, let ev):
            var g = g
            g.createdBy = "reflection"
            g.createdAt = now
            g.note = ev.joined(separator: "; ")
            s.beliefs.groups.append(g)
        case .aboutMe(let section, let text):
            guard case .success = s.aboutMe.apply(AboutMeFact(section: section.rawValue, text: text), by: .reflection, now: now) else { return false }
        }
        p.status = .approved
        p.decidedAt = now
        proposals[i] = p
        return true
    }

    public mutating func reject(_ id: UUID, now: Date) {
        guard let i = proposals.firstIndex(where: { $0.id == id && $0.status == .pending }) else { return }
        proposals[i].status = .rejected
        proposals[i].decidedAt = now
        checkPause(now: now)
    }

    public mutating func neverChange(_ id: UUID, now: Date) {
        guard let p = proposals.first(where: { $0.id == id }) else { return }
        pinned.insert(p.change.target)
        reject(id, now: now)
    }

    public mutating func revert(_ id: UUID, in s: inout DumpState, now: Date) -> Bool {
        guard let i = proposals.firstIndex(where: { $0.id == id && $0.status == .approved }) else { return false }
        let p = proposals[i]
        switch p.change {
        case .knob(let key, _):
            guard let prev = p.previous else { return false }
            Knobs.write(key, prev, in: &s.policy)
        case .starterStep:
            if let c = p.created { s.items.removeAll { $0.id == c && !$0.isDone } }
        case .intention(let intent):
            s.policy.intentions.removeAll { $0.id == intent.id }
        case .beliefGroup(let g, _):
            s.beliefs.groups.removeAll { $0.id == g.id }
            s.beliefs.items.removeAll { $0.group == g.id }
        case .aboutMe(let section, let text):
            s.aboutMe[section].removeAll { $0.text.plainKey == text.plainKey && !$0.byStudent }
        }
        proposals[i].status = .reverted
        proposals[i].decidedAt = now
        return true
    }

    mutating func checkPause(now: Date) {
        let decided = runs.filter { r in !proposals.contains { $0.runId == r.id && $0.status == .pending } }.suffix(2)
        guard decided.count == 2 else { return }
        let allRejected = decided.allSatisfy { r in
            let ps = proposals.filter { $0.runId == r.id }
            return !ps.isEmpty && ps.allSatisfy { $0.status == .rejected }
        }
        if allRejected { pausedUntil = now.addingTimeInterval(7 * 86400) }
    }

    public func isPaused(now: Date) -> Bool { pausedUntil.map { now < $0 } ?? false }
}
