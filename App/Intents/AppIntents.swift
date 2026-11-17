import AppIntents
import ProductiumCore

struct TellProductiumIntent: AppIntent {
    static var title: LocalizedStringResource = "Tell Productium"
    static var description = IntentDescription("Add a deadline, check in, or log how you feel, in plain words.")
    @Parameter(title: "What's new?") var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await AppModel.shared.dump(text)
        let reply = AppModel.shared.state.conversation.turns.last?.reply ?? "Got it."
        return .result(dialog: "\(reply)")
    }
}

enum CheckInPhrase: String, AppEnum {
    case leftHome = "left home", atSchool = "at school", leftSchool = "left school", home = "home"
    case startHomework = "starting homework", finishedHomework = "finished homework"
    case wokeUp = "woke up", bed = "going to bed"

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Check-in"
    static var caseDisplayRepresentations: [CheckInPhrase: DisplayRepresentation] = [
        .leftHome: "Left home", .atSchool: "At school", .leftSchool: "Left school", .home: "Home",
        .startHomework: "Starting homework", .finishedHomework: "Finished homework",
        .wokeUp: "Woke up", .bed: "Going to bed",
    ]
}

struct CheckInIntent: AppIntent {
    static var title: LocalizedStringResource = "Check in"
    static var description = IntentDescription("Log where you are or what you're starting, so Productium learns your routine. Works well from a Wi-Fi, NFC or alarm automation.")
    @Parameter(title: "Where / what") var phrase: CheckInPhrase

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        AppModel.shared.logMarker(phrase.rawValue, source: .voice)
        return .result(dialog: "Logged.")
    }
}

struct LogMoodIntent: AppIntent {
    static var title: LocalizedStringResource = "Log mood"
    @Parameter(title: "Mood (1–5)", inclusiveRange: (1, 5)) var mood: Int

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        AppModel.shared.logMood(mood, energy: nil, note: nil)
        return .result(dialog: "Thanks. Today's plan has adjusted.")
    }
}

struct StartFocusIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Start focus"
    static var description = IntentDescription("Start the block that's on now, or the next one. Try it from an NFC tag on your desk, or when a Focus turns on.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared.startNowOrNext()
        return .result()
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
        guard Friction.opened(app) else { return .result(value: false) }
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
        .result(value: Friction.opened(app))
    }
}

struct ClosedDistractingAppIntent: AppIntent {
    static var title: LocalizedStringResource = "Closed a Distracting App"
    static var description = IntentDescription("Use it in an “App is closed” automation with the same apps as the pause, and in an “App is opened” automation for the other apps you use (Messages, Safari, Camera…): opening any other app ends the session. Productium counts the minutes and stops the check-ins.")
    @Parameter(title: "App (leave empty for “any”)") var app: String?

    func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        .result(value: Friction.closed(app))
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
        Friction.ended(by: signal.source)
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
        let m = AppModel.shared.state.plan.moment(at: Date())
        return .result(value: m == .windDown || m == .sleep)
    }
}

enum Friction {
    static let graceMinutes = 10

    static var inGrace: Bool {
        Date().timeIntervalSince1970 < SharedConfig.defaults.double(forKey: SharedConfig.Key.frictionGraceUntil)
    }

    static func opened(_ app: String) -> Bool {
        let pause = !inGrace
        let wasOpen = log.open != nil
        let measures = update { $0.opened(app, at: Date(), paused: pause, calendar: .current); return $0.measuresClosing }
        if pause {
            let key = SharedConfig.Key.frictionPrefix + SharedConfig.dayKey()
            SharedConfig.defaults.set(SharedConfig.defaults.integer(forKey: key) + 1, forKey: key)
        } else if measures && !wasOpen {
            scheduleNextCheckIn()
        }
        return pause
    }

    static func grant(minutes: Int = graceMinutes) {
        SharedConfig.defaults.set(Date().addingTimeInterval(Double(minutes) * 60).timeIntervalSince1970,
                                  forKey: SharedConfig.Key.frictionGraceUntil)
        SharedConfig.defaults.set(0, forKey: SharedConfig.Key.scrollCheckInIndex)
        scheduleNextCheckIn()
    }

    @discardableResult
    static func closed(_ app: String? = nil) -> Int {
        let mins = update { $0.closed(app, at: Date()) }
        NotificationService.cancelScrollCheckIns()
        return mins
    }

    static func ended(by source: ScrollSession.EndSource) {
        guard update({ $0.ended(by: source, at: Date()) }) != nil else { return }
        NotificationService.cancelScrollCheckIns()
    }

    static func scheduleNextCheckIn() {
        let steps = checkInMinutes
        let i = SharedConfig.defaults.integer(forKey: SharedConfig.Key.scrollCheckInIndex)
        guard i < steps.count else { return }
        let wait = i == 0 ? steps[0] : steps[i] - steps[i - 1]
        NotificationService.scheduleScrollCheckIn(after: wait, total: steps[i], last: i == steps.count - 1)
        update { $0.checkInSent(at: Date().addingTimeInterval(Double(wait) * 60)) }
        SharedConfig.defaults.set(i + 1, forKey: SharedConfig.Key.scrollCheckInIndex)
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

    static func pausesToday() -> Int {
        SharedConfig.defaults.integer(forKey: SharedConfig.Key.frictionPrefix + SharedConfig.dayKey())
    }

    static var checkInMinutes: [Int] {
        SharedConfig.defaults.array(forKey: SharedConfig.Key.scrollCheckIns) as? [Int] ?? NudgeLevel.standard.scrollCheckIns
    }

    static var log: ScrollLog {
        get {
            guard let d = SharedConfig.defaults.data(forKey: SharedConfig.Key.scrollLog),
                  let l = try? JSONDecoder().decode(ScrollLog.self, from: d) else { return ScrollLog() }
            return l
        }
        set {
            if let d = try? JSONEncoder().encode(newValue) { SharedConfig.defaults.set(d, forKey: SharedConfig.Key.scrollLog) }
        }
    }
}

struct ProductiumShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: TellProductiumIntent(), phrases: ["Tell \(.applicationName)", "Add to \(.applicationName)"],
                    shortTitle: "Tell Productium", systemImageName: "text.bubble")
        AppShortcut(intent: CheckInIntent(), phrases: ["\(.applicationName) \(\.$phrase)", "Check in with \(.applicationName)"],
                    shortTitle: "Check in", systemImageName: "location")
        AppShortcut(intent: LogMoodIntent(), phrases: ["Log mood in \(.applicationName)"], shortTitle: "Log mood", systemImageName: "face.smiling")
        AppShortcut(intent: StartFocusIntent(), phrases: ["Start focus in \(.applicationName)"], shortTitle: "Start focus", systemImageName: "leaf")
        AppShortcut(intent: CurrentPlanIntent(), phrases: ["What's the plan in \(.applicationName)", "What should I do in \(.applicationName)"],
                    shortTitle: "Plan Now", systemImageName: "clock")
    }
}
