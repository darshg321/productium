import Foundation

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

    public var followUps: [Int] {
        switch self {
        case .gentle: return []
        case .standard: return [7]
        case .persistent: return [5, 12, 20]
        }
    }

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
    public var alarms: Bool
    public var scrollCheckIns: Bool
    public var arrivingHome: Bool
    public var deadlines: Bool
    /// A stand-up-and-walk reminder after about 90 minutes of study, and a morning-light one on free days (v1.1 H6).
    public var movement: Bool
    public var daylight: Bool

    public init(level: NudgeLevel = .standard, alarms: Bool = false, scrollCheckIns: Bool = true,
                arrivingHome: Bool = true, deadlines: Bool = true, movement: Bool = true, daylight: Bool = true) {
        self.movement = movement
        self.daylight = daylight
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
        movement = v(.movement, d.movement)
        daylight = v(.daylight, d.daylight)
    }
}

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

public enum NudgeKind: String, Codable, CaseIterable, Sendable {
    case leadUp, start, followUp, windDown, bedtime, stillUp, leaveSoon, leaveNow, deadline, checkIn, morning, intention
    case daylight
    /// v1.2 D4: "What are you up to?" (live) or "Nothing logged 3:10–4:30" (past).
    case untracked
    /// v1.2 A7: "Slept about 11:20–7:05?"
    case sleepConfirm
    /// v1.2 N7: a question from what the phone noticed ("You're home, but school's on until 3").
    case question
    /// v1.2 D6: the running entry, passive.
    case running
    /// v1.5 B4 / D4: the session you're in reached its planned end (+15 · +30 · Tomorrow · Done, and a stand-up).
    case sessionEnd

    /// v1.2 A8: the notification category each kind uses. Only these have actions; the text-input ones say so.
    public var category: NotificationCategory? {
        switch self {
        case .start, .followUp: return .start
        case .leadUp: return .lead
        case .checkIn: return .checkIn
        case .deadline: return .deadline
        case .untracked: return .untracked
        case .sleepConfirm: return .sleepConfirm
        case .question: return .question
        case .running: return .running
        case .sessionEnd: return .sessionEnd
        default: return nil
        }
    }
}

/// v1.2 A8: notification categories. Copy may invite a reply only when its category takes text.
public enum NotificationCategory: String, CaseIterable, Sendable {
    case start = "BLOCK_START", lead = "LEAD_UP", checkIn = "CHECK_IN", deadline = "DEADLINE", scroll = "SCROLL"
    case untracked = "UNTRACKED", sleepConfirm = "SLEEP_CONFIRM", question = "QUESTION", running = "RUNNING"
    case sessionEnd = "SESSION_END", focusRating = "FOCUS_RATING"

    public var takesText: Bool {
        switch self {
        case .checkIn, .untracked, .sleepConfirm, .question, .running: return true
        default: return false
        }
    }

    /// Words that invite typing an answer. A body with any of them needs a text field (`takesText`).
    public static let replyWords = ["reply", "answer", "type", "tell me", "say", "write"]

    public static func invitesReply(_ text: String) -> Bool {
        let words = Set(text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
        return replyWords.contains { w in w.contains(" ") ? text.lowercased().contains(w) : words.contains(w) }
    }
}

public struct PlannedNudge: Hashable, Sendable {
    public var id: String
    public var kind: NudgeKind
    public var at: Date
    public var title: String
    public var body: String
    public var blockId: UUID?
    public var itemId: UUID?
    public var deeplink: String?
    public var urgent: Bool
    /// One-tap answers shown as actions (start buttons for "What are you up to?").
    public var actions: [String]
    /// The stretch a question is about (an untracked stretch, a night).
    public var window: DateInterval?

    public init(id: String, kind: NudgeKind, at: Date, title: String, body: String, blockId: UUID? = nil,
                itemId: UUID? = nil, deeplink: String? = nil, urgent: Bool = false, actions: [String] = [],
                window: DateInterval? = nil) {
        self.actions = actions
        self.window = window
        self.id = id
        self.kind = kind
        self.at = at
        self.title = title
        self.body = body
        self.blockId = blockId
        self.itemId = itemId
        self.deeplink = deeplink
        self.urgent = urgent
    }
}

public struct PlannedAlarm: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case wake, bedtime, leave, missedStart
        /// v1.2 O4: an approved alarm `Alert` on an Entry (`EntryAlerts`).
        case entry
        /// v1.3 E: any other prompt set to Alarm.
        case prompt
    }
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
    public var startedBlockId: UUID?
    public var answeredBlockIds: Set<UUID>
    public var snoozedBlockIds: Set<UUID>
    /// What's running now (H4: no "hasn't started" follow-up while you're tracking something else).
    public var running: Entry?
    public var limit: Int
    public var timeLabel: ((Date) -> String)?
    public var policy: BehaviourPolicy
    public var dayRules: DayRuleBook
    /// v1.3 E: what each kind of prompt does (nil: from the v1.2 toggles in `settings`).
    public var prompts: PromptSettings
    public var alarmsAllowed: Bool
    /// The Now activity is on the Lock Screen (if not, its prompts fall back to notifications).
    public var liveActivity: Bool

    public init(now: Date, calendar: Calendar, plan: Plan, items: [WorkItem], settings: NudgeSettings,
                startedBlockId: UUID? = nil, answeredBlockIds: Set<UUID> = [], snoozedBlockIds: Set<UUID> = [],
                running: Entry? = nil, limit: Int = 52, timeLabel: ((Date) -> String)? = nil,
                policy: BehaviourPolicy = BehaviourPolicy(), dayRules: DayRuleBook = DayRuleBook(),
                prompts: PromptSettings? = nil, alarmsAllowed: Bool = true, liveActivity: Bool = true) {
        self.prompts = prompts ?? PromptSettings.migrated(from: settings, wakeAlarms: true)
        self.alarmsAllowed = alarmsAllowed
        self.liveActivity = liveActivity
        self.dayRules = dayRules
        self.policy = policy
        self.now = now
        self.calendar = calendar
        self.plan = plan
        self.items = items
        self.settings = settings
        self.startedBlockId = startedBlockId
        self.answeredBlockIds = answeredBlockIds
        self.snoozedBlockIds = snoozedBlockIds
        self.running = running
        self.limit = limit
        self.timeLabel = timeLabel
    }
}

/// v1.2 H4: what every task notification says: the first concrete step, how long, what it leads to, how far along.
public struct TaskCopy: Hashable, Sendable {
    /// "Chapter 3's first 5 pages · 20 min"
    public var first: String
    /// The first line plus progress and what it leads to.
    public var body: String

    public static func make(_ b: PlannedBlock, item: WorkItem?, plan: Plan, calendar cal: Calendar, time: (Date) -> String) -> TaskCopy {
        let step = item?.firstStep.flatMap { $0.isEmpty ? nil : $0 } ?? b.hint ?? "Open it and do the first small part"
        let first = "\(step.trimmingCharacters(in: CharacterSet(charactersIn: ". "))) · \(minutesLabel(b.minutes))"
        var parts = [first + "."]
        let day = plan.blocks(on: b.start, calendar: cal)
        let studyToday = day.filter(\.isStudy)
        let total = studyToday.reduce(0) { $0 + $1.minutes }
        let through = studyToday.filter { $0.start <= b.start }.reduce(0) { $0 + $1.minutes }
        let next = day.filter { $0.start >= b.end && $0.kind != .free && $0.kind != .gap && $0.kind != .breakTime }.min { $0.start < $1.start }
        if let n = next, n.start.timeIntervalSince(b.end) >= 20 * 60 {
            parts.append("Then you're free until \(time(n.start)).")
        } else if next == nil || next?.kind == .windDown || next?.kind == .sleep {
            parts.append(studyToday.last == b ? "Then you're done for today." : "Then you're free.")
        } else if total > b.minutes {
            parts.append("That's \(minutesLabel(through)) of today's \(minutesLabel(total)).")
        } else {
            parts.append("Next: \(next!.title) at \(time(next!.start)).")
        }
        return TaskCopy(first: first, body: parts.joined(separator: " "))
    }
}

public enum NudgePlanner {
    public static let horizon: TimeInterval = 86400

    public static func plan(_ input: NudgeInput) -> [PlannedNudge] {
        let now = input.now
        let end = now.addingTimeInterval(horizon)
        let level = input.settings.level
        let plan = input.plan
        var out: [PlannedNudge] = []
        func add(_ n: PlannedNudge) { if n.at > now.addingTimeInterval(30) && n.at < end { out.append(n) } }
        func time(_ d: Date) -> String { input.timeLabel?(d) ?? clock(d, input.calendar) }

        let study = plan.blocks.filter { $0.isStudy && $0.end > now && $0.start < end && !input.answeredBlockIds.contains($0.id) }
        if let b = plan.blocks.first(where: { $0.id == input.startedBlockId && $0.isStudy && $0.itemId != nil && $0.end > now }) {
            add(PlannedNudge(id: "plan.end.\(b.id)", kind: .sessionEnd, at: b.end, title: "Time's up: \(b.title)",
                             body: sessionEndBody(b, study: plan.blocks.filter(\.isStudy).sorted { $0.start < $1.start },
                                                  standUp: input.prompts.notifies(.movement) && level != .gentle),
                             blockId: b.id, itemId: b.itemId))
        }
        for (i, b) in study.enumerated() {
            let started = b.id == input.startedBlockId
            let snoozed = input.snoozedBlockIds.contains(b.id)
            // H4: no "hasn't started" while you're tracking something else; you're busy, not avoiding it.
            let elsewhere = input.running != nil && !started
            let backToBack = i > 0 && study[i - 1].end >= b.start.addingTimeInterval(-15 * 60)
            let item = b.itemId.flatMap { id in input.items.first { $0.id == id } }
            let copy = TaskCopy.make(b, item: item, plan: plan, calendar: input.calendar, time: time)
            // D1: the Live Activity shows what's next and counts down, so no lead-up or "min left" on top of it.
            if !started && !snoozed {
                if level != .gentle && !backToBack && b.minutes >= 20 && !elsewhere && !input.liveActivity {
                    add(PlannedNudge(id: "plan.lead.\(b.id)", kind: .leadUp, at: b.start.addingTimeInterval(-10 * 60),
                              title: "In 10 minutes: \(b.title)", body: copy.first,
                              blockId: b.id, itemId: b.itemId))
                }
                add(PlannedNudge(id: "plan.start.\(b.id)", kind: .start, at: b.start, title: b.title,
                          body: copy.body, blockId: b.id, itemId: b.itemId, deeplink: "productium://now", urgent: true))
                let followUps = Array(level.followUps.map { max(2, $0 + input.policy.followUpShiftMinutes) }.prefix(level == .persistent ? 2 : 1))
                for (k, m) in followUps.enumerated() where !elsewhere && !input.liveActivity
                    && Double(m) * 60 < b.end.timeIntervalSince(b.start) - 5 * 60 {
                    let left = b.minutes - m
                    add(PlannedNudge(id: "plan.follow.\(b.id).\(k)", kind: .followUp, at: b.start.addingTimeInterval(Double(m) * 60),
                              title: "\(b.title): \(left) min left",
                              body: "Even 10 minutes counts. \(copy.first)",
                              blockId: b.id, itemId: b.itemId, deeplink: "productium://now", urgent: level == .persistent))
                }
            }
        }

        for b in plan.blocks where b.kind == .event && b.itemId != nil && b.end > now && b.start < end {
            add(PlannedNudge(id: "plan.errand.\(b.id)", kind: .start, at: b.start, title: "At school: \(b.title)",
                      body: b.hint ?? "Do this between classes.", blockId: b.id, itemId: b.itemId))
        }

        if let wind = plan.blocks.first(where: { $0.kind == .windDown && $0.start > now.addingTimeInterval(30 * 60) && $0.start < end }) {
            add(PlannedNudge(id: "plan.checkin", kind: .checkIn, at: wind.start.addingTimeInterval(-30 * 60),
                      title: "20-second check-in",
                      body: "How was today? Anything new due? Press and hold to reply, no need to open the app."))
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

        if input.prompts.notifies(.deadline) {
            for item in input.items where item.isOpen && item.parentId == nil && item.due > now {
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

        if input.prompts.notifies(.daylight) && level != .gentle {
            for w in plan.wakePlans where w.wake > now && w.wake < end {
                let day = input.calendar.startOfDay(for: w.day)
                guard w.firstCommitment == nil, plan.blocks.allSatisfy({ !($0.kind == .commitment && input.calendar.isDate($0.start, inSameDayAs: day)) }) else { continue }
                add(PlannedNudge(id: "plan.daylight.\(Int(day.timeIntervalSince1970))", kind: .daylight, at: w.wake.addingTimeInterval(45 * 60),
                                 title: "Get some morning light",
                                 body: "Ten minutes outside in the first couple of hours helps your body clock, and tonight's sleep.",
                                 deeplink: "productium://today"))
            }
        }

        for intent in input.policy.intentions where intent.trigger == .time {
            guard let t = intent.time else { continue }
            for d in 0...1 {
                guard let day = input.calendar.date(byAdding: .day, value: d, to: input.calendar.startOfDay(for: now)),
                      intent.weekdays.isEmpty || intent.weekdays.contains(input.calendar.component(.weekday, from: day)),
                      let at = input.calendar.date(bySettingHour: t.hour, minute: t.minute, second: 0, of: day) else { continue }
                add(PlannedNudge(id: "intent.\(intent.id).\(d)", kind: .intention, at: at, title: "Your plan", body: intent.text,
                                 itemId: intent.itemId, deeplink: "productium://now"))
            }
        }
        let kept = input.prompts.filter(out, liveActivity: input.liveActivity).filter { !plan.isMuted($0.kind, at: $0.at, calendar: input.calendar) }
        return Array(dedupe(kept).sorted { $0.at < $1.at }.prefix(input.limit))
    }

    /// D4: the stand-up break rides on the session-end notification (after about 85 minutes of work with short breaks).
    static func sessionEndBody(_ b: PlannedBlock, study: [PlannedBlock], standUp: Bool) -> String {
        var run = 0
        var last: PlannedBlock?
        for x in study where x.end <= b.end {
            if let l = last, x.start.timeIntervalSince(l.end) > 25 * 60 { run = 0 }
            run += x.minutes
            last = x
        }
        let more = "Need more time? +15 or +30 min, or finish it tomorrow."
        return standUp && run >= 85 ? "You've worked about \(minutesLabel(run)): stand up for three minutes. \(more)" : more
    }

    public static let dailyCap = 8

    /// D2: at most `cap` notifications a day (alarms aren't counted). The least important go first.
    public static func capped(_ xs: [PlannedNudge], cap: Int, calendar cal: Calendar) -> (kept: [PlannedNudge], dropped: [PlannedNudge]) {
        guard cap > 0 else { return (xs, []) }
        var kept: [PlannedNudge] = [], dropped: [PlannedNudge] = []
        for (_, day) in Dictionary(grouping: xs, by: { cal.startOfDay(for: $0.at) }) {
            let counted = day.filter { $0.kind != .running }
            let order = counted.sorted { (rank($0.kind), $0.at) < (rank($1.kind), $1.at) }
            let keep = Set(order.prefix(cap).map(\.id))
            for n in day { if n.kind == .running || keep.contains(n.id) { kept.append(n) } else { dropped.append(n) } }
        }
        return (kept.sorted { $0.at < $1.at }, dropped.sorted { $0.at < $1.at })
    }

    static func dedupe(_ xs: [PlannedNudge]) -> [PlannedNudge] {
        var byMinute: [Int: [PlannedNudge]] = [:]
        for n in xs { byMinute[Int(n.at.timeIntervalSince1970 / 60), default: []].append(n) }
        var out: [PlannedNudge] = []
        for (_, group) in byMinute {
            if let best = group.sorted(by: { rank($0.kind) < rank($1.kind) }).first { out.append(best) }
        }
        return out
    }

    static func rank(_ k: NudgeKind) -> Int {
        switch k {
        case .leaveNow: return 0
        case .start: return 1
        case .leaveSoon: return 2
        case .bedtime: return 3
        case .followUp: return 4
        case .deadline: return 5
        case .leadUp: return 6
        case .sessionEnd: return 4
        case .windDown: return 7
        case .checkIn: return 9
        case .morning: return 10
        case .stillUp: return 11
        case .untracked, .sleepConfirm, .question, .running: return 12
        case .intention: return 6
        case .daylight: return 10
        }
    }

    public static func alarms(_ input: NudgeInput, max: Int = 6) -> [PlannedAlarm] {
        let rings = { (k: PromptKind) in input.prompts.rings(k, alarmsAllowed: input.alarmsAllowed) }
        let now = input.now, end = now.addingTimeInterval(horizon)
        var out: [PlannedAlarm] = []
        if rings(.bedtime), let s = input.plan.blocks.first(where: { $0.kind == .sleep && $0.start > now && $0.start < end }) {
            out.append(PlannedAlarm(key: "bed.\(AlarmPlanner.dayKey(s.end, input.calendar))", kind: .bedtime, at: s.start, title: "Bedtime"))
        }
        for w in input.plan.wakePlans {
            if rings(.leave), let leave = w.leaveBy, leave > now, leave < end {
                out.append(PlannedAlarm(key: "leave.\(AlarmPlanner.dayKey(leave, input.calendar))", kind: .leave, at: leave, title: "Time to leave"))
            }
        }
        for b in input.plan.blocks where rings(.missedStart) && b.isStudy && b.minutes >= 25 && b.id != input.startedBlockId
            && !input.answeredBlockIds.contains(b.id) && !input.snoozedBlockIds.contains(b.id) {
            let at = b.start.addingTimeInterval(10 * 60)
            guard at > now, at < end else { continue }
            out.append(PlannedAlarm(key: "miss.\(b.id)", kind: .missedStart, at: at, title: "Start \(b.title)", blockId: b.id))
        }
        let kept = out.filter { a in
            let kind: NudgeKind = a.kind == .bedtime ? .bedtime : a.kind == .leave ? .leaveNow : .start
            return !input.plan.isMuted(kind, at: a.at, calendar: input.calendar)
        }
        return Array(kept.sorted { $0.at < $1.at }.prefix(max))
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
