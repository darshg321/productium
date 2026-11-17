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

// MARK: - Settings by name

public enum DumpSettings {
    /// Every setting the Inbox may change, with what its value looks like (shown in the prompt).
    public static let keys: [(String, String)] = [
        ("sleepNeedMinutes", "450-600"), ("schoolDayWake", "HH:mm"), ("freeDayWake", "HH:mm"),
        ("autoWake", "true|false (work the wake-up back from the first class)"),
        ("windDownMinutes", "0-90"), ("dinner", "HH:mm or none"), ("dinnerMinutes", "10-120"),
        ("focusBlockMinutes", "15-90"), ("breakMinutes", "0-30"),
        ("maxStudyMinutesSchoolDay", "30-480"), ("maxStudyMinutesFreeDay", "30-600"),
        ("minFreeMinutesSchoolDay", "0-300"), ("minFreeMinutesFreeDay", "0-600"),
        ("allowSleepTradeoffs", "true|false"), ("chronotype", "early|intermediate|late"),
        ("schoolDays", "weekday numbers, e.g. 2,3,4,5,6"), ("screenTimeGoalMinutes", "0-600"),
        ("interests", "comma list"), ("nudgeLevel", "gentle|standard|persistent"),
        ("alarms", "true|false"), ("scrollCheckIns", "true|false"), ("arrivingHome", "true|false"),
        ("deadlineNudges", "true|false"),
    ]

    static func plain(_ s: String) -> String { s.lowercased().filter { $0.isLetter } }

    /// Applies one setting. Returns the receipt line, or nil when the key or value isn't usable.
    static func apply(key raw: String, value v: String, to p: inout Preferences) -> String? {
        let key = plain(raw)
        let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = t.lowercased()
        func int(_ lo: Int, _ hi: Int) -> Int? {
            let digits = t.prefix { $0.isNumber || $0 == "-" }
            guard let n = Int(digits) else { return nil }
            // "9h" / "9 hours" for a minutes setting
            let hours = lower.contains("h") && !lower.contains("min") && n <= 12
            return max(lo, min(hi, hours ? n * 60 : n))
        }
        func bool() -> Bool? {
            if ["true", "yes", "on", "1", "enable", "enabled"].contains(lower) { return true }
            if ["false", "no", "off", "0", "disable", "disabled", "none"].contains(lower) { return false }
            return nil
        }
        func time() -> TimeOfDay? { DumpApplier.timeOfDay(t) }
        switch key {
        case "sleepneedminutes", "sleepneed", "sleep": guard let n = int(450, 600) else { return nil }; p.sleepNeedMinutes = n
        case "schooldaywake": guard let x = time() else { return nil }; p.schoolDayWake = x
        case "freedaywake", "weekendwake": guard let x = time() else { return nil }; p.freeDayWake = x
        case "autowake": guard let b = bool() else { return nil }; p.autoWake = b
        case "winddownminutes", "winddown": guard let n = int(0, 90) else { return nil }; p.windDownMinutes = n
        case "dinner", "dinnertime":
            if ["none", "off", "no", "false", "skip"].contains(lower) { p.dinner = nil } else { guard let x = time() else { return nil }; p.dinner = x }
        case "dinnerminutes": guard let n = int(10, 120) else { return nil }; p.dinnerMinutes = n
        case "focusblockminutes", "focusminutes", "blockminutes": guard let n = int(15, 90) else { return nil }; p.focusBlockMinutes = n
        case "breakminutes": guard let n = int(0, 30) else { return nil }; p.breakMinutes = n
        case "maxstudyminutesschoolday": guard let n = int(30, 480) else { return nil }; p.maxStudyMinutesSchoolDay = n
        case "maxstudyminutesfreeday": guard let n = int(30, 600) else { return nil }; p.maxStudyMinutesFreeDay = n
        case "minfreeminutesschoolday": guard let n = int(0, 300) else { return nil }; p.minFreeMinutesSchoolDay = n
        case "minfreeminutesfreeday": guard let n = int(0, 600) else { return nil }; p.minFreeMinutesFreeDay = n
        case "allowsleeptradeoffs": guard let b = bool() else { return nil }; p.allowSleepTradeoffs = b
        case "chronotype": guard let c = Chronotype(rawValue: lower) else { return nil }; p.chronotype = c
        case "schooldays":
            let days = Set(t.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.filter { (1...7).contains($0) })
            guard !days.isEmpty || lower == "none" else { return nil }
            p.schoolDays = days
        case "screentimegoalminutes", "screentimegoal": guard let n = int(0, 600) else { return nil }; p.screenTimeGoalMinutes = n
        case "interests":
            p.interests = t.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        case "nudgelevel", "nudges", "notifications":
            guard let l = NudgeLevel(rawValue: lower) else { return nil }; p.nudges.level = l
        case "alarms": guard let b = bool() else { return nil }; p.nudges.alarms = b
        case "scrollcheckins": guard let b = bool() else { return nil }; p.nudges.scrollCheckIns = b
        case "arrivinghome": guard let b = bool() else { return nil }; p.nudges.arrivingHome = b
        case "deadlinenudges", "deadlines": guard let b = bool() else { return nil }; p.nudges.deadlines = b
        default: return nil
        }
        return "\(raw) → \(t)"
    }
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

    /// Applies every action it can, in order. Later actions see earlier ones (a task added
    /// first can be coloured next).
    @discardableResult
    public static func apply(_ r: DumpResult, to s: inout DumpState, now: Date, calendar cal: Calendar) -> DumpReport {
        var rep = DumpReport()
        let tz = cal.timeZone
        func tod(_ v: String?) -> TimeOfDay? { timeOfDay(v) }
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
        func ref(_ a: DumpAction) -> String? {
            if let id = a.id, !id.isEmpty { return id }
            // A model sometimes puts the reference in `target`.
            if let t = a.target, t.count <= 8, t.count >= 5, t.dropFirst().allSatisfy(\.isHexDigit) { return t }
            return nil
        }
        func name(_ a: DumpAction) -> String? { a.target ?? a.title }
        func taskIndex(_ a: DumpAction, includeDone: Bool = false) -> Int? {
            if let r = ref(a) {
                if let i = s.items.firstIndex(where: { Ref.matches(r, prefix: "t", full: $0.id.uuidString) }) { return i }
            }
            let pool = s.items.indices.filter {
                includeDone || !s.items[$0].isDone || s.items[$0].doneAt.map { now.timeIntervalSince($0) < 86400 } == true
            }
            return match(name(a), pool.map { ($0, s.items[$0].title) })
        }
        func activityIndex(_ a: DumpAction) -> Int? {
            if let r = ref(a), let i = s.commitments.firstIndex(where: { Ref.matches(r, prefix: "a", full: $0.id.uuidString) }) { return i }
            return activityIndex(named: name(a))
        }
        func activityIndex(named n: String?) -> Int? { match(n, s.commitments.indices.map { ($0, s.commitments[$0].title) }) }
        func eventIndex(_ a: DumpAction) -> Int? {
            if let r = ref(a), let i = s.oneOffs.firstIndex(where: { Ref.matches(r, prefix: "e", full: $0.id) }) { return i }
            return match(name(a), s.oneOffs.indices.filter { s.oneOffs[$0].end > now }.map { ($0, s.oneOffs[$0].title) })
        }
        func missing(_ what: String, _ a: DumpAction) {
            rep.problems.append("Couldn't find \(what) “\(ref(a) ?? name(a) ?? "?")”")
        }
        func norm(_ t: String) -> String { t.lowercased().filter { $0.isLetter || $0.isNumber } }

        for a in r.actions {
            guard let type = DumpActionType(loose: a.type) else {
                rep.problems.append("Skipped an unknown action “\(a.type)”")
                continue
            }
            switch type {
            case .addTask:
                let p = ParsedItem(title: a.title ?? a.target ?? "", kind: a.kind ?? "other", subject: a.subject, due: a.due ?? "",
                                   estimateMinutes: a.estimateMinutes, importance: a.importance, difficulty: a.difficulty, topics: a.topics)
                let parent = a.parent.flatMap { r in s.items.first { Ref.matches(r, prefix: "t", full: $0.id.uuidString) } }
                guard var item = AIMapper.item(p, timeZone: tz, parentId: parent?.id) else {
                    rep.problems.append("Couldn't add “\(a.title ?? "a task")”: it needs a title and a due date")
                    continue
                }
                item.notes = a.notes
                if case .some(let c)? = colour(a.color) { item.color = c }
                if let parent { item.due = min(item.due, parent.due); item.subject = item.subject ?? parent.subject }
                if let i = s.items.firstIndex(where: { !$0.isDone && norm($0.title) == norm(item.title) && $0.parentId == item.parentId }) {
                    // Already there: an update, never a second copy.
                    s.items[i].due = item.due
                    if a.estimateMinutes != nil { s.items[i].estimateMinutes = item.estimateMinutes }
                    if a.color != nil { s.items[i].color = item.color }
                    rep.changes.append("Updated \(item.title)")
                } else {
                    s.items.append(item)
                    rep.changes.append(parent.map { "Added step to \($0.title): \(item.title)" } ?? "Added \(item.title)")
                }
            case .updateTask:
                guard let i = taskIndex(a, includeDone: true) else { missing("task", a); continue }
                if let t = a.title, !t.isEmpty, a.target != nil || a.id != nil { s.items[i].title = String(t.prefix(120)) }
                if let k = a.kind.flatMap(TaskKind.init(rawValue:)) { s.items[i].kind = k }
                if let v = a.subject { s.items[i].subject = v.isEmpty ? nil : v }
                if let d = a.due.flatMap({ AIMapper.parseDate($0, timeZone: tz) }) { s.items[i].due = d }
                if let m = a.estimateMinutes { s.items[i].estimateMinutes = max(5, min(3000, m)) }
                if let m = a.importance { s.items[i].importance = max(1, min(5, m)) }
                if let m = a.difficulty { s.items[i].difficulty = max(1, min(3, m)) }
                if let m = a.progressMinutes { s.items[i].completedMinutes += max(0, m) }
                if let m = a.doneMinutes { s.items[i].completedMinutes = max(0, m) }
                if let t = a.topics { s.items[i].topics = t }
                if let n = a.notes { s.items[i].notes = n.isEmpty ? nil : n }
                if case .some(let c)? = colour(a.color) { s.items[i].color = c }
                rep.changes.append("Changed \(s.items[i].title)")
            case .completeTask:
                guard let i = taskIndex(a) else { missing("task", a); continue }
                guard !s.items[i].isDone else { continue }
                s.items[i].isDone = true
                s.items[i].doneAt = now
                rep.changes.append("Done: \(s.items[i].title)")
                if let p = s.items[i].parentId, !s.items.contains(where: { $0.parentId == p && !$0.isDone }),
                   let j = s.items.firstIndex(where: { $0.id == p }), !s.items[j].isDone {
                    s.items[j].isDone = true
                    s.items[j].doneAt = now
                    rep.changes.append("Done: \(s.items[j].title)")
                }
            case .reopenTask:
                guard let i = taskIndex(a, includeDone: true) else { missing("task", a); continue }
                s.items[i].isDone = false
                s.items[i].doneAt = nil
                rep.changes.append("Not done: \(s.items[i].title)")
            case .deleteTask:
                guard let i = taskIndex(a, includeDone: true) else { missing("task", a); continue }
                let id = s.items[i].id
                rep.changes.append("Removed \(s.items[i].title)")
                s.items.removeAll { $0.id == id || $0.parentId == id }

            case .addActivity:
                guard var c = AIMapper.commitment(ParsedCommitment(title: a.title ?? "", kind: a.kind ?? "extracurricular",
                                                                   weekdays: a.weekdays ?? [], start: a.start ?? "", end: a.end ?? "")) else {
                    rep.problems.append("Couldn't add “\(a.title ?? "an activity")”: it needs days, a start and an end after it")
                    continue
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
            case .updateActivity:
                guard let i = activityIndex(a) else { missing("activity", a); continue }
                var c = s.commitments[i]
                if let w = weekdays(a.weekdays) { c.weekdays = w }
                if let t = tod(a.start) { c.start = t }
                if let t = tod(a.end) { c.end = t }
                if let t = a.title, !t.isEmpty, a.target != nil || a.id != nil { c.title = t }
                if let k = a.kind.flatMap(CommitmentKind.init(rawValue:)) { c.kind = k }
                if let b = a.bufferMinutes { c.bufferMinutes = max(0, min(90, b)) }
                if case .some(let col)? = colour(a.color) { c.color = col }
                if let v = a.validFrom { c.validFrom = AIMapper.parseDate(v, timeZone: tz).map { cal.startOfDay(for: $0) } }
                if let v = a.validUntil { c.validUntil = AIMapper.parseDate(v, timeZone: tz) }
                guard c.end > c.start else { rep.problems.append("\(c.title) would end before it starts, so it wasn't changed"); continue }
                s.commitments[i] = c
                rep.changes.append("Changed \(c.title)")
            case .deleteActivity:
                guard let i = activityIndex(a) else { missing("activity", a); continue }
                rep.changes.append("Removed \(s.commitments[i].title)")
                let id = s.commitments[i].id
                s.commitments.remove(at: i)
                s.exceptions.removeAll { $0.commitmentId == id }
            case .splitActivity:
                guard let i = activityIndex(a) else { missing("activity", a); continue }
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
                guard !made.isEmpty else { rep.problems.append("Couldn't split \(original.title): no usable parts"); continue }
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

            case .addEvent:
                let d = day(a.date)
                guard let st = tod(a.start), let en = tod(a.end),
                      let sd = cal.date(bySettingHour: st.hour, minute: st.minute, second: 0, of: d),
                      let ed0 = cal.date(bySettingHour: en.hour, minute: en.minute, second: 0, of: d) else {
                    rep.problems.append("Couldn't add “\(a.title ?? "an event")”: it needs a date, start and end"); continue
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
            case .updateEvent:
                guard let i = eventIndex(a) else { missing("event", a); continue }
                var ev = s.oneOffs[i]
                let d = a.date.map { day($0) } ?? cal.startOfDay(for: ev.start)
                let st = tod(a.start) ?? TimeOfDay(cal.component(.hour, from: ev.start), cal.component(.minute, from: ev.start))
                let en = tod(a.end) ?? TimeOfDay(cal.component(.hour, from: ev.end), cal.component(.minute, from: ev.end))
                if let sd = cal.date(bySettingHour: st.hour, minute: st.minute, second: 0, of: d),
                   let ed = cal.date(bySettingHour: en.hour, minute: en.minute, second: 0, of: d) {
                    ev.start = sd
                    ev.end = ed > sd ? ed : ed.addingTimeInterval(86400)
                }
                if let t = a.title, !t.isEmpty, a.target != nil || a.id != nil { ev.title = t }
                if case .some(let c)? = colour(a.color) { ev.color = c }
                s.oneOffs[i] = ev
                rep.changes.append("Changed \(ev.title)")
            case .deleteEvent:
                guard let i = eventIndex(a) else { missing("event (calendar events are changed in Calendar)", a); continue }
                rep.changes.append("Removed \(s.oneOffs[i].title)")
                s.oneOffs.remove(at: i)

            case .changeDay:
                // An existing day change by id: edit it in place.
                if let r = ref(a), let i = s.exceptions.firstIndex(where: { Ref.matches(r, prefix: "d", full: $0.id.uuidString) }) {
                    if let v = a.date { s.exceptions[i].day = day(v) }
                    if let c = a.cancelled { s.exceptions[i].cancelled = c }
                    if let t = tod(a.start) { s.exceptions[i].start = t }
                    if let t = tod(a.end) { s.exceptions[i].end = t }
                    if let t = tod(a.wake) { s.exceptions[i].wake = t }
                    if let n = a.note { s.exceptions[i].note = n }
                    rep.changes.append("Changed that day")
                    continue
                }
                let d = day(a.date)
                var ex = DayException(day: d, cancelled: a.cancelled ?? false, start: tod(a.start), end: tod(a.end),
                                      wake: tod(a.wake), note: a.note)
                let t = (a.target ?? a.activity)?.lowercased()
                if let r = ref(a), let i = s.commitments.firstIndex(where: { Ref.matches(r, prefix: "a", full: $0.id.uuidString) }) {
                    ex.commitmentId = s.commitments[i].id
                } else if let t, !t.isEmpty {
                    if let k = CommitmentKind(rawValue: t) {
                        ex.kind = k
                    } else if let i = activityIndex(named: t) {
                        ex.commitmentId = s.commitments[i].id
                    } else if t.contains("school") || t.contains("class") {
                        ex.kind = .school
                    } else { missing("activity", a); continue }
                } else if ex.wake == nil { rep.problems.append("A day change needs an activity, or a wake time"); continue }
                // Replace an earlier change for the same thing on the same day.
                s.exceptions.removeAll { cal.isDate($0.day, inSameDayAs: d) && $0.commitmentId == ex.commitmentId
                    && $0.kind == ex.kind && ($0.wake != nil) == (ex.wake != nil) }
                s.exceptions.append(ex)
                let what = ex.commitmentId.flatMap { id in s.commitments.first { $0.id == id }?.title } ?? ex.kind?.rawValue ?? "plans"
                rep.changes.append(ex.cancelled ? "No \(what) on that day" : ex.wake != nil && ex.commitmentId == nil && ex.kind == nil
                                   ? "Wake-up changed that day" : "Changed \(what) that day")
            case .deleteDayChange:
                let before = s.exceptions.count
                if let r = ref(a) {
                    s.exceptions.removeAll { Ref.matches(r, prefix: "d", full: $0.id.uuidString) }
                } else if let v = a.date {
                    let d = day(v)
                    let target = (a.target ?? "").lowercased()
                    let cid = target.isEmpty ? nil : activityIndex(named: target).map { s.commitments[$0].id }
                    s.exceptions.removeAll { e in
                        cal.isDate(e.day, inSameDayAs: d) && (target.isEmpty || e.commitmentId == cid
                            || (e.kind.map { target.contains($0.rawValue) } ?? false))
                    }
                }
                if s.exceptions.count < before { rep.changes.append("That day is back to normal") }
                else { missing("day change", a) }

            case .log:
                guard let act = a.activity?.lowercased(), !act.isEmpty else { continue }
                let phase = MarkerPhase(rawValue: a.phase ?? "end") ?? .end
                s.markers.append(TimelineEvent(at: when(a.at), phrase: a.note ?? act, activity: act,
                                               category: TimeCategory(rawValue: a.category ?? "") ?? .free, phase: phase, source: .voice))
                rep.changes.append("Logged \(act.replacingOccurrences(of: "_", with: " "))")
            case .routine:
                guard let id = a.routine ?? a.target, let i = s.routines.firstIndex(where: { $0.id == id || $0.name.lowercased() == id.lowercased() }) else {
                    missing("routine", a); continue
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
            case .mood:
                guard let m = a.mood else { continue }
                s.moods.append(MoodEntry(at: now, mood: m, energy: a.energy, note: a.note))
            case .screenTime:
                let d = day(a.date)
                let apps = (a.apps ?? []).map { AppUsage(name: $0.name, minutes: max(0, $0.minutes), distracting: $0.distracting ?? false) }
                let distracting = a.distractingMinutes ?? apps.filter(\.distracting).reduce(0) { $0 + $1.minutes }
                let entry = ScreenDay(day: d, distractingMinutes: max(0, distracting), totalMinutes: a.screenMinutes,
                                      apps: apps.isEmpty ? nil : apps, source: "screenshot")
                s.screen.removeAll { cal.isDate($0.day, inSameDayAs: d) }
                s.screen.append(entry)
                s.screen.sort { $0.day < $1.day }
                rep.changes.append("Screen time saved")
            case .settings:
                var any = false
                if let k = a.key, let v = a.value {
                    if let line = DumpSettings.apply(key: k, value: v, to: &s.prefs) { rep.changes.append("Setting: \(line)"); any = true }
                    else { rep.problems.append("Couldn't set \(k) to “\(v)”") }
                }
                if let v = a.sleepNeedMinutes { s.prefs.sleepNeedMinutes = max(450, min(600, v)); any = true }
                if let v = tod(a.freeDayWake) { s.prefs.freeDayWake = v; any = true }
                if let v = a.maxStudyMinutesSchoolDay { s.prefs.maxStudyMinutesSchoolDay = max(30, min(360, v)); any = true }
                if let v = a.minFreeMinutesSchoolDay { s.prefs.minFreeMinutesSchoolDay = max(30, min(300, v)); any = true }
                if let v = a.interests { s.prefs.interests = v; any = true }
                if any && a.key == nil { rep.changes.append("Settings updated") }
            case .setColor:
                guard let c = colour(a.color ?? a.value) else {
                    rep.problems.append("“\(a.color ?? "")” isn't a colour I know (try \(Palette.names.prefix(6).joined(separator: ", ")), or #RRGGBB)")
                    continue
                }
                let label = c ?? "default"
                if let cat = Palette.category(a.category) {
                    s.prefs.colors[cat] = c
                    rep.changes.append("\(cat.replacingOccurrences(of: "_", with: " ").capitalized) is \(label)")
                } else if let r = ref(a) {
                    if let i = s.items.firstIndex(where: { Ref.matches(r, prefix: "t", full: $0.id.uuidString) }) {
                        s.items[i].color = c; rep.changes.append("\(s.items[i].title) is \(label)")
                    } else if let i = s.commitments.firstIndex(where: { Ref.matches(r, prefix: "a", full: $0.id.uuidString) }) {
                        s.commitments[i].color = c; rep.changes.append("\(s.commitments[i].title) is \(label)")
                    } else if let i = s.oneOffs.firstIndex(where: { Ref.matches(r, prefix: "e", full: $0.id) }) {
                        s.oneOffs[i].color = c; rep.changes.append("\(s.oneOffs[i].title) is \(label)")
                    } else { missing("thing to colour", a) }
                } else if let i = activityIndex(named: name(a)) {
                    s.commitments[i].color = c; rep.changes.append("\(s.commitments[i].title) is \(label)")
                } else if let i = taskIndex(a) {
                    s.items[i].color = c; rep.changes.append("\(s.items[i].title) is \(label)")
                } else if let cat = Palette.category(name(a)) {
                    s.prefs.colors[cat] = c
                    rep.changes.append("\(cat.capitalized) is \(label)")
                } else { missing("thing to colour", a) }
            }
        }
        return rep
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
