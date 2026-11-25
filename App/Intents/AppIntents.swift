import AppIntents
import ProductiumCore

struct TellProductiumIntent: AppIntent {
    static var title: LocalizedStringResource = "Tell Productium"
    static var description = IntentDescription("Add a deadline, check in, or log how you feel, in plain words.")
    @Parameter(title: "What's new?") var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        AppModel.shared.log(.intent, "TellProductiumIntent")
        await AppModel.shared.submit(text, source: .shortcut)
        let reply = AppModel.shared.state.conversation.turns.last?.reply ?? "Got it."
        return .result(dialog: "\(reply)")
    }
}

// MARK: - v1.2 M1–M4: start and stop the time log from anywhere

/// A start button as Siri, Spotlight and Shortcuts see it. Anything typed works too ("Start Laundry").
struct ActivityEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Activity"
    static var defaultQuery = ActivityQuery()
    var id: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(id)") }
}

struct ActivityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [ActivityEntity] { identifiers.map { ActivityEntity(id: $0) } }

    @MainActor
    func entities(matching string: String) async throws -> [ActivityEntity] {
        let mine = AppModel.shared.state.quickStarts.buttons.filter { !$0.removed && $0.title.localizedCaseInsensitiveContains(string) }
        return [ActivityEntity(id: string)] + mine.map { ActivityEntity(id: $0.title) }.filter { $0.id != string }
    }

    @MainActor
    func suggestedEntities() async throws -> [ActivityEntity] {
        AppModel.shared.startButtons().row.map { ActivityEntity(id: $0.title) }
    }
}

/// "Start Shower": an NFC sticker, the Action button, a Focus automation, Siri. Runs in the app, no screen needed.
struct StartActivityIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Start Activity"
    static var description = IntentDescription("Starts tracking something (a start button, a task, or any name). Use it from an NFC sticker, the Action button, or a Focus turning on.")
    @Parameter(title: "Activity") var activity: ActivityEntity

    init() {}
    init(_ title: String) { activity = ActivityEntity(id: title) }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        AppModel.shared.log(.intent, "StartActivityIntent", ["activity": activity.id])
        AppModel.shared.start(title: activity.id, source: "intent")
        return .result(dialog: "Started \(activity.id).")
    }
}

/// One NFC sticker on the shower door: the first tap starts Shower, the next stops it.
struct ToggleActivityIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Start or Stop Activity"
    static var description = IntentDescription("Stops it if it's what's running, otherwise starts it. One NFC sticker per thing.")
    @Parameter(title: "Activity") var activity: ActivityEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let m = AppModel.shared
        m.log(.intent, "ToggleActivityIntent", ["activity": activity.id])
        if ActivityToggle.ops(activity.id, running: m.running).first?.verb == .stop {
            m.stopRunning(source: "toggle")
            return .result(dialog: "Stopped \(activity.id).")
        }
        m.start(title: activity.id, source: "toggle")
        return .result(dialog: "Started \(activity.id).")
    }
}

/// N4: an alarm stopped (Productium's own alarm's Stop, or the Shortcuts "When alarm is stopped" automation).
struct AlarmStoppedIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Alarm Stopped"
    static var description = IntentDescription("Tells Productium when you turned your alarm off, so it knows when you woke up.")
    @Parameter(title: "When it rang") var ringAt: Date?

    init() {}
    init(ringAt: Date) { self.ringAt = ringAt }

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared.log(.intent, "AlarmStoppedIntent")
        AppModel.shared.alarmStopped(ringAt: ringAt)
        return .result()
    }
}

/// M4: donate what you start and stop, so iOS can suggest it on the Lock Screen and in Spotlight at the usual time.
enum Donations {
    static func started(_ title: String) {
        Task { _ = try? await IntentDonationManager.shared.donate(intent: StartActivityIntent(title)) }
    }
    static func stopped() {
        Task { _ = try? await IntentDonationManager.shared.donate(intent: StopActivityIntent()) }
    }
}

struct LogMoodIntent: AppIntent {
    static var title: LocalizedStringResource = "Log mood"
    @Parameter(title: "Mood (1–5)", inclusiveRange: (1, 5)) var mood: Int

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        AppModel.shared.log(.intent, "LogMoodIntent")
        AppModel.shared.logMood(mood, energy: nil, note: nil)
        return .result(dialog: "Thanks. Today's plan has adjusted.")
    }
}

struct PauseBeforeScrollingIntent: AppIntent {
    static var title: LocalizedStringResource = "Pause Before Scrolling"
    static var description = IntentDescription("Opens a short pause in Productium, unless you chose to continue in the last few minutes. Use it in an “App is opened” automation, one per app, with the app's name filled in. Returns whether it paused.")
    @Parameter(title: "App", default: "Scrolling app") var app: String

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        AppModel.shared.log(.intent, "PauseBeforeScrollingIntent")
        defer { AppModel.shared.rebuildAppEntries() }
        guard Friction.opened(app) else { return .result(value: false) }
        Friction.pausedAt = Date()
        if #available(iOS 26.0, *), systemContext.currentMode.canContinueInForeground {
            if (try? await continueInForeground(alwaysConfirm: false)) != nil {
                AppModel.shared.deepLink = "productium://gap"
            }
        }
        return .result(value: true)
    }
}

struct ShouldPauseIntent: AppIntent {
    static var title: LocalizedStringResource = "Should I pause?"
    static var description = IntentDescription("True unless you chose to continue in the last few minutes. Use it with If and Open URLs (productium://gap) in an “App is opened” automation.")
    @Parameter(title: "App", default: "Scrolling app") var app: String

    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        await AppModel.shared.log(.intent, "ShouldPauseIntent")
        let pause = Friction.opened(app)
        await AppModel.shared.rebuildAppEntries()
        return .result(value: pause)
    }
}

struct ClosedDistractingAppIntent: AppIntent {
    static var title: LocalizedStringResource = "Closed a Distracting App"
    static var description = IntentDescription("Use it in an “App is closed” automation with the same apps as the pause, and in an “App is opened” automation for the other apps you use (Messages, Safari, Camera…): opening any other app ends the session. Productium counts the minutes and stops the check-ins.")
    @Parameter(title: "App (leave empty for “any”)") var app: String?

    func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        await AppModel.shared.log(.intent, "ClosedDistractingAppIntent")
        let minutes = Friction.closed(app)
        await AppModel.shared.rebuildAppEntries()
        return .result(value: minutes)
    }
}

/// v1.3: one automation for every app ("App is opened", all apps ticked, App = Shortcut Input). Productium then logs
/// screen time for each app, files scrolling apps under Scrolling and messaging apps under Messaging, as assumed time.
struct OpenedAppIntent: AppIntent {
    static var title: LocalizedStringResource = "Opened an App"
    static var description = IntentDescription("Use it in an “App is opened” automation with every app ticked, and App set to Shortcut Input. Productium logs your screen time per app and fills your day with scrolling and messaging (as assumed time you can confirm). It never opens Productium.")
    @Parameter(title: "App") var app: String

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared.log(.intent, "OpenedAppIntent", ["app": String(app.prefix(40))])
        AppModel.shared.appOpened(app)
        return .result()
    }
}

enum StopSignal: String, AppEnum {
    case otherApp, charger, alarm, focus

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "What happened"
    static var caseDisplayRepresentations: [StopSignal: DisplayRepresentation] = [
        .otherApp: "Opened another app", .charger: "Charger connected", .alarm: "Alarm stopped", .focus: "A Focus turned on",
    ]

    var source: ScrollSession.EndSource { self == .otherApp ? .otherApp : .lockProxy }
}

struct StoppedScrollingIntent: AppIntent {
    static var title: LocalizedStringResource = "Probably Stopped Scrolling"
    static var description = IntentDescription("Ends a scrolling session that's still open. Use it in “Charger is connected”, “Alarm is stopped” and “Sleep/Work/Driving Focus turns on” automations.")
    @Parameter(title: "What happened", default: .charger) var signal: StopSignal

    func perform() async throws -> some IntentResult {
        await AppModel.shared.log(.intent, "StoppedScrollingIntent")
        Friction.ended(by: signal.source)
        await AppModel.shared.rebuildAppEntries()
        if signal == .charger {
            let d = LocalStore.defaults
            let times = (d.array(forKey: LocalStore.Key.chargingTimes) as? [Double] ?? []) + [Date().timeIntervalSince1970]
            d.set(Array(times.suffix(40)), forKey: LocalStore.Key.chargingTimes)
        }
        return .result()
    }
}

enum PlanMomentEnum: String, AppEnum {
    case focus, breakTime, busy, free, windDown, sleep

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Plan right now"
    static var caseDisplayRepresentations: [PlanMomentEnum: DisplayRepresentation] = [
        .focus: "Focus", .breakTime: "Break", .busy: "Busy", .free: "Free", .windDown: "Wind-down", .sleep: "Sleep",
    ]
}

struct CurrentPlanIntent: AppIntent {
    static var title: LocalizedStringResource = "What's the Plan Now?"
    static var description = IntentDescription("Returns Focus, Break, Busy, Free, Wind-down or Sleep, from today's plan.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<PlanMomentEnum> & ProvidesDialog {
        AppModel.shared.log(.intent, "CurrentPlanIntent")
        let m = AppModel.shared.state.plan.moment(at: Date())
        let value = PlanMomentEnum(rawValue: m.rawValue) ?? .free
        return .result(value: value, dialog: "\(m.title)")
    }
}

struct ScreensOffIntent: AppIntent {
    static var title: LocalizedStringResource = "Is It Screens-Off Time?"
    static var description = IntentDescription("True during wind-down and sleep in today's plan. Use it with If to turn on grayscale or log bedtime.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        AppModel.shared.log(.intent, "ScreensOffIntent")
        let m = AppModel.shared.state.plan.moment(at: Date())
        return .result(value: m == .windDown || m == .sleep)
    }
}

enum Friction {
    static let graceMinutes = 10

    static var inGrace: Bool {
        Date().timeIntervalSince1970 < LocalStore.defaults.double(forKey: LocalStore.Key.frictionGraceUntil)
    }

    static func opened(_ app: String) -> Bool {
        let pause = !inGrace
        let wasOpen = log.open?.isScrolling ?? false
        let measures = update { $0.opened(app, at: Date(), paused: pause, calendar: .current); return $0.measuresClosing }
        if pause {
            let key = LocalStore.Key.frictionPrefix + LocalStore.dayKey()
            LocalStore.defaults.set(LocalStore.defaults.integer(forKey: key) + 1, forKey: key)
        } else if measures && !wasOpen {
            scheduleNextCheckIn()
        }
        return pause
    }

    static func grant(minutes: Int = graceMinutes) {
        LocalStore.defaults.set(Date().addingTimeInterval(Double(minutes) * 60).timeIntervalSince1970,
                                  forKey: LocalStore.Key.frictionGraceUntil)
        LocalStore.defaults.set(0, forKey: LocalStore.Key.scrollCheckInIndex)
        scheduleNextCheckIn()
    }

    @discardableResult
    static func closed(_ app: String? = nil) -> Int {
        let mins = update { $0.closed(app, at: Date()) }
        NotificationService.cancelScrollCheckIns()
        return mins
    }

    /// v1.6 G7: when the pause automation last opened Productium; that opening doesn't end the session it paused.
    nonisolated(unsafe) static var pausedAt = Date.distantPast

    static func ended(by source: ScrollSession.EndSource) {
        guard update({ $0.ended(by: source, at: Date()) }) != nil else { return }
        NotificationService.cancelScrollCheckIns()
    }

    static func scheduleNextCheckIn() {
        let steps = checkInMinutes
        let i = LocalStore.defaults.integer(forKey: LocalStore.Key.scrollCheckInIndex)
        guard i < steps.count else { return }
        let wait = i == 0 ? steps[0] : steps[i] - steps[i - 1]
        NotificationService.scheduleScrollCheckIn(after: wait, total: steps[i], last: i == steps.count - 1)
        update { $0.checkInSent(at: Date().addingTimeInterval(Double(wait) * 60)) }
        LocalStore.defaults.set(i + 1, forKey: LocalStore.Key.scrollCheckInIndex)
    }

    static func answered(stillScrolling: Bool) {
        let open = update { $0.checkInAnswered(stillScrolling: stillScrolling, at: Date()) }
        if open && stillScrolling { scheduleNextCheckIn() } else { NotificationService.cancelScrollCheckIns() }
    }

    @discardableResult
    static func update<T>(_ change: (inout ScrollLog) -> T) -> T {
        var l = log
        let result = change(&l)
        log = l
        return result
    }

    static var checkInMinutes: [Int] {
        LocalStore.defaults.array(forKey: LocalStore.Key.scrollCheckIns) as? [Int] ?? NudgeLevel.standard.scrollCheckIns
    }

    static var log: ScrollLog {
        get {
            guard let d = LocalStore.defaults.data(forKey: LocalStore.Key.scrollLog),
                  let l = try? JSONDecoder().decode(ScrollLog.self, from: d) else { return ScrollLog() }
            return l
        }
        set {
            if let d = try? JSONEncoder().encode(newValue) { LocalStore.defaults.set(d, forKey: LocalStore.Key.scrollLog) }
        }
    }
}

struct ProductiumShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: TellProductiumIntent(), phrases: ["Tell \(.applicationName)", "Add to \(.applicationName)"],
                    shortTitle: "Tell Productium", systemImageName: "text.bubble")
        AppShortcut(intent: StartActivityIntent(), phrases: ["Start \(\.$activity) in \(.applicationName)",
                                                             "Track \(\.$activity) in \(.applicationName)"],
                    shortTitle: "Start Activity", systemImageName: "play.fill")
        AppShortcut(intent: StopActivityIntent(), phrases: ["Stop in \(.applicationName)", "I'm done in \(.applicationName)"],
                    shortTitle: "Stop Activity", systemImageName: "stop.fill")
        AppShortcut(intent: ToggleActivityIntent(), phrases: ["Toggle \(\.$activity) in \(.applicationName)"],
                    shortTitle: "Start or Stop", systemImageName: "playpause.fill")
        AppShortcut(intent: LogMoodIntent(), phrases: ["Log mood in \(.applicationName)"], shortTitle: "Log mood", systemImageName: "face.smiling")
        AppShortcut(intent: CurrentPlanIntent(), phrases: ["What's the plan in \(.applicationName)", "What should I do in \(.applicationName)"],
                    shortTitle: "Plan Now", systemImageName: "clock")
    }
}
