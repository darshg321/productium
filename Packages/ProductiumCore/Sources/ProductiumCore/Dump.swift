import Foundation

// What the insight pass and settings work on: a slice of `AppState` (`AppState.dumpState`). The box's ops are `BoxOps.swift`.

public struct DumpState: Sendable {
    public var items: [WorkItem]
    public var moods: [MoodEntry]
    public var screen: [ScreenDay]
    public var prefs: Preferences
    public var policy: BehaviourPolicy
    public var progress: [ProgressEntry]
    public var aboutMe: AboutMe
    public var beliefs: Beliefs
    public var scrollingApps: [String: Bool] = [:]
    public var screenAverages: [ScreenDay] = []
    public var dayRules = DayRuleBook()
    public var metricTiles: [MetricID] = MetricID.defaultTiles
    /// Read-only here: whether the device has allowed alarms (the box can't grant that).
    public var alarmsAllowed = false
    public var rewardSettings = RewardSettings()
    /// v1.3 A4: the activity grid (the insight pass tidies it); its last uses and the tree are read-only here.
    public var quickStarts = QuickStarts()
    public var quickStartUse: [UUID: Date] = [:]
    public var categories = CategoryTree()

    public init(items: [WorkItem],
                moods: [MoodEntry], screen: [ScreenDay], prefs: Preferences,
                policy: BehaviourPolicy = BehaviourPolicy(), progress: [ProgressEntry] = [], aboutMe: AboutMe = .empty,
                beliefs: Beliefs = Beliefs(), scrollingApps: [String: Bool] = [:], screenAverages: [ScreenDay] = []) {
        self.scrollingApps = scrollingApps
        self.screenAverages = screenAverages
        self.beliefs = beliefs
        self.progress = progress
        self.aboutMe = aboutMe
        self.items = items
        self.moods = moods
        self.screen = screen
        self.prefs = prefs
        self.policy = policy
    }
}
