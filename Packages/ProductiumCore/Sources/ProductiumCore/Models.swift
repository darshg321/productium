import Foundation

// Sets and UUID-keyed dictionaries encode in a stable order, so an export round-trips byte for byte.
@propertyWrapper
public struct SortedSet<T: Hashable & Codable & Comparable & Sendable>: Codable, Hashable, Sendable {
    public var wrappedValue: Set<T>
    public init(wrappedValue: Set<T>) { self.wrappedValue = wrappedValue }
    public init(from decoder: Decoder) throws {
        wrappedValue = Set(try decoder.singleValueContainer().decode([T].self))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(wrappedValue.sorted())
    }
}

extension UUID: @retroactive CodingKeyRepresentable {
    public var codingKey: CodingKey { UUIDKey(stringValue: uuidString) }
    public init?<T: CodingKey>(codingKey: T) { self.init(uuidString: codingKey.stringValue) }
    struct UUIDKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

public struct TimeOfDay: Codable, Hashable, Comparable, Sendable {
    public var hour: Int
    public var minute: Int

    public init(_ hour: Int, _ minute: Int = 0) {
        self.hour = max(0, min(23, hour))
        self.minute = max(0, min(59, minute))
    }

    public init(minutes: Int) {
        let m = ((minutes % 1440) + 1440) % 1440
        self.init(m / 60, m % 60)
    }

    public var minutesFromMidnight: Int { hour * 60 + minute }

    public static func < (a: TimeOfDay, b: TimeOfDay) -> Bool { a.minutesFromMidnight < b.minutesFromMidnight }

    public var label: String { String(format: "%d:%02d", hour, minute) }

    enum CodingKeys: String, CodingKey { case hour, minute }

    /// `{hour, minute}`, or "HH:mm" / "9pm" as the model sometimes writes it.
    public init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            guard let t = ClockText.timeOfDay(s) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a time: \(s)"))
            }
            self = t
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(try c.decode(Int.self, forKey: .hour), (try? c.decode(Int.self, forKey: .minute)) ?? 0)
    }
}

public enum TaskKind: String, Codable, CaseIterable, Sendable {
    case assignment, quiz, test, project, essay, application, reading, practice, chore, other

    public var isMemoryBased: Bool { self == .quiz || self == .test }

    public var isProduction: Bool {
        switch self {
        case .assignment, .project, .essay, .application, .chore: return true
        default: return false
        }
    }

    public var defaultEstimate: Int {
        switch self {
        case .quiz: return 60
        case .test: return 180
        case .assignment: return 60
        case .project: return 300
        case .essay: return 360
        case .application: return 600
        case .reading: return 45
        case .practice: return 30
        case .chore: return 30
        case .other: return 45
        }
    }

    public var symbol: String {
        switch self {
        case .assignment: return "doc.text"
        case .quiz: return "checklist"
        case .test: return "graduationcap"
        case .project: return "hammer"
        case .essay: return "pencil.line"
        case .application: return "building.columns"
        case .reading: return "book"
        case .practice: return "repeat"
        case .chore: return "checkmark.circle"
        case .other: return "circle"
        }
    }
}

public enum ItemSource: String, Codable, Sendable { case manual, calendar, ai }

public struct WorkItem: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var kind: TaskKind
    public var subject: String?
    public var due: Date
    public var estimateMinutes: Int
    public var completedMinutes: Int
    public var importance: Int
    public var difficulty: Int
    /// v1.2: open / done / dropped. `isDone` reads and writes it.
    public var state: TaskState
    public var doneAt: Date?
    public var parentId: UUID?
    public var topics: [String]
    public var notes: String?
    public var source: ItemSource
    public var externalId: String?
    public var createdAt: Date
    public var color: String?
    public var deferralLog: [DeferralEvent]?
    /// v1.2: where its time is filed (nil: `CategoryRules` picks, usually Work › Studying › subject).
    public var category: CategoryID?
    /// v1.2 A2: not scheduled before this ("not today", "start Thursday").
    public var notBefore: Date?
    /// v1.2: at most this much of it in one day ("no more than 45 min of reading a day").
    public var maxMinutesPerDay: Int?
    /// v1.2 H: the first concrete step, named in reminders (instead of a separate "starter" task).
    public var firstStep: String?
    /// v1.6 B5: every session is this long ("each Hamlet session 1.5 hours exactly"); nil lets the planner choose.
    public var sessionMinutes: Int?

    public var isDone: Bool {
        get { state == .done }
        set { state = newValue ? .done : (state == .done ? .open : state) }
    }

    public init(id: UUID = UUID(), title: String, kind: TaskKind, subject: String? = nil, due: Date,
                estimateMinutes: Int? = nil, completedMinutes: Int = 0, importance: Int = 3,
                difficulty: Int = 2, isDone: Bool = false, doneAt: Date? = nil, parentId: UUID? = nil,
                topics: [String] = [], notes: String? = nil, source: ItemSource = .manual,
                externalId: String? = nil, createdAt: Date = Date(), color: String? = nil) {
        self.id = id
        self.title = title
        self.kind = kind
        self.subject = subject
        self.due = due
        self.estimateMinutes = max(5, estimateMinutes ?? kind.defaultEstimate)
        self.completedMinutes = max(0, completedMinutes)
        self.importance = max(1, min(5, importance))
        self.difficulty = max(1, min(3, difficulty))
        self.state = isDone ? .done : .open
        self.doneAt = doneAt
        self.parentId = parentId
        self.topics = topics
        self.notes = notes
        self.source = source
        self.externalId = externalId
        self.createdAt = createdAt
        self.color = color
    }
}

public enum CommitmentKind: String, Codable, CaseIterable, Sendable {
    case school, extracurricular, job, family, other
}

public struct ActivityPeriod: Codable, Hashable, Sendable {
    public var title: String
    public var start: TimeOfDay
    public var end: TimeOfDay
    @SortedSet public var weekdays: Set<Int>
    /// Extra condition besides `weekdays` ("only on B days"). Evaluated where the day's activities are resolved.
    public var when: DayRule?

    public init(title: String, start: TimeOfDay, end: TimeOfDay, weekdays: Set<Int> = [], when: DayRule? = nil) {
        self.title = title
        self.start = start
        self.end = end
        self.weekdays = weekdays
        self.when = when
    }

    /// An empty weekday set means every day the activity runs.
    public func applies(on weekday: Int) -> Bool { weekdays.isEmpty || weekdays.contains(weekday) }
}

public struct Commitment: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var kind: CommitmentKind
    @SortedSet public var weekdays: Set<Int>
    public var start: TimeOfDay
    public var end: TimeOfDay
    public var bufferMinutes: Int
    public var validFrom: Date?
    public var validUntil: Date?
    public var color: String?
    public var periods: [ActivityPeriod]?
    /// Extra condition besides `weekdays` (A/B days, odd weeks, exam-week). v1.1 A2.
    public var when: DayRule?

    public init(id: UUID = UUID(), title: String, kind: CommitmentKind, weekdays: Set<Int>,
                start: TimeOfDay, end: TimeOfDay, bufferMinutes: Int = 10,
                validFrom: Date? = nil, validUntil: Date? = nil, color: String? = nil, periods: [ActivityPeriod]? = nil,
                when: DayRule? = nil) {
        self.when = when
        self.periods = periods
        self.id = id
        self.title = title
        self.kind = kind
        self.weekdays = weekdays
        self.start = start
        self.end = end
        self.bufferMinutes = bufferMinutes
        self.validFrom = validFrom
        self.validUntil = validUntil
        self.color = color
    }
}

public struct FixedEvent: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var kind: CommitmentKind
    public var color: String?

    public init(id: String, title: String, start: Date, end: Date, kind: CommitmentKind = .other, color: String? = nil) {
        self.id = id
        self.title = title
        self.start = start
        self.end = max(end, start)
        self.kind = kind
        self.color = color
    }
}

public enum Chronotype: String, Codable, CaseIterable, Sendable {
    case early, intermediate, late

    public static func nearest(shiftHours h: Double) -> Chronotype {
        allCases.min { abs($0.shiftHours - h) < abs($1.shiftHours - h) } ?? .intermediate
    }

    public var shiftHours: Double {
        switch self {
        case .early: return -1.5
        case .intermediate: return 0
        case .late: return 1.5
        }
    }
}

public struct Preferences: Codable, Hashable, Sendable {
    public var sleepNeedMinutes: Int
    public var sleepFloorMinutes: Int
    public var schoolDayWake: TimeOfDay
    public var freeDayWake: TimeOfDay
    public var windDownMinutes: Int
    public var allowSleepTradeoffs: Bool
    @SortedSet public var schoolDays: Set<Int>
    public var interests: [String]
    public var autoWake: Bool
    public var nudges: NudgeSettings
    public var colors: [String: String]
    /// The student's (or the box's) choice to have the morning alarm at all; it also needs the Wake-Up Alarms permission.
    public var wakeAlarms: Bool
    /// v1.3 E: what each kind of prompt does. Replaces `nudges`' toggles and `wakeAlarms` (kept for the migration).
    public var prompts: PromptSettings

    public init(sleepNeedMinutes: Int = 540, sleepFloorMinutes: Int = 420,
                schoolDayWake: TimeOfDay = TimeOfDay(6, 45), freeDayWake: TimeOfDay = TimeOfDay(8, 30),
                windDownMinutes: Int = 30, allowSleepTradeoffs: Bool = true,
                schoolDays: Set<Int> = [2, 3, 4, 5, 6], interests: [String] = [], autoWake: Bool = true,
                nudges: NudgeSettings = NudgeSettings(), colors: [String: String] = [:], wakeAlarms: Bool = true,
                prompts: PromptSettings = PromptSettings()) {
        self.prompts = prompts
        self.wakeAlarms = wakeAlarms
        self.sleepNeedMinutes = sleepNeedMinutes
        self.sleepFloorMinutes = sleepFloorMinutes
        self.schoolDayWake = schoolDayWake
        self.freeDayWake = freeDayWake
        self.windDownMinutes = windDownMinutes
        self.allowSleepTradeoffs = allowSleepTradeoffs
        self.schoolDays = schoolDays
        self.interests = interests
        self.autoWake = autoWake
        self.nudges = nudges
        self.colors = colors
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Preferences()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? def }
        sleepNeedMinutes = v(.sleepNeedMinutes, d.sleepNeedMinutes)
        sleepFloorMinutes = v(.sleepFloorMinutes, d.sleepFloorMinutes)
        schoolDayWake = v(.schoolDayWake, d.schoolDayWake)
        freeDayWake = v(.freeDayWake, d.freeDayWake)
        windDownMinutes = v(.windDownMinutes, d.windDownMinutes)
        allowSleepTradeoffs = v(.allowSleepTradeoffs, d.allowSleepTradeoffs)
        schoolDays = v(.schoolDays, d.schoolDays)
        interests = v(.interests, d.interests)
        autoWake = v(.autoWake, d.autoWake)
        nudges = v(.nudges, d.nudges)
        colors = v(.colors, d.colors)
        wakeAlarms = v(.wakeAlarms, d.wakeAlarms)
        prompts = v(.prompts, d.prompts)
    }

    enum CodingKeys: String, CodingKey {
        case sleepNeedMinutes, sleepFloorMinutes, schoolDayWake, freeDayWake, windDownMinutes, allowSleepTradeoffs
        case schoolDays, interests, autoWake, nudges, colors, wakeAlarms, prompts
    }
}

public struct HealthDay: Codable, Hashable, Sendable {
    public var day: Date
    public var steps: Int?
    public var sleepMinutes: Int?
    public var bedtime: Date?
    public var wake: Date?
    public var daylightMinutes: Int?
    public var restingHeartRate: Double?
    public var sleepSource: SleepSource?
    /// Apple's exercise minutes (rings), and the minutes of logged workouts. v1.1 H3.
    public var exerciseMinutes: Int?
    public var workoutMinutes: Int?
    /// v1.2 A5: which source the night came from ("Apple Watch", "iPhone (in bed, no stages)").
    public var sleepDevice: String?
    /// v1.2 A5: daytime sleep (each ≥20 minutes), apart from the night.
    public var naps: [DateInterval]?
    /// v1.2 M8: heart-rate variability (SDNN, ms), the day's average.
    public var hrv: Double?

    public init(day: Date, steps: Int? = nil, sleepMinutes: Int? = nil, bedtime: Date? = nil,
                wake: Date? = nil, daylightMinutes: Int? = nil, restingHeartRate: Double? = nil, sleepSource: SleepSource? = nil,
                exerciseMinutes: Int? = nil, workoutMinutes: Int? = nil, sleepDevice: String? = nil, naps: [DateInterval]? = nil,
                hrv: Double? = nil) {
        self.sleepDevice = sleepDevice
        self.naps = naps
        self.hrv = hrv
        self.exerciseMinutes = exerciseMinutes
        self.workoutMinutes = workoutMinutes
        self.sleepSource = sleepSource
        self.day = day
        self.steps = steps
        self.sleepMinutes = sleepMinutes
        self.bedtime = bedtime
        self.wake = wake
        self.daylightMinutes = daylightMinutes
        self.restingHeartRate = restingHeartRate
    }
}

public struct MoodEntry: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var at: Date
    public var mood: Int
    public var energy: Int?
    public var note: String?

    public init(id: UUID = UUID(), at: Date = Date(), mood: Int, energy: Int? = nil, note: String? = nil) {
        self.id = id
        self.at = at
        self.mood = max(1, min(5, mood))
        self.energy = energy.map { max(1, min(5, $0)) }
        self.note = note
    }
}

public struct AppUsage: Codable, Hashable, Sendable {
    public var name: String
    public var minutes: Int
    public var distracting: Bool
    /// From a Screen Time screenshot's per-app Pickups / Notifications, when shown.
    public var pickups: Int?
    public var notifications: Int?
    public init(name: String, minutes: Int, distracting: Bool, pickups: Int? = nil, notifications: Int? = nil) {
        self.name = name
        self.minutes = minutes
        self.distracting = distracting
        self.pickups = pickups
        self.notifications = notifications
    }
}

public struct ScreenDay: Codable, Hashable, Sendable {
    public var day: Date
    public var distractingMinutes: Int
    public var unlockRequests: Int
    public var totalMinutes: Int?
    public var apps: [AppUsage]?
    public var source: String?
    public var partial: Bool?
    /// From a Screen Time screenshot (day view, or the daily average for a week view). v1.1 H1.
    public var pickups: Int?
    /// Minutes after midnight of the first pickup shown ("First Pickup 6:42 AM" = 402).
    public var firstPickup: Int?
    public var notifications: Int?

    public init(day: Date, distractingMinutes: Int, unlockRequests: Int = 0, totalMinutes: Int? = nil,
                apps: [AppUsage]? = nil, source: String? = nil, partial: Bool? = nil,
                pickups: Int? = nil, firstPickup: Int? = nil, notifications: Int? = nil) {
        self.partial = partial
        self.pickups = pickups
        self.firstPickup = firstPickup
        self.notifications = notifications
        self.day = day
        self.distractingMinutes = distractingMinutes
        self.unlockRequests = unlockRequests
        self.totalMinutes = totalMinutes
        self.apps = apps
        self.source = source
    }
}

public enum BlockKind: String, Codable, Sendable {
    case work, review, breakTime, free, gap, commitment, event, meal, routine, windDown, sleep
}

public struct PlannedBlock: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var kind: BlockKind
    public var start: Date
    public var end: Date
    public var title: String
    public var itemId: UUID?
    public var hint: String?
    public var borrowsSleep: Bool
    public var usesFreeTime: Bool
    public var color: String?
    public var sourceId: String?

    public init(id: UUID = UUID(), kind: BlockKind, start: Date, end: Date, title: String,
                itemId: UUID? = nil, hint: String? = nil, borrowsSleep: Bool = false, usesFreeTime: Bool = false,
                color: String? = nil, sourceId: String? = nil) {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end
        self.title = title
        self.itemId = itemId
        self.hint = hint
        self.borrowsSleep = borrowsSleep
        self.usesFreeTime = usesFreeTime
        self.color = color
        self.sourceId = sourceId
    }

    public var minutes: Int { Int(end.timeIntervalSince(start) / 60) }
    public var isStudy: Bool { kind == .work || kind == .review }
}

public enum WarningLevel: String, Codable, Sendable { case info, caution, critical }

public struct PlanWarning: Codable, Hashable, Sendable {
    public var level: WarningLevel
    public var message: String
    public var itemId: UUID?
    /// v1.5 C5: minutes of the task (in your terms) that don't fit before it's due.
    public var shortfall: Int?

    public init(level: WarningLevel, message: String, itemId: UUID? = nil, shortfall: Int? = nil) {
        self.level = level
        self.message = message
        self.itemId = itemId
        self.shortfall = shortfall
    }

    /// What Dismiss remembers: a task's shortfall once (its minutes change with every replan), anything else by its words.
    public var dismissKey: String { shortfall != nil ? "shortfall:\(itemId?.uuidString ?? message)" : message }
}

public struct Plan: Codable, Hashable, Sendable {
    public var generatedAt: Date
    public var blocks: [PlannedBlock]
    public var warnings: [PlanWarning]
    public var shortfalls: [UUID: Int]
    public var sleepTradeoffMinutes: Int
    public var loadFactor: Double
    public var wakePlans: [WakePlan]
    /// Days a situation muted reminders on (v1.1 A.2). Nil in plans made before situations.
    public var mutes: [NudgeMute]?

    public init(generatedAt: Date, blocks: [PlannedBlock], warnings: [PlanWarning],
                shortfalls: [UUID: Int], sleepTradeoffMinutes: Int, loadFactor: Double, wakePlans: [WakePlan] = [],
                mutes: [NudgeMute]? = nil) {
        self.mutes = mutes
        self.generatedAt = generatedAt
        self.blocks = blocks
        self.warnings = warnings
        self.shortfalls = shortfalls
        self.sleepTradeoffMinutes = sleepTradeoffMinutes
        self.loadFactor = loadFactor
        self.wakePlans = wakePlans
    }

    public static let empty = Plan(generatedAt: .distantPast, blocks: [], warnings: [], shortfalls: [:],
                                   sleepTradeoffMinutes: 0, loadFactor: 1)

    /// Whether a situation muted this kind of reminder on that day.
    public func isMuted(_ kind: NudgeKind, at d: Date, calendar: Calendar) -> Bool {
        (mutes ?? []).contains { calendar.isDate($0.day, inSameDayAs: d) && ($0.kind == nil || $0.kind == kind) }
    }

    public func blocks(on day: Date, calendar: Calendar) -> [PlannedBlock] {
        blocks.filter { calendar.isDate($0.start, inSameDayAs: day) }
    }

    public func current(at now: Date) -> PlannedBlock? {
        blocks.first { $0.start <= now && now < $0.end && $0.kind != .sleep }
    }

    public func next(after now: Date) -> PlannedBlock? {
        blocks.first { $0.start > now && $0.kind != .sleep }
    }
}

public enum OutcomeStatus: String, Codable, Sendable { case done, partial, skipped }

/// How a planned session went, judged from the log once its day is over (`AdherenceLearner`): what `LearnedModel`
/// learns adherence, good hours and focus length from. Not stored.
public struct SessionResult: Hashable, Sendable {
    public var itemId: UUID?
    public var kind: TaskKind?
    public var plannedStart: Date
    public var plannedMinutes: Int
    public var actualMinutes: Int
    public var status: OutcomeStatus
    /// How much of it happened at the planned hour (0–1); nil = same as `score`. What the hour learns from.
    public var onTimeScore: Double?

    public init(itemId: UUID?, kind: TaskKind?, plannedStart: Date, plannedMinutes: Int, actualMinutes: Int, status: OutcomeStatus) {
        self.itemId = itemId
        self.kind = kind
        self.plannedStart = plannedStart
        self.plannedMinutes = plannedMinutes
        self.actualMinutes = actualMinutes
        self.status = status
    }

    public var score: Double {
        switch status {
        case .done: return 1
        case .partial: return 0.5
        case .skipped: return 0
        }
    }
}
