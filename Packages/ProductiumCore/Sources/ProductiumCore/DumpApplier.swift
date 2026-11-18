import Foundation

public enum Ref {
    public static func task(_ id: UUID) -> String { "t" + short(id.uuidString) }
    public static func activity(_ id: UUID) -> String { "a" + short(id.uuidString) }
    public static func event(_ id: String) -> String { "e" + short(id) }
    public static func dayChange(_ id: UUID) -> String { "d" + short(id.uuidString) }
    public static func situation(_ id: UUID) -> String { "s" + short(id.uuidString) }
    public static func alarm(_ id: UUID) -> String { "r" + short(id.uuidString) }
    public static func reminder(_ id: UUID) -> String { "n" + short(id.uuidString) }

    static func short(_ s: String) -> String {
        if UUID(uuidString: s) != nil { return String(s.lowercased().filter(\.isHexDigit).prefix(6)) }
        // FNV-1a: `hashValue` changes every launch.
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(String(h, radix: 16).prefix(6))
    }

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

public struct DumpReport: Hashable, Sendable {
    public var changes: [String] = []
    public var problems: [String] = []
    public init(changes: [String] = [], problems: [String] = []) { self.changes = changes; self.problems = problems }
}

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

    @discardableResult
    public static func apply(_ r: DumpResult, to s: inout DumpState, now: Date, calendar cal: Calendar,
                             writer: Writer = .box, turnId: UUID? = nil) -> DumpReport {
        var rep = DumpReport()
        let before = Dictionary(s.items.map { ($0.id, $0.completedMinutes) }, uniquingKeysWith: { a, _ in a })
        for op in r.ops { apply(op, to: &s, now: now, calendar: cal, writer: writer, report: &rep) }
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
        let h = Handlers(now: now, cal: cal, writer: writer)
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
        case (.upsert, "reminder"): h.upsertReminder(a, &s, &rep)
        case (.delete, "reminder"): h.deleteReminder(a, &s, &rep)
        case (.upsert, "alarm"): h.upsertAlarm(a, &s, &rep)
        case (.delete, "alarm"): h.deleteAlarm(a, &s, &rep)
        case (.upsert, "situation"): h.upsertSituation(a, &s, &rep)
        case (.upsert, "day_rule"): h.dayRule(a, &s, &rep)
        case (.upsert, "gap"): h.gap(a, &s, &rep)
        case (.delete, "situation"): h.deleteSituation(a, &s, &rep)
        case (.delete, "task"): h.deleteTask(a, &s, &rep)
        case (.delete, "activity"): h.deleteActivity(a, &s, &rep)
        case (.delete, "event"): h.deleteEvent(a, &s, &rep)
        case (.delete, "day_change"): h.deleteDayChange(a, &s, &rep)
        case (.delete, let e): rep.problems.append("A \(e.replacingOccurrences(of: "_", with: " ")) can't be deleted")
        default: rep.problems.append("Skipped “\(op.op)” on \(spec.name)")
        }
    }

    struct Handlers {
        let now: Date
        let cal: Calendar
        var writer: Writer = .box
        var tz: TimeZone { cal.timeZone }

        func tod(_ v: String?) -> TimeOfDay? { DumpApplier.timeOfDay(v) }
        func day(_ v: String?) -> Date {
            guard let v, let d = AIMapper.parseDate(v, timeZone: tz) else { return cal.startOfDay(for: now) }
            return cal.startOfDay(for: d)
        }
        func when(_ v: String?) -> Date {
            guard let v, let d = AIMapper.parseDate(v, timeZone: tz) else { return now }
            return min(d, now)
        }
        func weekdays(_ w: [Int]?) -> Set<Int>? {
            guard let w else { return nil }
            let set = Set(w.filter { (1...7).contains($0) })
            return set.isEmpty ? nil : set
        }
        func colour(_ raw: String?) -> String?? {
            guard let raw else { return nil }
            let l = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if ["", "default", "none", "reset", "auto", "clear"].contains(l) { return .some(nil) }
            guard let c = Palette.normalise(raw) else { return nil }
            return .some(c)
        }
        func ref(_ a: DumpFields) -> String? {
            if let id = a.id, !id.isEmpty { return id }
            if let t = a.target, t.count <= 8, t.count >= 5, t.dropFirst().allSatisfy(\.isHexDigit) { return t }
            return nil
        }
        func name(_ a: DumpFields) -> String? { a.target ?? a.title }
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

        func upsertTask(_ a: DumpFields, _ s: inout DumpState, _ rep: inout DumpReport) {
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
            item.atSchool = a.atSchool
            if let m = a.doneMinutes { item.completedMinutes = max(0, m) }
            if case .some(let c)? = colour(a.color) { item.color = c }
            if let parent { item.due = min(item.due, parent.due); item.subject = item.subject ?? parent.subject }
            if let i = s.items.firstIndex(where: { !$0.isDone && $0.title.plainKey == item.title.plainKey && $0.parentId == item.parentId }) {
                s.items[i].due = item.due
                if a.estimateMinutes != nil { s.items[i].estimateMinutes = item.estimateMinutes }
                if a.color != nil { s.items[i].color = item.color }
                rep.changes.append("Updated \(item.title)")
            } else {
                if a.done == true { item.isDone = true; item.doneAt = now }
                s.items.append(item)
                taskAlarms(item, a, &s, &rep)
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
            if let m = a.doneMinutes { s.items[i].completedMinutes = max(0, m); changed = true }
            if let v = a.atSchool { s.items[i].atSchool = v; changed = true }
            if let t = a.topics { s.items[i].topics = t; changed = true }
            if let n = a.notes { s.items[i].notes = n.isEmpty ? nil : n; changed = true }
            if case .some(let c)? = colour(a.color) { s.items[i].color = c; changed = true }
            if a.alarm != nil || a.blockAlarm != nil { taskAlarms(s.items[i], a, &s, &rep) }
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
            s.alarmRules.removeAll { $0.itemId == id }
        }

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
            c.periods = periods(a.periods, &rep)
            c.validFrom = a.validFrom.flatMap { AIMapper.parseDate($0, timeZone: tz) }.map { cal.startOfDay(for: $0) }
            c.validUntil = a.validUntil.flatMap { AIMapper.parseDate($0, timeZone: tz) }
            if let i = s.commitments.firstIndex(where: { $0.title.plainKey == c.title.plainKey && !$0.weekdays.isDisjoint(with: c.weekdays) }) {
                let id = s.commitments[i].id
                c.id = id
                if a.color == nil { c.color = s.commitments[i].color }
                if a.bufferMinutes == nil { c.bufferMinutes = s.commitments[i].bufferMinutes }
                if a.periods == nil { c.periods = s.commitments[i].periods }
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
            if a.periods != nil { c.periods = periods(a.periods, &rep) }
            if let v = a.validFrom { c.validFrom = AIMapper.parseDate(v, timeZone: tz).map { cal.startOfDay(for: $0) } }
            if let v = a.validUntil { c.validUntil = AIMapper.parseDate(v, timeZone: tz) }
            guard c.end > c.start else { rep.problems.append("\(c.title) would end before it starts, so it wasn't changed"); return }
            guard c != s.commitments[i] else { return }
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
            let covered = made.reduce(into: Set<Int>()) { $0.formUnion($1.weekdays) }
            let left = original.weekdays.subtracting(covered)
            if left.isEmpty {
                s.commitments.remove(at: i)
            } else {
                s.commitments[i].weekdays = left
            }
            for c in made {
                if let j = s.commitments.firstIndex(where: { $0.id != original.id && $0.title.plainKey == c.title.plainKey
                    && !$0.weekdays.isDisjoint(with: c.weekdays) }) {
                    var updated = c
                    updated.id = s.commitments[j].id
                    s.commitments[j] = updated
                } else {
                    s.commitments.append(c)
                }
            }
            let partIds = s.commitments.filter { c in made.contains { $0.title.plainKey == c.title.plainKey } }.map(\.id)
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
            let ed = ed0 > sd ? ed0 : ed0.addingTimeInterval(86400)
            let title = a.title ?? "Busy"
            let candidate = FixedEvent(id: "", title: title, start: sd, end: ed)
            if let i = s.oneOffs.firstIndex(where: { EventMatch.duplicates($0, candidate, calendar: cal) }) {
                s.oneOffs[i].start = sd
                s.oneOffs[i].end = ed
                s.oneOffs[i].title = title
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

        func changeDay(_ a: DumpFields, _ s: inout DumpState, _ rep: inout DumpReport) {
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
            if !ex.cancelled, ex.wake == nil, !changesTimes(ex, s.commitments) {
                rep.problems.append("Skipped a day change that changes nothing (not cancelled, same times)")
                return
            }
            s.exceptions.removeAll { cal.isDate($0.day, inSameDayAs: d) && $0.commitmentId == ex.commitmentId
                && $0.kind == ex.kind && ($0.wake != nil) == (ex.wake != nil) }
            s.exceptions.append(ex)
            let what = ex.commitmentId.flatMap { id in s.commitments.first { $0.id == id }?.title } ?? ex.kind?.rawValue ?? "plans"
            rep.changes.append(ex.cancelled ? "No \(what) on that day" : ex.wake != nil && ex.commitmentId == nil && ex.kind == nil
                               ? "Wake-up changed that day" : "Changed \(what) that day")
        }

        func changesTimes(_ ex: DayException, _ commitments: [Commitment]) -> Bool {
            let usual = ex.commitmentId.flatMap { id in commitments.first { $0.id == id } }
            let startsDifferently = ex.start.map { $0 != usual?.start } ?? false
            let endsDifferently = ex.end.map { $0 != usual?.end } ?? false
            return startsDifferently || endsDifferently
        }

        func periods(_ parts: [DumpPart]?, _ rep: inout DumpReport) -> [ActivityPeriod]? {
            guard let parts else { return nil }
            return parts.compactMap { p in
                guard let st = tod(p.start), let en = tod(p.end), en > st, !p.title.isEmpty else {
                    rep.problems.append("Skipped period “\(p.title)”: it needs a start and a later end"); return nil
                }
                return ActivityPeriod(title: p.title, start: st, end: en, weekdays: weekdays(p.weekdays) ?? [])
            }
        }

        func plannerInput(_ s: DumpState) -> PlannerInput {
            PlannerInput(now: now, calendar: cal, items: s.items, commitments: s.commitments, events: s.calendarEvents + s.oneOffs,
                         preferences: s.prefs, routines: s.routines, exceptions: s.exceptions, horizonDays: 14, policy: s.policy,
                         beliefs: s.beliefs, situations: s.situations, dayRules: s.dayRules)
        }

        /// A task's own alarms (`alarm`: before it's due, `blockAlarm`: before each study block) are rules tied to the task.
        func taskAlarms(_ item: WorkItem, _ a: DumpFields, _ s: inout DumpState, _ rep: inout DumpReport) {
            func set(_ kind: AlarmRule.Kind, _ minutes: Int?) {
                guard let minutes else { return }
                s.alarmRules.removeAll { $0.kind == kind && $0.itemId == item.id }
                if minutes < 0 { rep.changes.append("Removed the \(kind == .beforeDue ? "due" : "block") alarm for \(item.title)"); return }
                guard s.alarmRules.filter({ $0.itemId != nil }).count < 40 else { rep.problems.append("That's a lot of task alarms already"); return }
                let m = min(minutes, 7 * 24 * 60)
                s.alarmRules.append(AlarmRule(kind: kind, itemId: item.id, minutes: m, source: writer, createdAt: now))
                rep.changes.append(kind == .beforeDue
                    ? "Alarm \(m == 0 ? "when" : "\(minutesLabel(m)) before") \(item.title) is due"
                    : "Alarm \(minutesLabel(m)) before each \(item.title) block")
            }
            set(.beforeDue, a.alarm)
            set(.beforeBlocks, a.blockAlarm)
        }

        func upsertAlarm(_ a: DumpFields, _ s: inout DumpState, _ rep: inout DumpReport) {
            var old: AlarmRule?
            if let r = ref(a) { old = s.alarmRules.first { Ref.matches(r, prefix: "r", full: $0.id.uuidString) } }
            let kindWord = (a.kind ?? "").lowercased().filter(\.isLetter)
            let kind: AlarmRule.Kind? = ["clock": .clock, "time": .clock, "beforedue": .beforeDue, "due": .beforeDue,
                                         "beforeblocks": .beforeBlocks, "block": .beforeBlocks, "blocks": .beforeBlocks,
                                         "shift": .shift, "move": .shift, "off": .suppress, "suppress": .suppress, "remove": .suppress][kindWord] ?? old?.kind
            guard let kind else { rep.problems.append("An alarm needs a kind: clock, before_due, before_blocks, shift or off"); return }
            let itemId = a.task.flatMap { r in s.items.first { Ref.matches(r, prefix: "t", full: $0.id.uuidString) }?.id } ?? old?.itemId
            let target: PlannedAlarm.Kind? = a.alarmKind.flatMap { w in
                ["wake": PlannedAlarm.Kind.wake, "bed": .bedtime, "bedtime": .bedtime, "leave": .leave, "leaveby": .leave,
                 "missedstart": .missedStart, "start": .missedStart, "missed": .missedStart][w.lowercased().filter(\.isLetter)]
            } ?? old?.target
            var r = old ?? AlarmRule(kind: kind, source: writer, createdAt: now)
            r.kind = kind
            r.label = String((a.label ?? a.title ?? r.label).prefix(60))
            if let t = tod(a.time ?? a.start) { r.time = t }
            r.itemId = itemId
            r.target = target
            if let m = a.minutes { r.minutes = max(-240, min(7 * 24 * 60, m)) }
            if let e = a.enabled { r.enabled = e }
            if let ex = a.expires { r.expires = ex.isEmpty ? nil : AIMapper.parseDate(ex, timeZone: tz).map { cal.startOfDay(for: $0) } }
            if let raw = a.scope {
                guard let rule = SituationText.rule(raw, tz: tz, commitments: s.commitments, items: s.items) else {
                    rep.problems.append("Couldn't read which days that alarm is for"); return
                }
                r.when = rule
            }
            switch kind {
            case .clock where r.time == nil: rep.problems.append("A clock alarm needs a time (HH:mm)"); return
            case .beforeDue where r.itemId == nil: rep.problems.append("That alarm needs the task it's for"); return
            case .shift where r.target == nil || r.minutes == 0, .suppress where r.target == nil:
                rep.problems.append("Moving or removing one of Productium's alarms needs which one (wake, bedtime, leave or missedStart)\(kind == .shift ? " and how many minutes" : "")"); return
            default: break
            }
            if kind == .suppress || kind == .shift, r.target == .wake, !s.prefs.wakeAlarms || !s.alarmsAllowed {
                rep.problems.append("The morning alarm is off, so there's nothing to \(kind == .shift ? "move" : "remove")"); return
            }
            if kind == .shift { r.minutes = max(-120, min(120, r.minutes)) }
            r.source = old?.source ?? writer
            if old == nil, s.alarmRules.count >= 40 { rep.problems.append("That's a lot of alarm rules already"); return }
            s.alarmRules.removeAll { $0.id == r.id }
            s.alarmRules.append(r)
            if !s.alarmsAllowed {
                let note = "iOS has to allow alarms before this one can ring: it will ask, or turn them on in Settings."
                if !rep.problems.contains(note) { rep.problems.append(note) }
            }
            rep.changes.append((old == nil ? "Alarm: " : "Alarm updated: ") + r.summary(items: s.items, calendar: cal) + (r.enabled ? "" : " (off)"))
        }

        func upsertReminder(_ a: DumpFields, _ s: inout DumpState, _ rep: inout DumpReport) {
            var i: Int?
            if let r = ref(a) { i = s.policy.intentions.firstIndex { Ref.matches(r, prefix: "n", full: $0.id.uuidString) } }
            let home = (a.trigger ?? "").lowercased().contains("home")
            let time = tod(a.time ?? a.start)
            guard i != nil || !(a.text ?? a.title ?? "").isEmpty else { rep.problems.append("A reminder needs text"); return }
            guard i != nil || home || time != nil else { rep.problems.append("A reminder needs a time (HH:mm) or “when I get home”"); return }
            var r = i.map { s.policy.intentions[$0] } ?? IntentionNudge(trigger: home ? IntentionNudge.Trigger.arriveHome : IntentionNudge.Trigger.time, text: "", byStudent: true)
            if let t = a.text ?? a.title, !t.isEmpty { r.text = String(t.prefix(140)) }
            if a.trigger != nil { r.trigger = home ? IntentionNudge.Trigger.arriveHome : IntentionNudge.Trigger.time }
            if let t = time { r.time = t }
            if let w = a.weekdays { r.weekdays = w.filter { (1...7).contains($0) }.sorted() }
            if let t = a.task { r.itemId = s.items.first { Ref.matches(t, prefix: "t", full: $0.id.uuidString) }?.id }
            if let i { s.policy.intentions[i] = r } else {
                guard s.policy.intentions.count < 30 else { rep.problems.append("That's a lot of reminders already"); return }
                s.policy.intentions.append(r)
            }
            rep.changes.append("Reminder: \(r.text)" + (r.trigger == IntentionNudge.Trigger.arriveHome ? " when you get home" : r.time.map { " at \($0.label)" } ?? ""))
        }

        func deleteReminder(_ a: DumpFields, _ s: inout DumpState, _ rep: inout DumpReport) {
            guard let r = ref(a) else { missing("reminder", a, &rep); return }
            let before = s.policy.intentions.count
            s.policy.intentions.removeAll { Ref.matches(r, prefix: "n", full: $0.id.uuidString) }
            if s.policy.intentions.count < before { rep.changes.append("Removed that reminder") } else { missing("reminder", a, &rep) }
        }

        func deleteAlarm(_ a: DumpFields, _ s: inout DumpState, _ rep: inout DumpReport) {
            guard let r = ref(a) else { missing("alarm", a, &rep); return }
            let before = s.alarmRules.count
            s.alarmRules.removeAll { Ref.matches(r, prefix: "r", full: $0.id.uuidString) }
            if s.alarmRules.count < before { rep.changes.append("Removed that alarm") } else { missing("alarm", a, &rep) }
        }

        func upsertSituation(_ a: DumpFields, _ s: inout DumpState, _ rep: inout DumpReport) {
            guard let scope = SituationText.rule(a.scope, tz: tz, commitments: s.commitments, items: s.items) else {
                rep.problems.append("A situation needs a scope (which days) as a day rule"); return
            }
            var effects: [Effect] = []
            for raw in a.effects ?? [] {
                if let e = SituationText.effect(raw, tz: tz, commitments: s.commitments, items: s.items) { effects.append(e) }
                else { rep.problems.append("Couldn't read the effect \(raw.prefix(60))") }
            }
            guard !effects.isEmpty else { rep.problems.append("A situation needs at least one effect"); return }
            var old: Situation?
            if let r = ref(a) { old = s.situations.first { Ref.matches(r, prefix: "s", full: $0.id.uuidString) } }
            let expires = a.expires.flatMap { AIMapper.parseDate($0, timeZone: tz) }.map { cal.startOfDay(for: $0) }
            let sit = Situation(id: old?.id ?? UUID(), said: a.said ?? a.note ?? a.title ?? "", scope: scope, effects: effects,
                                expires: expires, source: writer, createdAt: now)
            var base = s
            base.situations.removeAll { $0.id == old?.id }
            let input = plannerInput(base)
            switch SituationRules.admit(sit, into: input, writer: writer, calendarEventIds: Set(s.calendarEvents.map(\.id))) {
            case .failure(let why): rep.problems.append(why.reason); return
            case .success: break
            }
            s.situations = base.situations + [sit]
            rep.changes.append((old == nil ? "Added: " : "Updated: ") + (sit.said.isEmpty ? scope.text(cal) : sit.said) + " (" + scope.text(cal) + ")")
            let diffs = Preview.diff(input, adding: sit)
            rep.changes += Preview.receipt(diffs, calendar: cal, limit: 5)
        }

        func deleteSituation(_ a: DumpFields, _ s: inout DumpState, _ rep: inout DumpReport) {
            guard let r = ref(a) else { missing("situation", a, &rep); return }
            let before = s.situations.count
            s.situations.removeAll { Ref.matches(r, prefix: "s", full: $0.id.uuidString) }
            if s.situations.count < before { rep.changes.append("Removed that situation") } else { missing("situation", a, &rep) }
        }

        func dayRule(_ a: DumpFields, _ s: inout DumpState, _ rep: inout DumpReport) {
            guard let name = a.name?.trimmingCharacters(in: .whitespaces).lowercased(), !name.isEmpty else {
                rep.problems.append("A day rule needs a name"); return
            }
            if (a.kind ?? "").lowercased().hasPrefix("seq") {
                guard let rule = SituationText.rule(a.rule, tz: tz, commitments: s.commitments, items: s.items), let anchor = a.anchor.flatMap({ AIMapper.parseDate($0, timeZone: tz) }) else {
                    rep.problems.append("A sequence needs a rule and an anchor date"); return
                }
                s.dayRules.sequences.removeAll { $0.name == name }
                s.dayRules.sequences.append(DaySequence(name: name, rule: rule, anchor: cal.startOfDay(for: anchor)))
                rep.changes.append("Counting “\(name)” days from \(DateFormatter.local("EEE d MMM", cal).string(from: anchor))")
            } else {
                let days = (a.dates ?? []).compactMap { AIMapper.parseDate($0, timeZone: tz) }
                guard !days.isEmpty else { rep.problems.append("A label needs dates"); return }
                if a.remove == true { s.dayRules.unlabel(name, days, calendar: cal) } else { s.dayRules.label(name, days, calendar: cal) }
                rep.changes.append("\(name): \(a.remove == true ? "removed" : "added") \(days.count) day\(days.count == 1 ? "" : "s")")
            }
        }

        func gap(_ a: DumpFields, _ s: inout DumpState, _ rep: inout DumpReport) {
            guard let wanted = a.wanted, !wanted.isEmpty else { return }
            s.gapNotes.append(GapNote(at: now, said: a.said ?? a.note ?? "", wanted: wanted))
            s.gapNotes = Array(s.gapNotes.suffix(100))
            rep.problems.append("I can't do that yet, and I've noted it: \(wanted)")
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

        func log(_ a: DumpFields, _ s: inout DumpState, _ rep: inout DumpReport) {
            guard var act = a.activity?.lowercased(), !act.isEmpty else { rep.problems.append("A marker needs an activity"); return }
            var phase = MarkerPhase(rawValue: a.phase ?? "end") ?? .end
            if let (k, p) = SleepEstimator.normalised(activity: act, phase: phase) { act = k; phase = p }
            let category = MarkerCategory.infer(activity: act, commitments: s.commitments,
                                                model: TimeCategory(rawValue: a.category ?? ""))
            MarkerLog.add([TimelineEvent(at: when(a.at), phrase: a.note ?? act, activity: act,
                                         category: category, phase: phase, source: .voice)], to: &s.markers)
            rep.changes.append("Logged \(act.replacingOccurrences(of: "_", with: " "))")
        }

        func mood(_ a: DumpFields, _ s: inout DumpState, _ rep: inout DumpReport) {
            guard let m = a.mood else { rep.problems.append("A mood needs a number 1-5"); return }
            s.moods.append(MoodEntry(at: now, mood: m, energy: a.energy, note: a.note))
        }

        func screenTime(_ a: DumpFields, _ s: inout DumpState, _ rep: inout DumpReport) {
            let rawApps = (a.apps ?? []).filter { !$0.name.isEmpty }
            ScrollingApps.register(rawApps.map { ($0.name, $0.category) }, into: &s.scrollingApps)
            let apps = rawApps.map { AppUsage(name: $0.name, minutes: max(0, $0.minutes), distracting: false,
                                                       pickups: $0.pickups.map { max(0, $0) }, notifications: $0.notifications.map { max(0, $0) }) }
            let period = (a.period ?? "day").lowercased()
            var entry = ScreenDay(day: .distantPast, distractingMinutes: 0, totalMinutes: a.screenMinutes.map { max(0, $0) },
                                  apps: apps.isEmpty ? nil : apps, source: "screenshot", partial: a.partial == true ? true : nil,
                                  pickups: a.pickups.map { max(0, $0) }, firstPickup: ScreenReceipt.parseClock(a.firstPickup),
                                  notifications: a.notifications.map { max(0, $0) })
            entry = entry.recomputed(s.scrollingApps)
            if apps.isEmpty { rep.problems.append("That screenshot shows no apps, so I can't tell how much of it was scrolling") }

            if period.contains("week") || period.contains("average") || period.contains("avg") {
                entry.day = cal.startOfDay(for: now)
                entry.source = "screenshot-average"
                s.screenAverages.removeAll { cal.isDate($0.day, inSameDayAs: entry.day) }
                s.screenAverages.append(entry)
                s.screenAverages = Array(s.screenAverages.sorted { $0.day < $1.day }.suffix(12))
                rep.changes.append(ScreenReceipt.line(entry, label: "Daily average"))
                if let m = entry.mismatch { rep.problems.append("Daily average doesn't add up: \(m). Which is right?") }
                return
            }

            let d = ScreenDates.resolve(label: a.dateLabelShown, date: a.date.flatMap { AIMapper.parseDate($0, timeZone: tz) },
                                        now: now, calendar: cal)
            entry.day = d
            if let existing = s.screen.first(where: { cal.isDate($0.day, inSameDayAs: d) }), existing.source == "screenshot" {
                entry = existing.merged(with: entry, s.scrollingApps)
            }
            s.screen.removeAll { cal.isDate($0.day, inSameDayAs: d) }
            s.screen.append(entry)
            s.screen.sort { $0.day < $1.day }
            rep.changes.append(ScreenReceipt.line(entry, label: DateFormatter.local("EEE d MMM", cal).string(from: d)))
            if let m = entry.mismatch {
                rep.problems.append("Screen Time for \(DateFormatter.local("EEE d MMM", cal).string(from: d)) doesn't add up: \(m). Tell me which number is right.")
            }
        }

        func routine(_ a: DumpFields, _ s: inout DumpState, _ rep: inout DumpReport) {
            guard let id = a.id ?? a.target ?? a.title,
                  let i = s.routines.firstIndex(where: { $0.id == id || $0.name.lowercased() == id.lowercased() }) else {
                missing("routine", a, &rep); return
            }
            if let m = a.minutes, m > 0, m < 240 {
                s.routines[i].stated = m
                rep.changes.append("\(s.routines[i].name) is \(m) min")
            }
            if let e = a.enabled {
                s.routines[i].enabled = e
                rep.changes.append("\(s.routines[i].name) \(e ? "on" : "off")")
            }
        }
    }

    static func match(_ target: String?, _ candidates: [(Int, String)]) -> Int? {
        guard let target, !target.isEmpty else { return nil }
        func words(_ s: String) -> String {
            s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
        }
        let t = words(target)
        let tw = Set(t.split(separator: " "))
        var best: (Int, Double)?
        for (i, name) in candidates {
            let n = words(name)
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
