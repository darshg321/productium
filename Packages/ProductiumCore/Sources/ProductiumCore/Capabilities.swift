import Foundation

public enum RiskTier: Int, Codable, Comparable, Sendable, CaseIterable {
    case data = 0, learned = 1, behaviour = 2
    public static func < (a: RiskTier, b: RiskTier) -> Bool { a.rawValue < b.rawValue }

    public var title: String {
        switch self {
        case .data: return "Data"
        case .learned: return "Learned value"
        case .behaviour: return "Behaviour"
        }
    }
}

public enum Writer: String, Codable, Sendable {
    case student, box, reflection

    public func mayApply(_ t: RiskTier) -> Bool {
        switch self {
        case .student: return true
        case .box: return t < .behaviour
        case .reflection: return true
        }
    }

    public func mayWrite(_ s: AboutMeSection) -> Bool {
        switch self {
        case .student: return true
        case .box: return s == .stated
        case .reflection: return s != .stated
        }
    }
}

public typealias AboutMeWriter = Writer

public struct BehaviourPolicy: Codable, Hashable, Sendable {
    public var capacityMultiplier: Double
    public var maxBlockMinutes: Int
    public var freeTimeMultiplier: Double
    public var followUpShiftMinutes: Int
    public var intentions: [IntentionNudge]

    public init(capacityMultiplier: Double = 1, maxBlockMinutes: Int = 55, freeTimeMultiplier: Double = 1,
                followUpShiftMinutes: Int = 0, intentions: [IntentionNudge] = []) {
        self.intentions = intentions
        self.capacityMultiplier = capacityMultiplier
        self.maxBlockMinutes = maxBlockMinutes
        self.freeTimeMultiplier = freeTimeMultiplier
        self.followUpShiftMinutes = followUpShiftMinutes
    }
}

public struct IntentionNudge: Codable, Hashable, Identifiable, Sendable {
    public enum Trigger: String, Codable, Sendable { case time, arriveHome }
    public var id: UUID
    public var trigger: Trigger
    public var weekdays: [Int]
    public var time: TimeOfDay?
    public var text: String
    public var itemId: UUID?
    /// Set when the student (through the box) made it; the insight pass counts and changes only its own.
    public var byStudent: Bool?

    public init(id: UUID = UUID(), trigger: Trigger, weekdays: [Int] = [], time: TimeOfDay? = nil, text: String, itemId: UUID? = nil,
                byStudent: Bool? = nil) {
        self.byStudent = byStudent
        self.id = id
        self.trigger = trigger
        self.weekdays = weekdays
        self.time = time
        self.text = text
        self.itemId = itemId
    }
}

public struct KnobSpec: Hashable, Sendable {
    public var key: String
    public var tier: RiskTier
    public var format: String
    public var range: ClosedRange<Double>?
    public var maxStep: Double?
    public var reflectionForbidden: Bool
    public var note: String

    public init(_ key: String, _ tier: RiskTier, _ format: String, range: ClosedRange<Double>? = nil, maxStep: Double? = nil,
                reflectionForbidden: Bool = false, note: String = "") {
        self.key = key
        self.tier = tier
        self.format = format
        self.range = range
        self.maxStep = maxStep
        self.reflectionForbidden = reflectionForbidden
        self.note = note
    }
}

public enum Registry {
    static let colorFormat = "a colour name, #RRGGBB, or default"

    public static let knobs: [KnobSpec] = [
        KnobSpec("color.<category>", .data, colorFormat, note: "categories: \(Palette.categories.joined(separator: "|")), subject:<name>, task:<kind>"),
        KnobSpec("interests", .data, "comma list"),
        KnobSpec("schoolDays", .data, "weekday numbers, e.g. 2,3,4,5,6"),
        KnobSpec("autoWake", .data, "true|false (work the wake-up back from the first class)"),
        KnobSpec("windDownMinutes", .data, "0-90"),
        KnobSpec("nudgeLevel", .data, "gentle|standard|persistent"),
        KnobSpec("alarms", .data, "true|false"), KnobSpec("wakeAlarms", .data, "true|false (the morning alarm)"),
        KnobSpec("movementNudges", .data, "true|false"), KnobSpec("daylightNudges", .data, "true|false"),
        KnobSpec("celebrations", .data, "full|subtle|off"), KnobSpec("celebrationSound", .data, "true|false"),
        KnobSpec("metricTiles", .data, "comma list of: \(MetricID.allCases.map(\.rawValue).joined(separator: "|")) (the Review tiles, in order)"),
        KnobSpec("scrollingApps", .data, "App:on|off, … (what counts as scrolling)"), KnobSpec("scrollCheckIns", .data, "true|false"),
        KnobSpec("arrivingHome", .data, "true|false"), KnobSpec("deadlineNudges", .data, "true|false"),
        KnobSpec("prompt.<kind>", .data, "off|quiet|live activity|notification|alarm",
                 note: "kinds: \(PromptKind.allCases.map(\.rawValue).joined(separator: "|"))"),
        KnobSpec("sleepNeedMinutes", .learned, "450-600", reflectionForbidden: true),
        KnobSpec("sleepFloorMinutes", .learned, "360-480", reflectionForbidden: true),
        KnobSpec("allowSleepTradeoffs", .learned, "true|false", reflectionForbidden: true),
        KnobSpec("schoolDayWake", .learned, "HH:mm"), KnobSpec("freeDayWake", .learned, "HH:mm"),
        KnobSpec("wake", .learned, "HH:mm, + \"free days\" or \"every day\" (default school days)"),
        KnobSpec("sleep", .learned, "hours of sleep needed, e.g. 9 h", reflectionForbidden: true),
        KnobSpec("rotation", .data, "a date and its day of the timetable rotation: \"today 2\", \"2026-11-24 1\""),
        KnobSpec("study.schoolDayCapacity", .learned, "minutes", range: 30...480),
        KnobSpec("study.freeDayCapacity", .learned, "minutes", range: 30...600),
        KnobSpec("study.schoolDayFreeTime", .learned, "minutes", range: 0...360),
        KnobSpec("study.freeDayFreeTime", .learned, "minutes", range: 0...600),
        KnobSpec("study.focusMinutes", .learned, "minutes", range: 15...90),
        KnobSpec("study.breakMinutes", .learned, "minutes", range: 0...30),
        KnobSpec("routines.dinnerTime", .learned, "HH:mm"), KnobSpec("routines.dinnerMinutes", .learned, "minutes, 0 = none", range: 0...120),
        KnobSpec("sleep.chronotype", .learned, "early|intermediate|late"),
        KnobSpec("planner.capacityMultiplier", .behaviour, "0.6-1.3", range: 0.6...1.3, maxStep: 0.1,
                 note: "how much of the learned study capacity to plan"),
        KnobSpec("planner.maxBlockMinutes", .behaviour, "20-60", range: 20...60, maxStep: 10,
                 note: "longest study block"),
        KnobSpec("planner.freeTimeMultiplier", .behaviour, "0.8-1.5", range: 0.8...1.5, maxStep: 0.1,
                 note: "how much free time to protect"),
        KnobSpec("nudges.followUpShiftMinutes", .behaviour, "-3-10", range: -3...10, maxStep: 5,
                 note: "how much later than usual to ask again if a block hasn't started"),
    ]

    public static func knob(_ key: String) -> KnobSpec? {
        let k = key.trimmingCharacters(in: .whitespaces)
        if k.lowercased().hasPrefix("color") || k.lowercased().hasPrefix("colour") { return knobs[0] }
        if k.lowercased().hasPrefix("prompt.") { return knobs.first { $0.key == "prompt.<kind>" } }
        let p = k.lowercased().filter { $0.isLetter || $0 == "." }
        return knobs.first { $0.key.lowercased().filter { $0.isLetter || $0 == "." } == p }
            ?? knobs.first { $0.key.contains(".") && $0.key.split(separator: ".").last.map { $0.lowercased() == p } == true }
    }

}

public enum KnobResult: Hashable, Sendable {
    case changed(String)
    case refused(String)
}

public enum Knobs {
    public static func value(_ key: String, in p: BehaviourPolicy) -> Double? {
        switch key {
        case "planner.capacityMultiplier": return p.capacityMultiplier
        case "planner.maxBlockMinutes": return Double(p.maxBlockMinutes)
        case "planner.freeTimeMultiplier": return p.freeTimeMultiplier
        case "nudges.followUpShiftMinutes": return Double(p.followUpShiftMinutes)
        default: return nil
        }
    }

    static func write(_ key: String, _ v: Double, in p: inout BehaviourPolicy) {
        switch key {
        case "planner.capacityMultiplier": p.capacityMultiplier = (v * 100).rounded() / 100
        case "planner.maxBlockMinutes": p.maxBlockMinutes = Int(v.rounded())
        case "planner.freeTimeMultiplier": p.freeTimeMultiplier = (v * 100).rounded() / 100
        case "nudges.followUpShiftMinutes": p.followUpShiftMinutes = Int(v.rounded())
        default: break
        }
    }

    public static func bounded(_ spec: KnobSpec, from current: Double, to target: Double) -> Double {
        var v = target
        if let s = spec.maxStep { v = max(current - s, min(current + s, v)) }
        if let r = spec.range { v = max(r.lowerBound, min(r.upperBound, v)) }
        return v
    }

    /// v1.5 C3: "wake" / "sleep" in your words. "wake" = school days unless the value says free days / weekends or
    /// every day; a school-day wake you set is used as is (not worked back from the first class).
    static func sleepAlias(_ rawKey: String, _ value: String, by writer: Writer, in s: inout DumpState) -> KnobResult? {
        let k = rawKey.lowercased().filter(\.isLetter)
        let v = value.lowercased()
        let wakeKeys = ["wake", "wakeup", "waketime", "wakeuptime", "schoolwake", "weekdaywake", "freewake", "weekendwake", "schooldaywake"]
        if wakeKeys.contains(k) {
            guard let t = clock(in: v) else { return .refused("“\(value)” isn't a time for wake (like 7:30)") }
            let free = k.hasPrefix("free") || k.hasPrefix("weekend") || v.contains("free") || v.contains("weekend")
            let both = v.contains("every day") || v.contains("everyday") || v.contains("all days") || v.contains("both")
            var lines: [String] = []
            if !free || both {
                s.prefs.schoolDayWake = t
                s.prefs.autoWake = false
                lines.append("School-day wake → \(t.label)")
            }
            if free || both {
                s.prefs.freeDayWake = t
                lines.append("Free-day wake → \(t.label)")
            }
            return .changed(lines.joined(separator: ", "))
        }
        if ["rotation", "rotationday", "dayrotation", "schoolday", "daynumber"].contains(k) {
            // "today 2", "2026-11-24 day 1", "tomorrow is a day 2"
            guard let n = v.split(whereSeparator: { !$0.isNumber }).compactMap({ Int($0) }).last(where: { (1...2).contains($0) }) else {
                return .refused("Say which day of the rotation, like “today 2”")
            }
            let cal = Calendar.current
            let today = cal.startOfDay(for: Date())
            var date = today
            if v.contains("tomorrow") { date = cal.date(byAdding: .day, value: 1, to: today) ?? today }
            if let r = v.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression), let d = DayKeys.date(String(v[r]), cal) { date = d }
            Rotation.set(date, to: n, book: &s.dayRules, calendar: cal)
            return .changed("\(DateFormatter.local("EEE d MMM", cal).string(from: date)) is a Day \(n)")
        }
        if ["sleep", "sleepneed", "sleephours", "sleepminutes", "sleeplength", "sleepneeded"].contains(k) {
            guard let n = Double(v.prefix { $0.isNumber || $0 == "." }), n > 0 else { return .refused("“\(value)” isn't an amount of sleep (like 9 h)") }
            let minutes = Int((n <= 12 && !v.contains("min") ? n * 60 : n).rounded())
            if writer == .reflection { return .refused("Sleep need is yours to change, never Productium's") }
            s.prefs.sleepNeedMinutes = max(450, min(600, minutes))
            return .changed("Sleep need → \(durationText(s.prefs.sleepNeedMinutes))")
        }
        return nil
    }

    /// The first clock time in free text: "7:30 on school days", "wake at 7", "6:45am".
    static func clock(in v: String) -> TimeOfDay? {
        guard let r = v.range(of: #"\d{1,2}(:\d{2})?\s*(am|pm)?"#, options: .regularExpression) else { return nil }
        return ClockText.timeOfDay(String(v[r]).replacingOccurrences(of: " ", with: ""))
    }

    static func durationText(_ m: Int) -> String { m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min" }

    public static func set(_ rawKey: String, _ value: String, by writer: Writer, in s: inout DumpState) -> KnobResult {
        if let r = sleepAlias(rawKey, value, by: writer, in: &s) { return r }
        // v1.6 A3: a routine moves with its setting ("dinners at 7:30" is one change, not one per day).
        switch rawKey.lowercased().filter(\.isLetter) {
        case "dinner", "dinnertime": return set("routines.dinnerTime", value, by: writer, in: &s)
        case "dinnerminutes", "dinnerlength": return set("routines.dinnerMinutes", value, by: writer, in: &s)
        default: break
        }
        guard let spec = Registry.knob(rawKey) else { return .refused("There's no setting called “\(rawKey)”") }
        guard writer.mayApply(spec.tier) else {
            return .refused("“\(spec.key)” changes how the app behaves, so Productium only adjusts it from how your weeks go (you can see and undo it in What Productium Thinks)")
        }
        if writer == .reflection && spec.reflectionForbidden {
            return .refused("“\(spec.key)” is yours to change, never Productium's")
        }
        if spec.tier == .behaviour {
            guard let target = Double(value.trimmingCharacters(in: .whitespaces).filter { $0.isNumber || $0 == "." || $0 == "-" }),
                  let cur = Self.value(spec.key, in: s.policy) else { return .refused("“\(value)” isn't a number for \(spec.key)") }
            let v = bounded(spec, from: cur, to: target)
            write(spec.key, v, in: &s.policy)
            return .changed("\(spec.key) → \(Self.value(spec.key, in: s.policy).map(format) ?? value)")
        }
        if spec.key.contains("."), s.beliefs[spec.key] != nil {
            let t = value.trimmingCharacters(in: .whitespaces).lowercased()
            var v: Double?
            if spec.key == "routines.dinnerTime" { v = ClockText.timeOfDay(t).map { Double($0.minutesFromMidnight) } }
            else if spec.key == "sleep.chronotype" { v = Chronotype(rawValue: t)?.shiftHours }
            else if let n = Double(t.prefix { $0.isNumber || $0 == "." }) {
                v = t.contains("h") && !t.contains("min") && n <= 12 ? n * 60 : n
            }
            guard var x = v else { return .refused("Couldn't set \(spec.key) to “\(value)”") }
            if let r = spec.range { x = max(r.lowerBound, min(r.upperBound, x)) }
            _ = s.beliefs.state(spec.key, x, now: Date())
            return .changed("\(s.beliefs[spec.key]?.label ?? spec.key): you said \(s.beliefs[spec.key]?.display ?? value)")
        }
        if spec.key == "color.<category>" {
            let name = String(rawKey.drop { $0 != "." }.dropFirst())
            guard let cat = Palette.category(name) else { return .refused("“\(name)” isn't a category I can colour") }
            let l = value.trimmingCharacters(in: .whitespaces).lowercased()
            if ["", "default", "none", "reset", "auto", "clear"].contains(l) {
                s.prefs.colors[cat] = nil
                return .changed("\(cat.replacingOccurrences(of: "_", with: " ").capitalized) is back to its default colour")
            }
            guard let c = Palette.normalise(value) else {
                return .refused("“\(value)” isn't a colour I know (try \(Palette.names.prefix(6).joined(separator: ", ")), or #RRGGBB)")
            }
            s.prefs.colors[cat] = c
            return .changed("\(cat.replacingOccurrences(of: "_", with: " ").capitalized) is \(c)")
        }
        if spec.key == "prompt.<kind>" {
            let name = String(rawKey.drop { $0 != "." }.dropFirst()).plainKey
            guard let kind = PromptKind.allCases.first(where: { $0.rawValue.lowercased() == name }) else {
                return .refused("“\(name)” isn't a kind of prompt")
            }
            let v = value.lowercased().filter(\.isLetter)
            guard let sev = Severity.allCases.first(where: { $0.rawValue.lowercased() == v }) else {
                return .refused("A prompt is off, quiet, live activity, notification or alarm")
            }
            s.prefs.prompts[kind] = sev
            return .changed("\(kind.title) → \(sev.title)")
        }
        let lowerValue = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch spec.key {
        case "celebrations":
            guard let l = CelebrationLevel(rawValue: lowerValue) else { return .refused("celebrations is full, subtle or off") }
            s.rewardSettings.level = l
            return .changed("Celebrations → \(l.title)")
        case "metricTiles":
            let ids = value.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { MetricID(rawValue: String($0).trimmingCharacters(in: .whitespaces)) }
            guard !ids.isEmpty else { return .refused("metricTiles is a list like scrolling, sleep, focus") }
            var seen = Set<MetricID>()
            s.metricTiles = ids.filter { seen.insert($0).inserted }.prefix(12).map { $0 }
            return .changed("Review tiles: \(s.metricTiles.map(\.rawValue).joined(separator: ", "))")
        case "celebrationSound":
            guard let b = ["true", "on", "yes"].contains(lowerValue) ? true : ["false", "off", "no"].contains(lowerValue) ? false : nil else { return .refused("celebrationSound is true or false") }
            s.rewardSettings.sound = b
            return .changed("Celebration sound → \(b ? "on" : "off")")
        case "scrollingApps":
            var n = 0
            for part in value.split(separator: ",") {
                let bits = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard bits.count == 2, !bits[0].isEmpty else { continue }
                s.scrollingApps[bits[0]] = ["on", "true", "yes", "1"].contains(bits[1].lowercased())
                n += 1
            }
            return n > 0 ? .changed("Scrolling apps: \(n) updated") : .refused("scrollingApps looks like Instagram:on, Slack:off")
        case "wakeAlarms":
            if ["true", "on", "yes", "1"].contains(lowerValue), !s.prefs.wakeAlarms, !s.alarmsAllowed {
                return .refused("The morning alarm needs alarms allowed first: Settings → Connections → Wake-Up Alarms")
            }
        default: break
        }
        guard let line = PreferenceKnobs.apply(key: spec.key, value: value, to: &s.prefs) else {
            return .refused("Couldn't set \(spec.key) to “\(value)”")
        }
        return .changed(line)
    }

    static func format(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.2g", v) }
}

enum PreferenceKnobs {
    static func apply(key raw: String, value v: String, to p: inout Preferences) -> String? {
        let key = raw.plainKey
        let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = t.lowercased()
        func int(_ lo: Int, _ hi: Int) -> Int? {
            let digits = t.prefix { $0.isNumber || $0 == "-" }
            guard let n = Int(digits) else { return nil }
            let hours = lower.contains("h") && !lower.contains("min") && n <= 12
            return max(lo, min(hi, hours ? n * 60 : n))
        }
        func bool() -> Bool? {
            if ["true", "yes", "on", "1", "enable", "enabled"].contains(lower) { return true }
            if ["false", "no", "off", "0", "disable", "disabled", "none"].contains(lower) { return false }
            return nil
        }
        func time() -> TimeOfDay? { ClockText.timeOfDay(t) }
        switch key {
        case "sleepneedminutes": guard let n = int(450, 600) else { return nil }; p.sleepNeedMinutes = n
        case "sleepfloorminutes": guard let n = int(360, 480) else { return nil }; p.sleepFloorMinutes = n
        case "schooldaywake": guard let x = time() else { return nil }; p.schoolDayWake = x
        case "freedaywake": guard let x = time() else { return nil }; p.freeDayWake = x
        case "autowake": guard let b = bool() else { return nil }; p.autoWake = b
        case "winddownminutes": guard let n = int(0, 90) else { return nil }; p.windDownMinutes = n
        case "allowsleeptradeoffs": guard let b = bool() else { return nil }; p.allowSleepTradeoffs = b
        case "schooldays":
            let days = Set(t.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.filter { (1...7).contains($0) })
            guard !days.isEmpty || lower == "none" else { return nil }
            p.schoolDays = days
        case "interests":
            p.interests = t.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        case "nudgelevel":
            guard let l = NudgeLevel(rawValue: lower) else { return nil }; p.nudges.level = l
        case "alarms":
            guard let b = bool() else { return nil }
            p.nudges.alarms = b
            for k in [PromptKind.bedtime, .leave, .missedStart] { p.prompts[k] = b ? .alarm : .notification }
        case "wakealarms": guard let b = bool() else { return nil }; p.wakeAlarms = b; p.prompts[.wake] = b ? .alarm : .notification
        case "movementnudges": guard let b = bool() else { return nil }; p.nudges.movement = b; p.prompts[.movement] = b ? .notification : .off
        case "daylightnudges": guard let b = bool() else { return nil }; p.nudges.daylight = b; p.prompts[.daylight] = b ? .notification : .off
        case "scrollcheckins": guard let b = bool() else { return nil }; p.nudges.scrollCheckIns = b; p.prompts[.scrollCheckIns] = b ? .notification : .off
        case "arrivinghome": guard let b = bool() else { return nil }; p.nudges.arrivingHome = b
        case "deadlinenudges": guard let b = bool() else { return nil }; p.nudges.deadlines = b; p.prompts[.deadline] = b ? .notification : .off
        default: return nil
        }
        return "\(raw) → \(t)"
    }
}
