import AppIntents
import ProductiumCore

/// Siri / Shortcuts / Action button: "Hey Siri, Productium left home",
/// "Tell Productium bio quiz thursday". Input in a few seconds, app unopened.
struct TellProductiumIntent: AppIntent {
    static var title: LocalizedStringResource = "Tell Productium"
    static var description = IntentDescription("Add a deadline, check in, or log how you feel, in plain words.")
    @Parameter(title: "What's new?") var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await AppModel.shared.submit(text)
        let reply = AppModel.shared.toast ?? "Got it."
        return .result(dialog: "\(reply)")
    }
}

enum CheckInPhrase: String, AppEnum {
    case leftHome = "left home", atSchool = "at school", leftSchool = "left school", home = "home"
    case startHomework = "starting homework", finishedHomework = "finished homework"

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Check-in"
    static var caseDisplayRepresentations: [CheckInPhrase: DisplayRepresentation] = [
        .leftHome: "Left home", .atSchool: "At school", .leftSchool: "Left school", .home: "Home",
        .startHomework: "Starting homework", .finishedHomework: "Finished homework",
    ]
}

struct CheckInIntent: AppIntent {
    static var title: LocalizedStringResource = "Check in"
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

struct StartFocusIntent: AppIntent {
    static var title: LocalizedStringResource = "Start focus"
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        let m = AppModel.shared
        if let b = m.state.plan.current(at: Date()), b.isStudy { m.startFocus(b) }
        else if let n = m.state.plan.next(after: Date()), n.isStudy, let item = n.itemId.flatMap({ id in m.state.items.first { $0.id == id } }) {
            m.focusNow(on: item)
        }
        return .result()
    }
}

/// Friction without the Screen Time API (works with free signing): a Shortcuts automation
/// "When Instagram is opened → If [Should I pause?] → Open URL productium://gap".
/// After "I'll go back anyway" there's a 10-min grace window, so returning to the app
/// doesn't loop. Same design as one sec's pause and opt-out (Grüning et al. 2023).
struct ShouldPauseIntent: AppIntent {
    static var title: LocalizedStringResource = "Should I pause?"
    static var description = IntentDescription("True unless you chose to continue in the last few minutes. Use it in an “App is opened” automation.")

    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let d = SharedConfig.defaults
        if Date().timeIntervalSince1970 < d.double(forKey: SharedConfig.Key.frictionGraceUntil) { return .result(value: false) }
        let key = SharedConfig.Key.frictionPrefix + SharedConfig.dayKey()
        d.set(d.integer(forKey: key) + 1, forKey: key)
        return .result(value: true)
    }
}

enum Friction {
    static func grant(minutes: Int = 10) {
        SharedConfig.defaults.set(Date().addingTimeInterval(Double(minutes) * 60).timeIntervalSince1970,
                                  forKey: SharedConfig.Key.frictionGraceUntil)
    }
    static func pausesToday() -> Int {
        SharedConfig.defaults.integer(forKey: SharedConfig.Key.frictionPrefix + SharedConfig.dayKey())
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
    }
}
