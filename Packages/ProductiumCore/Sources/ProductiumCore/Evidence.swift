import Foundation

public struct ProgressEntry: Codable, Hashable, Identifiable, Sendable {
    public enum Source: String, Codable, Sendable { case task, evidence }

    public var id: UUID
    public var at: Date
    public var itemId: UUID?
    public var minutes: Int
    public var from: Int?
    public var to: Int?
    public var source: Source
    public var estimated: Bool
    public var note: String?
    public var turnId: UUID?

    public init(id: UUID = UUID(), at: Date, itemId: UUID? = nil, minutes: Int, from: Int? = nil, to: Int? = nil,
                source: Source, estimated: Bool = false, note: String? = nil, turnId: UUID? = nil) {
        self.id = id
        self.at = at
        self.itemId = itemId
        self.minutes = minutes
        self.from = from
        self.to = to
        self.source = source
        self.estimated = estimated
        self.note = note
        self.turnId = turnId
    }
}

extension Array where Element == ProgressEntry {
    public func minutes(on day: Date, calendar: Calendar) -> Int {
        Swift.max(0, filter { calendar.isDate($0.at, inSameDayAs: day) }.reduce(0) { $0 + $1.minutes })
    }
}

public enum EvidenceRouter {
    static func route(_ r: DumpResult, to s: inout DumpState, now: Date, calendar cal: Calendar, writer: Writer,
                      touchedItems: Set<UUID>, turnId: UUID?, report rep: inout DumpReport) {
        for f in r.facts {
            switch s.aboutMe.apply(f, by: writer, now: now) {
            case .success(let line): if line.hasPrefix("Noted") { rep.changes.append(line) }
            case .failure(let why): rep.problems.append("Didn't note “\(f.text.prefix(60))”: \(why)")
            }
        }
        var newMarkers: [TimelineEvent] = []
        for e in r.evidence {
            newMarkers += route(e, to: &s, now: now, calendar: cal, touchedItems: touchedItems, turnId: turnId, report: &rep)
        }
        guard !newMarkers.isEmpty else { return }
        for day in Set(newMarkers.map { cal.startOfDay(for: $0.at) }) {
            let evs = s.markers.filter { cal.isDate($0.at, inSameDayAs: day) }
            let before = s.routines
            s.routines = RoutineLearner.learn(day: evs, healthWake: nil, routines: s.routines)
            for (a, b) in zip(before, s.routines) where b.samples.count > a.samples.count || b.samples != a.samples {
                if let m = b.samples.last { rep.changes.append("Learned: \(b.name.lowercased()) took \(m) min") }
            }
        }
    }

    static func route(_ e: DumpEvidence, to s: inout DumpState, now: Date, calendar cal: Calendar,
                      touchedItems: Set<UUID>, turnId: UUID?, report rep: inout DumpReport) -> [TimelineEvent] {
        let tz = cal.timeZone
        let start = e.start.flatMap { AIMapper.parseDate($0, timeZone: tz) }.map { min($0, now) }
        var end = e.end.flatMap { AIMapper.parseDate($0, timeZone: tz) }.map { min($0, now) }
        if let st = start, let en = end, en <= st { end = nil }
        let words = e.what.lowercased()
        let kind = kindOf(e.kind, words)
        let task = e.task.flatMap { r in s.items.first { Ref.matches(r, prefix: "t", full: $0.id.uuidString) } }
            ?? DumpApplier.match(e.what, s.items.indices.filter { !s.items[$0].isDone }.map { ($0, s.items[$0].title) }).map { s.items[$0] }
                .flatMap { kind == .study ? $0 : nil }

        if kind == .study {
            let span = start.flatMap { st in end.map { Int($0.timeIntervalSince(st) / 60) } }
            let minutes = e.minutes ?? span
            if let task, touchedItems.contains(task.id) { return [] }
            guard let minutes, minutes > 0 else {
                rep.problems.append("Couldn't count “\(e.what.prefix(60))” as work done: no time given")
                return []
            }
            s.progress.append(ProgressEntry(at: end ?? start ?? now, itemId: task?.id, minutes: min(minutes, 16 * 60),
                                            source: .evidence, estimated: e.estimated == true,
                                            note: e.what, turnId: turnId))
            rep.changes.append("Counted \(minutes) min of work today" + (task.map { " on \($0.title)" } ?? ""))
            return []
        }

        let (activity, category, label) = markerKey(kind, words, start ?? end ?? now, s.commitments, cal)
        var made: [TimelineEvent] = []
        func add(_ at: Date, _ phase: MarkerPhase) {
            let m = TimelineEvent(at: at, phrase: e.what, activity: activity, category: category, phase: phase, source: .voice)
            made += MarkerLog.add([m], to: &s.markers)
        }
        if let st = start { add(st, .start) }
        if let en = end { add(en, .end) }
        if start == nil, end == nil, let m = e.minutes, m > 0 {
            add(now.addingTimeInterval(-Double(m) * 60), .start)
            add(now, .end)
        }
        if !made.isEmpty { rep.changes.append("Logged \(label)") }
        return made
    }

    enum EvidenceKind { case travel, study, activity, sleep, other }

    static func kindOf(_ raw: String?, _ words: String) -> EvidenceKind {
        switch raw?.lowercased() {
        case "travel", "commute", "walk", "transit": return .travel
        case "study", "work", "homework": return .study
        case "activity", "club", "class", "school": return .activity
        case "sleep": return .sleep
        default: break
        }
        if ["walk", "left home", "drove", "bus", "arrived", "got to", "commute", "bike"].contains(where: words.contains) { return .travel }
        if ["slept", "sleep", "bed", "woke"].contains(where: words.contains) { return .sleep }
        if ["worked", "studied", "wrote", "draft", "homework", "revised", "essay", "read "].contains(where: words.contains) { return .study }
        return .other
    }

    static func markerKey(_ kind: EvidenceKind, _ words: String, _ at: Date, _ commitments: [Commitment],
                          _ cal: Calendar) -> (String, TimeCategory, String) {
        switch kind {
        case .travel:
            let hour = cal.component(.hour, from: at)
            let weekday = cal.component(.weekday, from: at)
            let school = commitments.filter { $0.kind == .school && $0.weekdays.contains(weekday) }
            let toSchool = words.contains("school") && !words.contains("from school") && !words.contains("home")
            if let first = school.map(\.start).min(), toSchool || (hour * 60 + cal.component(.minute, from: at) < first.minutesFromMidnight) {
                return ("to_school", .commute, "the trip to school")
            }
            if !school.isEmpty, words.contains("home") || hour >= 12 { return ("from_school", .commute, "the trip home") }
            return ("travel", .commute, "travel")
        case .sleep: return ("sleep", .sleep, "sleep")
        case .activity, .other:
            if let c = commitments.first(where: { words.contains(MarkerParser.normalise($0.title)) }) {
                return (MarkerParser.normalise(c.title), TimeCategory.from(c.kind), c.title)
            }
            let key = words.split(whereSeparator: { !$0.isLetter }).prefix(3).joined(separator: "_")
            let act = key.isEmpty ? "activity" : key
            return (act, MarkerCategory.infer(activity: act, commitments: commitments, model: kind == .activity ? .activities : .free), words)
        case .study: return ("study", .study, "study")
        }
    }
}
