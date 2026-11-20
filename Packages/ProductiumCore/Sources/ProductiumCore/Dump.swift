import Foundation

// What the insight pass and settings work on: a slice of `AppState` (`AppState.dumpState`). The box's ops are `BoxOps.swift`.

public struct DumpState: Sendable {
    public var items: [WorkItem]
    public var commitments: [Commitment]
    public var exceptions: [DayException]
    public var oneOffs: [FixedEvent]
    public var markers: [TimelineEvent]
    public var routines: [Routine]
    public var moods: [MoodEntry]
    public var screen: [ScreenDay]
    public var prefs: Preferences
    public var policy: BehaviourPolicy
    public var progress: [ProgressEntry]
    public var aboutMe: AboutMe
    public var beliefs: Beliefs
    public var scrollingApps: [String: Bool] = [:]
    public var screenAverages: [ScreenDay] = []
    /// Conditional overrides (v1.1 A). The insight pass adds them through `ChangeLog`; the box through `SituationRules.admit`.
    public var situations: [Situation] = []
    public var dayRules = DayRuleBook()
    public var gapNotes: [GapNote] = []
    public var alarmRules: [AlarmRule] = []
    public var metricTiles: [MetricID] = MetricID.defaultTiles
    /// Read-only here: whether the device has allowed alarms (the box can't grant that).
    public var alarmsAllowed = false
    public var rewardSettings = RewardSettings()
    /// Read-only: imported calendar events (a situation can't free their time).
    public var calendarEvents: [FixedEvent] = []

    public init(items: [WorkItem], commitments: [Commitment], exceptions: [DayException], oneOffs: [FixedEvent],
                markers: [TimelineEvent], routines: [Routine], moods: [MoodEntry], screen: [ScreenDay], prefs: Preferences,
                policy: BehaviourPolicy = BehaviourPolicy(), progress: [ProgressEntry] = [], aboutMe: AboutMe = .empty,
                beliefs: Beliefs = Beliefs(), scrollingApps: [String: Bool] = [:], screenAverages: [ScreenDay] = []) {
        self.scrollingApps = scrollingApps
        self.screenAverages = screenAverages
        self.beliefs = beliefs
        self.progress = progress
        self.aboutMe = aboutMe
        self.items = items
        self.commitments = commitments
        self.exceptions = exceptions
        self.oneOffs = oneOffs
        self.markers = markers
        self.routines = routines
        self.moods = moods
        self.screen = screen
        self.prefs = prefs
        self.policy = policy
    }
}
