import Foundation

// MARK: - How pushy the phone is

/// How much the phone interrupts. Every level keeps the basics (block start, "how did it go?",
/// the evening check-in and morning brief); higher levels add warnings before things happen
/// and follow-ups when they don't.
public enum NudgeLevel: String, Codable, CaseIterable, Sendable {
    case gentle, standard, persistent

    public var title: String {
        switch self {
        case .gentle: return "Gentle"
        case .standard: return "Standard"
        case .persistent: return "Persistent"
        }
    }

    public var summary: String {
        switch self {
        case .gentle:
            return "Block starts, “how did it go?”, wind-down, and the evening before something is due."
        case .standard:
            return "Adds a 10-minute heads-up before work, one follow-up if you haven't started, a leave-soon warning, bedtime, and a note when you get home."
        case .persistent:
            return "Adds more follow-ups, a “still up?” after bedtime, a same-day deadline reminder, and more scrolling check-ins."
        }
    }

    /// Minutes after a block's start to ask again if focus hasn't started.
    public var followUps: [Int] {
        switch self {
        case .gentle: return []
        case .standard: return [7]
        case .persistent: return [5, 12, 20]
        }
    }

    /// Minutes into a scroll session (after "Go back anyway") to check in.
    public var scrollCheckIns: [Int] {
        switch self {
        case .gentle: return [15]
        case .standard: return [10, 20]
        case .persistent: return [10, 20, 30]
        }
    }
}

public struct NudgeSettings: Codable, Hashable, Sendable {
    public var level: NudgeLevel
    /// Real alarms (AlarmKit) for bedtime, leaving and a block that hasn't started. Opt-in:
    /// they ring through silent mode and Focus.
    public var alarms: Bool
    public var scrollCheckIns: Bool
    public var arrivingHome: Bool
    public var deadlines: Bool

    public init(level: NudgeLevel = .standard, alarms: Bool = false, scrollCheckIns: Bool = true,
                arrivingHome: Bool = true, deadlines: Bool = true) {
        self.level = level
        self.alarms = alarms
        self.scrollCheckIns = scrollCheckIns
        self.arrivingHome = arrivingHome
        self.deadlines = deadlines
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = NudgeSettings()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? def }
        level = v(.level, d.level)
        alarms = v(.alarms, d.alarms)
        scrollCheckIns = v(.scrollCheckIns, d.scrollCheckIns)
        arrivingHome = v(.arrivingHome, d.arrivingHome)
        deadlines = v(.deadlines, d.deadlines)
    }
}

// MARK: - What the plan says right now

/// One word for what the plan says this minute, so Shortcuts automations can branch on it
/// ("if it's wind-down, turn on grayscale").
public enum PlanMoment: String, Codable, CaseIterable, Sendable {
    case focus, breakTime, busy, free, windDown, sleep

    public var title: String {
        switch self {
        case .focus: return "Focus"
        case .breakTime: return "Break"
        case .busy: return "Busy"
        case .free: return "Free"
        case .windDown: return "Wind-down"
        case .sleep: return "Sleep"
        }
    }
}

extension Plan {
    /// Sleep counts too (`current(at:)` skips it). A gap with nothing planned is free.
    public func moment(at now: Date) -> PlanMoment {
        guard let b = blocks.first(where: { $0.start <= now && now < $0.end }) else { return .free }
        switch b.kind {
        case .work, .review: return .focus
        case .breakTime: return .breakTime
        case .free, .gap: return .free
        case .commitment, .event, .meal, .routine: return .busy
        case .windDown: return .windDown
        case .sleep: return .sleep
        }
    }
}

// MARK: - Notifications to schedule

public enum NudgeKind: String, Codable, Sendable {
    case leadUp, start, followUp, end, windDown, bedtime, stillUp, leaveSoon, leaveNow, deadline, checkIn, morning, marker
}

/// One local notification, decided here and handed to UserNotifications by the app.
public struct PlannedNudge: Hashable, Sendable {
    public var id: String
    public var kind: NudgeKind
    public var at: Date
    public var title: String
    public var body: String
    public var blockId: UUID?
    public var itemId: UUID?
    public var marker: String?
    public var deeplink: String?
    /// Breaks through Focus where the build allows it.
    public var urgent: Bool

    public init(id: String, kind: NudgeKind, at: Date, title: String, body: String, blockId: UUID? = nil,
                itemId: UUID? = nil, marker: String? = nil, deeplink: String? = nil, urgent: Bool = false) {
        self.id = id
        self.kind = kind
        self.at = at
        self.title = title
        self.body = body
        self.blockId = blockId
        self.itemId = itemId
        self.marker = marker
        self.deeplink = deeplink
        self.urgent = urgent
    }
}

/// An AlarmKit alarm: louder than a notification, used only when the student opts in.
public struct PlannedAlarm: Hashable, Sendable {
    public enum Kind: String, Sendable { case bedtime, leave, missedStart }
    public var key: String
    public var kind: Kind
    public var at: Date
    public var title: String
    public var blockId: UUID?

    public init(key: String, kind: Kind, at: Date, title: String, blockId: UUID? = nil) {
        self.key = key
        self.kind = kind
        self.at = at
        self.title = title
        self.blockId = blockId
    }
}

public struct NudgeInput {
    public var now: Date
    public var calendar: Calendar
    public var plan: Plan
    public var items: [WorkItem]
    public var settings: NudgeSettings
    /// Block a focus session is running for: no start, follow-up or lead-up for it.
    public var startedBlockId: UUID?
    /// Blocks already answered (done / partly / skipped): nothing more about them.
    public var answeredBlockIds: Set<UUID>
    /// Blocks snoozed from a notification: their start and follow-ups are left to the snooze.
    public var snoozedBlockIds: Set<UUID>
    /// One-tap routine prompts while routines are still being learned.
    public var markerPrompts: [(Date, String)]
    /// iOS keeps at most 64 pending requests; leave room for wake-ups, housekeeping and snoozes.
    public var limit: Int
    /// How times read in the text ("4:30 PM"). The app passes the phone's own format.
    public var timeLabel: ((Date) -> String)?
    /// Tier 2 behaviour knobs (approved changes only).
    public var policy: BehaviourPolicy

    public init(now: Date, calendar: Calendar, plan: Plan, items: [WorkItem], settings: NudgeSettings,
                startedBlockId: UUID? = nil, answeredBlockIds: Set<UUID> = [], snoozedBlockIds: Set<UUID> = [],
                markerPrompts: [(Date, String)] = [], limit: Int = 52, timeLabel: ((Date) -> String)? = nil,
                policy: BehaviourPolicy = BehaviourPolicy()) {
        self.policy = policy
        self.now = now
        self.calendar = calendar
        self.plan = plan
        self.items = items
        self.settings = settings
        self.startedBlockId = startedBlockId
        self.answeredBlockIds = answeredBlockIds
        self.snoozedBlockIds = snoozedBlockIds
        self.markerPrompts = markerPrompts
        self.limit = limit
        self.timeLabel = timeLabel
    }
}

public enum NudgePlanner {
    public static let horizon: TimeInterval = 86400

    /// Every notification for the next 24 h, soonest first, at most `limit`.
    /// Pure: the app removes its pending "plan." requests and adds these.
    public static func plan(_ input: NudgeInput) -> [PlannedNudge] {
        let now = input.now
        let end = now.addingTimeInterval(horizon)
        let level = input.settings.level
        let plan = input.plan
        var out: [PlannedNudge] = []
        func add(_ n: PlannedNudge) { if n.at > now.addingTimeInterval(30) && n.at < end { out.append(n) } }
        func time(_ d: Date) -> String { input.timeLabel?(d) ?? clock(d, input.calendar) }

        // Study blocks: heads-up, start, follow-ups, "how did it go?".
        let study = plan.blocks.filter { $0.isStudy && $0.end > now && $0.start < end && !input.answeredBlockIds.contains($0.id) }
        for (i, b) in study.enumerated() {
            let started = b.id == input.startedBlockId
            let snoozed = input.snoozedBlockIds.contains(b.id)
            // A block that follows straight on from another doesn't need its own heads-up.
            let backToBack = i > 0 && study[i - 1].end >= b.start.addingTimeInterval(-15 * 60)
            if !started && !snoozed {
                if level != .gentle && !backToBack && b.minutes >= 20 {
                    add(PlannedNudge(id: "plan.lead.\(b.id)", kind: .leadUp, at: b.start.addingTimeInterval(-10 * 60),
                              title: "In 10 minutes: \(b.title)",
                              body: "Get water and open what you need. Pick the first small step now. Starts at \(time(b.start)).",
                              blockId: b.id, itemId: b.itemId))
                }
                add(PlannedNudge(id: "plan.start.\(b.id)", kind: .start, at: b.start, title: b.title,
                          body: b.hint ?? "Starting now. Tap Start Focus, or snooze it 10 minutes.",
                          blockId: b.id, itemId: b.itemId, deeplink: "productium://now", urgent: true))
                let followUps = level.followUps.map { max(2, $0 + input.policy.followUpShiftMinutes) }
                for (k, m) in followUps.enumerated() where Double(m) * 60 < b.end.timeIntervalSince(b.start) - 5 * 60 {
                    let left = b.minutes - m
                    let body = k == 0
                        ? "Not started yet. Even 10 minutes of it counts. \(left) minutes left in this block."
                        : k == followUps.count - 1
                            ? "Last nudge for this one. Start now, or tap Can't Today and it moves to a better slot."
                            : "Still time: \(left) minutes left. Open it and do the first small step."
                    add(PlannedNudge(id: "plan.follow.\(b.id).\(k)", kind: .followUp, at: b.start.addingTimeInterval(Double(m) * 60),
                              title: "\(b.title) hasn't started", body: body,
                              blockId: b.id, itemId: b.itemId, deeplink: "productium://now", urgent: level == .persistent))
                }
            }
            add(PlannedNudge(id: "plan.end.\(b.id)", kind: .end, at: b.end, title: "How did it go?", body: b.title,
                      blockId: b.id, itemId: b.itemId))
        }

        // Evening: check-in, wind-down, bedtime, and (persistent) a "still up?".
        if let wind = plan.blocks.first(where: { $0.kind == .windDown && $0.start > now.addingTimeInterval(30 * 60) && $0.start < end }) {
            add(PlannedNudge(id: "plan.checkin", kind: .checkIn, at: wind.start.addingTimeInterval(-30 * 60),
                      title: "20-second check-in",
                      body: "How was today? Anything new due? Reply here, no need to open the app."))
        }
        for w in plan.blocks where w.kind == .windDown && w.end > now && w.start < end {
            add(PlannedNudge(id: "plan.wind.\(w.id)", kind: .windDown, at: w.start, title: "Wind-down",
                      body: "Bed at \(time(w.end)). Screens off, lights low, phone on the charger outside the bedroom."))
        }
        for s in plan.blocks where s.kind == .sleep && s.start > now && s.start < end {
            if level != .gentle {
                add(PlannedNudge(id: "plan.bed.\(s.id)", kind: .bedtime, at: s.start, title: "Bedtime",
                          body: s.hint.map { "Lights out now for \($0)." } ?? "Lights out now.", urgent: true))
            }
            if level == .persistent {
                add(PlannedNudge(id: "plan.stillup.\(s.id)", kind: .stillUp, at: s.start.addingTimeInterval(20 * 60),
                          title: "Still up?", body: "Every 20 minutes now is 20 minutes less sleep. Put the phone down. Tomorrow's plan is ready."))
            }
        }

        // Morning brief and leaving the house.
        if let w = plan.wakePlans.first(where: { $0.wake > now && $0.wake < end }) {
            let day = plan.blocks(on: w.wake, calendar: input.calendar).filter(\.isStudy)
            let mins = day.reduce(0) { $0 + $1.minutes }
            var body = day.first.map { "First up \(time($0.start)): \($0.title)." } ?? "Enjoy it."
            if let leave = w.leaveBy { body += " Leave by \(time(leave))." }
            add(PlannedNudge(id: "plan.morning", kind: .morning, at: w.wake.addingTimeInterval(10 * 60),
                      title: day.isEmpty ? "Nothing planned today" : "Today: \(minutesLabel(mins)) of focused work",
                      body: body, deeplink: "productium://today"))
        }
        for w in plan.wakePlans where (w.leaveBy ?? .distantPast) > now {
            guard let leave = w.leaveBy, leave < end else { continue }
            if level != .gentle {
                add(PlannedNudge(id: "plan.leave.soon.\(Int(leave.timeIntervalSince1970))", kind: .leaveSoon,
                          at: leave.addingTimeInterval(-10 * 60), title: "Leave in 10 minutes",
                          body: "Out the door at \(time(leave)). Shoes, bag, keys.", urgent: true))
            }
            add(PlannedNudge(id: "plan.leave.now.\(Int(leave.timeIntervalSince1970))", kind: .leaveNow, at: leave,
                      title: "Time to go", body: w.firstCommitment.map { "Leave now to be there by \(time($0))." } ?? "Leave now.",
                      urgent: true))
        }

        // Deadlines: the evening before (6 pm), and on the day for persistent.
        if input.settings.deadlines {
            for item in input.items where !item.isDone && item.parentId == nil && item.due > now {
                let left = max(0, item.estimateMinutes - item.completedMinutes)
                guard left > 0 || item.kind.isMemoryBased else { continue }
                let cal = input.calendar
                let next = plan.blocks.first { $0.isStudy && $0.itemId == item.id && $0.start > now }
                let nextText = next.map { " Next session \(dayWord($0.start, now: now, cal))\(time($0.start))." } ?? ""
                if let dayBefore = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: item.due)),
                   let six = cal.date(bySettingHour: 18, minute: 0, second: 0, of: dayBefore) {
                    let what = item.kind.isMemoryBased ? "One more round of self-testing tonight beats rereading." :
                        "About \(minutesLabel(left)) of it left."
                    add(PlannedNudge(id: "plan.due.\(item.id)", kind: .deadline, at: six,
                              title: "Due tomorrow at \(time(item.due)): \(item.title)", body: what + nextText,
                              itemId: item.id, deeplink: "productium://tasks"))
                }
                if level == .persistent, cal.component(.hour, from: item.due) >= 11 {
                    add(PlannedNudge(id: "plan.dueday.\(item.id)", kind: .deadline, at: item.due.addingTimeInterval(-3 * 3600),
                              title: "Due at \(time(item.due)): \(item.title)",
                              body: "Three hours left. If it's not done, a finished good-enough version beats a perfect late one.",
                              itemId: item.id, deeplink: "productium://tasks", urgent: true))
                }
            }
        }

        for (i, s) in input.markerPrompts.prefix(4).enumerated() {
            add(PlannedNudge(id: "plan.marker.\(i)", kind: .marker, at: s.0, title: s.1 + "?",
                      body: "Tap Yes when it happens. A few of these and Productium learns your routine.", marker: s.1))
        }

        // Several things at the same minute: keep the most useful one.
        return Array(dedupe(out).sorted { $0.at < $1.at }.prefix(input.limit))
    }

    /// Two nudges in the same minute become one, except "how did it go?" for a block that just
    /// ended, which always stays (its buttons are the whole point).
    static func dedupe(_ xs: [PlannedNudge]) -> [PlannedNudge] {
        var byMinute: [Int: [PlannedNudge]] = [:]
        for n in xs { byMinute[Int(n.at.timeIntervalSince1970 / 60), default: []].append(n) }
        var out: [PlannedNudge] = []
        for (_, group) in byMinute {
            let ends = group.filter { $0.kind == .end }
            let others = group.filter { $0.kind != .end }.sorted { rank($0.kind) < rank($1.kind) }
            out += ends
            if let best = others.first { out.append(best) }
        }
        return out
    }

    /// Lower is more important when two collide.
    static func rank(_ k: NudgeKind) -> Int {
        switch k {
        case .leaveNow: return 0
        case .start: return 1
        case .leaveSoon: return 2
        case .bedtime: return 3
        case .followUp: return 4
        case .deadline: return 5
        case .leadUp: return 6
        case .windDown: return 7
        case .end: return 8
        case .checkIn: return 9
        case .morning: return 10
        case .stillUp: return 11
        case .marker: return 12
        }
    }

    /// Opt-in alarms for the next 24 h: bedtime, leaving, and a study block 10 minutes in
    /// that hasn't been started. The app cancels the last one when focus starts.
    public static func alarms(_ input: NudgeInput, max: Int = 6) -> [PlannedAlarm] {
        guard input.settings.alarms else { return [] }
        let now = input.now, end = now.addingTimeInterval(horizon)
        var out: [PlannedAlarm] = []
        if let s = input.plan.blocks.first(where: { $0.kind == .sleep && $0.start > now && $0.start < end }) {
            out.append(PlannedAlarm(key: "bed.\(s.id)", kind: .bedtime, at: s.start, title: "Bedtime"))
        }
        for w in input.plan.wakePlans {
            if let leave = w.leaveBy, leave > now, leave < end {
                out.append(PlannedAlarm(key: "leave.\(Int(leave.timeIntervalSince1970))", kind: .leave, at: leave, title: "Time to leave"))
            }
        }
        for b in input.plan.blocks where b.isStudy && b.minutes >= 25 && b.id != input.startedBlockId
            && !input.answeredBlockIds.contains(b.id) && !input.snoozedBlockIds.contains(b.id) {
            let at = b.start.addingTimeInterval(10 * 60)
            guard at > now, at < end else { continue }
            out.append(PlannedAlarm(key: "miss.\(b.id)", kind: .missedStart, at: at, title: "Start \(b.title)", blockId: b.id))
        }
        return Array(out.sorted { $0.at < $1.at }.prefix(max))
    }

    static func clock(_ d: Date, _ cal: Calendar) -> String {
        let c = cal.dateComponents([.hour, .minute], from: d)
        let h = c.hour ?? 0, m = c.minute ?? 0
        let h12 = h % 12 == 0 ? 12 : h % 12
        return String(format: "%d:%02d %@", h12, m, h < 12 ? "AM" : "PM")
    }

    static func dayWord(_ d: Date, now: Date, _ cal: Calendar) -> String {
        if cal.isDate(d, inSameDayAs: now) { return "today at " }
        if let t = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(d, inSameDayAs: t) { return "tomorrow at " }
        return ""
    }
}

extension Array where Element == ScreenDay {
    /// Adds Shortcuts-measured days. A screenshot or the Screen Time monitor is more complete,
    /// so it's never replaced by a Shortcuts count.
    public func merging(measured: [ScreenDay], calendar cal: Calendar) -> [ScreenDay] {
        var byDay = Dictionary(map { (cal.startOfDay(for: $0.day), $0) }, uniquingKeysWith: { $1 })
        for m in measured {
            let d = cal.startOfDay(for: m.day)
            if let e = byDay[d], e.source != "shortcuts" { continue }
            byDay[d] = m
        }
        return byDay.values.sorted { $0.day < $1.day }
    }
}
