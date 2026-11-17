import Foundation

// MARK: - Short references
//
// The Inbox context lists every task, activity, event and day change with a short reference
// ("t3f9a2"), and actions name what they change by it. Titles still work as a fallback, but an
// id can't match the wrong "Period 2" or miss "School" because the model called it "classes".

public enum Ref {
    public static func task(_ id: UUID) -> String { "t" + short(id.uuidString) }
    public static func activity(_ id: UUID) -> String { "a" + short(id.uuidString) }
    public static func event(_ id: String) -> String { "e" + short(id) }
    public static func dayChange(_ id: UUID) -> String { "d" + short(id.uuidString) }

    static func short(_ s: String) -> String {
        if UUID(uuidString: s) != nil { return String(s.lowercased().filter(\.isHexDigit).prefix(6)) }
        // Not a UUID (a calendar event id): a stable FNV-1a hash, since `hashValue` changes every launch.
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(String(h, radix: 16).prefix(6))
    }

    /// True when `ref` (with or without its letter, or a full UUID) names `full`.
    static func matches(_ ref: String, prefix: Character, full: String) -> Bool {
        let r = ref.trimmingCharacters(in: .whitespaces).lowercased()
        guard !r.isEmpty else { return false }
        if r == full.lowercased() { return true }
        let mine = short(full)
        if r == "\(prefix)\(mine)" { return true }
        let bare = r.first == prefix ? String(r.dropFirst()) : r
        return bare.count >= 4 && bare.allSatisfy(\.isHexDigit) && mine.hasPrefix(bare)
    }
}

/// What applying a reply did: the lines for the receipt, and what it couldn't do (so the reply
/// can't claim a change that didn't happen).
public struct DumpReport: Hashable, Sendable {
    public var changes: [String] = []
    public var problems: [String] = []
    public init(changes: [String] = [], problems: [String] = []) { self.changes = changes; self.problems = problems }
}

// MARK: - Applying a reply

public enum DumpApplier {
    static func timeOfDay(_ v: String?) -> TimeOfDay? {
        guard var v = v?.trimmingCharacters(in: .whitespaces).lowercased(), !v.isEmpty else { return nil }
        let pm = v.hasSuffix("pm"), am = v.hasSuffix("am")
        if pm || am { v = String(v.dropLast(2)).trimmingCharacters(in: .whitespaces) }
        let p = v.split(separator: ":").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard var h = p.first, (0...23).contains(h) else { return nil }
        if pm && h < 12 { h += 12 }
        if am && h == 12 { h = 0 }
        let m = p.count > 1 ? p[1] : 0
        guard (0...59).contains(m) else { return nil }
        return TimeOfDay(h, m)
    }

    /// Applies every operation it can, in order. Later operations see earlier ones (a task added
    /// first can be changed next). `writer` decides which tiers are allowed (see Capabilities).
    @discardableResult
    public static func apply(_ r: DumpResult, to s: inout DumpState, now: Date, calendar cal: Calendar,
                             writer: Writer = .box, turnId: UUID? = nil) -> DumpReport {
        var rep = DumpReport()
        let before = Dictionary(s.items.map { ($0.id, $0.completedMinutes) }, uniquingKeysWith: { a, _ in a })
        for op in r.ops { apply(op, to: &s, now: now, calendar: cal, writer: writer, report: &rep) }
        // Every change to a task's minutes done is work logged now (or a correction of it).
        var touched: Set<UUID> = []
        for item in s.items {
            let was = before[item.id] ?? 0
            guard item.completedMinutes != was else { continue }
            touched.insert(item.id)
            s.progress.append(ProgressEntry(at: now, itemId: item.id, minutes: item.completedMinutes - was, from: was,
                                            to: item.completedMinutes, source: .task, turnId: turnId))
        }
        EvidenceRouter.route(r, to: &s, now: now, calendar: cal, writer: writer, touchedItems: touched, turnId: turnId, report: &rep)
        return rep
    }

    /// The entity an operation is about: named, or read off its id's letter ("t3f9a2" is a task).
    static func entity(of op: DumpOp, _ s: DumpState) -> EntitySpec? {
        if let e = Registry.entity(op.entity) { return e }
        guard let id = op.id?.lowercased(), let first = id.first, id.count >= 5, id.dropFirst().allSatisfy(\.isHexDigit) else {
            if let id = op.id, s.routines.contains(where: { $0.id == id }) { return Registry.entity("routine") }
            return nil
        }
        return Registry.entities.first { $0.refPrefix == String(first) }
    }

    static func apply(_ op: DumpOp, to s: inout DumpState, now: Date, calendar cal: Calendar, writer: Writer,
                      report rep: inout DumpReport) {
        guard let kind = DumpOpKind(loose: op.op) else {
            rep.problems.append("Skipped an unknown operation “\(op.op)”")
            return
        }
        if kind == .set {
            guard let k = op.knob ?? op.fields?["knob"].flatMap({ if case .string(let v) = $0 { return v }; return nil }),
                  let v = op.value ?? op.fields?["value"].flatMap({ if case .string(let v) = $0 { return v }; return nil }) else {
                rep.problems.append("A setting needs a knob and a value"); return
            }
            switch Knobs.set(k, v, by: writer, in: &s) {
            case .changed(let line): rep.changes.append("Setting: \(line)")
            case .refused(let why): rep.problems.append(why)
            }
            return
        }
        guard let spec = entity(of: op, s) else {
            rep.problems.append("Skipped “\(op.op)”: it doesn't say what it's about (entity)")
            return
        }
        guard writer.mayApply(spec.tier) else {
            rep.problems.append("Changing \(spec.name)s isn't allowed from here"); return
        }
        let a = DumpFields.read(op)
        let h = Handlers(now: now, cal: cal)
        switch (kind, spec.name) {
        case (.split, "activity"): h.splitActivity(a, &s, &rep)
        case (.split, _): rep.problems.append("Only an activity can be split")
        case (.upsert, "task"): h.upsertTask(a, &s, &rep)
        case (.upsert, "activity"): h.upsertActivity(a, &s, &rep)
        case (.upsert, "event"): h.upsertEvent(a, &s, &rep)
        case (.upsert, "day_change"): h.changeDay(a, &s, &rep)
        case (.upsert, "marker"): h.log(a, &s, &rep)
        case (.upsert, "mood"): h.mood(a, &s, &rep)
        case (.upsert, "screen_time"): h.screenTime(a, &s, &rep)
        case (.upsert, "routine"): h.routine(a, &s, &rep)
        case (.delete, "task"): h.deleteTask(a, &s, &rep)
        case (.delete, "activity"): h.deleteActivity(a, &s, &rep)
        case (.delete, "event"): h.deleteEvent(a, &s, &rep)
        case (.delete, "day_change"): h.deleteDayChange(a, &s, &rep)
        case (.delete, let e): rep.problems.append("A \(e.replacingOccurrences(of: "_", with: " ")) can't be deleted")
        default: rep.problems.append("Skipped “\(op.op)” on \(spec.name)")
        }
    }

    /// One handler per entity and operation. They share the lookups.
    struct Handlers {
        let now: Date
        let cal: Calendar
        var tz: TimeZone { cal.timeZone }

        func tod(_ v: String?) -> TimeOfDay? { DumpApplier.timeOfDay(v) }
        func day(_ v: String?) -> Date {
            guard let v, let d = AIMapper.parseDate(v, timeZone: tz) else { return cal.startOfDay(for: now) }
            return cal.startOfDay(for: d)
        }
        func when(_ v: String?) -> Date {
            guard let v, let d = AIMapper.parseDate(v, timeZone: tz) else { return now }
            // A bare date parses to 23:59, and a moment in the future isn't a log. Keep it sane.
            return min(d, now)
        }
        func weekdays(_ w: [Int]?) -> Set<Int>? {
            guard let w else { return nil }
            let set = Set(w.filter { (1...7).contains($0) })
            return set.isEmpty ? nil : set
        }
        func colour(_ raw: String?) -> String?? {
            // nil = not mentioned, .some(nil) = back to default
            guard let raw else { return nil }
            let l = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if ["", "default", "none", "reset", "auto", "clear"].contains(l) { return .some(nil) }
            guard let c = Palette.normalise(raw) else { return nil }
            return .some(c)
        }
        func ref(_ a: DumpFields) -> String? {
            if let id = a.id, !id.isEmpty { return id }
            // A model sometimes puts the reference in `target`.
            if let t = a.target, t.count <= 8, t.count >= 5, t.dropFirst().allSatisfy(\.isHexDigit) { return t }
            return nil
        }
        func name(_ a: DumpFields) -> String? { a.target ?? a.title }
        func norm(_ t: String) -> String { t.lowercased().filter { $0.isLetter || $0.isNumber } }
        func missing(_ what: String, _ a: DumpFields, _ rep: inout DumpReport) {
            rep.problems.append("Couldn't find \(what) “\(ref(a) ?? name(a) ?? "?")”")
        }

        func taskIndex(_ a: DumpFields, _ s: DumpState, includeDone: Bool = false, byName: Bool = true) -> Int? {
            if let r = ref(a) { return s.items.firstIndex { Ref.matches(r, prefix: "t", full: $0.id.uuidString) } }
            guard byName else { return nil }
            let pool = s.items.indices.filter {
                includeDone || !s.items[$0].isDone || s.items[$0].doneAt.map { now.timeIntervalSince($0) < 86400 } == true
            }
            return DumpApplier.match(name(a), pool.map { ($0, s.items[$0].title) })
        }
        func activityIndex(_ a: DumpFields, _ s: DumpState) -> Int? {
            if let r = ref(a) { return s.commitments.firstIndex { Ref.matches(r, prefix: "a", full: $0.id.uuidString) } }
            return activityIndex(named: name(a), s)
        }
        func activityIndex(named n: String?, _ s: DumpState) -> Int? {
            DumpApplier.match(n, s.commitments.indices.map { ($0, s.commitments[$0].title) })
        }
        func eventIndex(_ a: DumpFields, _ s: DumpState) -> Int? {
            if let r = ref(a) { return s.oneOffs.firstIndex { Ref.matches(r, prefix: "e", full: $0.id) } }
            return DumpApplier.match(name(a), s.oneOffs.indices.filter { s.oneOffs[$0].end > now }.map { ($0, s.oneOffs[$0].title) })
        }

        // MARK: Tasks

        func upsertTask(_ a: DumpFields, _ s: inout DumpState, _ rep: inout DumpReport) {
            // An id names an existing task. Without one, a target name, or a title with no due date
            // that matches an open task, is a change to it; anything else is new.
            if ref(a) != nil {
                guard let i = taskIndex(a, s, includeDone: true) else { missing("task", a, &rep); return }
                updateTask(i, a, &s, &rep, rename: true)
            } else if a.target != nil || a.due == nil, let i = taskIndex(a, s) {
                updateTask(i, a, &s, &rep, rename: a.target != nil)
            } else {
                addTask(a, &s, &rep)
            }
        }

        func addTask(_ a: DumpFields, _ s: inout DumpState, _ rep: inout DumpReport) {
            let p = ParsedItem(title: a.title ?? a.target ?? "", kind: a.kind ?? "other", subject: a.subject, due: a.due ?? "",
                               estimateMinutes: a.estimateMinutes, importance: a.importance, difficulty: a.difficulty, topics: a.topics)
            let parent = a.parent.flatMap { r in s.items.first { Ref.matches(r, prefix: "t", full: $0.id.uuidString) } }
            guard var item = AIMapper.item(p, timeZone: tz, parentId: parent?.id) else {
                rep.problems.append("Couldn't add “\(a.title ?? "a task")”: it needs a title and a due date")
                return
            }
            item.notes = a.notes
            if let m = a.doneMinutes { item.completedMinutes = max(0, m) }
            if case .some(let c)? = colour(a.color) { item.color = c }
            if let parent { item.due = min(item.due, parent.due); item.subject = item.subject ?? parent.subject }
            if let i = s.items.firstIndex(where: { !$0.isDone && norm($0.title) == norm(item.title) && $0.parentId == item.parentId }) {
                // Already there: an update, never a second copy.
                s.items[i].due = item.due
                if a.estimateMinutes != nil { s.items[i].estimateMinutes = item.estimateMinutes }
                if a.color != nil { s.items[i].color = item.color }
                rep.changes.append("Updated \(item.title)")
            } else {
                if a.done == true { item.isDone = true; item.doneAt = now }
                s.items.append(item)
                rep.changes.append(parent.map { "Added step to \($0.title): \(item.title)" } ?? "Added \(item.title)")
            }
        }

        func updateTask(_ i: Int, _ a: DumpFields, _ s: inout DumpState, _ rep: inout DumpReport, rename: Bool) {
            var changed = false
            if let t = a.title, !t.isEmpty, rename, t != s.items[i].title { s.items[i].title = String(t.prefix(120)); changed = true }
            if let k = a.kind.flatMap(TaskKind.init(rawValue:)) { s.items[i].kind = k; changed = true }
            if let v = a.subject { s.items[i].subject = v.isEmpty ? nil : v; changed = true }
            if let d = a.due.flatMap({ AIMapper.parseDate($0, timeZone: tz) }) { s.items[i].due = d; changed = true }
            if let m = a.estimateMinutes { s.items[i].estimateMinutes = max(5, min(3000, m)); changed = true }
            if let m = a.importance { s.items[i].importance = max(1, min(5, m)); changed = true }
            if let m = a.difficulty { s.items[i].difficulty = max(1, min(3, m)); changed = true }
            // Absolute, so saying "200 minutes so far" twice leaves 200.
            if let m = a.doneMinutes { s.items[i].completedMinutes = max(0, m); changed = true }
            if let t = a.topics { s.items[i].topics = t; changed = true }
            if let n = a.notes { s.items[i].notes = n.isEmpty ? nil : n; changed = true }
            if case .some(let c)? = colour(a.color) { s.items[i].color = c; changed = true }
            if changed { rep.changes.append("Changed \(s.items[i].title)") }
            switch a.done {
            case true?:
                guard !s.items[i].isDone else { break }
                s.items[i].isDone = true
                s.items[i].doneAt = now
                rep.changes.append("Done: \(s.items[i].title)")
                if let p = s.items[i].parentId, !s.items.contains(where: { $0.parentId == p && !$0.isDone }),
                   let j = s.items.firstIndex(where: { $0.id == p }), !s.items[j].isDone {
                    s.items[j].isDone = true
                    s.items[j].doneAt = now
                    rep.changes.append("Done: \(s.items[j].title)")
                }
            case false?:
                guard s.items[i].isDone else { break }
                s.items[i].isDone = false
                s.items[i].doneAt = nil
                rep.changes.append("Not done: \(s.items[i].title)")
            case nil: break
            }
        }

        func deleteTask(_ a: DumpFields, _ s: inout DumpState, _ rep: inout DumpReport) {
            guard let i = taskIndex(a, s, includeDone: true) else { missing("task", a, &rep); return }
            let id = s.items[i].id
            rep.changes.append("Removed \(s.items[i].title)")
            s.items.removeAll { $0.id == id || $0.parentId == id }
        }

        // MARK: Activities

        func upsertActivity(_ a: DumpFields, _ s: inout DumpState, _ rep: inout DumpReport) {
            if ref(a) != nil {
                guard let i = activityIndex(a, s) else { missing("activity", a, &rep); return }
                updateActivity(i, a, &s, &rep, rename: true)
            } else if a.target != nil, let i = activityIndex(a, s) {
                updateActivity(i, a, &s, &rep, rename: true)
            } else if a.weekdays == nil || a.start == nil, let i = activityIndex(a, s) {
                updateActivity(i, a, &s, &rep, rename: false)
            } else {
                addActivity(a, &s, &rep)
            }
        }

        func addActivity(_ a: DumpFields, _ s: inout DumpState, _ rep: inout DumpReport) {
            guard var c = AIMapper.commitment(ParsedCommitment(title: a.title ?? "", kind: a.kind ?? "extracurricular",
                                                               weekdays: a.weekdays ?? [], start: a.start ?? "", end: a.end ?? "")) else {
                rep.problems.append("Couldn't add “\(a.title ?? "an activity")”: it needs days, a start and an end after it")
                return
            }
            if let b = a.bufferMinutes { c.bufferMinutes = max(0, min(90, b)) }
            if case .some(let col)? = colour(a.color) { c.color = col }
            c.validFrom = a.validFrom.flatMap { AIMapper.parseDate($0, timeZone: tz) }.map { cal.startOfDay(for: $0) }
            c.validUntil = a.validUntil.flatMap { AIMapper.parseDate($0, timeZone: tz) }
            // Same name on overlapping days is the same activity: update it instead of adding a twin.
            if let i = s.commitments.firstIndex(where: { norm($0.title) == norm(c.title) && !$0.weekdays.isDisjoint(with: c.weekdays) }) {
                let id = s.commitments[i].id
                c.id = id
                if a.color == nil { c.color = s.commitments[i].color }
                if a.bufferMinutes == nil { c.bufferMinutes = s.commitments[i].bufferMinutes }
                s.commitments[i] = c
                rep.changes.append("Updated \(c.title) (it was already in your week)")
            } else {
                s.commitments.append(c)
                rep.changes.append("Added \(c.title) to your week")
            }
        }

        func updateActivity(_ i: Int, _ a: DumpFields, _ s: inout DumpState, _ rep: inout DumpReport, rename: Bool) {
            var c = s.commitments[i]
            if let w = weekdays(a.weekdays) { c.weekdays = w }
            if let t = tod(a.start) { c.start = t }
            if let t = tod(a.end) { c.end = t }
            if let t = a.title, !t.isEmpty, rename { c.title = t }
            if let k = a.kind.flatMap(CommitmentKind.init(rawValue:)) { c.kind = k }
            if let b = a.bufferMinutes { c.bufferMinutes = max(0, min(90, b)) }
            if case .some(let col)? = colour(a.color) { c.color = col }
            if let v = a.validFrom { c.validFrom = AIMapper.parseDate(v, timeZone: tz).map { cal.startOfDay(for: $0) } }
            if let v = a.validUntil { c.validUntil = AIMapper.parseDate(v, timeZone: tz) }
            guard c.end > c.start else { rep.problems.append("\(c.title) would end before it starts, so it wasn't changed"); return }
            guard c != s.commitments[i] else { return }   // already like that
            s.commitments[i] = c
            rep.changes.append("Changed \(c.title)")
        }

        func deleteActivity(_ a: DumpFields, _ s: inout DumpState, _ rep: inout DumpReport) {
            guard let i = activityIndex(a, s) else { missing("activity", a, &rep); return }
            rep.changes.append("Removed \(s.commitments[i].title)")
            let id = s.commitments[i].id
            s.commitments.remove(at: i)
            s.exceptions.removeAll { $0.commitmentId == id }
        }

        /// The `split` macro: one activity into parts (school into periods). Expands into
        /// upserts of the parts and a delete (or narrowing) of the original.
        func splitActivity(_ a: DumpFields, _ s: inout DumpState, _ rep: inout DumpReport) {
            guard let i = activityIndex(a, s) else { missing("activity", a, &rep); return }
            let original = s.commitments[i]
            var made: [Commitment] = []
            for p in a.parts ?? [] {
                guard let st = tod(p.start), let en = tod(p.end), en > st, !p.title.isEmpty else {
                    rep.problems.append("Skipped part “\(p.title)”: it needs a start and a later end"); continue
                }
                var c = Commitment(title: p.title, kind: original.kind, weekdays: weekdays(p.weekdays) ?? original.weekdays,
                                   start: st, end: en, bufferMinutes: original.bufferMinutes,
                                   validFrom: original.validFrom, validUntil: original.validUntil, color: original.color)
                if case .some(let col)? = colour(p.color ?? a.color) { c.color = col }
                made.append(c)
            }
            guard !made.isEmpty else { rep.problems.append("Couldn't split \(original.title): no usable parts"); return }
            // Days none of the parts cover keep the original as it was.
            let covered = made.reduce(into: Set<Int>()) { $0.formUnion($1.weekdays) }
            let left = original.weekdays.subtracting(covered)
            if left.isEmpty {
                s.commitments.remove(at: i)
            } else {
                s.commitments[i].weekdays = left
            }
            // Replace any earlier parts with the same names (re-splitting never doubles up).
            for c in made {
                if let j = s.commitments.firstIndex(where: { $0.id != original.id && norm($0.title) == norm(c.title)
                    && !$0.weekdays.isDisjoint(with: c.weekdays) }) {
                    var updated = c
                    updated.id = s.commitments[j].id
                    s.commitments[j] = updated
                } else {
                    s.commitments.append(c)
                }
            }
            // A cancelled day for the whole thing cancels every part; changed times can't be split.
            let partIds = s.commitments.filter { c in made.contains { norm($0.title) == norm(c.title) } }.map(\.id)
            let old = s.exceptions.filter { $0.commitmentId == original.id }
            if left.isEmpty { s.exceptions.removeAll { $0.commitmentId == original.id } }
            for e in old where e.cancelled {
                for pid in partIds where !s.exceptions.contains(where: { $0.commitmentId == pid && cal.isDate($0.day, inSameDayAs: e.day) }) {
                    s.exceptions.append(DayException(day: e.day, commitmentId: pid, cancelled: true, note: e.note))
                }
            }
            if old.contains(where: { !$0.cancelled }) && left.isEmpty {
                rep.problems.append("Changed times on single days for \(original.title) were cleared; set them again per part")
            }
            let dayNames = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
            rep.changes.append("Split \(original.title) into \(made.count) parts"
                               + (left.isEmpty ? "" : " (\(left.sorted().map { dayNames[$0] }.joined(separator: "/")) unchanged)"))
        }

        // MARK: Events

        func upsertEvent(_ a: DumpFields, _ s: inout DumpState, _ rep: inout DumpReport) {
            if ref(a) != nil || a.target != nil {
                guard let i = eventIndex(a, s) else { missing("event (calendar events are changed in Calendar)", a, &rep); return }
                updateEvent(i, a, &s, &rep)
            } else {
                addEvent(a, &s, &rep)
            }
        }

        func addEvent(_ a: DumpFields, _ s: inout DumpState, _ rep: inout DumpReport) {
            let d = day(a.date)
            guard let st = tod(a.start), let en = tod(a.end),
                  let sd = cal.date(bySettingHour: st.hour, minute: st.minute, second: 0, of: d),
                  let ed0 = cal.date(bySettingHour: en.hour, minute: en.minute, second: 0, of: d) else {
                rep.problems.append("Couldn't add “\(a.title ?? "an event")”: it needs a date, start and end"); return
            }
            let ed = ed0 > sd ? ed0 : ed0.addingTimeInterval(86400)   // 22:00-01:00 runs past midnight
            let title = a.title ?? "Busy"
            if let i = s.oneOffs.firstIndex(where: { norm($0.title) == norm(title) && cal.isDate($0.start, inSameDayAs: sd) }) {
                s.oneOffs[i].start = sd
                s.oneOffs[i].end = ed
                if case .some(let c)? = colour(a.color) { s.oneOffs[i].color = c }
                rep.changes.append("Updated \(title)")
            } else {
                var ev = FixedEvent(id: UUID().uuidString, title: title, start: sd, end: ed,
                                    kind: a.kind.flatMap(CommitmentKind.init(rawValue:)) ?? .other)
                if case .some(let c)? = colour(a.color) { ev.color = c }
                s.oneOffs.append(ev)
                rep.changes.append("Added \(title)")
            }
        }

        func updateEvent(_ i: Int, _ a: DumpFields, _ s: inout DumpState, _ rep: inout DumpReport) {
            var ev = s.oneOffs[i]
            let d = a.date.map { day($0) } ?? cal.startOfDay(for: ev.start)
            let st = tod(a.start) ?? TimeOfDay(cal.component(.hour, from: ev.start), cal.component(.minute, from: ev.start))
            let en = tod(a.end) ?? TimeOfDay(cal.component(.hour, from: ev.end), cal.component(.minute, from: ev.end))
            if let sd = cal.date(bySettingHour: st.hour, minute: st.minute, second: 0, of: d),
               let ed = cal.date(bySettingHour: en.hour, minute: en.minute, second: 0, of: d) {
                ev.start = sd
                ev.end = ed > sd ? ed : ed.addingTimeInterval(86400)
            }
            if let t = a.title, !t.isEmpty { ev.title = t }
            if let k = a.kind.flatMap(CommitmentKind.init(rawValue:)) { ev.kind = k }
            if case .some(let c)? = colour(a.color) { ev.color = c }
            s.oneOffs[i] = ev
            rep.changes.append("Changed \(ev.title)")
        }

        func deleteEvent(_ a: DumpFields, _ s: inout DumpState, _ rep: inout DumpReport) {
            guard let i = eventIndex(a, s) else { missing("event (calendar events are changed in Calendar)", a, &rep); return }
            rep.changes.append("Removed \(s.oneOffs[i].title)")
            s.oneOffs.remove(at: i)
        }

        // MARK: Day changes

        func changeDay(_ a: DumpFields, _ s: inout DumpState, _ rep: inout DumpReport) {
            // An existing day change by id: edit it in place.
            if let r = ref(a), let i = s.exceptions.firstIndex(where: { Ref.matches(r, prefix: "d", full: $0.id.uuidString) }) {
                if let v = a.date { s.exceptions[i].day = day(v) }
                if let c = a.cancelled { s.exceptions[i].cancelled = c }
                if let t = tod(a.start) { s.exceptions[i].start = t }
                if let t = tod(a.end) { s.exceptions[i].end = t }
                if let t = tod(a.wake) { s.exceptions[i].wake = t }
                if let n = a.note { s.exceptions[i].note = n }
                rep.changes.append("Changed that day")
                return
            }
            let d = day(a.date)
            var ex = DayException(day: d, cancelled: a.cancelled ?? false, start: tod(a.start), end: tod(a.end),
                                  wake: tod(a.wake), note: a.note)
            // What it's about: an activity id, an activity's name, a kind ("school"), or nothing (wake only).
            let about = (a.activity ?? a.target ?? (a.id.flatMap { $0.lowercased().hasPrefix("a") ? $0 : nil }))?
                .trimmingCharacters(in: .whitespaces)
            if let t = about, !t.isEmpty {
                if let i = s.commitments.firstIndex(where: { Ref.matches(t, prefix: "a", full: $0.id.uuidString) }) {
                    ex.commitmentId = s.commitments[i].id
                } else if let k = CommitmentKind(rawValue: t.lowercased()) {
                    ex.kind = k
                } else if let i = activityIndex(named: t, s) {
                    ex.commitmentId = s.commitments[i].id
                } else if t.lowercased().contains("school") || t.lowercased().contains("class") {
                    ex.kind = .school
                } else { rep.problems.append("Couldn't find activity “\(t)”"); return }
            } else if ex.wake == nil { rep.problems.append("A day change needs an activity, or a wake time"); return }
            // Replace an earlier change for the same thing on the same day.
            s.exceptions.removeAll { cal.isDate($0.day, inSameDayAs: d) && $0.commitmentId == ex.commitmentId
                && $0.kind == ex.kind && ($0.wake != nil) == (ex.wake != nil) }
            s.exceptions.append(ex)
            let what = ex.commitmentId.flatMap { id in s.commitments.first { $0.id == id }?.title } ?? ex.kind?.rawValue ?? "plans"
            rep.changes.append(ex.cancelled ? "No \(what) on that day" : ex.wake != nil && ex.commitmentId == nil && ex.kind == nil
                               ? "Wake-up changed that day" : "Changed \(what) that day")
        }

        func deleteDayChange(_ a: DumpFields, _ s: inout DumpState, _ rep: inout DumpReport) {
            let before = s.exceptions.count
            if let r = ref(a) {
                s.exceptions.removeAll { Ref.matches(r, prefix: "d", full: $0.id.uuidString) }
            } else if let v = a.date {
                let d = day(v)
                let target = (a.activity ?? a.target ?? "").lowercased()
                let cid = target.isEmpty ? nil : activityIndex(named: target, s).map { s.commitments[$0].id }
                s.exceptions.removeAll { e in
                    cal.isDate(e.day, inSameDayAs: d) && (target.isEmpty || e.commitmentId == cid
                        || (e.kind.map { target.contains($0.rawValue) } ?? false))
                }
            }
            if s.exceptions.count < before { rep.changes.append("That day is back to normal") }
            else { missing("day change", a, &rep) }
        }

        // MARK: Markers, moods, screen time, routines

        func log(_ a: DumpFields, _ s: inout DumpState, _ rep: inout DumpReport) {
            guard var act = a.activity?.lowercased(), !act.isEmpty else { rep.problems.append("A marker needs an activity"); return }
            var phase = MarkerPhase(rawValue: a.phase ?? "end") ?? .end
            var category = TimeCategory(rawValue: a.category ?? "") ?? .free
            // "in_bed", "woke": the sleep vocabulary, so the night can be measured from them.
            if let (k, p) = SleepEstimator.normalised(activity: act, phase: phase) { act = k; phase = p; category = .sleep }
            s.markers.append(TimelineEvent(at: when(a.at), phrase: a.note ?? act, activity: act,
                                           category: category, phase: phase, source: .voice))
            rep.changes.append("Logged \(act.replacingOccurrences(of: "_", with: " "))")
        }

        func mood(_ a: DumpFields, _ s: inout DumpState, _ rep: inout DumpReport) {
            guard let m = a.mood else { rep.problems.append("A mood needs a number 1-5"); return }
            s.moods.append(MoodEntry(at: now, mood: m, energy: a.energy, note: a.note))
        }

        func screenTime(_ a: DumpFields, _ s: inout DumpState, _ rep: inout DumpReport) {
            let d = day(a.date)
            let apps = (a.apps ?? []).map { AppUsage(name: $0.name, minutes: max(0, $0.minutes), distracting: $0.distracting ?? false) }
            let distracting = a.distractingMinutes ?? apps.filter(\.distracting).reduce(0) { $0 + $1.minutes }
            let entry = ScreenDay(day: d, distractingMinutes: max(0, distracting), totalMinutes: a.screenMinutes,
                                  apps: apps.isEmpty ? nil : apps, source: "screenshot")
            s.screen.removeAll { cal.isDate($0.day, inSameDayAs: d) }
            s.screen.append(entry)
            s.screen.sort { $0.day < $1.day }
            rep.changes.append("Screen time saved")
        }

        func routine(_ a: DumpFields, _ s: inout DumpState, _ rep: inout DumpReport) {
            guard let id = a.id ?? a.target ?? a.title,
                  let i = s.routines.firstIndex(where: { $0.id == id || $0.name.lowercased() == id.lowercased() }) else {
                missing("routine", a, &rep); return
            }
            if let m = a.minutes, m > 0, m < 240 {
                // Stated durations replace learned samples: the student knows best.
                s.routines[i].samples = Array(repeating: m, count: 3)
                rep.changes.append("\(s.routines[i].name) is \(m) min")
            }
            if let e = a.enabled {
                s.routines[i].enabled = e
                rep.changes.append("\(s.routines[i].name) \(e ? "on" : "off")")
            }
        }
    }

    /// Best fuzzy match of a spoken name against existing names (exact > contains > shared words).
    static func match(_ target: String?, _ candidates: [(Int, String)]) -> Int? {
        guard let target, !target.isEmpty else { return nil }
        func norm(_ s: String) -> String {
            s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
        }
        let t = norm(target)
        let tw = Set(t.split(separator: " "))
        var best: (Int, Double)?
        for (i, name) in candidates {
            let n = norm(name)
            var score = 0.0
            if n == t { score = 3 }
            else if n.contains(t) || t.contains(n) { score = 2 }
            else {
                let nw = Set(n.split(separator: " "))
                let j = Double(tw.intersection(nw).count) / Double(max(1, tw.union(nw).count))
                if j >= 0.34 { score = 1 + j }
            }
            if score > 0, score > (best?.1 ?? 0) { best = (i, score) }
        }
        return best?.0
    }
}
