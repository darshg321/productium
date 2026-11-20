import Foundation

public struct SavedPlace: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var latitude: Double
    public var longitude: Double
    public var radius: Double = 120

    public init(id: String, name: String, latitude: Double, longitude: Double, radius: Double = 120) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.radius = radius
    }
}

public struct Integrations: Codable, Hashable, Sendable {
    public var health = false
    public var calendarImport = false
    public var calendarExport = false
    public var location = false
    public var alarms = false
    public var notifications = false
    public var motion = false
    public var healthNeedsRequest = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v(_ k: CodingKeys, _ d: Bool) -> Bool { (try? c.decodeIfPresent(Bool.self, forKey: k)) ?? d }
        health = v(.health, false); calendarImport = v(.calendarImport, false); calendarExport = v(.calendarExport, false)
        location = v(.location, false); alarms = v(.alarms, false)
        notifications = v(.notifications, false); motion = v(.motion, false)
        healthNeedsRequest = v(.healthNeedsRequest, false)
    }
}

public struct FocusSession: Codable, Hashable, Sendable {
    public var blockId: UUID
    public var itemId: UUID?
    public var title: String
    public var startedAt: Date
    public var plannedEnd: Date

    public init(blockId: UUID, itemId: UUID?, title: String, startedAt: Date, plannedEnd: Date) {
        self.blockId = blockId
        self.itemId = itemId
        self.title = title
        self.startedAt = startedAt
        self.plannedEnd = plannedEnd
    }
}

/// What's typed in the Inbox but not sent yet. Images live as files under drafts/ in the container.
public struct Draft: Codable, Hashable, Sendable {
    public var text: String
    public var imageFiles: [String]

    public init(text: String = "", imageFiles: [String] = []) {
        self.text = text
        self.imageFiles = imageFiles
    }

    public var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && imageFiles.isEmpty }
}

public struct AppState: Codable, Sendable {
    /// v1.2 is a clean break: state stored by an older schema isn't read (the app starts fresh, onboarding re-runs).
    public static let schema = 4
    public var schema = AppState.schema
    public var onboarded = false
    /// v1.2 Part 0: everything timed (classes, events, sessions, sleep, the log, the plan's blocks).
    public var entries: [Entry] = []
    /// v1.2 Part 0: standing instructions in the AI's words.
    public var rules: [Rule] = []
    /// v1.2 Part C.
    public var categories = CategoryTree()
    /// v1.2: what each day's plan asked for, per task, snapshotted at the day's first plan (`Accountability`).
    public var dayPlans: [DayKey: [UUID: Int]] = [:]
    /// v1.2 F3: charts pinned to Review. Only the query is kept; the numbers are computed live from the log.
    public var pinnedCharts: [PinnedChart] = []
    /// v1.2 Part T: the development log, in every backup.
    public var telemetry = Telemetry()
    public var prefs = Preferences()
    public var items: [WorkItem] = []
    public var commitments: [Commitment] = []
    public var routines: [Routine] = Routine.defaults
    public var markers: [TimelineEvent] = []
    public var outcomes: [BlockOutcome] = []
    public var planHistory: [String: [PlannedBlock]] = [:]
    /// Planned bedtime per night, keyed by the morning (for "in bed on time").
    public var plannedBedtimes: [String: Date] = [:]
    public var progress: [ProgressEntry] = []
    public var moods: [MoodEntry] = []
    public var health: [HealthDay] = []
    public var motion: [MotionSpan] = []
    public var screen: [ScreenDay] = []
    public var screenAverages: [ScreenDay] = []
    public var scrollingApps: [String: Bool] = [:]
    public var events: [FixedEvent] = []
    public var oneOffs: [FixedEvent] = []
    public var exceptions: [DayException] = []
    /// v1.1 A.2: overrides on the planner's inputs over any span of days.
    public var situations: [Situation] = []
    /// Named day sequences (A/B rotations) and labels ("exam-week", "no-school").
    public var dayRules = DayRuleBook()
    /// Things the student said that the app couldn't act on (v1.2's backlog).
    public var gapNotes: [GapNote] = []
    /// Alarms added, moved or switched off by the box or the insight pass (`AlarmRules`).
    public var alarmRules: [AlarmRule] = []
    public var learned = LearnedModel()
    public var beliefs = Beliefs()
    public var policy = BehaviourPolicy()
    public var taper = ScreenTaper()
    public var flashcards: [Flashcard] = []
    public var reads: [ReadPiece] = []
    public var plan: Plan = .empty
    public var places: [SavedPlace] = []
    public var visits: [PlaceVisit] = []
    @SortedSet public var declinedPlaces: Set<String> = []
    public var integrations = Integrations()
    public var review: WeeklyReview?
    public var reviewAt: Date?
    public var conversation = Conversation(startedAt: Date())
    public var archive = ConversationArchive()
    public var draft = Draft()
    public var focus: FocusSession?
    @SortedSet public var dismissed: Set<String> = []
    /// What the insight pass changed.
    public var changes = ChangeLog()
    /// When the insight pass last ran.
    public var insightAt: Date?
    /// Celebrations (v1.1 F): what was shown and how much the student wants.
    public var rewards = RewardLog()
    /// Which Life Metrics tiles show on Review, in order (G3).
    public var metricTiles: [MetricID] = MetricID.defaultTiles
    public var rewardSettings = RewardSettings()
    public var gaps = GapLog()
    public var appOpens: [Date] = []
    public var usage = UsageLedger()
    public var snoozed: [UUID: Date] = [:]

    public var dumpState: DumpState {
        get {
            var ds = DumpState(items: items, commitments: commitments, exceptions: exceptions, oneOffs: oneOffs, markers: markers,
                      routines: routines, moods: moods, screen: screen, prefs: prefs, policy: policy,
                      progress: progress, beliefs: beliefs, scrollingApps: scrollingApps, screenAverages: screenAverages)
            ds.situations = situations
            ds.dayRules = dayRules
            ds.gapNotes = gapNotes
            ds.alarmRules = alarmRules
            ds.metricTiles = metricTiles
            ds.alarmsAllowed = integrations.alarms
            ds.rewardSettings = rewardSettings
            ds.calendarEvents = events
            return ds
        }
        set {
            items = newValue.items
            commitments = newValue.commitments
            exceptions = newValue.exceptions
            oneOffs = newValue.oneOffs
            markers = newValue.markers
            routines = newValue.routines
            moods = newValue.moods
            screen = newValue.screen
            prefs = newValue.prefs
            policy = newValue.policy
            progress = newValue.progress
            beliefs = newValue.beliefs
            scrollingApps = newValue.scrollingApps
            screenAverages = newValue.screenAverages
            situations = newValue.situations
            dayRules = newValue.dayRules
            gapNotes = newValue.gapNotes
            alarmRules = newValue.alarmRules
            metricTiles = newValue.metricTiles
            rewardSettings = newValue.rewardSettings
        }
    }

    public init() {}

    // Lenient so a build that adds a field never wipes stored data.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppState()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? def }
        // No migration (v1.2 decision): an older schema decodes as a fresh state.
        guard v(.schema, 0) >= AppState.schema else { self = d; return }
        onboarded = v(.onboarded, d.onboarded)
        entries = v(.entries, d.entries)
        rules = v(.rules, d.rules)
        categories = v(.categories, d.categories)
        dayPlans = v(.dayPlans, d.dayPlans)
        telemetry = v(.telemetry, d.telemetry)
        pinnedCharts = v(.pinnedCharts, d.pinnedCharts)
        prefs = v(.prefs, d.prefs)
        items = v(.items, d.items)
        commitments = v(.commitments, d.commitments)
        routines = v(.routines, d.routines)
        markers = v(.markers, d.markers)
        outcomes = v(.outcomes, d.outcomes)
        planHistory = v(.planHistory, d.planHistory)
        plannedBedtimes = v(.plannedBedtimes, d.plannedBedtimes)
        progress = v(.progress, d.progress)
        moods = v(.moods, d.moods)
        health = v(.health, d.health)
        motion = v(.motion, d.motion)
        screen = v(.screen, d.screen)
        screenAverages = v(.screenAverages, d.screenAverages)
        scrollingApps = v(.scrollingApps, d.scrollingApps)
        events = v(.events, d.events)
        oneOffs = v(.oneOffs, d.oneOffs)
        exceptions = v(.exceptions, d.exceptions)
        situations = v(.situations, d.situations)
        dayRules = v(.dayRules, d.dayRules)
        gapNotes = v(.gapNotes, d.gapNotes)
        alarmRules = v(.alarmRules, d.alarmRules)
        learned = v(.learned, d.learned)
        beliefs = v(.beliefs, d.beliefs)
        policy = v(.policy, d.policy)
        taper = v(.taper, d.taper)
        flashcards = v(.flashcards, d.flashcards)
        reads = v(.reads, d.reads)
        plan = v(.plan, d.plan)
        places = v(.places, d.places)
        visits = v(.visits, d.visits)
        declinedPlaces = v(.declinedPlaces, d.declinedPlaces)
        integrations = v(.integrations, d.integrations)
        review = v(.review, d.review)
        reviewAt = v(.reviewAt, d.reviewAt)
        conversation = v(.conversation, d.conversation)
        archive = v(.archive, d.archive)
        draft = v(.draft, d.draft)
        focus = v(.focus, d.focus)
        dismissed = v(.dismissed, d.dismissed)
        changes = v(.changes, d.changes)
        insightAt = v(.insightAt, d.insightAt)
        rewards = v(.rewards, d.rewards)
        metricTiles = v(.metricTiles, d.metricTiles)
        rewardSettings = v(.rewardSettings, d.rewardSettings)
        gaps = v(.gaps, d.gaps)
        appOpens = v(.appOpens, d.appOpens)
        usage = v(.usage, d.usage)
        snoozed = v(.snoozed, d.snoozed)
    }

    public mutating func prune(now: Date) {
        snoozed = snoozed.filter { $0.value > now.addingTimeInterval(-3600) }
        telemetry.prune(now: now)
    }

    public mutating func restore(full s: AppState, keepingDevice: Bool = true) {
        let device = integrations
        self = s
        guard keepingDevice else { return }
        integrations = device
        focus = nil
        onboarded = true
    }
}
