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
    /// v1.2 M9: open tasks mirrored into a "Productium" list in Reminders.
    public var reminders = false
    /// v1.2 M5: new Screen Time screenshots read on the phone.
    public var photos = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v(_ k: CodingKeys, _ d: Bool) -> Bool { (try? c.decodeIfPresent(Bool.self, forKey: k)) ?? d }
        health = v(.health, false); calendarImport = v(.calendarImport, false); calendarExport = v(.calendarExport, false)
        location = v(.location, false); alarms = v(.alarms, false)
        notifications = v(.notifications, false); motion = v(.motion, false)
        healthNeedsRequest = v(.healthNeedsRequest, false)
        reminders = v(.reminders, false); photos = v(.photos, false)
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

public struct Feedback: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var at: Date
    public var text: String
    public var appVersion: String?

    public init(id: UUID = UUID(), at: Date, text: String, appVersion: String? = nil) {
        self.id = id
        self.at = at
        self.text = text
        self.appVersion = appVersion
    }
}

public struct AppState: Codable, Sendable {
    /// 8 = v1.6, the first of the new line (`Migrations`); older stored data is refused with `BeforeBaseline`.
    public static let schema = 8
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
    /// v1.2 C5: the taxonomy pass's runs (each can be reverted).
    public var taxonomy = TaxonomyLog()
    /// v1.2 P2: the patterns the last insight pass chose (shown in Review → Today and the Weekly Note).
    public var patterns: [Pattern] = []
    /// v1.2 Part N: what the phone noticed, asked and learned.
    public var inference = InferenceState()
    /// v1.2 Part H: how every task ended (kept after the task is deleted).
    public var taskHistory = TaskHistory()
    /// v1.2 Part I: your goals and the AI's (the built-in tracking goal is `Goal.trackingGaps`, not stored).
    public var goals: [Goal] = []
    /// v1.2 D4 / A7: what the tracking prompts asked and when you answered.
    public var prompts = PromptLog()
    /// v1.2 D2: start buttons.
    public var quickStarts = QuickStarts()
    /// v1.2 A9: replies saved before they're sent; removed once applied.
    public var outbox = Outbox()
    /// v1.2 C2: learned title → category rules and your corrections.
    public var categoryRules = CategoryRules()
    /// v1.2 Part T: the development log, in every backup.
    public var telemetry = Telemetry()
    /// Groups you compare day scores with (Review → Leaderboard).
    public var leaderboard = LeaderboardState()
    public var prefs = Preferences()
    public var items: [WorkItem] = []
    public var planHistory: [String: [PlannedBlock]] = [:]
    /// Planned bedtime per night, keyed by the morning (for "in bed on time").
    public var plannedBedtimes: [String: Date] = [:]
    public var progress: [ProgressEntry] = []
    public var moods: [MoodEntry] = []
    public var health: [HealthDay] = []
    /// v1.2 A6: what the last Health reads did (errors, sample counts, the night's source).
    public var healthReads = HealthReadLog()
    public var motion: [MotionSpan] = []
    public var screen: [ScreenDay] = []
    public var screenAverages: [ScreenDay] = []
    public var scrollingApps: [String: Bool] = [:]
    /// Named day sequences (A/B rotations) and labels ("exam-week", "no-school").
    public var dayRules = DayRuleBook()
    /// v1.2 J: changes waiting for your Approve / Decline (risky box ops, alarms the insight pass proposes).
    public var approvals: [Approval] = []
    public var learned = LearnedModel()
    public var beliefs = Beliefs()
    public var policy = BehaviourPolicy()
    public var taper = ScreenTaper()
    public var plan: Plan = .empty
    public var places: [SavedPlace] = []
    public var visits: [PlaceVisit] = []
    /// v1.2 Part E: places that name themselves, and the location history (180 days).
    public var placeBook = PlaceBook()
    public var trace = LocationTrace()
    public var integrations = Integrations()
    public var review: WeeklyReview?
    public var reviewAt: Date?
    public var conversation = Conversation(startedAt: Date())
    public var archive = ConversationArchive()
    public var draft = Draft()
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
    public var appOpens: [Date] = []
    public var usage = UsageLedger()
    public var snoozed: [UUID: Date] = [:]
    /// v1.3 H1: the daily backup's folder and last write.
    public var backup = BackupState()
    /// Notes you wrote for whoever builds Productium (Settings → Backup & Restore); they travel in the export.
    public var feedback: [Feedback] = []
    /// v1.6 C1: a session on pause (nil: nothing paused).
    public var paused: PausedSession?

    public var dumpState: DumpState {
        get {
            var ds = DumpState(items: items, moods: moods, screen: screen, prefs: prefs, policy: policy,
                      progress: progress, beliefs: beliefs, scrollingApps: scrollingApps, screenAverages: screenAverages)
            ds.dayRules = dayRules
            ds.metricTiles = metricTiles
            ds.alarmsAllowed = integrations.alarms
            ds.rewardSettings = rewardSettings
            ds.quickStarts = quickStarts
            ds.quickStartUse = quickStarts.lastUse(entries)
            ds.categories = categories
            return ds
        }
        set {
            items = newValue.items
            moods = newValue.moods
            screen = newValue.screen
            prefs = newValue.prefs
            policy = newValue.policy
            progress = newValue.progress
            beliefs = newValue.beliefs
            scrollingApps = newValue.scrollingApps
            screenAverages = newValue.screenAverages
            dayRules = newValue.dayRules
            metricTiles = newValue.metricTiles
            rewardSettings = newValue.rewardSettings
            quickStarts = newValue.quickStarts
        }
    }

    public init() {}

    /// When you started using Productium: the first thing you told it, planned, typed or opened. Days before it have
    /// Health and Screen Time data (comparable) but no log, so nothing log-based (scores, work, tracked, categories)
    /// counts them.
    public var trackingSince: Date? {
        let told = entries.lazy.filter { $0.source == .you || $0.source == .plan }.map(\.createdAt).min()
        let said = (archive.conversations.flatMap(\.turns) + conversation.turns).map(\.at).min()
        return [told, said, appOpens.min(), items.map(\.createdAt).min()].compactMap { $0 }.min()
    }

    // Lenient so a build that adds a field never wipes stored data.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppState()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? def }
        let stored = v(.schema, 0)
        guard stored >= Migrations.oldest else { throw BeforeBaseline(schema: stored) }
        onboarded = v(.onboarded, d.onboarded)
        entries = v(.entries, d.entries)
        rules = v(.rules, d.rules)
        categories = v(.categories, d.categories)
        dayPlans = v(.dayPlans, d.dayPlans)
        telemetry = v(.telemetry, d.telemetry)
        leaderboard = v(.leaderboard, d.leaderboard)
        outbox = v(.outbox, d.outbox)
        prompts = v(.prompts, d.prompts)
        goals = v(.goals, d.goals)
        taskHistory = v(.taskHistory, d.taskHistory)
        inference = v(.inference, d.inference)
        taxonomy = v(.taxonomy, d.taxonomy)
        patterns = v(.patterns, d.patterns)
        quickStarts = v(.quickStarts, d.quickStarts)
        categoryRules = v(.categoryRules, d.categoryRules)
        pinnedCharts = v(.pinnedCharts, d.pinnedCharts)
        prefs = v(.prefs, d.prefs)
        items = v(.items, d.items)
        planHistory = v(.planHistory, d.planHistory)
        plannedBedtimes = v(.plannedBedtimes, d.plannedBedtimes)
        progress = v(.progress, d.progress)
        moods = v(.moods, d.moods)
        health = v(.health, d.health)
        healthReads = v(.healthReads, d.healthReads)
        motion = v(.motion, d.motion)
        screen = v(.screen, d.screen)
        screenAverages = v(.screenAverages, d.screenAverages)
        scrollingApps = v(.scrollingApps, d.scrollingApps)
        dayRules = v(.dayRules, d.dayRules)
        approvals = v(.approvals, d.approvals)
        learned = v(.learned, d.learned)
        beliefs = v(.beliefs, d.beliefs)
        policy = v(.policy, d.policy)
        taper = v(.taper, d.taper)
        plan = v(.plan, d.plan)
        places = v(.places, d.places)
        visits = v(.visits, d.visits)
        placeBook = v(.placeBook, d.placeBook)
        trace = v(.trace, d.trace)
        integrations = v(.integrations, d.integrations)
        review = v(.review, d.review)
        reviewAt = v(.reviewAt, d.reviewAt)
        conversation = v(.conversation, d.conversation)
        archive = v(.archive, d.archive)
        draft = v(.draft, d.draft)
        dismissed = v(.dismissed, d.dismissed)
        changes = v(.changes, d.changes)
        insightAt = v(.insightAt, d.insightAt)
        rewards = v(.rewards, d.rewards)
        metricTiles = v(.metricTiles, d.metricTiles)
        rewardSettings = v(.rewardSettings, d.rewardSettings)
        appOpens = v(.appOpens, d.appOpens)
        usage = v(.usage, d.usage)
        snoozed = v(.snoozed, d.snoozed)
        backup = v(.backup, d.backup)
        feedback = v(.feedback, d.feedback)
        paused = v(.paused, d.paused)
        if stored < AppState.schema { Migrations.upgrade(&self, from: stored) }
    }

    /// v1.6 G3: what an export or backup carries: everything, with the development log cut to its last 7 days.
    public func forExport(now: Date) -> AppState {
        var s = self
        s.telemetry.events.removeAll { $0.at < now.addingTimeInterval(-7 * 86400) }
        return s
    }

    public mutating func prune(now: Date) {
        snoozed = snoozed.filter { $0.value > now.addingTimeInterval(-3600) }
        telemetry.prune(now: now)
        outbox.prune(now: now)
        prompts.prune(now: now)
        trace.prune(now: now)
        inference.prune(now: now)
        approvals = Approvals.live(approvals, now: now)
    }

    public mutating func restore(full s: AppState, keepingDevice: Bool = true) {
        let device = integrations
        self = s
        guard keepingDevice else { return }
        integrations = device
        onboarded = true
    }
}
