import Foundation
import ActivityKit
import AppIntents

/// D5: what the Lock Screen and Dynamic Island show while something is tracked. Compiled into the app and the widget
/// extension; the extension only ever reads it (no App Group, so it gets everything through the activity's state).
struct RunningAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        /// "Health › Exercise"
        var path: String
        var start: Date
        /// "Study 1h 10 of 2h" when a goal covers it.
        var goalLine: String?
    }
    /// The running entry, so a new start replaces the activity instead of updating it.
    var entryId: UUID
}

// The intents below run in the app's process (LiveActivityIntent), so the extension's copies never do any work.

struct StopActivityIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Stop Activity"
    static var description = IntentDescription("Stops whatever is being tracked. Use it from Back Tap, a sticker, or a Focus turning off.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        #if WIDGET_EXTENSION
        return .result(dialog: "Stopped.")
        #else
        AppModel.shared.log(.intent, "StopActivityIntent")
        let title = AppModel.shared.running?.title
        AppModel.shared.stopRunning(source: "intent")
        return .result(dialog: title.map { "Stopped \($0)." } ?? "Nothing was running.")
        #endif
    }
}

struct StartFocusIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Start focus"
    static var description = IntentDescription("Start the block that's on now, or the next one. Try it from an NFC tag on your desk, or when a Focus turns on.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        AppModel.shared.log(.intent, "StartFocusIntent")
        AppModel.shared.startNowOrNext()
        #endif
        return .result()
    }
}
