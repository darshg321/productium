import Foundation

// MARK: - The app's whole persisted state
//
// Kept in ProductiumCore (pure Foundation) so it can be tested on Linux: the export test checks
// that every stored property is in the export and survives a round trip.

public struct SavedPlace: Codable, Hashable, Identifiable, Sendable {
    public var id: String          // "home", "school", or a custom id
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
    public var screenTime = false
    public var location = false
    public var alarms = false
    public var liveActivities = true
    public var notifications = false
    public var motion = false

    public init() {}

    /// A switch added in a later build starts off instead of resetting the others.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v(_ k: CodingKeys, _ d: Bool) -> Bool { (try? c.decodeIfPresent(Bool.self, forKey: k)) ?? d }
        health = v(.health, false); calendarImport = v(.calendarImport, false); calendarExport = v(.calendarExport, false)
        screenTime = v(.screenTime, false); location = v(.location, false); alarms = v(.alarms, false)
        liveActivities = v(.liveActivities, true); notifications = v(.notifications, false); motion = v(.motion, false)
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

/// Everything the app persists in state.json. Every field decodes with a default, so a build
/// that adds a field never wipes the student's data (the export test checks every field round-trips).
public struct AppState: Codable, Sendable {
    public var onboarded = false
    public var prefs = Preferences()
    public var items: [WorkItem] = []
    public var commitments: [Commitment] = []
    public var routines: [Routine] = Routine.defaults
    public var markers: [TimelineEvent] = []
    public var outcomes: [BlockOutcome] = []
    /// Work logged outside study blocks (box progress, evidence).
    public var progress: [ProgressEntry] = []
    public var moods: [MoodEntry] = []
    public var health: [HealthDay] = []
    /// Core Motion spans (walks, rides, still periods).
    public var motion: [MotionSpan] = []
    public var screen: [ScreenDay] = []
    public var events: [FixedEvent] = []          // calendar cache
    public var oneOffs: [FixedEvent] = []         // one-off busy time from the brain dump
    public var exceptions: [DayException] = []    // one-day changes ("no school today")
    public var learned = LearnedModel()
    /// Tier 2: how the app behaves. Changed only by approved proposals.
    public var policy = BehaviourPolicy()
    public var taper = ScreenTaper()
    public var flashcards: [Flashcard] = []
    public var reads: [ReadPiece] = []
    public var plan: Plan = .empty
    public var places: [SavedPlace] = []
    public var integrations = Integrations()
    public var review: WeeklyReview?
    public var reviewAt: Date?
    /// The Inbox box: one ongoing AI session until it's cleared.
    public var conversation = Conversation(startedAt: Date())
    /// Cleared conversations ("Past prompts").
    public var archive = ConversationArchive()
    public var focus: FocusSession?
    @SortedSet public var learnedDays: Set<String> = []
    @SortedSet public var dismissed: Set<String> = []
    /// "What were you doing?" questions and their answers.
    public var gaps = GapLog()
    /// When Productium was opened (phone-use evidence for gaps and sleep).
    public var appOpens: [Date] = []
    public var usage = UsageLedger()              // AI token meter
    public var snoozed: [UUID: Date] = [:]        // block → when its snooze reminder fires

    public var dumpState: DumpState {
        get {
            DumpState(items: items, commitments: commitments, exceptions: exceptions, oneOffs: oneOffs, markers: markers,
                      routines: routines, moods: moods, screen: screen, prefs: prefs, policy: policy,
                      progress: progress)
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
        }
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppState()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? def }
        onboarded = v(.onboarded, d.onboarded)
        prefs = v(.prefs, d.prefs)
        items = v(.items, d.items)
        commitments = v(.commitments, d.commitments)
        routines = v(.routines, d.routines)
        markers = v(.markers, d.markers)
        outcomes = v(.outcomes, d.outcomes)
        progress = v(.progress, d.progress)
        moods = v(.moods, d.moods)
        health = v(.health, d.health)
        motion = v(.motion, d.motion)
        screen = v(.screen, d.screen)
        events = v(.events, d.events)
        oneOffs = v(.oneOffs, d.oneOffs)
        exceptions = v(.exceptions, d.exceptions)
        learned = v(.learned, d.learned)
        policy = v(.policy, d.policy)
        taper = v(.taper, d.taper)
        flashcards = v(.flashcards, d.flashcards)
        reads = v(.reads, d.reads)
        plan = v(.plan, d.plan)
        places = v(.places, d.places)
        integrations = v(.integrations, d.integrations)
        review = v(.review, d.review)
        reviewAt = v(.reviewAt, d.reviewAt)
        conversation = v(.conversation, d.conversation)
        archive = v(.archive, d.archive)
        focus = v(.focus, d.focus)
        learnedDays = v(.learnedDays, d.learnedDays)
        dismissed = v(.dismissed, d.dismissed)
        gaps = v(.gaps, d.gaps)
        appOpens = v(.appOpens, d.appOpens)
        usage = v(.usage, d.usage)
        snoozed = v(.snoozed, d.snoozed)
    }

    /// Nothing the student might want in an export is thrown away: only expired snoozes go.
    /// (If the file ever gets genuinely big, old data moves to an archive file instead.)
    public mutating func prune(now: Date) {
        snoozed = snoozed.filter { $0.value > now.addingTimeInterval(-3600) }
    }

    /// Restore from an export. Permissions (integrations) belong to this phone, not the export,
    /// so they're kept, and a focus session from another time is dropped. With `keepingDevice`
    /// off it's an exact copy (for tests and the repair script).
    public mutating func restore(full s: AppState, keepingDevice: Bool = true) {
        let device = integrations
        self = s
        guard keepingDevice else { return }
        integrations = device
        focus = nil
        onboarded = true
    }
}

