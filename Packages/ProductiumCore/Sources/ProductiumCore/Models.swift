import Foundation

// MARK: - Stable encoding
//
// An export, imported and exported again, gives the same file byte for byte. A `Set` encodes in
// whatever order its hash table happens to have, so persisted sets are written sorted, and
// UUID-keyed dictionaries are written as JSON objects (which `.sortedKeys` orders).

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

// MARK: - Time of day

/// A wall-clock time with no date attached (e.g. school starts 08:30).
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
}

// MARK: - Work items (assignments, tests, applications…)

public enum TaskKind: String, Codable, CaseIterable, Sendable {
    case assignment, quiz, test, project, essay, application, reading, practice, chore, other

    /// Memory-based work: learning that has to be retained for a test.
    /// Spaced retrieval practice applies, and sleep is never traded away for it.
    public var isMemoryBased: Bool { self == .quiz || self == .test }

    /// Production work: makes something by a deadline (essay, project, form).
    /// This is the only kind that may, as a last resort, borrow a little sleep.
    public var isProduction: Bool {
        switch self {
        case .assignment, .project, .essay, .application, .chore: return true
        default: return false
        }
    }

    /// Default minutes when the student doesn't say how long something takes.
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
    /// The student's (or default) estimate. The planner corrects it with the
    /// personal planning-fallacy factor in `LearnedModel`.
    public var estimateMinutes: Int
    public var completedMinutes: Int
    /// 1 (barely matters) … 5 (high stakes: big test, application).
    public var importance: Int
    /// 1 easy … 3 hard. Hard work goes into the student's peak-energy hours.
    public var difficulty: Int
    public var isDone: Bool
    public var doneAt: Date?
    public var parentId: UUID?
    /// Topics (e.g. "chapter 4: derivatives"), used for flashcards and gap reads.
    public var topics: [String]
    public var notes: String?
    public var source: ItemSource
    public var externalId: String?
    public var createdAt: Date
    /// The student's colour for this task (a `Palette` name or #RRGGBB). Nil = by type/subject.
    public var color: String?

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
        self.isDone = isDone
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

// MARK: - Fixed time (school, activities, calendar)

public enum CommitmentKind: String, Codable, CaseIterable, Sendable {
    case school, extracurricular, job, family, other
}

/// Something recurring every week: classes, practice, a job shift.
public struct Commitment: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var kind: CommitmentKind
    /// Calendar weekday numbers, 1 = Sunday … 7 = Saturday.
    @SortedSet public var weekdays: Set<Int>
    public var start: TimeOfDay
    public var end: TimeOfDay
    /// Travel/transition minutes added before and after (you don't teleport).
    public var bufferMinutes: Int
    public var validFrom: Date?
    public var validUntil: Date?
    public var color: String?

    public init(id: UUID = UUID(), title: String, kind: CommitmentKind, weekdays: Set<Int>,
                start: TimeOfDay, end: TimeOfDay, bufferMinutes: Int = 10,
                validFrom: Date? = nil, validUntil: Date? = nil, color: String? = nil) {
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

/// A one-off event (usually imported from the iOS calendar).
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

// MARK: - Preferences (what the student tells us, a handful of fields)

public enum Chronotype: String, Codable, CaseIterable, Sendable {
    case early, intermediate, late

    /// The chronotype whose shift is closest to `shiftHours` (a learned belief).
    public static func nearest(shiftHours h: Double) -> Chronotype {
        allCases.min { abs($0.shiftHours - h) < abs($1.shiftHours - h) } ?? .intermediate
    }

    /// Peak-alertness shift in hours, relative to an intermediate chronotype.
    public var shiftHours: Double {
        switch self {
        case .early: return -1.5
        case .intermediate: return 0
        case .late: return 1.5
        }
    }
}

/// What the student decides. Everything the app can learn instead (study capacity, free time,
/// focus and break length, dinner, chronotype, a screen-time goal) is a belief (Beliefs.swift).
public struct Preferences: Codable, Hashable, Sendable {
    /// Teens 13-18 need 8-10 h (AASM consensus, Paruthi et al. 2016). Changed only by the student,
    /// or by an approved reflection proposal with evidence.
    public var sleepNeedMinutes: Int
    /// Absolute floor that sleep trade-offs can never go under.
    public var sleepFloorMinutes: Int
    /// Used when Auto Wake is off, and as the latest wake on free days.
    public var schoolDayWake: TimeOfDay
    public var freeDayWake: TimeOfDay
    public var windDownMinutes: Int
    public var allowSleepTradeoffs: Bool
    /// Calendar weekday numbers that are school days (default Mon–Fri).
    @SortedSet public var schoolDays: Set<Int>
    public var interests: [String]
    /// Work wake-up time back from the first commitment and the learned commute.
    public var autoWake: Bool
    /// How much the phone interrupts, and with what.
    public var nudges: NudgeSettings
    /// Colour overrides by category (see `Palette.categories`): "free" → "green", "school" → "teal",
    /// "subject:math" → "blue". A task's or activity's own colour beats these.
    public var colors: [String: String]

    public init(sleepNeedMinutes: Int = 540, sleepFloorMinutes: Int = 420,
                schoolDayWake: TimeOfDay = TimeOfDay(6, 45), freeDayWake: TimeOfDay = TimeOfDay(8, 30),
                windDownMinutes: Int = 30, allowSleepTradeoffs: Bool = true,
                schoolDays: Set<Int> = [2, 3, 4, 5, 6], interests: [String] = [], autoWake: Bool = true,
                nudges: NudgeSettings = NudgeSettings(), colors: [String: String] = [:]) {
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

    /// Missing keys fall back to defaults, so a build that adds a preference keeps the rest.
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
    }

    enum CodingKeys: String, CodingKey {
        case sleepNeedMinutes, sleepFloorMinutes, schoolDayWake, freeDayWake, windDownMinutes, allowSleepTradeoffs
        case schoolDays, interests, autoWake, nudges, colors
    }
}

// MARK: - Signals from the phone

public struct HealthDay: Codable, Hashable, Sendable {
    public var day: Date            // start of day
    public var steps: Int?
    public var sleepMinutes: Int?   // asleep minutes for the night ending this morning
    public var bedtime: Date?
    public var wake: Date?
    public var daylightMinutes: Int?
    public var restingHeartRate: Double?
    /// Where the night came from: nil or .health = measured; otherwise estimated (see SleepEstimator).
    public var sleepSource: SleepSource?

    public init(day: Date, steps: Int? = nil, sleepMinutes: Int? = nil, bedtime: Date? = nil,
                wake: Date? = nil, daylightMinutes: Int? = nil, restingHeartRate: Double? = nil, sleepSource: SleepSource? = nil) {
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
    /// 1 (awful) … 5 (great)
    public var mood: Int
    /// 1 (drained) … 5 (energised). Optional; one tap only if the student wants.
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
    public init(name: String, minutes: Int, distracting: Bool) {
        self.name = name
        self.minutes = minutes
        self.distracting = distracting
    }
}

/// Minutes in distracting apps per day, from DeviceActivity thresholds or a
/// Screen Time screenshot read by the AI.
public struct ScreenDay: Codable, Hashable, Sendable {
    public var day: Date
    public var distractingMinutes: Int
    public var unlockRequests: Int
    public var totalMinutes: Int?
    public var apps: [AppUsage]?
    public var source: String?           // "monitor" | "screenshot"

    public init(day: Date, distractingMinutes: Int, unlockRequests: Int = 0, totalMinutes: Int? = nil,
                apps: [AppUsage]? = nil, source: String? = nil) {
        self.day = day
        self.distractingMinutes = distractingMinutes
        self.unlockRequests = unlockRequests
        self.totalMinutes = totalMinutes
        self.apps = apps
        self.source = source
    }
}

// MARK: - Plan

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
    /// One-line "how" for the block (e.g. retrieval practice instructions).
    public var hint: String?
    /// True when this block sits in time that would normally be sleep.
    public var borrowsSleep: Bool
    /// True when this block sits in time that would normally be free time.
    public var usesFreeTime: Bool
    /// Resolved colour (task/activity/category override), nil = the kind's default.
    public var color: String?
    /// The activity (commitment) or one-off event this block came from.
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

    public init(level: WarningLevel, message: String, itemId: UUID? = nil) {
        self.level = level
        self.message = message
        self.itemId = itemId
    }
}

public struct Plan: Codable, Hashable, Sendable {
    public var generatedAt: Date
    public var blocks: [PlannedBlock]
    public var warnings: [PlanWarning]
    /// Items that can't be fully finished. The plan advises a "good enough" target.
    public var shortfalls: [UUID: Int]
    public var sleepTradeoffMinutes: Int
    public var loadFactor: Double
    /// Planned wake-up (and leave-by) per day, used for alarms.
    public var wakePlans: [WakePlan]

    public init(generatedAt: Date, blocks: [PlannedBlock], warnings: [PlanWarning],
                shortfalls: [UUID: Int], sleepTradeoffMinutes: Int, loadFactor: Double, wakePlans: [WakePlan] = []) {
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

// MARK: - Outcomes (what actually happened)

public enum OutcomeStatus: String, Codable, Sendable { case done, partial, skipped }

public struct BlockOutcome: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var blockId: UUID
    public var itemId: UUID?
    public var kind: TaskKind?
    public var plannedStart: Date
    public var plannedMinutes: Int
    public var actualMinutes: Int
    public var status: OutcomeStatus
    public var loggedAt: Date

    public init(id: UUID = UUID(), blockId: UUID, itemId: UUID?, kind: TaskKind?, plannedStart: Date,
                plannedMinutes: Int, actualMinutes: Int, status: OutcomeStatus, loggedAt: Date = Date()) {
        self.id = id
        self.blockId = blockId
        self.itemId = itemId
        self.kind = kind
        self.plannedStart = plannedStart
        self.plannedMinutes = plannedMinutes
        self.actualMinutes = actualMinutes
        self.status = status
        self.loggedAt = loggedAt
    }

    public var score: Double {
        switch status {
        case .done: return 1
        case .partial: return 0.5
        case .skipped: return 0
        }
    }
}
